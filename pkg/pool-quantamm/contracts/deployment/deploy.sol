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
         ChainlinkOracle _chainlinkETHUSDOracle = new ChainlinkOracle(0x694AA1769357215DE4FAC081bf1f309aDC325306);

         UpdateWeightRunner _updateWeightRunner = new UpdateWeightRunner(msg.sender, address(_chainlinkETHUSDOracle));
         
         AntiMomentumUpdateRule _antiMomentum = new AntiMomentumUpdateRule(address(_updateWeightRunner));
         MomentumUpdateRule _momentum = new MomentumUpdateRule(address(_updateWeightRunner));
         DifferenceMomentumUpdateRule _difMomentum = new DifferenceMomentumUpdateRule(address(_updateWeightRunner));
         ChannelFollowingUpdateRule _channelFollow = new ChannelFollowingUpdateRule(address(_updateWeightRunner));
         MinimumVarianceUpdateRule _minVariance = new MinimumVarianceUpdateRule(address(_updateWeightRunner));
         PowerChannelUpdateRule _powerChannel = new PowerChannelUpdateRule(address(_updateWeightRunner));
        
         QuantAMMWeightedPoolFactory _factory = new QuantAMMWeightedPoolFactory(IVault(0xbA1333333333a1BA1108E8412f11850A5C319bA9), 604800, "0.1", "0.1", address(_updateWeightRunner));
         
         //BTC-USD
         ChainlinkOracle _chainlinkBTCUSDOracle = new ChainlinkOracle(0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43);

        //USDC-USD
        ChainlinkOracle _chainlinkUSDCUSDOracle = new ChainlinkOracle(0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E);

        vm.stopBroadcast();
    }
}