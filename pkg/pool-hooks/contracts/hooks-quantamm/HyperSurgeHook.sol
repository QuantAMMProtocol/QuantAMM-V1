// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

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

    function spot(uint32 pairIndex) internal view returns (uint64 price) {
        (bool ok, bytes memory out) = PRECOMPILE.staticcall(abi.encode(pairIndex));
        require(ok, "price");
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

    // ===== Errors
    error InvalidArrayLengths();
    error TokenIndexOutOfRange();
    error NumTokensOutOfRange();


    // ===== Types
    struct TokenPriceCfg {
        uint32 pairIndex; // Hyperliquid market id (0 allowed only when isUsd = 1)
        uint8 isUsd; // 1 = USD quoted (price = 1e18), 0 = use HL spot
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
    uint256 private immutable _defaultMaxSurgeFee;
    uint256 private immutable _defaultThreshold;
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

    // ===== Register: set numTokens, defaults (index-only config)
    /// @inheritdoc IHooks
    function onRegister(
        address,
        address pool,
        TokenConfig[] memory tokenCfgs,
        LiquidityManagement calldata
    ) public override onlyVault returns (bool) {
        PoolCfg storage pc = _poolCfg[pool];

        uint256 n = tokenCfgs.length;
        if (n < 2 || n > 8) revert NumTokensOutOfRange();

        pc.details.arbMaxSurgeFeePercentage = _defaultMaxSurgeFee.toUint32();
        pc.details.arbThresholdPercentage = _defaultThreshold.toUint32();
        pc.details.arbCapDeviationPercentage = _defaultCapDeviation.toUint32();
        pc.details.noiseMaxSurgeFeePercentage = _defaultMaxSurgeFee.toUint32();
        pc.details.noiseThresholdPercentage = _defaultThreshold.toUint32();
        pc.details.noiseCapDeviationPercentage = _defaultCapDeviation.toUint32();
        pc.details.numTokens = uint8(n);
        pc.details.initialized = true;

        // No address-based mappings; indices are fixed by the pool and used for config.
        return true;
    }

    // ========= Owner configuration (index-based) =========

    /// @notice Configure a single token’s Hyperliquid mapping for a given pool by token index (0..7).
    /// @param pool The pool address to configure.
    /// @param tokenIndex The index of the token to configure (0..7).
    /// @param pairIdx the index of the pair being set
    /// @param isUsd if the hyperliquid price is based in usd
    function setTokenPriceConfigIndex(
        address pool,
        uint8 tokenIndex,
        uint32 pairIdx,
        bool isUsd
    ) external onlySwapFeeManagerOrGovernance(pool) {
        PoolDetails memory details = _poolCfg[pool].details;
        require(details.initialized, "POOL");
        if (tokenIndex >= details.numTokens) revert TokenIndexOutOfRange();

        TokenPriceCfg memory tempCfg;
        uint8 sz = 0; // default for USD quoted
        if (isUsd) {
            tempCfg.pairIndex = 0;
            tempCfg.isUsd = 1;
            tempCfg.priceDivisor = 1; // unused at runtime when isUsd=1, set to 1 defensively
        } else {
            require(pairIdx != 0, "PAIRIDX");
            sz = HyperTokenInfo.szDecimals(pairIdx); // may revert "dec"
            require(sz <= 6, "dec");

            tempCfg.pairIndex = pairIdx;
            tempCfg.isUsd = 0;
            tempCfg.priceDivisor = _divisorFromSz(sz); // precompute to avoid EXP in hot path
        }

        _poolCfg[pool].tokenCfg[tokenIndex] = tempCfg;

        emit TokenPriceConfiguredIndex(pool, tokenIndex, tempCfg.pairIndex, sz, tempCfg.isUsd == 1);
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
    /// @param isUsd if the hyperliquid prices are based in USD
    function setTokenPriceConfigBatchIndex(
        address pool,
        uint8[] calldata tokenIndices,
        uint32[] calldata pairIdx,
        bool[] calldata isUsd
    ) external onlySwapFeeManagerOrGovernance(pool) {
        PoolDetails memory detail = _poolCfg[pool].details;
        require(detail.initialized, "POOL");
        SetBatchConfigs memory cfg;
        if (tokenIndices.length != pairIdx.length || tokenIndices.length != isUsd.length) revert InvalidArrayLengths();
        cfg.len = tokenIndices.length;
        for (cfg.i = 0; cfg.i < cfg.len; ) {
            cfg.idx = tokenIndices[cfg.i];
            if (cfg.idx >= detail.numTokens) revert TokenIndexOutOfRange();
            cfg.sz = 0; // default for USD quoted
            if (isUsd[cfg.i]) {
                cfg.tempCfg.pairIndex = 0;
                cfg.tempCfg.isUsd = 1;
                cfg.tempCfg.priceDivisor = 1;
            } else {
                require(pairIdx[cfg.i] != 0, "PAIRIDX");
                cfg.sz = HyperTokenInfo.szDecimals(pairIdx[cfg.i]); // may revert "dec"
                require(cfg.sz <= 6, "dec");

                cfg.tempCfg.pairIndex = pairIdx[cfg.i];
                cfg.tempCfg.isUsd = 0;
                cfg.tempCfg.priceDivisor = _divisorFromSz(cfg.sz);
            }

            _poolCfg[pool].tokenCfg[cfg.idx] = cfg.tempCfg;

            emit TokenPriceConfiguredIndex(pool, cfg.idx, cfg.tempCfg.pairIndex, cfg.sz, cfg.tempCfg.isUsd == 1);
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
        if(tradeType == TradeType.ARBITRAGE){
            _poolCfg[pool].details.arbMaxSurgeFeePercentage = pct.toUint32();
        } else {
            _poolCfg[pool].details.noiseMaxSurgeFeePercentage = pct.toUint32();
        }
        emit MaxSurgeFeePercentageChanged(pool, pct, tradeType);
    }

    ///@inheritdoc IHyperSurgeHook
    function setSurgeThresholdPercentage(
        address pool,
        uint256 pct, 
        TradeType tradeType
    ) external override onlySwapFeeManagerOrGovernance(pool) {
        _ensureValidPct(pct); // keep a valid ramp span: threshold < capDev ≤ 1
        uint256 capDev;
        if(tradeType == TradeType.ARBITRAGE){
            _poolCfg[pool].details.arbThresholdPercentage = pct.toUint32();
            capDev = uint256(_poolCfg[pool].details.arbCapDeviationPercentage);
        }
        else{
            _poolCfg[pool].details.noiseThresholdPercentage = pct.toUint32();
            capDev = uint256(_poolCfg[pool].details.noiseCapDeviationPercentage);
        }

        require(capDev == 0 || pct < capDev, "cap<=thr");
        emit ThresholdPercentageChanged(pool, pct, tradeType);
    }

    /// @inheritdoc IHyperSurgeHook
    function setCapDeviationPercentage(
        address pool,
        uint256 capDevPct, 
        TradeType tradeType
    ) external override onlySwapFeeManagerOrGovernance(pool) {
        _ensureValidPct(capDevPct);
        uint256 thr;
        if(tradeType == TradeType.ARBITRAGE){
            _poolCfg[pool].details.arbCapDeviationPercentage = capDevPct.toUint32();
            thr = uint256(_poolCfg[pool].details.arbThresholdPercentage);
        }
        else{
            _poolCfg[pool].details.noiseCapDeviationPercentage = capDevPct.toUint32();
            thr = uint256(_poolCfg[pool].details.noiseThresholdPercentage);
        }

        require(capDevPct > thr, "cap<=thr");
        emit CapDeviationPercentageChanged(pool, capDevPct, tradeType);
    }

    // =========================================================================
    // New: After-liquidity protections (multi-token; Stable Surge-style policy)
    // =========================================================================

    struct AddLiquidityLocals {
        uint256 n;
        uint256[] oldBalances;
        uint256 beforeDev;
        uint256 afterDev;
        uint256 threshold;
        bool isWorseningSurge;
    }

    /// @notice Allow proportional adds, but block non-proportional adds that worsen deviation and end above threshold.
    function onAfterAddLiquidity(
        address, // sender (unused)
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

        // Sanity: array lengths must match; if not, allow (defensive - don't block by mistake).
        if (amountsInScaled18.length != balancesScaled18.length) {
            return (true, amountsInRaw);
        }

        locals.n = balancesScaled18.length;
        if (locals.n < 2) return (true, amountsInRaw);

        // Reconstruct pre-add balances = post - in; if underflow detected, allow.
        locals.oldBalances = new uint256[](locals.n);
        for (uint256 i = 0; i < locals.n; ++i) {
            if (amountsInScaled18[i] > balancesScaled18[i]) {
                return (true, amountsInRaw);
            }
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
            emit LiquidityBlocked(pool, /*isAdd=*/ true, locals.beforeDev, locals.afterDev, locals.threshold);
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
        address, // sender (unused)
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
            emit LiquidityBlocked(pool, false, locals.beforeDev, locals.afterDev, locals.threshold);
        }

        return (!locals.isWorseningSurge, amountsOutRaw);
    }

    struct ComputeOracleDeviationLocals {
        uint256 n;
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

        PoolCfg storage pc = _poolCfg[pool];
        PoolDetails memory d = pc.details;
        if (!d.initialized) return 0;

        locals.n = d.numTokens;
        if (locals.n < 2) return 0;
        if (balancesScaled18.length < locals.n) locals.n = balancesScaled18.length; // defensive bound

        // Fetch normalized weights from the Weighted pool.
        if (w.length < locals.n) return 0;

        // Build external prices per token (1e18). Missing/zero -> mark as 0 (skipped).
        for (locals.i = 0; locals.i < locals.n; ++locals.i) {
            TokenPriceCfg memory cfg = pc.tokenCfg[locals.i];
            if (cfg.isUsd == 1) {
                locals.px[locals.i] = 1e18;
            } else if (cfg.pairIndex != 0) {
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
        for (locals.i = 0; locals.i < locals.n; ++locals.i) {
            locals.bi = balancesScaled18[locals.i];
            locals.wi = w[locals.i];
            locals.pxi = locals.px[locals.i];
            if (locals.bi == 0 || locals.wi == 0 || locals.pxi == 0) continue;
            for (locals.j = locals.i + 1; locals.j < locals.n; ++locals.j) {
                locals.bj = balancesScaled18[locals.j];
                locals.wj = w[locals.j];
                locals.pxj = locals.px[locals.j];
                if (locals.bj == 0 || locals.wj == 0 || locals.pxj == 0) continue;

                // Pool-implied spot for j vs i: (Bj/wj) / (Bi/wi)
                locals.poolPx = _pairSpotFromBalancesWeights(locals.bj, locals.wj, locals.bi, locals.wi);
                if (locals.poolPx == 0) continue;

                // External ratio j/i
                locals.extPx = locals.pxj.divDown(locals.pxi);
                if (locals.extPx == 0) continue;

                locals.dev = _relAbsDiff(locals.poolPx, locals.extPx);
                if (locals.dev > locals.maxDev) locals.maxDev = locals.dev;
            }
        }

        return locals.maxDev;
    }

    /// @notice Getter to read the pool-specific surge threshold (1e18 = 100%).
    function getSurgeThresholdPercentage(address pool, TradeType tradeType) public view returns (uint256) {
        if(tradeType == TradeType.ARBITRAGE){
            return uint256(_poolCfg[pool].details.arbThresholdPercentage) * 1e9;
        }
        else{
            return uint256(_poolCfg[pool].details.noiseThresholdPercentage) * 1e9;
        }
    }

    ///@inheritdoc IHyperSurgeHook
    function getMaxSurgeFeePercentage(address pool, TradeType tradeType) external view override returns (uint256) {
        if(tradeType == TradeType.ARBITRAGE){
            return uint256(_poolCfg[pool].details.arbMaxSurgeFeePercentage) * 1e9;
        }
        else{
            return uint256(_poolCfg[pool].details.noiseMaxSurgeFeePercentage) * 1e9;
        }
    }

    ///@inheritdoc IHyperSurgeHook
    function getCapDeviationPercentage(address pool, TradeType tradeType) external view override returns (uint256) {
        if(tradeType == TradeType.ARBITRAGE){
            return uint256(_poolCfg[pool].details.arbCapDeviationPercentage) * 1e9;
        }
        else{
            return uint256(_poolCfg[pool].details.noiseCapDeviationPercentage) * 1e9;
        }
    }

    // ===== Single locals-struct (for stack depth)
    struct ComputeLocals {
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
        PoolDetails poolDetails;
    }

    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata p,
        address pool,
        uint256 staticSwapFee
    ) public view override onlyVault returns (bool, uint256) {
        PoolCfg storage pc = _poolCfg[pool];
        ComputeLocals memory locals;
        locals.poolDetails = pc.details;

        //TODO should it return false to not allow the swap?
        if (!locals.poolDetails.initialized) return (true, staticSwapFee);
        
        if (p.indexIn >= locals.poolDetails.numTokens || p.indexOut >= locals.poolDetails.numTokens)
            return (true, staticSwapFee);

        // 1) Ask the Weighted pool to compute the counter-amount (external call).
        locals.calcAmountScaled18 = WeightedPool(pool).onSwap(p);

        // 2) Use only two balances (no array copy)
        uint256 bIn = p.balancesScaled18[p.indexIn];
        uint256 bOut = p.balancesScaled18[p.indexOut];

        // Fetch weights and guard indices as in original.
        uint256[] memory weights = WeightedPool(pool).getNormalizedWeights();

        locals.poolPxBefore = _pairSpotFromBalancesWeights(bIn, weights[p.indexIn], bOut, weights[p.indexOut]);

        if (p.kind == SwapKind.EXACT_IN) {
            bIn += p.amountGivenScaled18;
            bOut -= locals.calcAmountScaled18;
        } else {
            bIn += locals.calcAmountScaled18;
            bOut -= p.amountGivenScaled18;
        }
        
        //TODO overkill check? wont it just throw if the index is out of bounds?
        if (weights.length <= p.indexIn || weights.length <= p.indexOut) return (true, staticSwapFee);
        
        uint256 wIn = weights[p.indexIn];
        uint256 wOut = weights[p.indexOut];

        // P_pool = (B_out/w_out) / (B_in/w_in) = (B_out * w_in) / (B_in * w_out)
        locals.poolPx = _pairSpotFromBalancesWeights(bIn, wIn, bOut, wOut);
        if (locals.poolPx == 0) return (true, staticSwapFee);

        // 4) External prices (p_out / p_in), struct-per-index with cached divisor
    
        TokenPriceCfg memory pInCfg = pc.tokenCfg[p.indexIn];
        if (pInCfg.isUsd == 1) {
            locals.pxIn = 1e18;
        } else {
            uint32 pairIdxIn = pInCfg.pairIndex;
            require(pairIdxIn != 0, "price");
            uint64 rawIn = HyperPrice.spot(pairIdxIn); // "price" on failure
            // divisor precomputed at config time
            locals.pxIn = (uint256(rawIn) * 1e18) / uint256(pInCfg.priceDivisor);
        }
    
        TokenPriceCfg memory pOutCfg = pc.tokenCfg[p.indexOut];
        if (pOutCfg.isUsd == 1) {
            locals.pxOut = 1e18;
        } else {
            uint32 pairIdxOut = pOutCfg.pairIndex;
            require(pairIdxOut != 0, "price");
            uint64 rawOut = HyperPrice.spot(pairIdxOut); // "price" on failure
            locals.pxOut = (uint256(rawOut) * 1e18) / uint256(pOutCfg.priceDivisor);
        }

        if (locals.pxIn == 0) return (true, staticSwapFee);
        locals.extPx = locals.pxOut.divDown(locals.pxIn);
        if (locals.extPx == 0) return (true, staticSwapFee);

        // 5) Deviation
        locals.deviation = _relAbsDiff(locals.poolPx, locals.extPx); // |pool - ext| / ext

        if((locals.poolPx > locals.poolPxBefore))
        {
            if(locals.poolPxBefore < locals.extPx)
            {
                // If the pool price is increasing, we are in an arbitrage situation
                locals.capDevPct = uint256(locals.poolDetails.arbCapDeviationPercentage);
                locals.maxPct = uint256(locals.poolDetails.arbMaxSurgeFeePercentage);
                locals.threshold = uint256(locals.poolDetails.arbThresholdPercentage);
            }
            else
            {
                // If the pool price is decreasing, we are in a noise situation
                locals.capDevPct = uint256(locals.poolDetails.noiseCapDeviationPercentage);
                locals.maxPct = uint256(locals.poolDetails.noiseMaxSurgeFeePercentage);
                locals.threshold = uint256(locals.poolDetails.noiseThresholdPercentage);
            }
        }
        else{
            if(locals.poolPxBefore < locals.extPx)
            {
                // If the pool price is increasing, we are in a noise situation
                locals.capDevPct = uint256(locals.poolDetails.noiseCapDeviationPercentage);
                locals.maxPct = uint256(locals.poolDetails.noiseMaxSurgeFeePercentage);
                locals.threshold = uint256(locals.poolDetails.noiseThresholdPercentage);
            }
            else
            {
                // If the pool price is decreasing, we are in an arbitrage situation
                locals.capDevPct = uint256(locals.poolDetails.arbCapDeviationPercentage);
                locals.maxPct = uint256(locals.poolDetails.arbMaxSurgeFeePercentage);
                locals.threshold = uint256(locals.poolDetails.arbThresholdPercentage);
            }
        }

        locals.capDevPct *= 1e9; // convert to 1e18 scale
        locals.maxPct *= 1e9; // convert to 1e18 scale
        locals.threshold *= 1e9; // convert to 1e18 scale

        if (locals.deviation <= locals.threshold) return (true, staticSwapFee);

        uint256 span = locals.capDevPct - locals.threshold; // > 0 by fallback above

        uint256 norm = (locals.deviation - locals.threshold).divDown(span);
        if (norm > FixedPoint.ONE) norm = FixedPoint.ONE;

        locals.increment = (locals.maxPct - staticSwapFee).mulDown(norm);
        locals.surgeFee = staticSwapFee + locals.increment;
        if (locals.surgeFee > locals.maxPct) locals.surgeFee = locals.maxPct;

        return (true, locals.surgeFee);
    }

    // ===== Internals =====

    function _pairSpotFromBalancesWeights(
        uint256 bIn,
        uint256 wIn,
        uint256 bOut,
        uint256 wOut
    ) internal pure returns (uint256) {
        require(bIn > 0, "bal0"); // original guard
        if (bOut == 0 || wIn == 0 || wOut == 0) return 0;
        uint256 num = bOut.mulDown(wIn);
        uint256 den = bIn.mulDown(wOut);
        if (den == 0) return 0;
        return num.divDown(den);
    }

    function _relAbsDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == b) return 0;
        if (a > b) return (a - b).divDown(b);
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

    ///@inheritdoc IHyperSurgeHook
    function getTokenPriceConfigIndex(
        address pool,
        uint8 tokenIndex
    ) external view override returns (uint32 pairIndex, bool isUsd, uint32 priceDivisor) {
        TokenPriceCfg memory cfg = _poolCfg[pool].tokenCfg[tokenIndex];
        return (cfg.pairIndex, cfg.isUsd == 1, cfg.priceDivisor);
    }

    ///@inheritdoc IHyperSurgeHook
    function getTokenPriceConfigs(
        address pool
    )
        external
        view
        override
        returns (uint32[] memory pairIndexArr, bool[] memory isUsdArr, uint32[] memory priceDivisorArr)
    {
        PoolDetails memory details = _poolCfg[pool].details;
        uint8 numTokens = details.numTokens;

        pairIndexArr = new uint32[](numTokens);
        isUsdArr = new bool[](numTokens);
        priceDivisorArr = new uint32[](numTokens);

        for (uint8 i = 0; i < numTokens; ++i) {
            TokenPriceCfg memory cfg = _poolCfg[pool].tokenCfg[i];
            pairIndexArr[i] = cfg.pairIndex;
            isUsdArr[i] = cfg.isUsd == 1;
            priceDivisorArr[i] = cfg.priceDivisor;
        }
    }

    ///@inheritdoc IHyperSurgeHook
    function getDefaultMaxSurgeFeePercentage() external view override returns (uint256) {
        return _defaultMaxSurgeFee;
    }

    ///@inheritdoc IHyperSurgeHook
    function getDefaultSurgeThresholdPercentage() external view override returns (uint256) {
        return _defaultThreshold;
    }
}
