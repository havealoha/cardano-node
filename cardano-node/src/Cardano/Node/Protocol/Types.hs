{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}

module Cardano.Node.Protocol.Types
  ( Protocol(..)
  , SomeConsensusProtocol(..)
  ) where

import qualified Cardano.Api as Api

import           Control.DeepSeq (NFData)
import           Data.Aeson
import           GHC.Generics (Generic)
import           NoThunks.Class (NoThunks)

import           Cardano.Node.Orphans ()
import           Cardano.Node.Queries (HasKESInfo, HasKESMetricsData)
import           Cardano.Node.TraceConstraints (TraceConstraints)


data Protocol = ByronProtocol
              | ShelleyProtocol
              | CardanoProtocol
  deriving (Eq, Generic)

instance Show Protocol where
  show ByronProtocol = "Byron"
  show ShelleyProtocol = "Shelley"
  show CardanoProtocol = "Byron; Shelley"

deriving instance NFData Protocol
deriving instance NoThunks Protocol

instance FromJSON Protocol where
  parseJSON =
    withText "Protocol" $ \str -> case str of

      -- The new names
      "Byron" -> pure ByronProtocol
      "Shelley" -> pure ShelleyProtocol
      "Cardano" -> pure CardanoProtocol

      -- The old names
      "RealPBFT" -> pure ByronProtocol
      "TPraos" -> pure ShelleyProtocol

      _ -> fail $ "Parsing of Protocol failed. "
                <> show str <> " is not a valid protocol"

data SomeConsensusProtocol where

     SomeConsensusProtocol :: forall blk. ( Api.Protocol IO blk
                                          , HasKESMetricsData blk
                                          , HasKESInfo blk
                                          , TraceConstraints blk
                                          )
                           => Api.BlockType blk
                           -> Api.ProtocolInfoArgs blk
                           -> SomeConsensusProtocol
