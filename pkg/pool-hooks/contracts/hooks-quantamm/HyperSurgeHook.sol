// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IHooks.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IHyperSurgeHook } from "@balancer-labs/v3-interfaces/contracts/pool-hooks/IHyperSurgeHook.sol";
import {
    PoolSwapParams,
    LiquidityManagement,
    TokenConfig,
    HookFlags,
    SwapKind,
    AddLiquidityKind,
    RemoveLiquidityKind
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";
import { VaultGuard } from "@balancer-labs/v3-vault/contracts/VaultGuard.sol";
import { SingletonAuthentication } from "@balancer-labs/v3-vault/contracts/SingletonAuthentication.sol";
import { Version } from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { WeightedPool } from "@balancer-labs/v3-pool-weighted/contracts/WeightedPool.sol";

/// -----------------------------------------------------------------------
/// Hyperliquid helpers (precompiles) — original revert tags
/// -----------------------------------------------------------------------
library HyperPrice {
    address internal constant PRECOMPILE = 0x0000000000000000000000000000000000000808; // spotPx
    error PricePrecompileFailed();

    function spot(uint32 pairIndex) internal view returns (uint64 price) {
        (bool ok, bytes memory out) = PRECOMPILE.staticcall(abi.encode(pairIndex));
        if (!ok) {
            revert PricePrecompileFailed();
        }
        price = abi.decode(out, (uint64));
    }
}

library HyperTokenInfo {
    address internal constant PRECOMPILE = 0x0000000000000000000000000000000000000807; // tokenInfo

    function szDecimals(uint32 pairIndex) internal view returns (uint8) {
        (bool ok, bytes memory out) = PRECOMPILE.staticcall(abi.encode(pairIndex));
        require(ok, "dec");
        return abi.decode(out, (uint8));
    }
}

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

    struct TokenPriceCfg {
        uint32 pairIndex;
        uint32 priceDivisor; // precomputed: 10**(6 - szDecimals) (or LUT equivalent)
        // remaining bytes pack into same 32-byte slot
    }

    struct PoolDetails {
        uint32 arbMaxSurgeFeePercentage;
        uint32 arbThresholdPercentage;
        uint32 arbCapDeviationPercentage;
        uint32 noiseMaxSurgeFeePercentage;
        uint32 noiseThresholdPercentage;
        uint32 noiseCapDeviationPercentage;
        uint8 numTokens; // 2..8 inclusive
        bool initialized;
    }

    struct PoolCfg {
        PoolDetails details;
        TokenPriceCfg[8] tokenCfg; // per-index config
    }

    mapping(address => PoolCfg) private _poolCfg;

    ///@dev Default in 1e18
    uint256 private immutable _defaultMaxSurgeFee;

    ///@dev Default in 1e18
    uint256 private immutable _defaultThreshold;

    ///@dev Default in 1e18
    uint256 private immutable _defaultCapDeviation;

    constructor(
        IVault vault,
        uint256 defaultMaxSurgeFeePercentage,
        uint256 defaultThresholdPercentage,
        string memory version
    ) SingletonAuthentication(vault) VaultGuard(vault) Version(version) {
        _ensureValidPct(defaultMaxSurgeFeePercentage);
        _ensureValidPct(defaultThresholdPercentage);
        _defaultMaxSurgeFee = defaultMaxSurgeFeePercentage;
        _defaultThreshold = defaultThresholdPercentage;
        _defaultCapDeviation = 1e9; // 1.0 (100%) preserves existing behavior
    }

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
        PoolDetails memory details;
        if (tokenCfgs.length >= 2 && tokenCfgs.length <= 8) {
            details.arbMaxSurgeFeePercentage = _defaultMaxSurgeFee.toUint32();
            details.arbThresholdPercentage = _defaultThreshold.toUint32();
            details.arbCapDeviationPercentage = _defaultCapDeviation.toUint32();
            details.noiseMaxSurgeFeePercentage = _defaultMaxSurgeFee.toUint32();
            details.noiseThresholdPercentage = _defaultThreshold.toUint32();
            details.noiseCapDeviationPercentage = _defaultCapDeviation.toUint32();
            details.numTokens = uint8(tokenCfgs.length);
            details.initialized = true;

            //TODO given the only vault modifier I dont think we need to check if it is already initialised
            _poolCfg[pool].details = details;
        } else {
            revert NumTokensOutOfRange();
        }

        return true;
    }

    /// @notice Configure a single token’s Hyperliquid mapping for a given pool by token index (0..7).
    /// @param pool The pool address to configure.
    /// @param tokenIndex The index of the token to configure (0..7).
    /// @param pairIdx the index of the pair being set
    function setTokenPriceConfigIndex(
        address pool,
        uint8 tokenIndex,
        uint32 pairIdx
    ) external onlySwapFeeManagerOrGovernance(pool) {
        PoolDetails memory details = _poolCfg[pool].details;

        if (!details.initialized) revert PoolNotInitialized();
        if (tokenIndex >= details.numTokens) revert TokenIndexOutOfRange();

        TokenPriceCfg memory tempCfg;
        uint8 sz = 0; // default for USD quoted

        if (pairIdx == 0) {
            revert InvalidPairIndex();
        }

        sz = HyperTokenInfo.szDecimals(pairIdx); // may revert "dec"

        if (sz > 6) {
            revert InvalidDecimals();
        }

        tempCfg.pairIndex = pairIdx;
        tempCfg.priceDivisor = _divisorFromSz(sz); // precompute to avoid EXP in hot path

        _poolCfg[pool].tokenCfg[tokenIndex] = tempCfg;

        emit TokenPriceConfiguredIndex(pool, tokenIndex, tempCfg.pairIndex, sz);
    }

    struct SetBatchConfigs {
        uint8 idx;
        uint8 sz;
        TokenPriceCfg tempCfg;
        uint256 i;
        uint256 len;
    }

    /// @notice Batch version (indices).
    /// @param pool the pool address
    /// @param tokenIndices the indices of the token configs being changed
    /// @param pairIdx the index of the pair being changed
    function setTokenPriceConfigBatchIndex(
        address pool,
        uint8[] calldata tokenIndices,
        uint32[] calldata pairIdx
    ) external onlySwapFeeManagerOrGovernance(pool) {
        PoolDetails memory detail = _poolCfg[pool].details;
        if (!detail.initialized) revert PoolNotInitialized();
        SetBatchConfigs memory cfg;

        if (tokenIndices.length != pairIdx.length) {
            revert InvalidArrayLengths();
        }
        cfg.len = tokenIndices.length;

        for (cfg.i = 0; cfg.i < cfg.len; ) {
            cfg.idx = tokenIndices[cfg.i];

            if (cfg.idx >= detail.numTokens) {
                revert TokenIndexOutOfRange();
            }

            cfg.sz = 0;
            if (pairIdx[cfg.i] == 0) {
                revert InvalidPairIndex();
            }
            cfg.sz = HyperTokenInfo.szDecimals(pairIdx[cfg.i]); // may revert "dec"

            if (cfg.sz > 6) {
                revert InvalidDecimals();
            }

            cfg.tempCfg.pairIndex = pairIdx[cfg.i];
            cfg.tempCfg.priceDivisor = _divisorFromSz(cfg.sz);

            _poolCfg[pool].tokenCfg[cfg.idx] = cfg.tempCfg;

            emit TokenPriceConfiguredIndex(pool, cfg.idx, cfg.tempCfg.pairIndex, cfg.sz);

            unchecked {
                ++cfg.i;
            }
        }
    }

    ///@inheritdoc IHyperSurgeHook
    function setMaxSurgeFeePercentage(
        address pool,
        uint256 pct,
        TradeType tradeType
    ) external override onlySwapFeeManagerOrGovernance(pool) {
        _ensureValidPct(pct);
        if (tradeType == TradeType.ARBITRAGE) {
            _poolCfg[pool].details.arbMaxSurgeFeePercentage = pct.toUint32();
        } else {
            _poolCfg[pool].details.noiseMaxSurgeFeePercentage = pct.toUint32();
        }
        emit MaxSurgeFeePercentageChanged(msg.sender, pool, pct, tradeType);
    }

    ///@inheritdoc IHyperSurgeHook
    function setSurgeThresholdPercentage(
        address pool,
        uint256 pct,
        TradeType tradeType
    ) external override onlySwapFeeManagerOrGovernance(pool) {
        _ensureValidPct(pct); // keep a valid ramp span: threshold < capDev ≤ 1
        uint256 capDev;
        if (tradeType == TradeType.ARBITRAGE) {
            _poolCfg[pool].details.arbThresholdPercentage = pct.toUint32();
            capDev = uint256(_poolCfg[pool].details.arbCapDeviationPercentage);
        } else {
            _poolCfg[pool].details.noiseThresholdPercentage = pct.toUint32();
            capDev = uint256(_poolCfg[pool].details.noiseCapDeviationPercentage);
        }

        if (capDev != 0 && pct >= capDev) {
            revert InvalidThresholdDeviation();
        }

        emit ThresholdPercentageChanged(msg.sender, pool, pct, tradeType);
    }

    /// @inheritdoc IHyperSurgeHook
    function setCapDeviationPercentage(
        address pool,
        uint256 capDevPct,
        TradeType tradeType
    ) external override onlySwapFeeManagerOrGovernance(pool) {
        _ensureValidPct(capDevPct);
        uint256 thr;
        if (tradeType == TradeType.ARBITRAGE) {
            _poolCfg[pool].details.arbCapDeviationPercentage = capDevPct.toUint32();
            thr = uint256(_poolCfg[pool].details.arbThresholdPercentage);
        } else {
            _poolCfg[pool].details.noiseCapDeviationPercentage = capDevPct.toUint32();
            thr = uint256(_poolCfg[pool].details.noiseThresholdPercentage);
        }

        if (capDevPct <= thr) {
            revert InvalidCapDeviationPercentage();
        }

        emit CapDeviationPercentageChanged(msg.sender, pool, capDevPct, tradeType);
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
        address sender,
        address pool,
        AddLiquidityKind kind,
        uint256[] memory amountsInScaled18,
        uint256[] memory amountsInRaw,
        uint256, // lpAmount (unused)
        uint256[] memory balancesScaled18,
        bytes memory // userData (unused)
    ) public override returns (bool success, uint256[] memory hookAdjustedAmountsInRaw) {
        AddLiquidityLocals memory locals;

        // Proportional add is always allowed.
        if (kind == AddLiquidityKind.PROPORTIONAL) {
            return (true, amountsInRaw);
        }

        locals.oldBalances = new uint256[](balancesScaled18.length);
        for (uint256 i = 0; i < balancesScaled18.length; ++i) {
            unchecked {
                locals.oldBalances[i] = balancesScaled18[i] - amountsInScaled18[i];
            }
        }

        uint256[] memory weights = WeightedPool(pool).getNormalizedWeights();
        locals.beforeDev = _computeOracleDeviationPct(pool, locals.oldBalances, weights);
        locals.afterDev = _computeOracleDeviationPct(pool, balancesScaled18, weights);
        locals.threshold = getSurgeThresholdPercentage(pool, TradeType.NOISE);

        // Block only if deviation worsens AND exceeds threshold after the change.
        locals.isWorseningSurge = (locals.afterDev > locals.beforeDev) && (locals.afterDev > locals.threshold);

        if (locals.isWorseningSurge) {
            emit LiquidityBlocked(sender, pool, /*isAdd=*/ true, locals.beforeDev, locals.afterDev, locals.threshold);
        }

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
        address sender,
        address pool,
        RemoveLiquidityKind kind,
        uint256, // lpAmount (unused)
        uint256[] memory amountsOutScaled18,
        uint256[] memory amountsOutRaw,
        uint256[] memory balancesScaled18,
        bytes memory // userData (unused)
    ) public override returns (bool success, uint256[] memory hookAdjustedAmountsOutRaw) {
        RemoveLiquidityLocals memory locals;

        // Proportional remove is always allowed.
        if (kind == RemoveLiquidityKind.PROPORTIONAL) {
            return (true, amountsOutRaw);
        }

        if (amountsOutScaled18.length != balancesScaled18.length) {
            return (true, amountsOutRaw);
        }

        locals.n = balancesScaled18.length;
        if (locals.n < 2) return (true, amountsOutRaw);

        // Reconstruct pre-remove balances = post + out; if addition overflows, allow.
        locals.oldBalances = new uint256[](locals.n);
        for (uint256 i = 0; i < locals.n; ++i) {
            unchecked {
                uint256 b = balancesScaled18[i] + amountsOutScaled18[i];
                if (b < balancesScaled18[i]) {
                    return (true, amountsOutRaw); // overflow wrap -> allow
                }
                locals.oldBalances[i] = b;
            }
        }

        uint256[] memory weights = WeightedPool(pool).getNormalizedWeights();
        locals.beforeDev = _computeOracleDeviationPct(pool, locals.oldBalances, weights);
        locals.afterDev = _computeOracleDeviationPct(pool, balancesScaled18, weights);
        locals.threshold = getSurgeThresholdPercentage(pool, TradeType.NOISE);

        locals.isWorseningSurge = (locals.afterDev > locals.beforeDev) && (locals.afterDev > locals.threshold);

        if (locals.isWorseningSurge) {
            emit LiquidityBlocked(sender, pool, false, locals.beforeDev, locals.afterDev, locals.threshold);
        }

        return (!locals.isWorseningSurge, amountsOutRaw);
    }

    struct ComputeOracleDeviationLocals {
        uint256[8] px;
        uint256 maxDev;
        uint64 raw;
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
        PoolDetails memory details = pc.details;

        if (!details.initialized) {
            return 0;
        }

        // Build external prices per token (1e18). Missing/zero -> mark as 0 (skipped).
        for (locals.i = 0; locals.i < balancesScaled18.length; ++locals.i) {
            TokenPriceCfg memory cfg = pc.tokenCfg[locals.i];
            if (cfg.pairIndex != 0) {
                locals.raw = HyperPrice.spot(cfg.pairIndex); // reverts if precompile fails
                if (locals.raw != 0) {
                    // cfg.priceDivisor precomputed as 10**(6 - szDecimals)
                    if (cfg.priceDivisor != 0) {
                        locals.px[locals.i] = (uint256(locals.raw) * 1e18) / uint256(cfg.priceDivisor);
                    }
                }
            }
        }

        // Pairwise check (O(n^2), n<=8).
        for (locals.i = 0; locals.i < balancesScaled18.length; ) {
            locals.bi = balancesScaled18[locals.i];
            locals.wi = w[locals.i];
            locals.pxi = locals.px[locals.i];

            if (locals.pxi == 0) {
                //Do not block if there is an issue with the hyperliquid price
                return 0;
            }

            for (locals.j = locals.i + 1; locals.j < balancesScaled18.length; ) {
                locals.bj = balancesScaled18[locals.j];
                locals.wj = w[locals.j];
                locals.pxj = locals.px[locals.j];

                if (locals.pxj == 0) {
                    //Do not block if there is an issue with the hyperliquid price
                    return 0;
                }

                // Pool-implied spot for j vs i: (Bj/wj) / (Bi/wi)
                locals.poolPx = _pairSpotFromBalancesWeights(locals.bj, locals.wj, locals.bi, locals.wi);
                if (locals.poolPx == 0) continue;

                // External ratio j/i
                locals.extPx = locals.pxj.divDown(locals.pxi);

                locals.dev = _relAbsDiff(locals.poolPx, locals.extPx);
                if (locals.dev > locals.maxDev) locals.maxDev = locals.dev;
                unchecked {
                    ++locals.j;
                }
            }
            unchecked {
                ++locals.i;
            }
        }

        return locals.maxDev;
    }

    /// @notice Getter to read the pool-specific surge threshold (1e18 = 100%).
    function getSurgeThresholdPercentage(address pool, TradeType tradeType) public view override returns (uint256) {
        if (tradeType == TradeType.ARBITRAGE) {
            return uint256(_poolCfg[pool].details.arbThresholdPercentage) * 1e9;
        } else {
            return uint256(_poolCfg[pool].details.noiseThresholdPercentage) * 1e9;
        }
    }

    ///@inheritdoc IHyperSurgeHook
    function getMaxSurgeFeePercentage(address pool, TradeType tradeType) external view override returns (uint256) {
        if (tradeType == TradeType.ARBITRAGE) {
            return uint256(_poolCfg[pool].details.arbMaxSurgeFeePercentage) * 1e9;
        } else {
            return uint256(_poolCfg[pool].details.noiseMaxSurgeFeePercentage) * 1e9;
        }
    }

    ///@inheritdoc IHyperSurgeHook
    function getCapDeviationPercentage(address pool, TradeType tradeType) external view override returns (uint256) {
        if (tradeType == TradeType.ARBITRAGE) {
            return uint256(_poolCfg[pool].details.arbCapDeviationPercentage) * 1e9;
        } else {
            return uint256(_poolCfg[pool].details.noiseCapDeviationPercentage) * 1e9;
        }
    }

    ///@inheritdoc IHyperSurgeHook
    function getTokenPriceConfigIndex(
        address pool,
        uint8 tokenIndex
    ) external view override returns (uint32 pairIndex, uint32 priceDivisor) {
        TokenPriceCfg memory cfg = _poolCfg[pool].tokenCfg[tokenIndex];
        return (cfg.pairIndex, cfg.priceDivisor);
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
            priceDivisorArr[i] = cfg.priceDivisor;
        }
    }

    ///@inheritdoc IHyperSurgeHook
    function getDefaultMaxSurgeFeePercentage() external view override returns (uint256) {
        //already in 1e18 no need to convert
        return _defaultMaxSurgeFee;
    }

    ///@inheritdoc IHyperSurgeHook
    function getDefaultSurgeThresholdPercentage() external view override returns (uint256) {
        //already in 1e18 no need to convert
        return _defaultThreshold;
    }

    struct ComputeSurgeFeeLocals {
        uint256 calcAmountScaled18;
        uint256 poolPxBefore;
        uint256 poolPx;
        uint256 pxIn;
        uint256 pxOut;
        uint256 extPx;
        uint256 deviation;
        uint256 threshold;
        uint256 maxPct;
        uint256 increment;
        uint256 surgeFee;
        uint256 capDevPct;
        uint256 bIn;
        uint256 bOut;
        uint64 rawIn;
        uint64 rawOut;
        uint256 wIn;
        uint256 wOut;
        uint256 span;
        uint256 norm;
        PoolDetails poolDetails;
    }

    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata p,
        address pool,
        uint256 staticSwapFee
    ) public view override onlyVault returns (bool, uint256) {
        PoolCfg storage pc = _poolCfg[pool];
        ComputeSurgeFeeLocals memory locals;
        locals.poolDetails = pc.details;

        uint256[] memory weights = WeightedPool(pool).getNormalizedWeights();
        locals.wIn = weights[p.indexIn];
        locals.wOut = weights[p.indexOut];

        if (!locals.poolDetails.initialized) {
            return (false, staticSwapFee);
        }

        //TODO overkill check? wont it just throw if the index is out of bounds?
        if (p.indexIn >= locals.poolDetails.numTokens || p.indexOut >= locals.poolDetails.numTokens) {
            return (true, staticSwapFee);
        }

        //TODO overkill check? wont it just throw if the index is out of bounds?
        if (weights.length <= p.indexIn || weights.length <= p.indexOut) {
            return (true, staticSwapFee);
        }

        locals.calcAmountScaled18 = WeightedPool(pool).onSwap(p);

        TokenPriceCfg memory pInCfg = pc.tokenCfg[p.indexIn];
        TokenPriceCfg memory pOutCfg = pc.tokenCfg[p.indexOut];

        locals.rawIn = HyperPrice.spot(pInCfg.pairIndex);
        locals.rawOut = HyperPrice.spot(pOutCfg.pairIndex);

        locals.pxIn = (uint256(locals.rawIn) * 1e18) / uint256(pInCfg.priceDivisor);
        locals.pxOut = (uint256(locals.rawOut) * 1e18) / uint256(pOutCfg.priceDivisor);

        //Do not block if there is an issue with the hyperliquid price
        if (locals.pxIn == 0 || locals.pxOut == 0) {
            return (true, staticSwapFee);
        }

        locals.bIn = p.balancesScaled18[p.indexIn];
        locals.bOut = p.balancesScaled18[p.indexOut];

        return _computeSurgeFee(locals, p, staticSwapFee);
    }

    function _computeSurgeFee(
        ComputeSurgeFeeLocals memory locals,
        PoolSwapParams calldata p,
        uint256 staticSwapFee
    ) internal pure returns (bool ok, uint256 surgeFee) {
        locals.poolPxBefore = _pairSpotFromBalancesWeights(locals.bIn, locals.wIn, locals.bOut, locals.wOut);

        if (p.kind == SwapKind.EXACT_IN) {
            locals.bIn += p.amountGivenScaled18;
            locals.bOut -= locals.calcAmountScaled18;
        } else {
            locals.bIn += locals.calcAmountScaled18;
            locals.bOut -= p.amountGivenScaled18;
        }

        // P_pool = (B_out/w_out) / (B_in/w_in) = (B_out * w_in) / (B_in * w_out)
        locals.poolPx = _pairSpotFromBalancesWeights(locals.bIn, locals.wIn, locals.bOut, locals.wOut);
        if (locals.poolPx == 0) return (true, staticSwapFee);

        locals.extPx = locals.pxOut.divDown(locals.pxIn);

        //Do not block if there is an issue with the hyperliquid price
        if (locals.extPx == 0) return (true, staticSwapFee);

        // 5) Deviation
        locals.deviation = _relAbsDiff(locals.poolPx, locals.extPx); // |pool - ext| / ext

        if ((locals.poolPx > locals.poolPxBefore)) {
            if (locals.poolPxBefore < locals.extPx) {
                // If the pool price is increasing, we are in an arbitrage situation
                locals.capDevPct = uint256(locals.poolDetails.arbCapDeviationPercentage);
                locals.maxPct = uint256(locals.poolDetails.arbMaxSurgeFeePercentage);
                locals.threshold = uint256(locals.poolDetails.arbThresholdPercentage);
            } else {
                // If the pool price is decreasing, we are in a noise situation
                locals.capDevPct = uint256(locals.poolDetails.noiseCapDeviationPercentage);
                locals.maxPct = uint256(locals.poolDetails.noiseMaxSurgeFeePercentage);
                locals.threshold = uint256(locals.poolDetails.noiseThresholdPercentage);
            }
        } else {
            if (locals.poolPxBefore < locals.extPx) {
                // If the pool price is increasing, we are in a noise situation
                locals.capDevPct = uint256(locals.poolDetails.noiseCapDeviationPercentage);
                locals.maxPct = uint256(locals.poolDetails.noiseMaxSurgeFeePercentage);
                locals.threshold = uint256(locals.poolDetails.noiseThresholdPercentage);
            } else {
                // If the pool price is decreasing, we are in an arbitrage situation
                locals.capDevPct = uint256(locals.poolDetails.arbCapDeviationPercentage);
                locals.maxPct = uint256(locals.poolDetails.arbMaxSurgeFeePercentage);
                locals.threshold = uint256(locals.poolDetails.arbThresholdPercentage);
            }
        }

        // convert to 1e18 scale
        locals.capDevPct *= 1e9;
        locals.maxPct *= 1e9;
        locals.threshold *= 1e9;

        if (locals.deviation <= locals.threshold) {
            return (true, staticSwapFee);
        }

        locals.span = locals.capDevPct - locals.threshold; // > 0 by fallback above

        locals.norm = (locals.deviation - locals.threshold).divDown(locals.span);

        if (locals.norm > FixedPoint.ONE) {
            locals.norm = FixedPoint.ONE;
        }

        locals.increment = (locals.maxPct - staticSwapFee).mulDown(locals.norm);
        locals.surgeFee = staticSwapFee + locals.increment;
        if (locals.surgeFee > locals.maxPct) locals.surgeFee = locals.maxPct;

        return (true, locals.surgeFee);
    }

    function _pairSpotFromBalancesWeights(
        uint256 bIn,
        uint256 wIn,
        uint256 bOut,
        uint256 wOut
    ) internal pure returns (uint256) {
        uint256 num = bOut.mulDown(wIn);
        uint256 den = bIn.mulDown(wOut);

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

    function _divisorFromSz(uint8 s) internal pure returns (uint32) {
        // s in [0..6], divisor = 10**(6 - s)
        // LUT avoids EXP cost both at config and (especially) runtime.
        if (s == 0) return 1_000_000;
        if (s == 1) return 100_000;
        if (s == 2) return 10_000;
        if (s == 3) return 1_000;
        if (s == 4) return 100;
        if (s == 5) return 10;
        // s == 6
        return 1;
    }

    function _ensureValidPct(uint256 pct) internal pure {
        if (pct > 1e9) revert("pct");
    }

    ///@inheritdoc IHyperSurgeHook
    function getNumTokens(address pool) external view override returns (uint8) {
        return _poolCfg[pool].details.numTokens;
    }

    ///@inheritdoc IHyperSurgeHook
    function isPoolInitialized(address pool) external view override returns (bool) {
        return _poolCfg[pool].details.initialized;
    }
}
