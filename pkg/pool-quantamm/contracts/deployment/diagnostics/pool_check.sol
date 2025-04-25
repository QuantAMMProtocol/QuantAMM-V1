// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/console.sol"; // Import the console library for logging
import { Script } from "forge-std/Script.sol";
import "@openzeppelin//contracts/utils/Strings.sol";
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
    using Strings for uint256;
    using Strings for uint64;
    using Strings for uint40;

    function run() external {
        uint256 deployerPrivateKey;

        // For dry runs, we don't need a private key
        vm.startBroadcast();

        address pool = 0x9D430BFE48f2FCFd9a3964987144Eee2d7d5b4E9;
        address rule = 0x62B9eC6A5BBEBe4F5C5f46C8A8880df857004295;
        address updateWeightRunnerAddress = 0x21Ae9576a393413D6d91dFE2543dCb548Dbb8748;

        IQuantAMMWeightedPool.QuantAMMWeightedPoolDynamicData memory weights = QuantAMMWeightedPool(pool)
            .getQuantAMMWeightedPoolDynamicData();

        console.log("Total Supply");
        console.logUint(weights.totalSupply);
        console.log(weights.totalSupply.toString());

        console.log("Is Pool Initialized");
        console.log(weights.isPoolInitialized);

        console.log("Is Pool Paused");
        console.log(weights.isPoolPaused);

        console.log("Is Pool In Recovery Mode");
        console.log(weights.isPoolInRecoveryMode);

        IQuantAMMWeightedPool.QuantAMMWeightedPoolImmutableData memory immutableData = QuantAMMWeightedPool(pool)
            .getQuantAMMWeightedPoolImmutableData();

        console.log("Oracle Staleness Threshold");
        console.logUint(immutableData.oracleStalenessThreshold);
        console.log(immutableData.oracleStalenessThreshold.toString());

        console.log("Pool Registry");
        console.logUint(immutableData.poolRegistry);
        console.log(immutableData.poolRegistry.toString());

        console.log("Epsilon Max");
        console.logUint(immutableData.epsilonMax);
        console.log(immutableData.epsilonMax.toString());

        console.log("Absolute Weight Guard Rail");
        console.logUint(immutableData.absoluteWeightGuardRail);
        console.log(immutableData.absoluteWeightGuardRail.toString());

        console.log("Update Interval");
        console.logUint(immutableData.updateInterval);
        console.log(immutableData.updateInterval.toString());

        console.log("Max Trade Size Ratio");
        console.logUint(immutableData.maxTradeSizeRatio);
        console.log(immutableData.maxTradeSizeRatio.toString());

        console.log("Tokens");
        for (uint256 i = 0; i < immutableData.tokens.length; i++) {
            console.log(address(immutableData.tokens[i]));
        }

        console.log("Lambda");
        for (uint256 i = 0; i < immutableData.lambda.length; i++) {
            console.logUint(immutableData.lambda[i]);
            console.log(immutableData.lambda[i].toString());
        }

        console.log("Rule Parameters");
        for (uint256 i = 0; i < immutableData.ruleParameters.length; i++) {
            for (uint256 j = 0; j < immutableData.ruleParameters[i].length; j++) {
                console.logInt(immutableData.ruleParameters[i][j]);
                if (immutableData.ruleParameters[i][j] < 0) {
                    console.log(string.concat("-", uint256(-immutableData.ruleParameters[i][j]).toString()));
                } else {
                    console.log(uint256(immutableData.ruleParameters[i][j]).toString());
                }
            }
        }
        console.log("Balances Live Scaled 18");
        for (uint256 i = 0; i < weights.balancesLiveScaled18.length; i++) {
            console.logInt(int256(weights.balancesLiveScaled18[i]));
            console.log(weights.balancesLiveScaled18[i].toString());
        }

        console.log("weights and multipliers");
        for (uint256 i = 0; i < weights.firstFourWeightsAndMultipliers.length; i++) {
            console.logInt(int256(weights.firstFourWeightsAndMultipliers[i]));
            if (weights.firstFourWeightsAndMultipliers[i] < 0) {
                console.log(string.concat("-", uint256(-weights.firstFourWeightsAndMultipliers[i]).toString()));
            } else {
                console.log(uint256(weights.firstFourWeightsAndMultipliers[i]).toString());
            }
        }

        uint256[] memory weightsAndMultipliers = QuantAMMWeightedPool(pool).getNormalizedWeights();

        console.log("normalized weights");
        for (uint256 i = 0; i < weightsAndMultipliers.length; i++) {
            console.logInt(int256(weightsAndMultipliers[i]));
            console.log(weightsAndMultipliers[i].toString());
        }

        console.log("intermediate state");

        int256[] memory intermediateState = PowerChannelUpdateRule(rule).getIntermediateGradientState(pool, 3);
        for (uint256 i = 0; i < intermediateState.length; i++) {
            console.logInt(intermediateState[i]);
            if (intermediateState[i] < 0) {
                console.log(string.concat("-", uint256(-intermediateState[i]).toString()));
            } else {
                console.log(uint256(intermediateState[i]).toString());
            }
        }
        
        int256[] memory movingAverages = PowerChannelUpdateRule(rule)
                    .getMovingAverages(pool, 3);
        console.log("movingAverages");
        for (uint256 i = 0; i < movingAverages.length; i++) {
            console.logInt(int256(movingAverages[i]));
            if (movingAverages[i] < 0) {
                console.log(string.concat("-", uint256(-movingAverages[i]).toString()));
            } else {
                console.log(uint256(movingAverages[i]).toString());
            }
        }

        console.log("last update time");
        console.logUint(uint256(weights.lastInteropTime));
        console.log(weights.lastInteropTime.toString());
        console.logUint(uint256(weights.lastUpdateTime));
        console.log(weights.lastUpdateTime.toString());

        address[] memory oracles = UpdateWeightRunner(updateWeightRunnerAddress).getOptimisedPoolOracle(pool);

        console.log("poolOracles");

        for (uint256 i = 0; i < oracles.length; i++) {
            console.log(oracles[i]);
        }

        console.log("approved permissions");
        uint256 registry = UpdateWeightRunner(updateWeightRunnerAddress).getPoolApprovedActions(pool);
        console.logUint(registry);
        console.log(registry.toString());

        vm.stopBroadcast();
    }
}
