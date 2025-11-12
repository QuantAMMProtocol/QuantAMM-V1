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

        IERC20(0x314fDFAf8AD9b50fF105993C722a1826019Cf21D).approve(0xAE563E3f8219521950555F5962419C8919758Ea2, type(uint256).max);

        uint256[] memory minAmountsOut = new uint256[](3);
        minAmountsOut[0] = uint256(0);
        minAmountsOut[1] = uint256(0);
        minAmountsOut[2] = uint256(0);

        bytes memory userData = "";

        IRouter(0xAE563E3f8219521950555F5962419C8919758Ea2).removeLiquidityProportional(
            0x314fDFAf8AD9b50fF105993C722a1826019Cf21D,
            uint256(0.2646781979e18),
            minAmountsOut,
            false,
            userData
        );

        vm.stopBroadcast();
    }
}
