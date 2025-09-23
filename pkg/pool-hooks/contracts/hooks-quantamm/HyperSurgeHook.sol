// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IHyperSurgeHook } from "@balancer-labs/v3-interfaces/contracts/pool-hooks/IHyperSurgeHook.sol";
import { IHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IHooks.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { SingletonAuthentication } from "@balancer-labs/v3-vault/contracts/SingletonAuthentication.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { WeightedPool } from "@balancer-labs/v3-pool-weighted/contracts/WeightedPool.sol";
import { Version } from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";
import {
    HyperSpotPricePrecompile
} from "@balancer-labs/v3-standalone-utils/contracts/utils/HyperSpotPricePrecompile.sol";
import {
    HyperTokenInfoPrecompile
} from "@balancer-labs/v3-standalone-utils/contracts/utils/HyperTokenInfoPrecompile.sol";
import { VaultGuard } from "@balancer-labs/v3-vault/contracts/VaultGuard.sol";
import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";

/// -----------------------------------------------------------------------
/// Multitoken Hyper Surge Hook — struct-per-index configuration
/// -----------------------------------------------------------------------
contract HyperSurgeHook is BaseHooks, VaultGuard, SingletonAuthentication, Version, IHyperSurgeHook {
    using FixedPoint for uint256;
    using SafeCast for uint256;

    error InvalidArrayLengths();
    error TokenIndexOutOfRange();
    error InvalidPairIndex();
    error PoolNotInitialized();
    error InvalidDecimals();
    error InvalidSurgeFeePercentage();
    error InvalidThresholdDeviation();
    error InvalidCapDeviationPercentage();
    error InvalidPercentage();

    struct TokenPriceCfg {
        uint32 pairIndex;
        uint32 tokenIndex;
        uint8 sz;
    }

    struct PoolDetails {
        uint32 arbMaxSurgeFee9;
        uint32 arbThresholdPercentage9;
        uint32 arbCapDeviationPercentage9;
        uint32 noiseMaxSurgeFee9;
        uint32 noiseThresholdPercentage9;
        uint32 noiseCapDeviationPercentage9;
        uint8 numTokens;
    }

    struct PoolCfg {
        PoolDetails details;
        TokenPriceCfg[8] tokenCfg;
    }

    uint256 private constant MAX32 = uint256(type(uint32).max);

    ///@notice Hyperliquid has an internal maximum of 8 decimal places.
    uint256 private constant SZMAX = 8;

    mapping(address => PoolCfg) private _poolCfg;

    uint256 private immutable _defaultMaxSurgeFeePercentage18;

    uint256 private immutable _defaultThresholdPercentage18;

    uint256 private immutable _defaultCapDeviationPercentage18;

    modifier ensureValidPercentage(uint256 percentageValue) {
        _ensureValidPercentage(percentageValue);

        _;
    }

    constructor(
        IVault vault,
        uint256 defaultMaxSurgeFeePercentage18,
        uint256 defaultThresholdPercentage18,
        uint256 defaultCapDeviationPercentage18,
        string memory version
    ) SingletonAuthentication(vault) VaultGuard(vault) Version(version) {
        _ensureValidPercentage(defaultMaxSurgeFeePercentage18);
        _ensureValidPercentage(defaultThresholdPercentage18);
        _ensureValidPercentage(defaultCapDeviationPercentage18);
        _defaultMaxSurgeFeePercentage18 = defaultMaxSurgeFeePercentage18;
        _defaultThresholdPercentage18 = defaultThresholdPercentage18;
        _defaultCapDeviationPercentage18 = defaultCapDeviationPercentage18;
    }

    /**************************************************
                           Hooks   
     **************************************************/

    /// @inheritdoc IHooks
    function getHookFlags() public pure override returns (HookFlags memory hookFlags) {
        hookFlags.shouldCallComputeDynamicSwapFee = true;
        hookFlags.shouldCallAfterAddLiquidity = true;
        hookFlags.shouldCallAfterRemoveLiquidity = true;
    }

    /// @inheritdoc IHooks
    function onRegister(
        address,
        address pool,
        TokenConfig[] memory tokenCfgs,
        LiquidityManagement calldata
    ) public override onlyVault returns (bool) {
        PoolDetails memory details;
        details.numTokens = uint8(tokenCfgs.length);
        // Set the pool details, so we can use the setters and emit the proper events.
        _poolCfg[pool].details = details;

        _setMaxSurgeFeePercentage(pool, _defaultMaxSurgeFeePercentage18, TradeType.ARBITRAGE);
        _setMaxSurgeFeePercentage(pool, _defaultMaxSurgeFeePercentage18, TradeType.NOISE);
        _setSurgeThresholdPercentage(pool, _defaultThresholdPercentage18, TradeType.ARBITRAGE);
        _setSurgeThresholdPercentage(pool, _defaultThresholdPercentage18, TradeType.NOISE);
        _setCapDeviationPercentage(pool, _defaultCapDeviationPercentage18, TradeType.ARBITRAGE);
        _setCapDeviationPercentage(pool, _defaultCapDeviationPercentage18, TradeType.NOISE);

        return true;
    }

    /// @inheritdoc IHooks
    function onAfterAddLiquidity(
        address,
        address pool,
        AddLiquidityKind kind,
        uint256[] memory amountsInScaled18,
        uint256[] memory amountsInRaw,
        uint256, // lpAmount (unused)
        uint256[] memory balancesScaled18,
        bytes memory // userData (unused)
    ) public view override returns (bool success, uint256[] memory hookAdjustedAmountsInRaw) {
        // Allow proportional adds, but block non-proportional adds that worsen deviation and end above threshold.
        if (kind == AddLiquidityKind.PROPORTIONAL) {
            return (true, amountsInRaw);
        }

        bool isPriceDeviationWorsening = _isPriceDeviationWorsening(pool, amountsInScaled18, balancesScaled18, false);

        return (isPriceDeviationWorsening == false, amountsInRaw);
    }

    /// @inheritdoc IHooks
    function onAfterRemoveLiquidity(
        address,
        address pool,
        RemoveLiquidityKind kind,
        uint256, // lpAmount (unused)
        uint256[] memory amountsOutScaled18,
        uint256[] memory amountsOutRaw,
        uint256[] memory balancesScaled18,
        bytes memory // userData (unused)
    ) public view override returns (bool success, uint256[] memory hookAdjustedAmountsOutRaw) {
        // Allow proportional removes, but block non-proportional removes that worsen deviation and end above threshold.
        if (kind == RemoveLiquidityKind.PROPORTIONAL) {
            return (true, amountsOutRaw);
        }

        bool isPriceDeviationWorsening = _isPriceDeviationWorsening(pool, amountsOutScaled18, balancesScaled18, true);

        return (isPriceDeviationWorsening == false, amountsOutRaw);
    }

    /// @inheritdoc IHooks
    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata p,
        address pool,
        uint256 staticSwapFee
    ) public view override returns (bool, uint256) {
        PoolCfg memory pc = _poolCfg[pool];
        uint256[] memory weights = WeightedPool(pool).getNormalizedWeights();
        uint256 calculatedAmountScaled18 = WeightedPool(pool).onSwap(p);
        uint256 oraclePrice = _computeExternalPrice(pc, p.indexIn, p.indexOut);
        return _computeSurgeFee(p, pc.details, staticSwapFee, weights, calculatedAmountScaled18, oraclePrice);
    }

    /**************************************************
                           Setters   
     **************************************************/

    /**
     * @notice Configure a single token’s Hyperliquid mapping for a given pool by token index (0..7).
     * @param pool The pool address to configure.
     * @param tokenIndex The balancer index of the token to configure (0..7).
     * @param hlPairIdx the index of the pair being set
     * @param hlTokenIdx the index of the token being set
     */
    function setTokenPriceConfigIndex(
        address pool,
        uint8 tokenIndex,
        uint32 hlPairIdx,
        uint32 hlTokenIdx
    ) external onlySwapFeeManagerOrGovernance(pool) {
        PoolDetails storage details = _poolCfg[pool].details;
        _setTokenPriceConfigIndex(pool, tokenIndex, hlPairIdx, hlTokenIdx, details);
    }

    /**
     * @notice Batch version (indices).
     * @param pool the pool address
     * @param tokenIndices the indices of the token configs being changed
     * @param pairIdx the index of the pair being changed
     * @param hlTokenIdx the index of the token being set
     */
    function setTokenPriceConfigBatchIndex(
        address pool,
        uint8[] calldata tokenIndices,
        uint32[] calldata pairIdx,
        uint32[] calldata hlTokenIdx
    ) external onlySwapFeeManagerOrGovernance(pool) {
        InputHelpers.ensureInputLengthMatch(tokenIndices.length, pairIdx.length);

        PoolDetails storage detail = _poolCfg[pool].details;

        for (uint256 i = 0; i < tokenIndices.length; ++i) {
            _setTokenPriceConfigIndex(pool, tokenIndices[i], pairIdx[i], hlTokenIdx[i], detail);
        }
    }

    function _setTokenPriceConfigIndex(
        address pool,
        uint8 tokenIndex,
        uint32 hlPairIdx,
        uint32 hlTokenIdx,
        PoolDetails storage details
    ) internal {
        TokenPriceCfg memory tempCfg;

        if (hlPairIdx == 0) {
            revert InvalidPairIndex();
        }

        if (tokenIndex >= details.numTokens) {
            revert TokenIndexOutOfRange();
        }

        tempCfg.sz = HyperTokenInfoPrecompile.szDecimals(hlTokenIdx);

        if (tempCfg.sz > SZMAX) {
            revert InvalidDecimals();
        }

        tempCfg.pairIndex = hlPairIdx;

        _poolCfg[pool].tokenCfg[tokenIndex] = tempCfg;

        emit TokenPriceConfiguredIndex(pool, tokenIndex, tempCfg.pairIndex, hlTokenIdx, tempCfg.sz);
    }

    /// @inheritdoc IHyperSurgeHook
    function setMaxSurgeFeePercentage(
        address pool,
        uint256 newMaxSurgeFeePercentageScaled18,
        TradeType tradeType
    ) external override onlySwapFeeManagerOrGovernance(pool) ensureValidPercentage(newMaxSurgeFeePercentageScaled18) {
        _setMaxSurgeFeePercentage(pool, newMaxSurgeFeePercentageScaled18, tradeType);
    }

    function _setMaxSurgeFeePercentage(
        address pool,
        uint256 newMaxSurgeFeePercentageScaled18,
        TradeType tradeType
    ) internal {
        if (tradeType == TradeType.ARBITRAGE) {
            _poolCfg[pool].details.arbMaxSurgeFee9 = _safeConvertTo9Decimals(newMaxSurgeFeePercentageScaled18);
        } else {
            _poolCfg[pool].details.noiseMaxSurgeFee9 = _safeConvertTo9Decimals(newMaxSurgeFeePercentageScaled18);
        }

        emit MaxSurgeFeePercentageChanged(msg.sender, pool, newMaxSurgeFeePercentageScaled18, tradeType);
    }

    /// @inheritdoc IHyperSurgeHook
    function setSurgeThresholdPercentage(
        address pool,
        uint256 newThresholdPercentageScaled18,
        TradeType tradeType
    ) external override onlySwapFeeManagerOrGovernance(pool) ensureValidPercentage(newThresholdPercentageScaled18) {
        _setSurgeThresholdPercentage(pool, newThresholdPercentageScaled18, tradeType);
    }

    function _setSurgeThresholdPercentage(
        address pool,
        uint256 newThresholdPercentageScaled18,
        TradeType tradeType
    ) internal {
        uint256 capDeviationPercentageScaled18;
        PoolDetails memory poolDetails = _poolCfg[pool].details;
        if (tradeType == TradeType.ARBITRAGE) {
            poolDetails.arbThresholdPercentage9 = _safeConvertTo9Decimals(newThresholdPercentageScaled18);
            capDeviationPercentageScaled18 = _convertTo18Decimals(poolDetails.arbCapDeviationPercentage9);
        } else {
            poolDetails.noiseThresholdPercentage9 = _safeConvertTo9Decimals(newThresholdPercentageScaled18);
            capDeviationPercentageScaled18 = _convertTo18Decimals(poolDetails.noiseCapDeviationPercentage9);
        }

        // Keep a valid ramp span: threshold < capDev ≤ 1
        if (capDeviationPercentageScaled18 != 0 && newThresholdPercentageScaled18 >= capDeviationPercentageScaled18) {
            revert InvalidThresholdDeviation();
        }

        _poolCfg[pool].details = poolDetails;

        emit ThresholdPercentageChanged(msg.sender, pool, newThresholdPercentageScaled18, tradeType);
    }

    /// @inheritdoc IHyperSurgeHook
    function setCapDeviationPercentage(
        address pool,
        uint256 newCapDeviationPercentageScaled18,
        TradeType tradeType
    ) external override onlySwapFeeManagerOrGovernance(pool) ensureValidPercentage(newCapDeviationPercentageScaled18) {
        _setCapDeviationPercentage(pool, newCapDeviationPercentageScaled18, tradeType);
    }

    function _setCapDeviationPercentage(
        address pool,
        uint256 newCapDeviationPercentageScaled18,
        TradeType tradeType
    ) internal {
        uint256 thresholdPercentageScaled18;
        PoolDetails memory poolDetails = _poolCfg[pool].details;
        if (tradeType == TradeType.ARBITRAGE) {
            poolDetails.arbCapDeviationPercentage9 = _safeConvertTo9Decimals(newCapDeviationPercentageScaled18);
            thresholdPercentageScaled18 = _convertTo18Decimals(poolDetails.arbThresholdPercentage9);
        } else {
            poolDetails.noiseCapDeviationPercentage9 = _safeConvertTo9Decimals(newCapDeviationPercentageScaled18);
            thresholdPercentageScaled18 = _convertTo18Decimals(poolDetails.noiseThresholdPercentage9);
        }

        // Keep a valid ramp span: threshold < capDev ≤ 1
        if (newCapDeviationPercentageScaled18 <= thresholdPercentageScaled18) {
            revert InvalidCapDeviationPercentage();
        }

        _poolCfg[pool].details = poolDetails;

        emit CapDeviationPercentageChanged(msg.sender, pool, newCapDeviationPercentageScaled18, tradeType);
    }

    /**************************************************
                           Getters   
     **************************************************/

    /// @notice Getter to read the pool-specific surge threshold (1e18 = 100%).
    function getSurgeThresholdPercentage(address pool, TradeType tradeType) public view override returns (uint256) {
        if (tradeType == TradeType.ARBITRAGE) {
            return _convertTo18Decimals(_poolCfg[pool].details.arbThresholdPercentage9);
        } else {
            return _convertTo18Decimals(_poolCfg[pool].details.noiseThresholdPercentage9);
        }
    }

    /// @inheritdoc IHyperSurgeHook
    function getMaxSurgeFeePercentage(address pool, TradeType tradeType) external view override returns (uint256) {
        if (tradeType == TradeType.ARBITRAGE) {
            return _convertTo18Decimals(_poolCfg[pool].details.arbMaxSurgeFee9);
        } else {
            return _convertTo18Decimals(_poolCfg[pool].details.noiseMaxSurgeFee9);
        }
    }

    /// @inheritdoc IHyperSurgeHook
    function getCapDeviationPercentage(address pool, TradeType tradeType) external view override returns (uint256) {
        if (tradeType == TradeType.ARBITRAGE) {
            return _convertTo18Decimals(_poolCfg[pool].details.arbCapDeviationPercentage9);
        } else {
            return _convertTo18Decimals(_poolCfg[pool].details.noiseCapDeviationPercentage9);
        }
    }

    /// @inheritdoc IHyperSurgeHook
    function getTokenPriceConfigIndex(
        address pool,
        uint8 tokenIndex
    ) external view override returns (uint32 pairIndex, uint32 priceDivisor) {
        TokenPriceCfg memory cfg = _poolCfg[pool].tokenCfg[tokenIndex];
        return (cfg.pairIndex, _divisorFromSz(cfg.sz));
    }

    /// @inheritdoc IHyperSurgeHook
    function getTokenPriceConfigs(
        address pool
    ) external view override returns (uint32[] memory pairIndexArr, uint32[] memory priceDivisorArr) {
        PoolDetails memory details = _poolCfg[pool].details;

        pairIndexArr = new uint32[](details.numTokens);
        priceDivisorArr = new uint32[](details.numTokens);

        for (uint8 i = 0; i < details.numTokens; ++i) {
            TokenPriceCfg memory cfg = _poolCfg[pool].tokenCfg[i];
            pairIndexArr[i] = cfg.pairIndex;
            priceDivisorArr[i] = _divisorFromSz(cfg.sz);
        }
    }

    /// @inheritdoc IHyperSurgeHook
    function getDefaultMaxSurgeFeePercentage() external view override returns (uint256) {
        return _defaultMaxSurgeFeePercentage18;
    }

    /// @inheritdoc IHyperSurgeHook
    function getDefaultSurgeThresholdPercentage() external view override returns (uint256) {
        return _defaultThresholdPercentage18;
    }

    /// @inheritdoc IHyperSurgeHook
    function getDefaultCapDeviationPercentage() external view override returns (uint256) {
        return _defaultCapDeviationPercentage18;
    }

    /// @inheritdoc IHyperSurgeHook
    function getNumTokens(address pool) external view override returns (uint8) {
        return _poolCfg[pool].details.numTokens;
    }

    function _computeSurgeFee(
        PoolSwapParams calldata params,
        PoolDetails memory poolDetails,
        uint256 staticSwapFee,
        uint256[] memory weights,
        uint256 calculatedAmountScaled18,
        uint256 oraclePrice
    ) internal pure returns (bool ok, uint256 surgeFee) {
        // Do not block if there is an issue with the hyperliquid price
        if (oraclePrice == 0) {
            return (true, staticSwapFee);
        }

        (
            uint256 deviationScaled18,
            uint256 capDeviationPercentageScaled18,
            uint256 maxSurgeFeeScaled18,
            uint256 thresholdScaled18
        ) = _computeDeviationAndSelectPoolDetails(params, weights, calculatedAmountScaled18, oraclePrice, poolDetails);

        if (deviationScaled18 <= thresholdScaled18) {
            return (true, staticSwapFee);
        }

        uint256 span = capDeviationPercentageScaled18 - thresholdScaled18; // > 0 by fallback above
        uint256 norm = (deviationScaled18 - thresholdScaled18).divDown(span);

        if (norm > FixedPoint.ONE) {
            norm = FixedPoint.ONE;
        }

        uint256 increment = (maxSurgeFeeScaled18 - staticSwapFee).mulDown(norm);
        uint256 surgeFeeScaled18 = staticSwapFee + increment;

        return (true, surgeFeeScaled18);
    }

    function _computeDeviationAndSelectPoolDetails(
        PoolSwapParams calldata params,
        uint256[] memory weights,
        uint256 calculatedAmountScaled18,
        uint256 oraclePrice,
        PoolDetails memory poolDetails
    )
        internal
        pure
        returns (
            uint256 deviationScaled18,
            uint256 capDeviationScaled18,
            uint256 maxSurgeFeeScaled18,
            uint256 thresholdScaled18
        )
    {
        uint256 deviationBeforeScaled18;
        {
            uint256 poolPriceBefore = _pairSpotFromBalancesWeights(
                params.balancesScaled18,
                weights,
                params.indexIn,
                params.indexOut
            );
            deviationBeforeScaled18 = _relAbsDiff(poolPriceBefore, oraclePrice);
        }

        uint256[] memory newBalancesScaled18 = _simulateAfterSwapBalances(params, calculatedAmountScaled18);

        // P_pool = (B_out/w_out) / (B_in/w_in) = (B_out * w_in) / (B_in * w_out)
        {
            uint256 poolPriceAfter = _pairSpotFromBalancesWeights(
                newBalancesScaled18,
                weights,
                params.indexIn,
                params.indexOut
            );
            deviationScaled18 = _relAbsDiff(poolPriceAfter, oraclePrice); // |pool - ext| / ext
        }

        // Check if the swap is a noise (deviation is worsening) or an arbitrage (deviation is improving).
        if (deviationScaled18 > deviationBeforeScaled18) {
            // Deviation is worsening, use noise details.
            capDeviationScaled18 = _convertTo18Decimals(poolDetails.noiseCapDeviationPercentage9);
            maxSurgeFeeScaled18 = _convertTo18Decimals(poolDetails.noiseMaxSurgeFee9);
            thresholdScaled18 = _convertTo18Decimals(poolDetails.noiseThresholdPercentage9);
        } else {
            // Deviation is improving, use arb details (informed swap).
            capDeviationScaled18 = _convertTo18Decimals(poolDetails.arbCapDeviationPercentage9);
            maxSurgeFeeScaled18 = _convertTo18Decimals(poolDetails.arbMaxSurgeFee9);
            thresholdScaled18 = _convertTo18Decimals(poolDetails.arbThresholdPercentage9);

            // For the arbitrage direction we use the deviation before. If a large noise deviation is being corrected
            // the arbitrage pays more to take advantage of the larger arb opp and therefore greater profit as the fee
            // decreases the closer you get to market price, another arb opportunity presents itself once the first arb
            // is taken. This means a large fee != a large no arb region and the pool stays close to market. For more
            // information, check the HyperSurgeHook-README.md file.
            deviationScaled18 = deviationBeforeScaled18;
        }
    }

    function _simulateAfterSwapBalances(
        PoolSwapParams calldata params,
        uint256 calculatedAmountScaled18
    ) internal pure returns (uint256[] memory newBalances) {
        newBalances = new uint256[](params.balancesScaled18.length);

        for (uint256 i = 0; i < params.balancesScaled18.length; i++) {
            newBalances[i] = params.balancesScaled18[i];
        }

        if (params.kind == SwapKind.EXACT_IN) {
            newBalances[params.indexIn] += params.amountGivenScaled18;
            newBalances[params.indexOut] -= calculatedAmountScaled18;
        } else {
            newBalances[params.indexIn] += calculatedAmountScaled18;
            newBalances[params.indexOut] -= params.amountGivenScaled18;
        }
    }

    function _computeExternalPrice(
        PoolCfg memory pc,
        uint256 indexTokenIn,
        uint256 indexTokenOut
    ) internal view returns (uint256) {
        TokenPriceCfg memory pInCfg = pc.tokenCfg[indexTokenIn];
        TokenPriceCfg memory pOutCfg = pc.tokenCfg[indexTokenOut];

        uint256 rawPriceTokenIn = HyperSpotPricePrecompile.spotPrice(pInCfg.pairIndex);
        uint256 rawPriceTokenOut = HyperSpotPricePrecompile.spotPrice(pOutCfg.pairIndex);
        uint256 priceTokenInScaled18 = rawPriceTokenIn.divDown(_divisorFromSz(pInCfg.sz));
        uint256 priceTokenOutScaled18 = rawPriceTokenOut.divDown(_divisorFromSz(pOutCfg.sz));
        return priceTokenOutScaled18.divDown(priceTokenInScaled18);
    }

    function _pairSpotFromBalancesWeights(
        uint256[] memory balancesScaled18,
        uint256[] memory weights,
        uint256 indexTokenIn,
        uint256 indexTokenOut
    ) internal pure returns (uint256) {
        // This would cause a division by zero error. In normal circumstances this should never happen,
        // but we keep the defensive check since it is on the withdraw path.
        if (balancesScaled18[indexTokenIn] == 0 || weights[indexTokenOut] == 0) {
            return 0;
        }

        // Use pure math increases the precision of the operations and reduces gas cost.
        return
            ((balancesScaled18[indexTokenOut] * weights[indexTokenIn]) / weights[indexTokenOut]).divDown(
                balancesScaled18[indexTokenIn]
            );
    }

    function _relAbsDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a > b) {
            return (a - b).divDown(b);
        }
        return (b - a).divDown(b);
    }

    function _divisorFromSz(uint32 s) internal pure returns (uint32) {
        // s in [0..8], divisor = 10**(8 - s)
        // LUT avoids EXP cost both at config and (especially) runtime.
        if (s == 0) return 100_000_000;
        if (s == 1) return 10_000_000;
        if (s == 2) return 1_000_000;
        if (s == 3) return 100_000;
        if (s == 4) return 10_000;
        if (s == 5) return 1_000;
        if (s == 6) return 100;
        if (s == 7) return 10;
        // s == 8
        return 1;
    }

    struct ComputeOracleDeviationLocals {
        uint256[8] px;
        uint256 maxDev;
        uint256 raw;
        uint256 i;
        uint256 j;
        uint256 bi;
        uint256 wi;
        uint256 pxi;
        uint256 bj;
        uint256 wj;
        uint256 pxj;
        uint256 poolPx;
        uint256 extPx;
        uint256 dev;
        uint256 priceDivisor;
    }

    /**
     * @dev Computes the pool-wide oracle deviation as the MAX pairwise deviation across all token pairs (i<j):
     * |P_pool(i->j) - P_ext(i->j)| / P_ext(i->j). Uses the same spot & external price conventions as the swap-fee
     * compute.
     *
     * @param pool The pool address
     * @param balancesScaled18 The balances of the pool
     * @param w The weights of the pool
     */
    function _computeOracleDeviationPct(
        address pool,
        uint256[] memory balancesScaled18,
        uint256[] memory w
    ) internal view returns (uint256 maxDev) {
        ComputeOracleDeviationLocals memory locals;
        PoolCfg memory pc = _poolCfg[pool];

        // Build external prices per token (1e18). Missing/zero -> mark as 0 (skipped).
        for (locals.i = 0; locals.i < balancesScaled18.length; ++locals.i) {
            TokenPriceCfg memory cfg = pc.tokenCfg[locals.i];
            if (cfg.pairIndex != 0) {
                locals.raw = HyperSpotPricePrecompile.spotPrice(cfg.pairIndex); // reverts if precompile fails
                if (locals.raw != 0) {
                    locals.priceDivisor = _divisorFromSz(cfg.sz);
                    if (locals.priceDivisor != 0) {
                        locals.px[locals.i] = uint256(locals.raw).divDown(uint256(locals.priceDivisor));
                    }
                }
            }
        }

        return _findMaxDeviation(locals, balancesScaled18, w);
    }

    function _findMaxDeviation(
        ComputeOracleDeviationLocals memory locals,
        uint256[] memory balancesScaled18,
        uint256[] memory weights
    ) internal pure returns (uint256) {
        // Pairwise check (O(n^2), n<=8).
        for (locals.i = 0; locals.i < balancesScaled18.length; ++locals.i) {
            locals.bi = balancesScaled18[locals.i];
            locals.wi = weights[locals.i];
            locals.pxi = locals.px[locals.i];

            for (locals.j = locals.i + 1; locals.j < balancesScaled18.length; ++locals.j) {
                locals.bj = balancesScaled18[locals.j];
                locals.wj = weights[locals.j];
                locals.pxj = locals.px[locals.j];

                // Pool-implied spot for j vs i: (Bj/wj) / (Bi/wi)
                locals.poolPx = _pairSpotFromBalancesWeights(balancesScaled18, weights, locals.i, locals.j);

                if (locals.poolPx == 0) {
                    continue;
                }

                // External ratio j/i
                locals.extPx = locals.pxj.divDown(locals.pxi);

                locals.dev = _relAbsDiff(locals.poolPx, locals.extPx);

                if (locals.dev > locals.maxDev) {
                    locals.maxDev = locals.dev;
                }
            }
        }

        return locals.maxDev;
    }

    /**
     * @notice Checks if the pool price deviation is worsening after a add/remove liquidity operation.
     * @dev The pool price deviation is worsening if the deviation between oracle and pool price increased and the
     * deviation is greater than the surge threshold.
     *
     * @param pool The pool address
     * @param amountsInScaled18 The amounts added/removed in the operation
     * @param balancesScaled18 The balances after the add/remove liquidity operation
     * @param addAmount True if the amounts are being added, false if removed
     * @return True if the pool price deviation is worsening, false otherwise
     */
    function _isPriceDeviationWorsening(
        address pool,
        uint256[] memory amountsInScaled18,
        uint256[] memory balancesScaled18,
        bool addAmount
    ) internal view returns (bool) {
        uint256[] memory oldBalancesScaled18 = new uint256[](balancesScaled18.length);
        for (uint256 i = 0; i < balancesScaled18.length; ++i) {
            if (addAmount) {
                oldBalancesScaled18[i] = balancesScaled18[i] + amountsInScaled18[i];
            } else {
                oldBalancesScaled18[i] = balancesScaled18[i] - amountsInScaled18[i];
            }
        }

        uint256[] memory weights = WeightedPool(pool).getNormalizedWeights();
        uint256 priceDeviationBefore = _computeOracleDeviationPct(pool, oldBalancesScaled18, weights);
        uint256 priceDeviationAfter = _computeOracleDeviationPct(pool, balancesScaled18, weights);
        uint256 surgeThreshold = getSurgeThresholdPercentage(pool, TradeType.NOISE);

        return (priceDeviationAfter > priceDeviationBefore) && (priceDeviationAfter > surgeThreshold);
    }

    /// @notice Converts a 9 decimal places fixed point number to 18 decimal places.
    function _convertTo18Decimals(uint32 valueScaled9) internal pure returns (uint256) {
        return uint256(valueScaled9) * 1e9;
    }

    /// @notice Converts a 18 decimal places fixed point number to 9 decimal places.
    function _safeConvertTo9Decimals(uint256 valueScaled18) internal pure returns (uint32) {
        return (valueScaled18 / 1e9).toUint32();
    }

    function _ensureValidPercentage(uint256 percentageValue) internal pure {
        if (percentageValue < 1e9 || percentageValue > FixedPoint.ONE || percentageValue % 1e9 != 0) {
            revert InvalidPercentage();
        }
    }
}
