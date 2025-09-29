// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { HyperSurgeHook } from "../hooks-quantamm/HyperSurgeHook.sol";
import { PoolSwapParams } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

/// @notice Thin test/mock wrapper around HyperSurgeHook.
/// @dev Intentionally does not change any logic — it only exposes a distinct type
///      that your deployer/tests can target (mirroring StableSurgeHookMock usage).
contract HyperSurgeHookMock is HyperSurgeHook {
    constructor(
        IVault vault,
        uint256 defaultMaxSurgeFeePercentage,
        uint256 defaultThresholdPercentage,
        uint256 defaultCapDeviation,
        string memory version
    ) HyperSurgeHook(vault, defaultMaxSurgeFeePercentage, defaultThresholdPercentage, defaultCapDeviation, version) {}

    function ComputeOracleDeviationPct(
        address pool,
        uint256[] memory balancesScaled18,
        uint256[] memory w
    ) external view returns (uint256 maxDev) {
        return _computeOracleDeviationPct(pool, balancesScaled18, w);
    }

    function FindMaxDeviation(
        HyperSurgeHook.ComputeOracleDeviationLocals memory locals,
        uint256[] memory balancesScaled18,
        uint256[] memory w
    ) external pure returns (uint256) {
        return _findMaxDeviation(locals, balancesScaled18, w);
    }

    function PairSpotFromBalancesWeights(
        uint256[] memory balancesScaled18,
        uint256[] memory weights,
        uint256 indexTokenIn,
        uint256 indexTokenOut
    ) external pure returns (uint256) {
        return _pairSpotFromBalancesWeights(balancesScaled18, weights, indexTokenIn, indexTokenOut);
    }

    function RelAbsDiff(uint256 a, uint256 b) external pure returns (uint256) {
        return _relAbsDiff(a, b);
    }

    function DivisorFromSz(uint8 s) external pure returns (uint32) {
        return _divisorFromSz(s);
    }

    function EnsureValidPct(uint256 pct) external pure {
        _ensureValidPercentage(pct);
    }

    function ComputeSurgeFee(
        PoolSwapParams calldata p,
        PoolDetails memory poolDetails,
        uint256 staticSwapFee,
        uint256[] memory weights,
        uint256 calculatedAmountScaled18,
        uint256 oraclePrice
    ) external pure returns (bool ok, uint256 surgeFee) {
        return _computeSurgeFee(p, poolDetails, staticSwapFee, weights, calculatedAmountScaled18, oraclePrice);
    }
}
