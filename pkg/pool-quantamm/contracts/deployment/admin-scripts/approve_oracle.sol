// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

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
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

interface IDelayModifier {
    function executeNextTx(address to, uint256 value, bytes calldata data, uint8 operation) external;
}

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

        // replace with your deployed addresses & payload
        IDelayModifier delay = IDelayModifier(0x4F824dDe06314a7Aa1091902d17B82c4b519F424);
        address target = 0xeE20C7956bd715052DF13DB9BD77984Eab85F0C4;
        uint256 value = 0;
        bytes memory data = hex"df5dd1a50000000000000000000000006fe415f986b12da4381d7082ca0223a0a49771a9";
        uint8 operation = 0;

        delay.executeNextTx(target, value, data, operation);

        //BTC
        //UpdateWeightRunner(0x34932B2670BC4fb110fBe7772f0fC9905269705E).addOracle(OracleWrapper(0x6fE415F986b12Da4381d7082CA0223a0a49771A9));
        //
        ////ETH
        //UpdateWeightRunner(0x34932B2670BC4fb110fBe7772f0fC9905269705E).addOracle(OracleWrapper(0x70BE6803cD94EEecA55603C25a550d78D619B037));
        //
        ////PAXG
        //UpdateWeightRunner(0x34932B2670BC4fb110fBe7772f0fC9905269705E).addOracle(OracleWrapper(0x2E24826974Cd23bb851dBdbFD838521c61A530b3));
        //
        ////USDC
        //UpdateWeightRunner(0x34932B2670BC4fb110fBe7772f0fC9905269705E).addOracle(OracleWrapper(0x47eD785C84376F49610b90cea0A88dAe447B7881));

        vm.stopBroadcast();
    }
}
