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

        IERC20[] memory tokenAddresses = new IERC20[](3);
        tokenAddresses[0] = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
        tokenAddresses[1] = IERC20(0x45804880De22913dAFE09f4980848ECE6EcbAf78);
        tokenAddresses[2] = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

        IPermit2 permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3); // Permit2 contract address

        IERC20(tokenAddresses[0]).approve(address(permit2), type(uint256).max);
        IERC20(tokenAddresses[1]).approve(address(permit2), type(uint256).max);
        IERC20(tokenAddresses[2]).approve(address(permit2), type(uint256).max);

        // Approve token 0 using Permit2
        permit2.approve(
            address(tokenAddresses[0]),
            0xAE563E3f8219521950555F5962419C8919758Ea2, // The contract that will spend tokens
            uint160(type(uint256).max), // Amount to approve
            uint48(block.timestamp + 24 hours) // Expiry: 24 hours from now
        );

        // Approve token 1 using Permit2
        permit2.approve(
            address(tokenAddresses[1]),
            0xAE563E3f8219521950555F5962419C8919758Ea2, // The contract that will spend tokens
            uint160(type(uint256).max), // Amount to approve
            uint48(block.timestamp + 24 hours) // Expiry: 24 hours from now
        );

        // Approve token 1 using Permit2
        permit2.approve(
            address(tokenAddresses[2]),
            0xAE563E3f8219521950555F5962419C8919758Ea2, // The contract that will spend tokens
            uint160(type(uint256).max), // Amount to approve
            uint48(block.timestamp + 24 hours) // Expiry: 24 hours from now
        );

        uint256[] memory weights = new uint256[](3);
        weights[0] = uint256(2569597);
        weights[1] = uint256(778771989560757000);
        weights[2] = uint256(563622734);

        //IVault(0xbA1333333333a1BA1108E8412f11850A5C319bA9).sendTo(IERC20(0xff34b3d4aee8ddcd6f9afffb6fe49bd371b8a357), msg.sender, uint256(1));
        //IVault(0xbA1333333333a1BA1108E8412f11850A5C319bA9).sendTo(IERC20(0x29f2D40B0605204364af54EC677bD022dA425d03), msg.sender, uint256(1));
        uint256 amountIn = IRouter(0xAE563E3f8219521950555F5962419C8919758Ea2).initialize(
            0x6B61D8680C4F9E560c8306807908553f95c749C5,
            tokenAddresses,
            weights,
            0,
            false,
            bytes("")
        );

        vm.stopBroadcast();
    }
}
