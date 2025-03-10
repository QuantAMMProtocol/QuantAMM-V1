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
        
        //0x8905b91b301677e674cF964Fbc4Ac3844EF79620
        MomentumUpdateRule _momentum = new MomentumUpdateRule(address(_updateWeightRunner));
        
        //0x4FFE46130bCBb16BF5EDc4bBaa06f158921764C2
        DifferenceMomentumUpdateRule _difMomentum = new DifferenceMomentumUpdateRule(address(_updateWeightRunner));
        
        //0x62B9eC6A5BBEBe4F5C5f46C8A8880df857004295
        ChannelFollowingUpdateRule _channelFollow = new ChannelFollowingUpdateRule(address(_updateWeightRunner));
        
        //0xD5c43063563f9448cE822789651662cA7DcD5773
        MinimumVarianceUpdateRule _minVariance = new MinimumVarianceUpdateRule(address(_updateWeightRunner));
        
        //0x79F57AB6523EdC139F7f21F024f78b2738eE99bf
        PowerChannelUpdateRule _powerChannel = new PowerChannelUpdateRule(address(_updateWeightRunner));
    
        //0x502c0B3C0c4f781c98Cd46274bc2Ca5306eAFBB4
       QuantAMMWeightedPoolFactory _factory = new QuantAMMWeightedPoolFactory(IVault(0xbA1333333333a1BA1108E8412f11850A5C319bA9), 604800, "0.1", "0.1", address(_updateWeightRunner));
       // 
       // //BTC-USD
       //0x0947b79A24Ce1Db26227c1d3D9955E8c751f291B
       ChainlinkOracle _chainlinkBTCUSDOracle = new ChainlinkOracle(0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43);

       ////USDC-USD
       //0x4c4108B7a2999f2811cF798f829cE25A5E648E98
       ChainlinkOracle _chainlinkUSDCUSDOracle = new ChainlinkOracle(0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E);

        vm.stopBroadcast();
    }
}