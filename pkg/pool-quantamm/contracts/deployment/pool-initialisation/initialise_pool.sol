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

import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey;

        // For dry runs, we don't need a private key
        vm.startBroadcast();

        IERC20[] memory tokenAddresses = new IERC20[](4);
        tokenAddresses[0] = IERC20(0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38);
        tokenAddresses[1] = IERC20(0x29219dd400f2Bf60E5a23d13Be72B486D4038894);
        tokenAddresses[2] = IERC20(0x50c42dEAcD8Fc9773493ED674b675bE577f2634b);
        tokenAddresses[3] = IERC20(0xBb30e76d9Bb2CC9631F7fC5Eb8e87B5Aff32bFbd);

        IPermit2 permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3); // Permit2 contract address

        IERC20(tokenAddresses[0]).approve(address(permit2), type(uint256).max);
        IERC20(tokenAddresses[1]).approve(address(permit2), type(uint256).max);
        IERC20(tokenAddresses[2]).approve(address(permit2), type(uint256).max);
        IERC20(tokenAddresses[3]).approve(address(permit2), type(uint256).max);

        // Approve token 0 using Permit2
        permit2.approve(
            address(tokenAddresses[0]),
            0x93db4682A40721e7c698ea0a842389D10FA8Dae5, // The contract that will spend tokens
            uint160(type(uint256).max), // Amount to approve
            uint48(block.timestamp + 24 hours) // Expiry: 24 hours from now
        );

        // Approve token 1 using Permit2
        permit2.approve(
            address(tokenAddresses[1]),
            0x93db4682A40721e7c698ea0a842389D10FA8Dae5, // The contract that will spend tokens
            uint160(type(uint256).max), // Amount to approve
            uint48(block.timestamp + 24 hours) // Expiry: 24 hours from now
        );

        // Approve token 1 using Permit2
        permit2.approve(
            address(tokenAddresses[2]),
            0x93db4682A40721e7c698ea0a842389D10FA8Dae5, // The contract that will spend tokens
            uint160(type(uint256).max), // Amount to approve
            uint48(block.timestamp + 24 hours) // Expiry: 24 hours from now
        );

        // Approve token 1 using Permit2
        permit2.approve(
            address(tokenAddresses[3]),
            0x93db4682A40721e7c698ea0a842389D10FA8Dae5, // The contract that will spend tokens
            uint160(type(uint256).max), // Amount to approve
            uint48(block.timestamp + 24 hours) // Expiry: 24 hours from now
        );

        uint256[] memory weights = new uint256[](4);
        weights[0] = uint256(1e17);
        weights[1] = uint256(0.6e6);
        weights[2] = uint256(0.0002e18);
        weights[3] = uint256(0.000006e8);

        //IVault(0xbA1333333333a1BA1108E8412f11850A5C319bA9).sendTo(IERC20(0xff34b3d4aee8ddcd6f9afffb6fe49bd371b8a357), msg.sender, uint256(1));
        //IVault(0xbA1333333333a1BA1108E8412f11850A5C319bA9).sendTo(IERC20(0x29f2D40B0605204364af54EC677bD022dA425d03), msg.sender, uint256(1));
        uint256 amountIn = IRouter(0x93db4682A40721e7c698ea0a842389D10FA8Dae5).initialize(
            0xe40b5d08f4baC11dc93B7302FE0870B77C1B9E99,
            tokenAddresses,
            weights,
            0,
            false,
            bytes("")
        );

        vm.stopBroadcast();
    }
}
