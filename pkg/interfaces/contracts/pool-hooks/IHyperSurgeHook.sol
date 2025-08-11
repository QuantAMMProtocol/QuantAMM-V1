// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/**
 * @title IHyperSurgeHook
 * @notice Interface for the Hyper Surge hook: oracle-deviation surge fees and
 *         per-token external price configuration by pool token index.
 *
 * @dev
 * - This interface exposes Hyper-specific configuration and read APIs.
 * - Vault callback methods (e.g., onComputeDynamicSwapFeePercentage, onAfterAddLiquidity,
 *   onAfterRemoveLiquidity, getHookFlags, onRegister) are defined elsewhere (IHooks)
 *   and are intentionally not duplicated here.
 */
interface IHyperSurgeHook {
    enum TradeType {
        ARBITRAGE,
        NOISE
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when a pool is registered/initialized with this hook.
     * @param pool      Pool address
     * @param numTokens Number of tokens in the pool (2..8)
     */
    event PoolRegistered(address indexed pool, uint8 numTokens);

    /**
     * @notice Emitted when a token's external price configuration is set by token index.
     * @param pool         Pool address being configured
     * @param tokenIndex   Token index within the pool (0-based)
     * @param pairIndex    Hyperliquid pair/market index (0 if `isUsdQuote` = true)
     * @param szDecimals   Hyperliquid size-decimals for that pair (ignored if `isUsdQuote` = true)
     * @param isUsdQuote   True if the token is treated as USD-quoted (px = 1e18)
     */
    event TokenPriceConfiguredIndex(
        address indexed pool,
        uint8 indexed tokenIndex,
        uint32 pairIndex,
        uint8 szDecimals,
        bool isUsdQuote
    );

    /**
     * @notice Emitted when the per-pool maximum surge fee percentage is changed.
     * @dev 1e18-scaled (e.g., 1e17 = 10%).
     * @param pool   Pool address
     * @param pct    New max surge fee percentage (1e18 scale)
     * @param tradeType which direction the fee should be charged in
     */
    event MaxSurgeFeePercentageChanged(address indexed pool, uint256 pct, TradeType tradeType);

    /**
     * @notice Emitted when the per-pool surge threshold percentage is changed.
     * @dev 1e18-scaled (e.g., 5e16 = 5%).
     * @param pool   Pool address
     * @param pct    New threshold percentage (1e18 scale)
     * @param tradeType which direction the fee should be charged in
     */
    event ThresholdPercentageChanged(address indexed pool, uint256 pct, TradeType tradeType);

    /***
     * @notice Emitted when the per pool cap deviation is changed
     * @param pool address of the pool
     * @param pct the fee in pct 1e18 scale
     * @param tradeType which direction the fee should be charged in
     */
    event CapDeviationPercentageChanged(address indexed pool, uint256 pct, TradeType tradeType);

    /***
     * @notice Emitted when a pool's liquidity is blocked for surge fee collection.
     * @dev This is used to prevent liquidity from being added or removed during surge fee collection
     *      to ensure that the pool can collect the fees without interference.
     * @param pool      The pool whose liquidity is being blocked
     * @param isAdd     True if liquidity is being blocked for addition, false for removal
     * @param beforeDev The liquidity amount before blocking
     * @param afterDev  The liquidity amount after blocking
     * @param threshold The threshold amount that was used to block the liquidity
     */
    event LiquidityBlocked(address indexed pool, bool isAdd, uint256 beforeDev, uint256 afterDev, uint256 threshold);

    // -------------------------------------------------------------------------
    // Configuration (external, permissioned by implementation)
    // -------------------------------------------------------------------------

    /**
     * @notice Configure a single token’s external price mapping by token index for a given pool.
     * @dev
     * - If `isUsd` is true, the token is treated as USD-quoted (px = 1e18) and `pairIdx` is ignored.
     * - Otherwise, `pairIdx` must be nonzero and map to a valid Hyperliquid market.
     */
    function setTokenPriceConfigIndex(
        address pool,
        uint8 tokenIndex,
        uint32 pairIdx,
        bool isUsd
    ) external;

    /**
     * @notice Batch configure multiple tokens’ external price mapping by token index for a given pool.
     * @dev Array lengths must match: tokenIndices.length == pairIdx.length == isUsd.length.
     */
    function setTokenPriceConfigBatchIndex(
        address pool,
        uint8[] calldata tokenIndices,
        uint32[] calldata pairIdx,
        bool[] calldata isUsd
    ) external;

    /**
     * @notice Set the per-pool maximum surge fee percentage (cap).
     * @dev 1e18-scaled (e.g., 0.20e18 = 20%).
     */
    function setMaxSurgeFeePercentage(address pool, uint256 pct, TradeType tradeType) external;

    /**
     * @notice Set the per-pool surge threshold percentage (deviation level at which fees start ramping).
     * @dev 1e18-scaled (e.g., 0.05e18 = 5%).
     */
    function setSurgeThresholdPercentage(address pool, uint256 pct, TradeType tradeType) external;

    /**
        @notice sets the deviation where the max fee kicks in
        @param pool address of the pool
        @param capDevPct the deviation to set the cap to in %
    */
    function setCapDeviationPercentage(address pool, uint256 capDevPct, TradeType tradeType) external;

    // -------------------------------------------------------------------------
    // Getters (read-only)
    // -------------------------------------------------------------------------

    /**
     * @notice Current per-pool surge threshold percentage (1e18 = 100%).
     * @param pool Pool address
     * @return pct The surge threshold percentage (1e18 = 100%).
     */
    function getSurgeThresholdPercentage(address pool, TradeType tradeType) external view returns (uint256);

    /**
     * @notice Current per-pool maximum surge fee percentage (1e18 = 100%).
     * @param pool Pool address
     * @return pct The maximum surge fee percentage (1e18 = 100%).
     */
    function getMaxSurgeFeePercentage(address pool, TradeType tradeType) external view returns (uint256);

    /**
     * @notice Default cap deviation percentage used for new pools (1e18 = 100%).
     * @param pool Pool address
     * @return capDevPct The cap deviation percentage (1e18 = 100%)
     */
    function getCapDeviationPercentage(address pool, TradeType tradeType) external view returns (uint256);
    
    /**
     * @notice Number of tokens configured for the pool (2..8).
     * @param pool Pool address
     * @return numTokens Number of tokens in the pool (2..8)
     */
    function getNumTokens(address pool) external view returns (uint8);

    /**
     * @notice Whether the pool has been initialized/registered with this hook.
     * @param pool Pool address
     * @return True if the pool is registered, false otherwise.
     */
    function isPoolInitialized(address pool) external view returns (bool);

    /**
     * @notice Read the token price configuration for a specific token index.
     * @param pool        Pool address
     * @param tokenIndex  Token index (0-based)
     * @return pairIndex     Hyperliquid market/pair index (0 if USD-quoted)
     * @return isUsd         True if token is treated as USD (px = 1e18)
     * @return priceDivisor  Precomputed divisor used to scale Hyperliquid spot into 1e18
     */
    function getTokenPriceConfigIndex(
        address pool,
        uint8 tokenIndex
    )
        external
        view
        returns (
            uint32 pairIndex,
            bool isUsd,
            uint32 priceDivisor
        );

    /**
     * @notice Read all token price configurations for a pool (length = numTokens).
     * @dev Arrays are aligned by index; entry i corresponds to token index i.
     * @return pairIndexArr     Array of Hyperliquid pair indices (0 if USD-quoted)
     * @return isUsdArr         Array of USD flags
     * @return priceDivisorArr  Array of price divisors for scaling spot into 1e18
     */
    function getTokenPriceConfigs(
        address pool
    )
        external
        view
        returns (
            uint32[] memory pairIndexArr,
            bool[] memory isUsdArr,
            uint32[] memory priceDivisorArr
        );

    /**
     * @notice Default max surge fee percentage used for new pools (1e18 = 100%).
     * @return pct The default max surge fee percentage (1e18 = 100%)
     */
    function getDefaultMaxSurgeFeePercentage() external view returns (uint256 pct);

    /**
     * @notice Default surge threshold percentage used for new pools (1e18 = 100%).
     * @return pct The default surge threshold percentage (1e18 = 100%)
     */
    function getDefaultSurgeThresholdPercentage() external view returns (uint256 pct);
}
