## Sources:
##   - cardano-ledger/eras/alonzo/impl/src/Cardano/Ledger/Alonzo/Genesis.hs
##   - cardano-api/src/Cardano/Api/ProtocolParameters.hs:toBabbagePParamsUpdate
def cardano_api_pparams_to_geneses(api; desc):
  { epoch:                   1000000
  , description:             desc
  , alonzo:
    (
    { collateralPercentage:  api.collateralPercentage
    , executionPrices:
      { prSteps:
        { numerator:         (api.executionUnitPrices.priceSteps * 10000000)
        , denominator:       10000000
        }
      , prMem:
        { numerator:         (api.executionUnitPrices.priceMemory * 10000)
        , denominator:       10000
        }
      }
    , maxBlockExUnits:
      { exUnitsMem:          50000000
      , exUnitsSteps:        40000000000
      }
    , maxCollateralInputs:   api.maxCollateralInputs
    , maxTxExUnits:
      { exUnitsMem:          10000000
      , exUnitsSteps:        10000000000
      }
    , maxValueSize:          api.maxValueSize
    , coinsPerUTxOByte:      4310
    }
    * if api.utxoCostPerWord == null then {} else
    { lovelacePerUTxOWord:   api.utxoCostPerWord
    } end
    * if api.minUTxOValue == null then {} else
    { minUTxOValue:          api.minUTxOValue
    } end
    )
  , shelley:
    (
    { maxBlockBodySize:      api.maxBlockBodySize
    , maxBlockHeaderSize:    api.maxBlockHeaderSize
    , maxTxSize:             api.maxTxSize
    , minPoolCost:           api.minPoolCost
    , minUTxOValue:          api.minUTxOValue
    , rho:                   0
    , a0:                    0
    , eMax:                  api.poolRetireMaxEpoch
    , protocolVersion:       api.protocolVersion
    , keyDeposit:            0
    , poolDeposit:           0
    , nOpt:                  51
    , tau:                   0
    , minFeeB:               0
    , minFeeA:               1
    }
    * if api.decentralisation == null then {} else
    { decentralisationParam: api.decentralisation
    } end
    * if api.extraPraosEntropy == null then {} else
    { extraEntropy:          api.extraPraosEntropy
    } end
    )
  , costModels:
    { PlutusV1:              api.costModels.PlutusScriptV1
    , PlutusV2:              api.costModels.PlutusScriptV2
    }
  };
