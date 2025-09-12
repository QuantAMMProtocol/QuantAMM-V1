// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IHyperSurgeHook } from "@balancer-labs/v3-interfaces/contracts/pool-hooks/IHyperSurgeHook.sol";
import { IHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IHooks.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { SingletonAuthentication } from "@balancer-labs/v3-vault/contracts/SingletonAuthentication.sol";
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
    error NumTokensOutOfRange();
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

    mapping(address => PoolCfg) private _poolCfg;

    uint256 private immutable _defaultMaxSurgeFeePercentage18;

    uint256 private immutable _defaultThresholdPercentage18;

    uint256 private immutable _defaultCapDeviationPercentage18;

    modifier ensureValidPercentage(uint256 percentageValue) {
        if (percentageValue < 1e9 || percentageValue > 1e18 || percentageValue % 1e9 != 0) {
            revert InvalidPercentage();
        }
        _;
    }

    constructor(
        IVault vault,
        uint256 defaultMaxSurgeFeePercentage18,
        uint256 defaultThresholdPercentage18,
        uint256 defaultCapDeviationPercentage18,
        string memory version
    ) SingletonAuthentication(vault) VaultGuard(vault) Version(version) {
        _ensureValidPct(defaultMaxSurgeFeePercentage18);
        _ensureValidPct(defaultThresholdPercentage18);
        _ensureValidPct(defaultCapDeviationPercentage18);
        _defaultMaxSurgeFeePercentage18 = defaultMaxSurgeFeePercentage18;
        _defaultThresholdPercentage18 = defaultThresholdPercentage18;
        _defaultCapDeviationPercentage18 = defaultCapDeviationPercentage18;
    }

    /**************************************************
                           Hooks   
     **************************************************/

    ///@inheritdoc IHooks
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
        if (tokenCfgs.length < 2 || tokenCfgs.length > 8) {
            revert NumTokensOutOfRange();
        }

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

    struct AddLiquidityLocals {
        uint256[] oldBalances;
        uint256 beforeDev;
        uint256 afterDev;
        uint256 threshold;
        bool isWorseningSurge;
    }

    /// @notice Allow proportional adds, but block non-proportional adds that worsen deviation and end above threshold.
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
        AddLiquidityLocals memory locals;

        // Proportional add is always allowed.
        if (kind == AddLiquidityKind.PROPORTIONAL) {
            return (true, amountsInRaw);
        }

        locals.oldBalances = new uint256[](balancesScaled18.length);
        for (uint256 i = 0; i < balancesScaled18.length; ++i) {
            locals.oldBalances[i] = balancesScaled18[i] - amountsInScaled18[i];
        }

        uint256[] memory weights = WeightedPool(pool).getNormalizedWeights();
        locals.beforeDev = _computeOracleDeviationPct(pool, locals.oldBalances, weights);
        locals.afterDev = _computeOracleDeviationPct(pool, balancesScaled18, weights);
        locals.threshold = getSurgeThresholdPercentage(pool, TradeType.NOISE);

        // Block only if deviation worsens AND exceeds threshold after the change.
        locals.isWorseningSurge = (locals.afterDev > locals.beforeDev) && (locals.afterDev > locals.threshold);

        return (!locals.isWorseningSurge, amountsInRaw);
    }

    struct RemoveLiquidityLocals {
        uint256 n;
        uint256[] oldBalances;
        uint256 beforeDev;
        uint256 afterDev;
        uint256 threshold;
        bool isWorseningSurge;
    }

    /// @notice Allow proportional removes, but block non-proportional removes that worsen deviation and end above threshold.
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
        RemoveLiquidityLocals memory locals;
        locals.n = balancesScaled18.length;
        // Proportional remove is always allowed. should we check?
        if (kind == RemoveLiquidityKind.PROPORTIONAL) {
            return (true, amountsOutRaw);
        }

        // Reconstruct pre-remove balances = post + out; if addition overflows, allow.
        locals.oldBalances = new uint256[](locals.n);
        for (uint256 i = 0; i < locals.n; ++i) {
            locals.oldBalances[i] = balancesScaled18[i] + amountsOutScaled18[i];
        }

        uint256[] memory weights = WeightedPool(pool).getNormalizedWeights();
        locals.beforeDev = _computeOracleDeviationPct(pool, locals.oldBalances, weights);
        locals.afterDev = _computeOracleDeviationPct(pool, balancesScaled18, weights);
        locals.threshold = getSurgeThresholdPercentage(pool, TradeType.NOISE);

        locals.isWorseningSurge = (locals.afterDev > locals.beforeDev) && (locals.afterDev > locals.threshold);

        return (!locals.isWorseningSurge, amountsOutRaw);
    }

    /**************************************************
                           Setters   
     **************************************************/

    /// @notice Configure a single token’s Hyperliquid mapping for a given pool by token index (0..7).
    /// @param pool The pool address to configure.
    /// @param tokenIndex The balancer index of the token to configure (0..7).
    /// @param hlPairIdx the index of the pair being set
    /// @param hlTokenIdx the index of the token being set
    function setTokenPriceConfigIndex(
        address pool,
        uint8 tokenIndex,
        uint32 hlPairIdx,
        uint32 hlTokenIdx
    ) external onlySwapFeeManagerOrGovernance(pool) {
        PoolDetails storage details = _poolCfg[pool].details;
        _setTokenPriceConfigIndex(pool, tokenIndex, hlPairIdx, hlTokenIdx, details);
    }

    struct SetBatchConfigs {
        TokenPriceCfg tempCfg;
        uint256 i;
    }

    /// @notice Batch version (indices).
    /// @param pool the pool address
    /// @param tokenIndices the indices of the token configs being changed
    /// @param pairIdx the index of the pair being changed
    function setTokenPriceConfigBatchIndex(
        address pool,
        uint8[] calldata tokenIndices,
        uint32[] calldata pairIdx,
        uint32[] calldata hlTokenIdx
    ) external onlySwapFeeManagerOrGovernance(pool) {
        PoolDetails storage detail = _poolCfg[pool].details;
        SetBatchConfigs memory cfg;

        if (tokenIndices.length != pairIdx.length) {
            revert InvalidArrayLengths();
        }

        for (cfg.i = 0; cfg.i < tokenIndices.length; ++cfg.i) {
            _setTokenPriceConfigIndex(pool, tokenIndices[cfg.i], pairIdx[cfg.i], hlTokenIdx[cfg.i], detail);
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

        if (tempCfg.sz > 8) {
            revert InvalidDecimals();
        }

        tempCfg.pairIndex = hlPairIdx;

        _poolCfg[pool].tokenCfg[tokenIndex] = tempCfg;

        emit TokenPriceConfiguredIndex(pool, tokenIndex, tempCfg.pairIndex, hlTokenIdx, tempCfg.sz);
    }

    ///@inheritdoc IHyperSurgeHook
    function setMaxSurgeFeePercentage(
        address pool,
        uint256 newMaxSurgeFeePercentageScaled18,
        TradeType tradeType
    ) external override onlySwapFeeManagerOrGovernance(pool) {
        _setMaxSurgeFeePercentage(pool, newMaxSurgeFeePercentageScaled18, tradeType);
    }

    function _setMaxSurgeFeePercentage(
        address pool,
        uint256 newMaxSurgeFeePercentageScaled18,
        TradeType tradeType
    ) internal ensureValidPercentage(newMaxSurgeFeePercentageScaled18) {
        if (tradeType == TradeType.ARBITRAGE) {
            _poolCfg[pool].details.arbMaxSurgeFee9 = _safeConvertTo9Decimals(newMaxSurgeFeePercentageScaled18);
        } else {
            _poolCfg[pool].details.noiseMaxSurgeFee9 = _safeConvertTo9Decimals(newMaxSurgeFeePercentageScaled18);
        }

        emit MaxSurgeFeePercentageChanged(msg.sender, pool, newMaxSurgeFeePercentageScaled18, tradeType);
    }

    ///@inheritdoc IHyperSurgeHook
    function setSurgeThresholdPercentage(
        address pool,
        uint256 newThresholdPercentageScaled18,
        TradeType tradeType
    ) external override onlySwapFeeManagerOrGovernance(pool) {
        _setSurgeThresholdPercentage(pool, newThresholdPercentageScaled18, tradeType);
    }

    function _setSurgeThresholdPercentage(
        address pool,
        uint256 newThresholdPercentageScaled18,
        TradeType tradeType
    ) internal ensureValidPercentage(newThresholdPercentageScaled18) {
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
    ) external override onlySwapFeeManagerOrGovernance(pool) {
        _setCapDeviationPercentage(pool, newCapDeviationPercentageScaled18, tradeType);
    }

    function _setCapDeviationPercentage(
        address pool,
        uint256 newCapDeviationPercentageScaled18,
        TradeType tradeType
    ) internal ensureValidPercentage(newCapDeviationPercentageScaled18) {
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

    ///@inheritdoc IHyperSurgeHook
    function getMaxSurgeFeePercentage(address pool, TradeType tradeType) external view override returns (uint256) {
        if (tradeType == TradeType.ARBITRAGE) {
            return _convertTo18Decimals(_poolCfg[pool].details.arbMaxSurgeFee9);
        } else {
            return _convertTo18Decimals(_poolCfg[pool].details.noiseMaxSurgeFee9);
        }
    }

    ///@inheritdoc IHyperSurgeHook
    function getCapDeviationPercentage(address pool, TradeType tradeType) external view override returns (uint256) {
        if (tradeType == TradeType.ARBITRAGE) {
            return _convertTo18Decimals(_poolCfg[pool].details.arbCapDeviationPercentage9);
        } else {
            return _convertTo18Decimals(_poolCfg[pool].details.noiseCapDeviationPercentage9);
        }
    }

    ///@inheritdoc IHyperSurgeHook
    function getTokenPriceConfigIndex(
        address pool,
        uint8 tokenIndex
    ) external view override returns (uint32 pairIndex, uint32 priceDivisor) {
        TokenPriceCfg memory cfg = _poolCfg[pool].tokenCfg[tokenIndex];
        return (cfg.pairIndex, _divisorFromSz(cfg.sz));
    }

    ///@inheritdoc IHyperSurgeHook
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

    ///@inheritdoc IHyperSurgeHook
    function getDefaultMaxSurgeFeePercentage() external view override returns (uint256) {
        return _defaultMaxSurgeFeePercentage18;
    }

    ///@inheritdoc IHyperSurgeHook
    function getDefaultSurgeThresholdPercentage() external view override returns (uint256) {
        return _defaultThresholdPercentage18;
    }

    ///@inheritdoc IHyperSurgeHook
    function getDefaultCapDeviationPercentage() external view override returns (uint256) {
        return _defaultCapDeviationPercentage18;
    }

    ///@inheritdoc IHyperSurgeHook
    function getNumTokens(address pool) external view override returns (uint8) {
        return _poolCfg[pool].details.numTokens;
    }

    struct ComputeSurgeFeeLocals {
        uint256 calcAmountScaled18;
        uint256 poolPxBefore;
        uint256 poolPx;
        uint256 pxIn;
        uint256 pxOut;
        uint256 extPx;
        uint256 deviationBefore18;
        uint256 deviation18;
        uint256 threshold18;
        uint256 maxPct18;
        uint256 increment;
        uint256 surgeFee18;
        uint256 capDevPct18;
        uint256 bIn;
        uint256 bOut;
        uint256 rawIn;
        uint256 rawOut;
        uint256 wIn;
        uint256 wOut;
        uint256 span;
        uint256 norm;
        PoolDetails poolDetails;
    }

    /// @inheritdoc IHooks
    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata p,
        address pool,
        uint256 staticSwapFee
    ) public view override returns (bool, uint256) {
        PoolCfg storage pc = _poolCfg[pool];
        ComputeSurgeFeeLocals memory locals;
        locals.poolDetails = pc.details;

        uint256[] memory weights = WeightedPool(pool).getNormalizedWeights();
        locals.wIn = weights[p.indexIn];
        locals.wOut = weights[p.indexOut];

        locals.calcAmountScaled18 = WeightedPool(pool).onSwap(p);

        TokenPriceCfg memory pInCfg = pc.tokenCfg[p.indexIn];
        TokenPriceCfg memory pOutCfg = pc.tokenCfg[p.indexOut];

        locals.rawIn = HyperSpotPricePrecompile.spotPrice(pInCfg.pairIndex);
        locals.rawOut = HyperSpotPricePrecompile.spotPrice(pOutCfg.pairIndex);
        locals.pxIn = locals.rawIn.divDown(_divisorFromSz(pInCfg.sz));
        locals.pxOut = locals.rawOut.divDown(_divisorFromSz(pOutCfg.sz));
        locals.bIn = p.balancesScaled18[p.indexIn];
        locals.bOut = p.balancesScaled18[p.indexOut];

        return _computeSurgeFee(locals, p, staticSwapFee);
    }

    /// @notice pure function to compute surge fee
    /// @param locals the locals struct containing all the necessary variables
    /// @param p swap parameters
    /// @param staticSwapFee the static swap fee from the pool
    function _computeSurgeFee(
        ComputeSurgeFeeLocals memory locals,
        PoolSwapParams calldata p,
        uint256 staticSwapFee
    ) internal pure returns (bool ok, uint256 surgeFee) {
        locals.extPx = locals.pxOut.divDown(locals.pxIn);

        //Do not block if there is an issue with the hyperliquid price
        if (locals.extPx == 0) {
            return (true, staticSwapFee);
        }

        locals.poolPxBefore = _pairSpotFromBalancesWeights(locals.bIn, locals.wIn, locals.bOut, locals.wOut);
        locals.deviationBefore18 = _relAbsDiff(locals.poolPxBefore, locals.extPx);

        if (p.kind == SwapKind.EXACT_IN) {
            locals.bIn += p.amountGivenScaled18;
            locals.bOut -= locals.calcAmountScaled18;
        } else {
            locals.bIn += locals.calcAmountScaled18;
            locals.bOut -= p.amountGivenScaled18;
        }

        // P_pool = (B_out/w_out) / (B_in/w_in) = (B_out * w_in) / (B_in * w_out)
        locals.poolPx = _pairSpotFromBalancesWeights(locals.bIn, locals.wIn, locals.bOut, locals.wOut);
        locals.deviation18 = _relAbsDiff(locals.poolPx, locals.extPx); // |pool - ext| / ext

        if (locals.deviation18 > locals.deviationBefore18) {
            locals.capDevPct18 = _convertTo18Decimals(locals.poolDetails.noiseCapDeviationPercentage9);
            locals.maxPct18 = _convertTo18Decimals(locals.poolDetails.noiseMaxSurgeFee9);
            locals.threshold18 = _convertTo18Decimals(locals.poolDetails.noiseThresholdPercentage9);
        } else {
            locals.capDevPct18 = _convertTo18Decimals(locals.poolDetails.arbCapDeviationPercentage9);
            locals.maxPct18 = _convertTo18Decimals(locals.poolDetails.arbMaxSurgeFee9);
            locals.threshold18 = _convertTo18Decimals(locals.poolDetails.arbThresholdPercentage9);

            //For the arbitrage direction we use the deviation before.
            //Why this is the case is in the readme but in essence
            //if a large noise deviation is being corrected the arbitrage pays more
            //to take advantage of the larger arb opp and therefore greater profit
            //as the fee decreases the closer you get to market price, another
            //arb opportunity presents itself once the first arb is taken
            //this means a large fee != a large no arb region and the pool stays close to market
            locals.deviation18 = locals.deviationBefore18;
        }

        if (locals.deviation18 <= locals.threshold18) {
            return (true, staticSwapFee);
        }

        locals.span = locals.capDevPct18 - locals.threshold18; // > 0 by fallback above
        locals.norm = (locals.deviation18 - locals.threshold18).divDown(locals.span);

        if (locals.norm > FixedPoint.ONE) {
            locals.norm = FixedPoint.ONE;
        }

        locals.increment = (locals.maxPct18 - staticSwapFee).mulDown(locals.norm);
        locals.surgeFee18 = staticSwapFee + locals.increment;

        return (true, locals.surgeFee18);
    }

    function _pairSpotFromBalancesWeights(
        uint256 bIn,
        uint256 wIn,
        uint256 bOut,
        uint256 wOut
    ) internal pure returns (uint256) {
        uint256 num = bOut.mulDown(wIn);
        uint256 den = bIn.mulDown(wOut);

        //would be impossible given normal balances and weights but given
        //it is on the withdraw path keep the defensive check
        if (den == 0) {
            return 0;
        }

        return num.divDown(den);
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

    function _ensureValidPct(uint256 pct) internal pure {
        if (pct < 1e9 || pct > 1e18 || pct % 1e9 != 0) {
            revert InvalidPercentage();
        }
    }

    ///@notice Converts a 9 decimal places fixed point number to 18 decimal places.
    function _convertTo18Decimals(uint32 setting9Dp) internal pure returns (uint256) {
        return uint256(setting9Dp) * 1e9;
    }

    function _safeConvertTo9Decimals(uint256 setting18Dp) internal pure returns (uint32) {
        return (setting18Dp / 1e9).toUint32();
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

    /// @dev Computes the pool-wide oracle deviation as the MAX pairwise deviation
    ///      across all token pairs (i<j): |P_pool(i->j) - P_ext(i->j)| / P_ext(i->j).
    ///      Uses the same spot & external price conventions as the swap-fee compute.
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
        uint256[] memory w
    ) internal pure returns (uint256) {
        // Pairwise check (O(n^2), n<=8).
        for (locals.i = 0; locals.i < balancesScaled18.length; ++locals.i) {
            locals.bi = balancesScaled18[locals.i];
            locals.wi = w[locals.i];
            locals.pxi = locals.px[locals.i];

            for (locals.j = locals.i + 1; locals.j < balancesScaled18.length; ++locals.j) {
                locals.bj = balancesScaled18[locals.j];
                locals.wj = w[locals.j];
                locals.pxj = locals.px[locals.j];

                // Pool-implied spot for j vs i: (Bj/wj) / (Bi/wi)
                locals.poolPx = _pairSpotFromBalancesWeights(locals.bj, locals.wj, locals.bi, locals.wi);

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
}
