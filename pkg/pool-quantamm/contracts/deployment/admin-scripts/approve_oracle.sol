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

        // Only load the private key if broadcasting (i.e., not dry run)
        if (block.chainid != 11155111) { // Replace 11155111 with the chain ID you're working with (e.g., Sepolia)
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
            vm.startBroadcast(deployerPrivateKey);
        } else {
            // For dry runs, we don't need a private key
            vm.startBroadcast();
        }

        UpdateWeightRunner(0xCf70bf72e52c60D4B378F302c3798fdd7247709a).addOracle(OracleWrapper(0xdA841aEEE267b4607f8F0F3622e99060D64644EF));
        UpdateWeightRunner(0xCf70bf72e52c60D4B378F302c3798fdd7247709a).addOracle(OracleWrapper(0x809CEbbb376A97D175570b5c71ED2a219ACd6f21));
        UpdateWeightRunner(0xCf70bf72e52c60D4B378F302c3798fdd7247709a).addOracle(OracleWrapper(0xb71a9eeD4Ae116A1a9600F4B1d045F2eb91Ba66A));
        
        vm.stopBroadcast();
    }
}