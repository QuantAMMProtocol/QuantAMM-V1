// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import "../../rules/AntimomentumUpdateRule.sol";
import "../../rules/MomentumUpdateRule.sol";
import "../../rules/DifferenceMomentumUpdateRule.sol";
import "../../rules/ChannelFollowingUpdateRule.sol";
import "../../rules/MinimumVarianceUpdateRule.sol";
import "../../rules/PowerChannelUpdateRule.sol";
import "../../UpdateWeightRunner.sol";
import "../../QuantAMMWeightedPoolFactory.sol";
import "../../ChainlinkOracle.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";


contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey;

        address pool = 0x6663545aF63bC3268785Cf859f0608506759EBe8;

        // Only load the private key if broadcasting (i.e., not dry run)
        if (block.chainid != 11155111) { // Replace 11155111 with the chain ID you're working with (e.g., Sepolia)
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
            vm.startBroadcast(deployerPrivateKey);
        } else {
            // For dry runs, we don't need a private key
            vm.startBroadcast();
        }

        int256[] memory weightsAndMultpliers = new int256[](8);
        weightsAndMultpliers[0] = 0.4901884e18; // weight 0.1e18
        weightsAndMultpliers[1] = 0.4898068e18; // weight 0.3e18
        weightsAndMultpliers[2] = 0.0100024e18; // weight 0.5e18
        weightsAndMultpliers[3] = 0.0100024e18; // weight 0.2e18
        weightsAndMultpliers[4] = -3.612855556e13; // multiplier -3.612855556e13
        weightsAndMultpliers[5] = -1.75747037e13; // multiplier -1.75747037e13
        weightsAndMultpliers[6] = 4.537014815e13; // multiplier 4.537014815e13
        weightsAndMultpliers[7] = 1.759237037e13; // multiplier 1.759237037e13

        uint40 lastInterpolationTimePossible = uint40(block.timestamp) + uint40(10800); // 3 hours

        UpdateWeightRunner(0x26570ad4CC61eA3E944B1c4660416E45796D44b3)
        .setWeightsManually(weightsAndMultpliers, pool, lastInterpolationTimePossible, 4);
                
        vm.stopBroadcast();
    }
}