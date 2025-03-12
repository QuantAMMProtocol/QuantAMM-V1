// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

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

        // Only load the private key if broadcasting (i.e., not dry run)
        if (block.chainid != 11155111) { // Replace 11155111 with the chain ID you're working with (e.g., Sepolia)
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
            vm.startBroadcast(deployerPrivateKey);
        } else {
            // For dry runs, we don't need a private key
            vm.startBroadcast();
        }

        //ETH-USD
        //0x21Ae9576a393413D6d91dFE2543dCb548Dbb8748
        ChainlinkOracle _chainlinkETHUSDOracle = new ChainlinkOracle(0x694AA1769357215DE4FAC081bf1f309aDC325306);

        //0xB8688e8B06682ebef4e8ceAeEc2DAf57fC662f1B
        UpdateWeightRunner _updateWeightRunner = new UpdateWeightRunner(msg.sender, address(_chainlinkETHUSDOracle));
        
        //0x6f2bD10b9b17E80e5BCd49158890561f053Ed2EB
        AntiMomentumUpdateRule _antiMomentum = new AntiMomentumUpdateRule(address(_updateWeightRunner));
        
    }
}