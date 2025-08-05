// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IHooks.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
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
contract HyperSurgeHookMulti is BaseHooks, VaultGuard, SingletonAuthentication, Version {
    using FixedPoint for uint256;
    using SafeCast for uint256;

    // ===== Events (index-based; unchanged)
    event TokenPriceConfiguredIndex(
        address indexed pool,
        uint8 indexed tokenIndex,
        uint32 pairIndex,
        uint8 szDecimals,
        bool isUsdQuote
    );
    event MaxSurgeFeePercentageChanged(address indexed pool, uint256 newMaxSurgeFeePercentage);
    event ThresholdPercentageChanged(address indexed pool, uint256 newThresholdPercentage);

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
        uint64 maxSurgeFeePercentage; // 18-dec
        uint64 thresholdPercentage; // 18-dec
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
    }

    function getHookFlags() public pure override returns (HookFlags memory hookFlags) {
        hookFlags.shouldCallComputeDynamicSwapFee = true;
        hookFlags.shouldCallAfterAddLiquidity = true;
        hookFlags.shouldCallAfterRemoveLiquidity = true;
    }

    // ===== Single locals-struct (for stack depth)
    struct ComputeLocals {
        uint256 calcAmountScaled18;
        uint256 poolPx;
        uint256 pxIn;
        uint256 pxOut;
        uint256 extPx;
        uint256 deviation;
        uint256 threshold;
        uint256 maxPct;
        uint256 increment;
        uint256 surgeFee;
        PoolDetails poolDetails;
    }

    // ===== Register: set numTokens, defaults (index-only config)
    function onRegister(
        address,
        address pool,
        TokenConfig[] memory tokenCfgs,
        LiquidityManagement calldata
    ) public override onlyVault returns (bool) {
        PoolCfg storage pc = _poolCfg[pool];

        uint256 n = tokenCfgs.length;
        if (n < 2 || n > 8) revert NumTokensOutOfRange();

        pc.details.maxSurgeFeePercentage = _defaultMaxSurgeFee.toUint64();
        pc.details.thresholdPercentage = _defaultThreshold.toUint64();
        pc.details.numTokens = uint8(n);
        pc.details.initialized = true;

        // No address-based mappings; indices are fixed by the pool and used for config.
        return true;
    }

    // ========= Owner configuration (index-based) =========

    /// @notice Configure a single token’s Hyperliquid mapping for a given pool by token index (0..7).
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

    function setMaxSurgeFeePercentage(address pool, uint256 pct) external onlySwapFeeManagerOrGovernance(pool) {
        _ensureValidPct(pct);
        _poolCfg[pool].details.maxSurgeFeePercentage = pct.toUint64();
        emit MaxSurgeFeePercentageChanged(pool, pct);
    }

    function setSurgeThresholdPercentage(address pool, uint256 pct) external onlySwapFeeManagerOrGovernance(pool) {
        _ensureValidPct(pct);
        _poolCfg[pool].details.thresholdPercentage = pct.toUint64();
        emit ThresholdPercentageChanged(pool, pct);
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
        ) public view override returns (bool success, uint256[] memory hookAdjustedAmountsInRaw) {
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

            locals.beforeDev = _computeOracleDeviationPct(pool, locals.oldBalances);
            locals.afterDev = _computeOracleDeviationPct(pool, balancesScaled18);
            locals.threshold = getSurgeThresholdPercentage(pool);

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
            address, // sender (unused)
            address pool,
            RemoveLiquidityKind kind,
            uint256, // lpAmount (unused)
            uint256[] memory amountsOutScaled18,
            uint256[] memory amountsOutRaw,
            uint256[] memory balancesScaled18,
            bytes memory // userData (unused)
        ) public view override returns (bool success, uint256[] memory hookAdjustedAmountsOutRaw) {
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

            locals.beforeDev = _computeOracleDeviationPct(pool, locals.oldBalances);
            locals.afterDev = _computeOracleDeviationPct(pool, balancesScaled18);
            locals.threshold = getSurgeThresholdPercentage(pool);

            locals.isWorseningSurge = (locals.afterDev > locals.beforeDev) && (locals.afterDev > locals.threshold);
            return (!locals.isWorseningSurge, amountsOutRaw);
        }

        struct ComputeOracleDeviationLocals {
            uint256 n;
            uint256[] w;
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
            uint256[] memory balancesScaled18
        ) internal view returns (uint256 maxDev) {
            ComputeOracleDeviationLocals memory locals;

            PoolCfg storage pc = _poolCfg[pool];
            PoolDetails memory d = pc.details;
            if (!d.initialized) return 0;

            locals.n = d.numTokens;
            if (locals.n < 2) return 0;
            if (balancesScaled18.length < locals.n) locals.n = balancesScaled18.length; // defensive bound

            // Fetch normalized weights from the Weighted pool.
            locals.w = WeightedPool(pool).getNormalizedWeights();
            if (locals.w.length < locals.n) return 0;

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
                locals.wi = locals.w[locals.i];
                locals.pxi = locals.px[locals.i];
                if (locals.bi == 0 || locals.wi == 0 || locals.pxi == 0) continue;
                for (locals.j = locals.i + 1; locals.j < locals.n; ++locals.j) {
                    locals.bj = balancesScaled18[locals.j];
                    locals.wj = locals.w[locals.j];
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
    function getSurgeThresholdPercentage(address pool) public view returns (uint256) {
        return uint256(_poolCfg[pool].details.thresholdPercentage);
    }

    // ========= Dynamic fee (optimized hot path) =========
    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata p,
        address pool,
        uint256 staticSwapFee
    ) public view override onlyVault returns (bool, uint256) {
        PoolCfg storage pc = _poolCfg[pool];
        ComputeLocals memory locals;
        locals.poolDetails = pc.details;
        if (!locals.poolDetails.initialized) return (true, staticSwapFee);
        if (p.indexIn >= locals.poolDetails.numTokens || p.indexOut >= locals.poolDetails.numTokens)
            return (true, staticSwapFee);

        // (5) Early return when no surcharge is possible.
        uint256 maxPct = uint256(locals.poolDetails.maxSurgeFeePercentage);
        if (maxPct <= staticSwapFee) return (true, staticSwapFee);
        if (locals.threshold >= FixedPoint.ONE) return (true, staticSwapFee);

        // 1) Ask the Weighted pool to compute the counter-amount (external call; keep try/catch for safety)
        locals.calcAmountScaled18 = WeightedPool(pool).onSwap(p);

        // 2) Use only two balances (no array copy)
        uint256 bIn = p.balancesScaled18[p.indexIn];
        uint256 bOut = p.balancesScaled18[p.indexOut];

        if (p.kind == SwapKind.EXACT_IN) {
            bIn += p.amountGivenScaled18;
            bOut -= locals.calcAmountScaled18;
        } else {
            bIn += locals.calcAmountScaled18;
            bOut -= p.amountGivenScaled18;
        }

        uint256[] memory weights = WeightedPool(pool).getNormalizedWeights();
        if (weights.length <= p.indexIn || weights.length <= p.indexOut) return (true, staticSwapFee);
        uint256 wIn = weights[p.indexIn];
        uint256 wOut = weights[p.indexOut];

        // P_pool = (B_out/w_out) / (B_in/w_in) = (B_out * w_in) / (B_in * w_out)
        locals.poolPx = _pairSpotFromBalancesWeights(bIn, wIn, bOut, wOut);
        if (locals.poolPx == 0) return (true, staticSwapFee);

        // 4) External prices (p_out / p_in), struct-per-index with cached divisor
        {
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
        }
        {
            TokenPriceCfg memory pOutCfg = pc.tokenCfg[p.indexOut];
            if (pOutCfg.isUsd == 1) {
                locals.pxOut = 1e18;
            } else {
                uint32 pairIdxOut = pOutCfg.pairIndex;
                require(pairIdxOut != 0, "price");
                uint64 rawOut = HyperPrice.spot(pairIdxOut); // "price" on failure
                locals.pxOut = (uint256(rawOut) * 1e18) / uint256(pOutCfg.priceDivisor);
            }
        }

        if (locals.pxIn == 0) return (true, staticSwapFee);
        locals.extPx = locals.pxOut.divDown(locals.pxIn);
        if (locals.extPx == 0) return (true, staticSwapFee);

        // 5) Deviation and complement-based ramp up to max cap (original curve)
        locals.deviation = _relAbsDiff(locals.poolPx, locals.extPx); // |pool - ext| / ext
        locals.threshold = uint256(locals.poolDetails.thresholdPercentage);
        if (locals.deviation <= locals.threshold) return (true, staticSwapFee);

        // use cached maxPct from early check
        locals.maxPct = maxPct;
        locals.increment = (locals.maxPct - staticSwapFee).mulDown(
            (locals.deviation - locals.threshold).divDown(locals.threshold.complement())
        );

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

    function _ensureValidPct(uint256 pct) private pure {
        if (pct > FixedPoint.ONE) revert("pct");
    }
}
