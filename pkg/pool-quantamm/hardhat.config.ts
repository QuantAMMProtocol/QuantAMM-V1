import '@nomicfoundation/hardhat-ethers';
import '@nomicfoundation/hardhat-toolbox';
import '@typechain/hardhat';

import 'hardhat-ignore-warnings';
import 'hardhat-gas-reporter';

import { hardhatBaseConfig } from '@balancer-labs/v3-common';

const optimizerSteps =
  'dhfoDgvulfnTUtnIf [ xa[r]EscLM cCTUtTOntnfDIul Lcul Vcul [j] Tpeul xa[rul] xa[r]cL gvif CTUca[r]LSsTFOtfDnca[r]Iulc ] jmul[jul] VcTOcul jmul : fDnTOcmu';

export default {
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true,
    },
  },
  solidity: {
    compilers: hardhatBaseConfig.compilers,
    overrides: {
      'contracts/QuantAMMWeightedPool.sol': {
        version: '0.8.26',
        settings: {
          viaIR: true,
          evmVersion: 'cancun',
          optimizer: {
            enabled: true,
            runs: 500,
            details: {
              yulDetails: {
                optimizerSteps,
              },
            },
          },
        },
      },
      'contracts/QuantAMMWeightedPoolFactory.sol': {
        version: '0.8.26',
        settings: {
          viaIR: true,
          evmVersion: 'cancun',
          optimizer: {
            enabled: true,
            runs: 500,
            details: {
              yulDetails: {
                optimizerSteps,
              },
            },
          },
        },
      },
    },
  },
  warnings: hardhatBaseConfig.warnings,
};
