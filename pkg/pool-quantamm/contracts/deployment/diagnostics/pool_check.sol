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

        address pool = 0xCB78DF4EAd6D9558c19960Cdec71AcA3e37c1087;
        address rule = 0x2B311426f1bFbC69a526162acC308e13750bB61A;
        address updateWeightRunnerAddress = 0xB6b7CCa5E4D3B4DD1a4f52C38f287c7303Db7dA2;

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

        int256[] memory intermediateState = AntiMomentumUpdateRule(rule)
            .getIntermediateGradientState(pool, 2);
        console.logInt(intermediateState[0]);
        console.logInt(intermediateState[1]);


        int256[] memory movingAverages = AntiMomentumUpdateRule(rule)
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
            updateWeightRunnerAddress
        ).getOptimisedPoolOracle(pool);

        console.log("poolOracles");

        for(uint256 i = 0; i < oracles.length; i++) {
            console.log(oracles[i]);
        }

        vm.stopBroadcast();
    }
}
