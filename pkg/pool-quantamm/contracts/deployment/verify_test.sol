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
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";


contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey;

        bytes memory constructorArgs = abi.encode(
            address(0xdbeb3BF2533B4a529DF4DE222F8A061791E38f8B)  
        );

        console.logBytes(constructorArgs);
        
        vm.stopBroadcast();
    }
}