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

        // Approve permit2 contract on token
        IERC20(pool).approve(permit2, type(uint256).max);
        // Approve router on Permit2
        IPermit2(permit2).approve(pool, router, type(uint160).max, type(uint48).max);

        uint256[] memory amountIn = new uint256[](3);
        amountIn[0] = uint256(0);
        amountIn[1] = uint256(0);
        amountIn[2] = uint256(0);

        bytes memory userData = "";

        uint256 amountOut = IRouter(0xAE563E3f8219521950555F5962419C8919758Ea2).addLiquidityUnbalanced(
            pool,
            amountIn,
            0,
            false,
            userData
        );

        vm.stopBroadcast();
    }
}
