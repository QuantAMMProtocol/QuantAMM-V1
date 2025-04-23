// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/console.sol"; // Import the console library for logging
import { Script } from "forge-std/Script.sol";
import "../../rules/AntimomentumUpdateRule.sol";
import "../../rules/MomentumUpdateRule.sol";
import "../../rules/DifferenceMomentumUpdateRule.sol";
import "../../rules/ChannelFollowingUpdateRule.sol";
import "../../rules/MinimumVarianceUpdateRule.sol";
import "../../rules/PowerChannelUpdateRule.sol";
import "../../UpdateWeightRunner.sol";
import "../../QuantAMMWeightedPoolFactory.sol";
import "../../ChainlinkOracle.sol";
import { IRouter } from "@balancer-labs/v3-interfaces/contracts/vault/IRouter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IQuantAMMWeightedPool } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IQuantAMMWeightedPool.sol";

import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey;

        // Only load the private key if broadcasting (i.e., not dry run)
        if (block.chainid != 11155111) {
            // Replace 11155111 with the chain ID you're working with (e.g., Sepolia)
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
            vm.startBroadcast(deployerPrivateKey);
        } else {
            // For dry runs, we don't need a private key
            vm.startBroadcast();
        }

        address pool = 0x5C427119ad1676d08e8cbaB2BcAEfe9ce334A29c
;
        address rule = 0xb7Fe8caBBA9B05f59da643748ba725564aE496C1;
        address updateWeightRunnerAddress = 0x4397d0D8dCc24a5A6a007B768a1CFB45bF37267D;

        IQuantAMMWeightedPool.QuantAMMWeightedPoolDynamicData memory weights = QuantAMMWeightedPool(
            pool
        ).getQuantAMMWeightedPoolDynamicData();

        console.log("Total Supply");
        console.logUint(weights.totalSupply);

        console.log("Is Pool Initialized");
        console.log(weights.isPoolInitialized);

        console.log("Is Pool Paused");
        console.log(weights.isPoolPaused);

        console.log("Is Pool In Recovery Mode");
        console.log(weights.isPoolInRecoveryMode);
        IQuantAMMWeightedPool.QuantAMMWeightedPoolImmutableData memory immutableData = QuantAMMWeightedPool(
            pool
        ).getQuantAMMWeightedPoolImmutableData();

        console.log("Oracle Staleness Threshold");
        console.logUint(immutableData.oracleStalenessThreshold);

        console.log("Pool Registry");
        console.logUint(immutableData.poolRegistry);

        console.log("Epsilon Max");
        console.logUint(immutableData.epsilonMax);

        console.log("Absolute Weight Guard Rail");
        console.logUint(immutableData.absoluteWeightGuardRail);

        console.log("Update Interval");
        console.logUint(immutableData.updateInterval);

        console.log("Max Trade Size Ratio");
        console.logUint(immutableData.maxTradeSizeRatio);

        console.log("Tokens");
        for (uint256 i = 0; i < immutableData.tokens.length; i++) {
            console.log(address(immutableData.tokens[i]));
        }

        console.log("Lambda");
        for (uint256 i = 0; i < immutableData.lambda.length; i++) {
            console.logUint(immutableData.lambda[i]);
        }

        console.log("Rule Parameters");
        for (uint256 i = 0; i < immutableData.ruleParameters.length; i++) {
            for (uint256 j = 0; j < immutableData.ruleParameters[i].length; j++) {
            console.logInt(immutableData.ruleParameters[i][j]);
            }
        }
        console.log("Balances Live Scaled 18");
        for (uint256 i = 0; i < weights.balancesLiveScaled18.length; i++) {
            console.logInt(int256(weights.balancesLiveScaled18[i]));
        }

        console.log("weights and multipliers");
        for (uint256 i = 0; i < weights.firstFourWeightsAndMultipliers.length; i++) {
            console.logInt(int256(weights.firstFourWeightsAndMultipliers[i]));
        }

        uint256[] memory weightsAndMultipliers = QuantAMMWeightedPool(
            pool
        ).getNormalizedWeights();

        console.log("normalized weights");
        for(uint256 i = 0; i < weightsAndMultipliers.length; i++) {
            console.logInt(int256(weightsAndMultipliers[i]));
        }

        console.log("intermediate state");

        int256[] memory intermediateState = PowerChannelUpdateRule(rule)
            .getIntermediateGradientState(pool, 3);
        console.logInt(intermediateState[0]);
        console.logInt(intermediateState[1]);
        console.logInt(intermediateState[2]);


        int256[] memory movingAverages = PowerChannelUpdateRule(rule)
            .getMovingAverages(pool, 3);
        console.logInt(intermediateState[0]);
        console.logInt(intermediateState[1]);
        console.logInt(intermediateState[2]);

        console.log("movingAverages");
        for (uint256 i = 0; i < movingAverages.length; i++) {
            console.logInt(int256(movingAverages[i]));
        }

        console.log("last update time");
        console.logUint(uint256(weights.lastInteropTime));
        console.logUint(uint256(weights.lastUpdateTime));

        address[] memory oracles = UpdateWeightRunner(
            updateWeightRunnerAddress
        ).getOptimisedPoolOracle(pool);

        console.log("poolOracles");

        for(uint256 i = 0; i < oracles.length; i++) {
            console.log(oracles[i]);
        }

        console.log("approved permissions");
        uint256 registry = UpdateWeightRunner(updateWeightRunnerAddress)
            .getPoolApprovedActions(pool);
        console.logUint(registry);

        vm.stopBroadcast();
    }
}
