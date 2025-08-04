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
    SwapKind
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";
import { VaultGuard } from "@balancer-labs/v3-vault/contracts/VaultGuard.sol";
import { SingletonAuthentication } from "@balancer-labs/v3-vault/contracts/SingletonAuthentication.sol";

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
/// Multitoken Hyper Surge Hook — index-based config, packed per index
/// -----------------------------------------------------------------------
contract HyperSurgeHookMulti is BaseHooks, VaultGuard, SingletonAuthentication, Ownable {
    using FixedPoint for uint256;
    using SafeCast for uint256;

    // ===== Events (index-based)
    event TokenPriceConfiguredIndex(address indexed pool, uint8 indexed tokenIndex, uint32 pairIndex, uint8 szDecimals, bool isUsdQuote);
    event MaxSurgeFeePercentageChanged(address indexed pool, uint256 newMaxSurgeFeePercentage);
    event ThresholdPercentageChanged(address indexed pool, uint256 newThresholdPercentage);

    // ===== Errors
    error InvalidArrayLengths();
    error TokenIndexOutOfRange();
    error NumTokensOutOfRange();

    // ===== Types
    struct PoolCfg {
        uint64 maxSurgeFeePercentage; // 18-dec
        uint64 thresholdPercentage;   // 18-dec
        uint8  numTokens;             // 2..8 inclusive
        // Packed token config per index (2..8 tokens used).
        // For index i (0..7), layout in the 256-bit word:
        // bits [31:0]   -> pairIndex (uint32)
        // bits [39:32]  -> szDecimals (uint8)
        // bit  [40]     -> isUsdQuote (bool)
        // remaining bits reserved (zero)
        uint256[8] tokenCfgPacked;    // one SLOAD per token index
        bool initialized;
    }

    mapping(address => PoolCfg) private _poolCfg;
    uint256 private immutable _defaultMaxSurgeFee;
    uint256 private immutable _defaultThreshold;

    constructor(
        IVault vault,
        uint256 defaultMaxSurgeFeePercentage,
        uint256 defaultThresholdPercentage
    ) SingletonAuthentication(vault) VaultGuard(vault) Ownable(msg.sender) {
        _ensurePct(defaultMaxSurgeFeePercentage);
        _ensurePct(defaultThresholdPercentage);
        _defaultMaxSurgeFee = defaultMaxSurgeFeePercentage;
        _defaultThreshold   = defaultThresholdPercentage;
    }

    function getHookFlags() public pure override returns (HookFlags memory f) {
        f.shouldCallComputeDynamicSwapFee = true;
    }

    // ===== Single locals-struct kept (for stack depth)
    struct ComputeLocals {
        uint256 calcAmountScaled18;
        uint256 n;
        uint256[] newBalances;
        uint256[] w;
        uint256 poolPx;
        uint256 pxIn;
        uint256 pxOut;
        uint256 extPx;
        uint256 deviation;
        uint256 threshold;
        uint256 maxPct;
        uint256 increment;
        uint256 surgeFee;
    }

    // ===== Register: set numTokens, defaults
    function onRegister(
        address,
        address pool,
        TokenConfig[] memory tokenCfgs,
        LiquidityManagement calldata
    ) public override onlyVault returns (bool) {
        PoolCfg storage pc = _poolCfg[pool];

        uint256 n = tokenCfgs.length;
        if (n < 2 || n > 8) revert NumTokensOutOfRange();

        pc.maxSurgeFeePercentage = _defaultMaxSurgeFee.toUint64();
        pc.thresholdPercentage   = _defaultThreshold.toUint64();
        pc.numTokens = uint8(n);
        pc.initialized = true;

        // No address->index mapping needed (indices are fixed by pool).
        return true;
    }

    // ========= Owner configuration (index-based) =========

    /// @notice Configure a single token’s Hyperliquid mapping for a given pool by token index (0..7).
    function setTokenPriceConfigIndex(
        address pool,
        uint8 tokenIndex,
        uint32 pairIdx,
        bool isUsd
    ) external onlyOwner {
        PoolCfg storage pc = _requirePool(pool);
        if (tokenIndex >= pc.numTokens) revert TokenIndexOutOfRange();

        uint8 sz = 0;
        if (!isUsd) {
            require(pairIdx != 0, "PAIRIDX");
            sz = HyperTokenInfo.szDecimals(pairIdx); // may revert "dec"
        }

        // pack into 1 word for this index
        pc.tokenCfgPacked[tokenIndex] = _packTokenCfg(pairIdx, sz, isUsd);

        emit TokenPriceConfiguredIndex(pool, tokenIndex, pairIdx, sz, isUsd);
    }

    /// @notice Batch version (indices).
    function setTokenPriceConfigBatchIndex(
        address pool,
        uint8[] calldata tokenIndices,
        uint32[] calldata pairIdx,
        bool[] calldata isUsd
    ) external onlyOwner {
        PoolCfg storage pc = _requirePool(pool);

        if (tokenIndices.length != pairIdx.length || tokenIndices.length != isUsd.length) revert InvalidArrayLengths();
        uint256 len = tokenIndices.length;
        for (uint256 i = 0; i < len; ++i) {
            uint8 idx = tokenIndices[i];
            if (idx >= pc.numTokens) revert TokenIndexOutOfRange();
            uint8 sz = 0;
            if (!isUsd[i]) {
                require(pairIdx[i] != 0, "PAIRIDX");
                sz = HyperTokenInfo.szDecimals(pairIdx[i]);
            }
            pc.tokenCfgPacked[idx] = _packTokenCfg(pairIdx[i], sz, isUsd[i]);
            emit TokenPriceConfiguredIndex(pool, idx, pairIdx[i], sz, isUsd[i]);
        }
    }

    function setMaxSurgeFeePercentage(address pool, uint256 pct) external onlyOwner {
        _ensurePct(pct);
        PoolCfg storage pc = _poolCfg[pool];
        pc.maxSurgeFeePercentage = pct.toUint64();
        emit MaxSurgeFeePercentageChanged(pool, pct);
    }

    function setSurgeThresholdPercentage(address pool, uint256 pct) external onlyOwner {
        _ensurePct(pct);
        PoolCfg storage pc = _poolCfg[pool];
        pc.thresholdPercentage = pct.toUint64();
        emit ThresholdPercentageChanged(pool, pct);
    }

    // ========= Dynamic fee (unchanged logic; only config reads differ) =========
    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata p,
        address pool,
        uint256 staticSwapFee
    ) public view override returns (bool, uint256) {
        PoolCfg storage pc = _poolCfg[pool];
        if (!pc.initialized) return (true, staticSwapFee);
        if (p.indexIn >= pc.numTokens || p.indexOut >= pc.numTokens) return (true, staticSwapFee);

        ComputeLocals memory L;

        // 1) Ask the Weighted pool to compute the counter-amount (external call)
        try WeightedPool(pool).onSwap(p) returns (uint256 amt) {
            L.calcAmountScaled18 = amt;
        } catch {
            return (true, staticSwapFee);
        }

        // 2) Build post-trade balances (scaled 1e18)
        L.n = p.balancesScaled18.length;
        L.newBalances = new uint256[](L.n);
        for (uint256 i = 0; i < L.n; ++i) L.newBalances[i] = p.balancesScaled18[i];

        if (p.kind == SwapKind.EXACT_IN) {
            L.newBalances[p.indexIn]  += p.amountGivenScaled18;
            L.newBalances[p.indexOut] -= L.calcAmountScaled18;
        } else {
            L.newBalances[p.indexIn]  += L.calcAmountScaled18;
            L.newBalances[p.indexOut] -= p.amountGivenScaled18;
        }

        // 3) Fetch normalized weights (external)
        try WeightedPool(pool).getNormalizedWeights() returns (uint256[] memory weights) {
            L.w = weights;
        } catch {
            return (true, staticSwapFee);
        }
        if (L.w.length <= p.indexIn || L.w.length <= p.indexOut) return (true, staticSwapFee);

        // P_pool = (B_out/w_out) / (B_in/w_in) = (B_out * w_in) / (B_in * w_out)
        L.poolPx = _pairSpotFromBalancesWeights(
            L.newBalances[p.indexIn],  L.w[p.indexIn],
            L.newBalances[p.indexOut], L.w[p.indexOut]
        );
        if (L.poolPx == 0) return (true, staticSwapFee);

        // 4) External prices (p_out / p_in) using packed per-index config (2 SLOADs total)
        uint256 cfgIn  = pc.tokenCfgPacked[p.indexIn];
        uint256 cfgOut = pc.tokenCfgPacked[p.indexOut];
        L.pxIn  = _extPrice18Packed(cfgIn);
        L.pxOut = _extPrice18Packed(cfgOut);
        if (L.pxIn == 0) return (true, staticSwapFee);
        L.extPx = L.pxOut.divDown(L.pxIn);
        if (L.extPx == 0) return (true, staticSwapFee);

        // 5) Deviation and complement-based ramp up to max cap (original curve)
        L.deviation = _relAbsDiff(L.poolPx, L.extPx); // |pool - ext| / ext
        L.threshold = uint256(pc.thresholdPercentage);
        if (L.deviation <= L.threshold) return (true, staticSwapFee);
        if (L.threshold >= FixedPoint.ONE) return (true, staticSwapFee);

        L.maxPct = uint256(pc.maxSurgeFeePercentage);
        L.increment = (L.maxPct - staticSwapFee)
            .mulDown((L.deviation - L.threshold).divDown(L.threshold.complement()));

        L.surgeFee = staticSwapFee + L.increment;
        if (L.surgeFee > L.maxPct) L.surgeFee = L.maxPct;
        return (true, L.surgeFee);
    }

    // ===== Internals =====

    // Pack fields into one 256-bit word:
    // [31:0]  pairIndex (uint32)
    // [39:32] szDecimals (uint8)
    // [40]    isUsd (bool)
    function _packTokenCfg(uint32 pairIdx, uint8 sz, bool isUsd) internal pure returns (uint256 w) {
        w = uint256(pairIdx);
        w |= uint256(sz) << 32;
        if (isUsd) w |= (uint256(1) << 40);
    }

    // Unpack and compute external price (1e18).
    function _extPrice18Packed(uint256 w) internal view returns (uint256 px18) {
        bool isUsd = ((w >> 40) & 1) == 1;
        if (isUsd) return 1e18;

        uint32 pairIdx = uint32(w & 0xFFFFFFFF);
        require(pairIdx != 0, "price");

        uint8 s = uint8((w >> 32) & 0xFF);
        require(s <= 6, "dec");

        uint64 raw = HyperPrice.spot(pairIdx); // reverts "price" if precompile fails
        uint256 divisor = 10 ** (6 - s);
        px18 = (uint256(raw) * 1e18) / divisor;
    }

    function _pairSpotFromBalancesWeights(
        uint256 bIn,  uint256 wIn,
        uint256 bOut, uint256 wOut
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

    function _ensurePct(uint256 pct) private pure {
        if (pct > FixedPoint.ONE) revert("pct");
    }

    function _requirePool(address pool) private view returns (PoolCfg storage) {
        PoolCfg storage pc = _poolCfg[pool];
        require(pc.initialized, "POOL");
        return pc;
    }
}
