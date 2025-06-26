// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/console.sol"; // Import the console library for logging
import { Script } from "forge-std/Script.sol";
import "@openzeppelin//contracts/utils/Strings.sol";
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
import { IQuantAMMWeightedPool } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IQuantAMMWeightedPool.sol";

import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";

contract Deploy is Script {
    using Strings for uint256;
    using Strings for uint64;
    using Strings for uint40;

    function run() external {
        uint256 deployerPrivateKey;

        // For dry runs, we don't need a private key
        vm.startBroadcast();

        (int256 data, uint40 timestamp)  = OracleWrapper(0xaAFB604Dc5c7D178e767eD576cA9aa6D48B350C2).getData();
        console.log("Data");
        if (data < 0) {
            console.log(string.concat("-", uint256(-data).toString()));
        } else {
            console.log(uint256(data).toString());
        }
        console.log("Timestamp");
        console.log(timestamp.toString());

        vm.stopBroadcast();
    }
}
