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
     * @param hlPairIndex    Hyperliquid pair/market index
     * @param hlTokenIndex   Hyperliquid token index
     * @param szDecimals   Hyperliquid size-decimals for that pair
     */
    event TokenPriceConfiguredIndex(
        address indexed pool,
        uint8 indexed tokenIndex,
        uint32 hlPairIndex,
        uint32 hlTokenIndex,
        uint8 szDecimals
    );

    /**
     * @notice Emitted when the per-pool maximum surge fee percentage is changed.
     * @dev 1e18-scaled (e.g., 1e17 = 10%).
     * @param sender address of the sender
     * @param pool   Pool address
     * @param pct    New max surge fee percentage (1e18 scale)
     * @param tradeType which direction the fee should be charged in
     */
    event MaxSurgeFeePercentageChanged(address indexed sender, address indexed pool, uint256 pct, TradeType tradeType);

    /**
     * @notice Emitted when the per-pool surge threshold percentage is changed.
     * @dev 1e18-scaled (e.g., 5e16 = 5%).
     * @param sender address of the sender
     * @param pool   Pool address
     * @param pct    New threshold percentage (1e18 scale)
     * @param tradeType which direction the fee should be charged in
     */
    event ThresholdPercentageChanged(address indexed sender, address indexed pool, uint256 pct, TradeType tradeType);

    /***
     * @notice Emitted when the per pool cap deviation is changed
     * @param sender address of the sender
     * @param pool address of the pool
     * @param pct the fee in pct 1e18 scale
     * @param tradeType which direction the fee should be charged in
     */
    event CapDeviationPercentageChanged(address indexed sender, address indexed pool, uint256 pct, TradeType tradeType);

    /**
     * @notice Configure a single token’s external price mapping by token index for a given pool.
     * @param tokenIndex balancer pools index of the token
     * @param hlPairIdx the index of the pair being set from hl
     * @param hlTokenIdx the index of the token being set from hl
     */
    function setTokenPriceConfigIndex(
        address pool,
        uint8 tokenIndex,
        uint32 hlPairIdx,
        uint32 hlTokenIdx
    ) external;

    /**
     * @notice Batch configure multiple tokens’ external price mapping by token index for a given pool.
     * @param pool The pool address to configure.
     * @param tokenIndices The balancer indices of the tokens to configure (0..7).
     * @param hlPairIdx The indices of the pairs being set from hl.
     * @param hlTokenIdx The indices of the tokens being set from hl.
     */
    function setTokenPriceConfigBatchIndex(
        address pool,
        uint8[] calldata tokenIndices,
        uint32[] calldata hlPairIdx,
        uint32[] calldata hlTokenIdx
    ) external;

    /**
     * @notice Set the per-pool maximum surge fee percentage (cap).
     * @param pool Pool address
     * @param pct18 New maximum surge fee percentage (1e18 scale)
     */
    function setMaxSurgeFeePercentage(address pool, uint256 pct18, TradeType tradeType) external;

    /**
     * @notice Set the per-pool surge threshold percentage (deviation level at which fees start ramping).
     * @param pool Pool address
     * @param pct18 New threshold percentage (1e18 scale)
     */
    function setSurgeThresholdPercentage(address pool, uint256 pct18, TradeType tradeType) external;

    /**
        @notice sets the deviation where the max fee kicks in
        @param pool address of the pool
        @param capDevPct18 the deviation to set the cap to in %
    */
    function setCapDeviationPercentage(address pool, uint256 capDevPct18, TradeType tradeType) external;

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
     * @notice Read the token price configuration for a specific token index.
     * @param pool        Pool address
     * @param tokenIndex  Token index (0-based)
     * @return pairIndex     Hyperliquid market/pair index (0 if USD-quoted)
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
            uint32 priceDivisor
        );

    /**
     * @notice Read all token price configurations for a pool (length = numTokens).
     * @dev Arrays are aligned by index; entry i corresponds to token index i.
     * @return pairIndexArr     Array of Hyperliquid pair indices (0 if USD-quoted)
     * @return priceDivisorArr  Array of price divisors for scaling spot into 1e18
     */
    function getTokenPriceConfigs(
        address pool
    )
        external
        view
        returns (
            uint32[] memory pairIndexArr,
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

    /**
     * @notice Default cap deviation percentage used for new pools (1e18 = 100%).
     * @return pct The default cap deviation percentage (1e18 = 100%)
     */
    function getDefaultCapDeviationPercentage() external view returns (uint256 pct);
}
