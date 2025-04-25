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
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SwapKind, VaultSwapParams } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

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
        VaultSwapParams memory params = VaultSwapParams({
            kind: SwapKind.EXACT_IN,
            pool: 0x6663545aF63bC3268785Cf859f0608506759EBe8,
            tokenIn: IERC20(0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8), // Replace with actual tokenIn address
            tokenOut: IERC20(0x29f2D40B0605204364af54EC677bD022dA425d03), // Replace with actual tokenOut address
            amountGivenRaw: 100, // Replace with the actual amount
            limitRaw: 1e18, // Replace with the actual limit
            userData: ""
        });

        IVault(0xbA1333333333a1BA1108E8412f11850A5C319bA9).swap(params);

        vm.stopBroadcast();
    }
}
