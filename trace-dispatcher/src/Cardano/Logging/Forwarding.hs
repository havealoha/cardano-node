{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Logging.Forwarding
  (
    initForwarding
  ) where

import           Codec.CBOR.Term (Term)
import           Control.Concurrent.Async (async, race_, wait)
import           Control.Monad (void)
import           Control.Monad.IO.Class

import           "contra-tracer" Control.Tracer (Tracer, contramap, nullTracer, stdoutTracer)
import qualified Data.ByteString.Lazy as LBS
import           Data.Void (Void)
import           Data.Word (Word16)

import           Ouroboros.Network.Driver.Limits (ProtocolTimeLimits)
import           Ouroboros.Network.ErrorPolicy (nullErrorPolicies)
import           Ouroboros.Network.IOManager (IOManager)
import           Ouroboros.Network.Magic (NetworkMagic)
import           Ouroboros.Network.Mux (MiniProtocol (..), MiniProtocolLimits (..),
                   MiniProtocolNum (..), MuxMode (..), OuroborosApplication (..),
                   RunMiniProtocol (..), miniProtocolLimits, miniProtocolNum, miniProtocolRun)
import           Ouroboros.Network.Protocol.Handshake.Codec (cborTermVersionDataCodec,
                   codecHandshake, noTimeLimitsHandshake)
import           Ouroboros.Network.Protocol.Handshake.Type (Handshake)
import           Ouroboros.Network.Protocol.Handshake.Version (acceptableVersion,
                   queryVersion, simpleSingletonVersions)
import           Ouroboros.Network.Snocket (Snocket, MakeBearer, localAddressFromPath, localSnocket,
                   makeLocalBearer)
import           Ouroboros.Network.Socket (AcceptedConnectionsLimit (..), HandshakeCallbacks (..),
                   SomeResponderApplication (..), cleanNetworkMutableState, connectToNode,
                   newNetworkMutableState, nullNetworkConnectTracers, nullNetworkServerTracers,
                   withServerNode)

import qualified System.Metrics as EKG
import qualified System.Metrics.Configuration as EKGF
import           System.Metrics.Network.Forwarder
import qualified Trace.Forward.Configuration.DataPoint as DPF
import qualified Trace.Forward.Configuration.TraceObject as TF
import           Trace.Forward.Run.DataPoint.Forwarder
import           Trace.Forward.Run.TraceObject.Forwarder
import           Trace.Forward.Utils.DataPoint
import           Trace.Forward.Utils.TraceObject

import           Cardano.Logging.Types
import           Cardano.Logging.Utils (runInLoop)
import           Cardano.Logging.Version

initForwarding :: forall m. (MonadIO m)
  => IOManager
  -> TraceOptionForwarder
  -> NetworkMagic
  -> Maybe EKG.Store
  -> Maybe (FilePath, ForwarderMode)
  -> m (ForwardSink TraceObject, DataPointStore)
initForwarding iomgr config magic ekgStore tracerSocketMode = liftIO $ do
  forwardSink <- initForwardSink tfConfig
  dpStore <- initDataPointStore
  launchForwarders
    iomgr
    magic
    ekgConfig
    tfConfig
    dpfConfig
    ekgStore
    forwardSink
    dpStore
    tracerSocketMode
  pure (forwardSink, dpStore)
 where
  p = maybe "" fst tracerSocketMode
  connSize = tofConnQueueSize config
  disconnSize = tofDisconnQueueSize config
  verbosity = tofVerbosity config

  ekgConfig :: EKGF.ForwarderConfiguration
  ekgConfig =
    EKGF.ForwarderConfiguration
      { EKGF.forwarderTracer    = mkTracer verbosity
      , EKGF.acceptorEndpoint   = EKGF.LocalPipe p
      , EKGF.reConnectFrequency = 1.0
      , EKGF.actionOnRequest    = const $ pure ()
      }

  tfConfig :: TF.ForwarderConfiguration TraceObject
  tfConfig =
    TF.ForwarderConfiguration
      { TF.forwarderTracer       = mkTracer verbosity
      , TF.acceptorEndpoint      = p
      , TF.disconnectedQueueSize = disconnSize
      , TF.connectedQueueSize    = connSize
      }

  dpfConfig :: DPF.ForwarderConfiguration
  dpfConfig =
    DPF.ForwarderConfiguration
      { DPF.forwarderTracer  = mkTracer verbosity
      , DPF.acceptorEndpoint = p
      }

  mkTracer :: Show a => Verbosity -> Tracer IO a
  mkTracer Maximum = contramap show stdoutTracer
  mkTracer Minimum = nullTracer

launchForwarders
  :: IOManager
  -> NetworkMagic
  -> EKGF.ForwarderConfiguration
  -> TF.ForwarderConfiguration TraceObject
  -> DPF.ForwarderConfiguration
  -> Maybe EKG.Store
  -> ForwardSink TraceObject
  -> DataPointStore
  -> Maybe (FilePath, ForwarderMode)
  -> IO ()
launchForwarders iomgr magic
                 ekgConfig tfConfig dpfConfig
                 ekgStore sink dpStore tracerSocketMode =
  -- If 'tracerSocketMode' is not specified, it's impossible to establish
  -- network connection with acceptor application (for example, 'cardano-tracer').
  -- In this case, we should not lauch forwarders.
  case tracerSocketMode of
    Nothing -> return ()
    Just (socketPath, mode) ->
      void . async $
        runInLoop
          (launchForwardersViaLocalSocket
             iomgr
             magic
             ekgConfig
             tfConfig
             dpfConfig
             sink
             ekgStore
             dpStore
             socketPath
             mode)
          socketPath 1

launchForwardersViaLocalSocket
  :: IOManager
  -> NetworkMagic
  -> EKGF.ForwarderConfiguration
  -> TF.ForwarderConfiguration TraceObject
  -> DPF.ForwarderConfiguration
  -> ForwardSink TraceObject
  -> Maybe EKG.Store
  -> DataPointStore
  -> FilePath
  -> ForwarderMode
  -> IO ()
launchForwardersViaLocalSocket
  iomgr magic ekgConfig tfConfig dpfConfig sink ekgStore dpStore p mode =
  (case mode of
     Initiator -> doConnectToAcceptor magic (localSnocket iomgr) makeLocalBearer mempty
     Responder -> doListenToAcceptor magic (localSnocket iomgr) makeLocalBearer mempty)
  (localAddressFromPath p)
  noTimeLimitsHandshake ekgConfig tfConfig dpfConfig sink ekgStore dpStore

doConnectToAcceptor
  :: NetworkMagic
  -> Snocket IO fd addr
  -> MakeBearer IO fd
  -> (fd -> IO ())
  -> addr
  -> ProtocolTimeLimits (Handshake ForwardingVersion Term)
  -> EKGF.ForwarderConfiguration
  -> TF.ForwarderConfiguration TraceObject
  -> DPF.ForwarderConfiguration
  -> ForwardSink TraceObject
  -> Maybe EKG.Store
  -> DataPointStore
  -> IO ()
doConnectToAcceptor magic snocket makeBearer configureSocket address timeLimits
                    ekgConfig tfConfig dpfConfig sink ekgStore dpStore = do
  connectToNode
    snocket
    makeBearer
    configureSocket
    (codecHandshake forwardingVersionCodec)
    timeLimits
    (cborTermVersionDataCodec forwardingCodecCBORTerm)
    nullNetworkConnectTracers
    (HandshakeCallbacks acceptableVersion queryVersion)
    (simpleSingletonVersions
       ForwardingV_1
       (ForwardingVersionData magic)
       (forwarderApp [ (forwardEKGMetricsRun,                      1)
                     , (forwardTraceObjectsInit tfConfig  sink,    2)
                     , (forwardDataPointsInit   dpfConfig dpStore, 3)
                     ]
       )
    )
    Nothing
    address
 where
  forwarderApp
    :: [(RunMiniProtocol 'InitiatorMode initiatorCtx responderCtx LBS.ByteString IO () Void, Word16)]
    -> OuroborosApplication 'InitiatorMode initiatorCtx responderCtx LBS.ByteString IO () Void
  forwarderApp protocols =
    OuroborosApplication
      [ MiniProtocol
         { miniProtocolNum    = MiniProtocolNum num
         , miniProtocolLimits = MiniProtocolLimits { maximumIngressQueue = maxBound }
         , miniProtocolRun    = prot
         }
      | (prot, num) <- protocols
      ]

  forwardEKGMetricsRun =
    case ekgStore of
      Just store -> forwardEKGMetrics ekgConfig store
      Nothing -> forwardEKGMetricsDummy

doListenToAcceptor
  :: Ord addr
  => NetworkMagic
  -> Snocket IO fd addr
  -> MakeBearer IO fd
  -> (fd -> addr -> IO ())
  -> addr
  -> ProtocolTimeLimits (Handshake ForwardingVersion Term)
  -> EKGF.ForwarderConfiguration
  -> TF.ForwarderConfiguration TraceObject
  -> DPF.ForwarderConfiguration
  -> ForwardSink TraceObject
  -> Maybe EKG.Store
  -> DataPointStore
  -> IO ()
doListenToAcceptor magic snocket makeBearer configureSocket address timeLimits
                   ekgConfig tfConfig dpfConfig sink ekgStore dpStore = do
  networkState <- newNetworkMutableState
  race_ (cleanNetworkMutableState networkState)
        $ withServerNode
            snocket
            makeBearer
            configureSocket
            nullNetworkServerTracers
            networkState
            (AcceptedConnectionsLimit maxBound maxBound 0)
            address
            (codecHandshake forwardingVersionCodec)
            timeLimits
            (cborTermVersionDataCodec forwardingCodecCBORTerm)
            (HandshakeCallbacks acceptableVersion queryVersion)
            (simpleSingletonVersions
               ForwardingV_1
               (ForwardingVersionData magic)
               (SomeResponderApplication $
                 forwarderApp [ (forwardEKGMetricsRespRun,                  1)
                              , (forwardTraceObjectsResp tfConfig  sink,    2)
                              , (forwardDataPointsResp   dpfConfig dpStore, 3)
                              ]
               )
            )
            nullErrorPolicies
            $ \_ serverAsync ->
              wait serverAsync -- Block until async exception.
 where
  forwarderApp
    :: [(RunMiniProtocol 'ResponderMode initiatorCtx responderCtx LBS.ByteString IO Void (), Word16)]
    -> OuroborosApplication 'ResponderMode initiatorCtx responderCtx LBS.ByteString IO Void ()
  forwarderApp protocols =
    OuroborosApplication
      [ MiniProtocol
         { miniProtocolNum    = MiniProtocolNum num
         , miniProtocolLimits = MiniProtocolLimits { maximumIngressQueue = maxBound }
         , miniProtocolRun    = prot
         }
      | (prot, num) <- protocols
      ]

  forwardEKGMetricsRespRun =
    case ekgStore of
      Just store -> forwardEKGMetricsResp ekgConfig store
      Nothing -> forwardEKGMetricsRespDummy
