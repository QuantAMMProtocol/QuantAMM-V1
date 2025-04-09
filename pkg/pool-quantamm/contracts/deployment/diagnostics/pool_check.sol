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

        address pool = 0x7E7AAbC766aD4079257c88d41B9E95B0dd48c2C3;

        IQuantAMMWeightedPool.QuantAMMWeightedPoolDynamicData memory weights = QuantAMMWeightedPool(
            pool
        ).getQuantAMMWeightedPoolDynamicData();

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

        int256[] memory intermediateState = AntiMomentumUpdateRule(0x5104f2e6CB97334cD3c1BD000fAe871d77B66D15)
            .getIntermediateGradientState(pool, 2);
        console.logInt(intermediateState[0]);
        console.logInt(intermediateState[1]);


        int256[] memory movingAverages = AntiMomentumUpdateRule(0x5104f2e6CB97334cD3c1BD000fAe871d77B66D15)
            .getMovingAverages(pool, 2);
        console.logInt(intermediateState[0]);
        console.logInt(intermediateState[1]);

        console.log("movingAverages");
        for (uint256 i = 0; i < movingAverages.length; i++) {
            console.logInt(int256(movingAverages[i]));
        }

        console.log("last update time");
        console.logUint(uint256(weights.lastInteropTime));
        console.logUint(uint256(weights.lastUpdateTime));

        address[] memory oracles = UpdateWeightRunner(
            0xc840e742C9CC87F08C14537C6b6515cD952AC789
        ).getOptimisedPoolOracle(pool);

        console.log("poolOracles");

        for(uint256 i = 0; i < oracles.length; i++) {
            console.log(oracles[i]);
        }

        vm.stopBroadcast();
    }
}
