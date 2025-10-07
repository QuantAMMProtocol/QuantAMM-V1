// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import { OracleWrapper } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/OracleWrapper.sol";

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
     * @param szDecimals     Hyperliquid size-decimals for that pair
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
     * @notice Emitted when the oracle staleness threshold is changed
     * @param sender address of the sender
     * @param oldThreshold the old threshold in seconds
     * @param newThreshold the new threshold in seconds
     */
    event OracleStalenessThresholdChanged(address indexed sender, uint256 oldThreshold, uint256 newThreshold);
    /**
     * @notice Set the external price oracle for a specific token in a pool.
     * @param pool The pool address to configure.
     * @param tokenIndex The index of the token within the pool (0-based).
     * @param oracle The OracleWrapper instance to use for the token's price.
     */
    function setTokenOracle(
        address pool,
        uint8 tokenIndex,
        OracleWrapper oracle
    ) external;

    
    /**
     * @notice Batch version for setting oracle wrappers by token index.
     * @param pool The pool address to configure.
     * @param tokenIndices The indices of the tokens to configure.
     * @param oracles The oracle wrappers for each token index.
     */
    function setTokenOraclesBatch(
        address pool,
        uint8[] calldata tokenIndices,
        OracleWrapper[] calldata oracles
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
     * @notice Get the external price oracle configuration for a given token index in a pool.
     * @param pool Pool address
     * @param tokenIndex Token index within the pool (0-based)
     * @return oracle The OracleWrapper struct containing the oracle configuration.
     * / 
     */
     function getTokenOracle(
        address pool,
        uint8 tokenIndex
    ) external view returns (OracleWrapper oracle) ;

    /**
     * @notice Read all token price configurations for a pool (length = numTokens).
     * @dev Arrays are aligned by index; entry i corresponds to token index i.
     * @return pairIndexArr     Array of Hyperliquid pair indices (0 if USD-quoted)
     * @return priceDivisorArr  Array of price divisors for scaling spot into 1e18
     */
    function getTokenOracles(
        address pool
    ) external view returns (OracleWrapper[] memory oracles);

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
