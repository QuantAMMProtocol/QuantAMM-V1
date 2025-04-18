// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/console.sol";  // Import the console library for logging
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

        IERC20[] memory tokenAddresses = new IERC20[](4);
        tokenAddresses[0] = IERC20(0x29f2D40B0605204364af54EC677bD022dA425d03);
        tokenAddresses[1] = IERC20(0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9);
        tokenAddresses[2] = IERC20(0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8);
        tokenAddresses[3] = IERC20(0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357);

        IPermit2 permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3); // Permit2 contract address

        IERC20(tokenAddresses[0]).approve(address(permit2), type(uint256).max);
        IERC20(tokenAddresses[1]).approve(address(permit2), type(uint256).max);
        IERC20(tokenAddresses[2]).approve(address(permit2), type(uint256).max);
        IERC20(tokenAddresses[3]).approve(address(permit2), type(uint256).max);

        // Approve token 0 using Permit2
        permit2.approve(
            address(tokenAddresses[0]),
            0x0BF61f706105EA44694f2e92986bD01C39930280, // The contract that will spend tokens
            uint160(type(uint256).max), // Amount to approve
            uint48(block.timestamp + 24 hours) // Expiry: 24 hours from now
        );

        // Approve token 1 using Permit2
        permit2.approve(
            address(tokenAddresses[1]),
            0x0BF61f706105EA44694f2e92986bD01C39930280, // The contract that will spend tokens
            uint160(type(uint256).max), // Amount to approve
            uint48(block.timestamp + 24 hours) // Expiry: 24 hours from now
        );

        // Approve token 1 using Permit2
        permit2.approve(
            address(tokenAddresses[2]),
            0x0BF61f706105EA44694f2e92986bD01C39930280, // The contract that will spend tokens
            uint160(type(uint256).max), // Amount to approve
            uint48(block.timestamp + 24 hours) // Expiry: 24 hours from now
        );

        // Approve token 1 using Permit2
        permit2.approve(
            address(tokenAddresses[3]),
            0x0BF61f706105EA44694f2e92986bD01C39930280, // The contract that will spend tokens
            uint160(type(uint256).max), // Amount to approve
            uint48(block.timestamp + 24 hours) // Expiry: 24 hours from now
        );


        uint256[] memory weights = new uint256[](4);
        weights[0] = uint256(1000000);
        weights[1] = uint256(1000000);
        weights[2] = uint256(1000000);
        weights[3] = uint256(1000000);

        //IVault(0xbA1333333333a1BA1108E8412f11850A5C319bA9).sendTo(IERC20(0xff34b3d4aee8ddcd6f9afffb6fe49bd371b8a357), msg.sender, uint256(1));
        //IVault(0xbA1333333333a1BA1108E8412f11850A5C319bA9).sendTo(IERC20(0x29f2D40B0605204364af54EC677bD022dA425d03), msg.sender, uint256(1));
        uint256 amountIn = IRouter(0x0BF61f706105EA44694f2e92986bD01C39930280).initialize(
            0x6663545aF63bC3268785Cf859f0608506759EBe8,
            tokenAddresses,
            weights,
            0,
            false,
            bytes("")
        );
        
        vm.stopBroadcast();
    }
}