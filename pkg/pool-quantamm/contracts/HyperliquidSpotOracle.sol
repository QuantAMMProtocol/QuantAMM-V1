// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { OracleWrapper } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/OracleWrapper.sol";
import {
    HyperSpotPricePrecompile
} from "@balancer-labs/v3-standalone-utils/contracts/utils/HyperSpotPricePrecompile.sol";
import {
    HyperTokenInfoPrecompile
} from "@balancer-labs/v3-standalone-utils/contracts/utils/HyperTokenInfoPrecompile.sol";

/// @title HyperliquidOracle
/// @notice Oracle wrapper that adapts Hyperliquid's spot price precompile to the generic OracleWrapper (18-decimals, timestamped).
contract HyperliquidOracle is OracleWrapper {
    /// @notice Hyperliquid pair index used by the spot price precompile.
    uint32 public immutable pairIndex;

    /// @notice Stored Hyperliquid token "sz decimals" for the token whose price scale determines normalization.
    uint8 public immutable szDecimals;

    /// @notice Precomputed divisor from szDecimals used to normalize the precompile output to 18 decimals.
    uint32 public immutable priceDivisor;

    /// @notice invalid pair index with relation to the hyperliquid precompile.
    error InvalidPairIndex();

    /// @notice invalid data returned from the hyperliquid precompile.
    error InvalidData();

    /// @notice data overflowed int216.
    error Overflow();

    /// @param _pairIndex Hyperliquid pair index to read from the spot price precompile.
    /// @param _hlTokenIndex Hyperliquid token index used to fetch szDecimals (via the token info precompile).
    constructor(uint32 _pairIndex, uint32 _hlTokenIndex) {
        if (_pairIndex == 0) {
            revert InvalidPairIndex();
        }

        pairIndex = _pairIndex;

        uint8 _sz = HyperTokenInfoPrecompile.szDecimals(_hlTokenIndex);
        szDecimals = _sz;

        priceDivisor = _divisorFromSz(_sz);
    }

    /// @inheritdoc OracleWrapper
    function _getData() internal view override returns (int216 data, uint40 timestamp) {
        // Fetch raw price from the Hyperliquid precompile.
        uint256 raw = HyperSpotPricePrecompile.spotPrice(pairIndex);
        if (raw == 0) {
            revert InvalidData();
        }

        uint256 normalized = raw / uint256(priceDivisor);
        if (normalized == 0) {
            revert InvalidData();
        }

        if (normalized > uint256(uint216(type(int216).max))) {
            revert Overflow();
        }

        return (int216(int256(normalized)), uint40(block.timestamp));
    }

    /// @notice Deterministic LUT for the Hyperliquid "sz" → divisor mapping (same as in HyperSurge hook).
    /// @dev s in [0..8], divisor = 10**(8 - s). Encoded as a LUT to avoid EXP gas at runtime.
    function _divisorFromSz(uint8 s) internal pure returns (uint32) {
        if (s == 0) return 100_000_000;
        if (s == 1) return 10_000_000;
        if (s == 2) return 1_000_000;
        if (s == 3) return 100_000;
        if (s == 4) return 10_000;
        if (s == 5) return 1_000;
        if (s == 6) return 100;
        if (s == 7) return 10;
        // s == 8 (and anything > 8 is invalid upstream — we treat as 8)
        return 1;
    }
}
