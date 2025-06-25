// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import { IVaultAdmin } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultAdmin.sol";
import { IQuantAMMWeightedPool } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IQuantAMMWeightedPool.sol";

contract SafeHavenFeeController {
    address public immutable vault;
    address public immutable pool;
    uint256 public immutable rebalancePeriodFee = 2e16; // 2%
    uint256 public immutable stablePeriodFee = 5e15;

    //https://etherscan.io/address/0xbA1333333333a1BA1108E8412f11850A5C319bA9
    //https://etherscan.io/address/0x6B61D8680C4F9E560c8306807908553f95c749C5

    /// @param _vault The address of the vault
    /// @param _pool The address of the pool
    constructor(address _vault, address _pool) {
        vault = _vault;
        pool = _pool;
    }

    /// @notice Sets the fixed fees for the pool based on whether it is more of a CFMM compared to when weights are changing. When weights are stable lower fees increase likelyhook of retail flow
    function setFixedFees() external {
        IQuantAMMWeightedPool.QuantAMMWeightedPoolDynamicData memory poolData = IQuantAMMWeightedPool(pool)
            .getQuantAMMWeightedPoolDynamicData();

        bool isStable = true;

        if (poolData.lastInteropTime < block.timestamp) {
            //hardcoded length for safe haven.
            // [w1,w2,w3,m1,m2,m3]
            for (uint256 i = 3; i < 6; i++) {
                if (poolData.firstFourWeightsAndMultipliers[i] > 1e2) {
                    isStable = false;
                    break;
                }
            }
        }

        uint256 fee = isStable ? stablePeriodFee : rebalancePeriodFee;

        IVaultAdmin(vault).setStaticSwapFeePercentage(pool, fee);
    }
}
