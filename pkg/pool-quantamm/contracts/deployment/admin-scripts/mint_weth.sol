// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

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
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

interface IWETH {
    function deposit() external payable;
}

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

        IWETH(0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9).deposit{ value: 5000000000000000000 }();

        vm.stopBroadcast();
    }
}
