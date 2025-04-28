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
        // For dry runs, we don't need a private key
        vm.startBroadcast();
        address pool = 0x9D430BFE48f2FCFd9a3964987144Eee2d7d5b4E9;
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        address router = 0xAE563E3f8219521950555F5962419C8919758Ea2;
        // Approve permit2 contract on token
        IERC20(pool).approve(permit2, type(uint256).max);
        // Approve router on Permit2
        IPermit2(permit2).approve(pool, router, type(uint160).max, type(uint48).max);


        IERC20[] memory tokenAddresses = new IERC20[](3);
        tokenAddresses[0] = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
        tokenAddresses[1] = IERC20(0x45804880De22913dAFE09f4980848ECE6EcbAf78);
        tokenAddresses[2] = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

        IERC20(tokenAddresses[0]).approve(address(permit2), type(uint256).max);
        IERC20(tokenAddresses[1]).approve(address(permit2), type(uint256).max);
        IERC20(tokenAddresses[2]).approve(address(permit2), type(uint256).max);

        // Approve token 0 using Permit2
        IPermit2(permit2).approve(
            address(tokenAddresses[0]),
            0xAE563E3f8219521950555F5962419C8919758Ea2, // The contract that will spend tokens
            uint160(type(uint256).max), // Amount to approve
            uint48(block.timestamp + 24 hours) // Expiry: 24 hours from now
        );

        // Approve token 1 using Permit2
        IPermit2(permit2).approve(
            address(tokenAddresses[1]),
            0xAE563E3f8219521950555F5962419C8919758Ea2, // The contract that will spend tokens
            uint160(type(uint256).max), // Amount to approve
            uint48(block.timestamp + 24 hours) // Expiry: 24 hours from now
        );

        // Approve token 1 using Permit2
        IPermit2(permit2).approve(
            address(tokenAddresses[2]),
            0xAE563E3f8219521950555F5962419C8919758Ea2, // The contract that will spend tokens
            uint160(type(uint256).max), // Amount to approve
            uint48(block.timestamp + 24 hours) // Expiry: 24 hours from now
        );


        uint256[] memory amountIn = new uint256[](3);
        amountIn[0] = uint256(62785);
        amountIn[1] = uint256(569019341313499000);
        amountIn[2] = uint256(60000000);
        bytes memory userData = "";

        uint256 amountOut = IRouter(router).addLiquidityUnbalanced(
            pool,
            amountIn,
            0,
            false,
            userData
        );

        vm.stopBroadcast();
    }
}
