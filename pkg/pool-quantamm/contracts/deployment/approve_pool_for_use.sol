// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/console.sol";  // Import the console library for logging
import {Script} from "forge-std/Script.sol";
import "../rules/AntimomentumUpdateRule.sol";
import "../rules/MomentumUpdateRule.sol";
import "../rules/DifferenceMomentumUpdateRule.sol";
import "../rules/ChannelFollowingUpdateRule.sol";
import "../rules/MinimumVarianceUpdateRule.sol";
import "../rules/PowerChannelUpdateRule.sol";
import "../UpdateWeightRunner.sol";
import "../QuantAMMWeightedPoolFactory.sol";
import "../ChainlinkOracle.sol";
import { IRouter } from "@balancer-labs/v3-interfaces/contracts/vault/IRouter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey;

        // Only load the private key if broadcasting (i.e., not dry run)
        if (block.chainid != 11155111) { // Replace 11155111 with the chain ID you're working with (e.g., Sepolia)
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
            vm.startBroadcast(deployerPrivateKey);
        } else {
            // For dry runs, we don't need a private key
            vm.startBroadcast();
        }

        UpdateWeightRunner(0xc840e742C9CC87F08C14537C6b6515cD952AC789).setApprovedActionsForPool(0x7E7AAbC766aD4079257c88d41B9E95B0dd48c2C3, uint256(19));
        
        vm.stopBroadcast();
    }
}