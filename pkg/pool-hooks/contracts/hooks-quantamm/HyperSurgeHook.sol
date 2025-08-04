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
/// Multitoken Hyper Surge Hook
/// -----------------------------------------------------------------------
contract HyperSurgeHookMulti is BaseHooks, VaultGuard, SingletonAuthentication, Ownable {
    using FixedPoint for uint256;
    using SafeCast for uint256;

    // ===== Events
    event TokenPriceConfigured(address indexed pool, address indexed token, uint32 pairIndex, uint8 szDecimals, bool isUsdQuote);
    event MaxSurgeFeePercentageChanged(address indexed pool, uint256 newMaxSurgeFeePercentage);
    event ThresholdPercentageChanged(address indexed pool, uint256 newThresholdPercentage);

    // ===== Minimal custom errors for config
    error InvalidArrayLengths();
    error TokenNotConfigured();

    // ===== Types
    struct TokenPriceCfg {
        uint32 pairIndex;   // Hyperliquid market id (0 allowed only when isUsdQuote = true)
        uint8  szDecimals;  // cached from tokenInfo precompile
        bool   isUsdQuote;  // if true, price is exactly 1e18
    }

    struct PoolCfg {
        uint64 maxSurgeFeePercentage; // 18-dec
        uint64 thresholdPercentage;   // 18-dec
        mapping(address => TokenPriceCfg) tokenCfg; // per-token cfg
        address[] tokensByIndex;                    // index -> token (cached on register)
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

    // ===== Locals structs (per-function)
    struct ComputeLocals {
        address tokenIn;
        address tokenOut;
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

    // ===== Vault lifecycle

    function onRegister(
        address,
        address pool,
        TokenConfig[] memory tokenCfgs,
        LiquidityManagement calldata
    ) public override onlyVault returns (bool) {
        _poolCfg[pool].maxSurgeFeePercentage = _defaultMaxSurgeFee.toUint64();
        _poolCfg[pool].thresholdPercentage   = _defaultThreshold.toUint64();
        _poolCfg[pool].initialized = true;

        uint256 n = tokenCfgs.length;
        _poolCfg[pool].tokensByIndex = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            _poolCfg[pool].tokensByIndex[i] = address(tokenCfgs[i].token); // cache index -> token
        }
        return true;
    }

    // ========= Owner configuration =========
    /// @notice Configure a single token’s Hyperliquid mapping for a given pool.
    function _setTokenPriceConfig(
        address pool,
        address token,
        uint32 pairIdx,
        bool isUsd
    ) internal {
        // No local storage refs; operate inline on mapping to keep locals minimal
        if (isUsd) {
            _poolCfg[pool].tokenCfg[token].pairIndex = 0;
            _poolCfg[pool].tokenCfg[token].szDecimals = 0;
            _poolCfg[pool].tokenCfg[token].isUsdQuote = true;
        } else {
            require(pairIdx != 0, "PAIRIDX");
            uint8 sz = HyperTokenInfo.szDecimals(pairIdx); // may revert "dec"
            _poolCfg[pool].tokenCfg[token].pairIndex  = pairIdx;
            _poolCfg[pool].tokenCfg[token].szDecimals = sz;
            _poolCfg[pool].tokenCfg[token].isUsdQuote = false;
        }

        emit TokenPriceConfigured(
            pool,
            token,
            _poolCfg[pool].tokenCfg[token].pairIndex,
            _poolCfg[pool].tokenCfg[token].szDecimals,
            _poolCfg[pool].tokenCfg[token].isUsdQuote
        );
    }

    /// @notice Configure a single token’s Hyperliquid mapping for a given pool.
    function setTokenPriceConfig(
        address pool,
        address token,
        uint32 pairIdx,
        bool isUsd
    ) external onlyOwner {
        if (token == address(0)) revert TokenNotConfigured(); // zero-address guard
        _setTokenPriceConfig(pool, token, pairIdx, isUsd);
    }

    /// @notice Batch version.
    function setTokenPriceConfigBatch(
        address pool,
        address[] calldata tokens,
        uint32[] calldata pairIdx,
        bool[] calldata isUsd
    ) external onlyOwner {
        if (tokens.length != pairIdx.length || tokens.length != isUsd.length) revert InvalidArrayLengths();
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; ++i) {
            _setTokenPriceConfig(pool, tokens[i], pairIdx[i], isUsd[i]);
        }
    }

    function setMaxSurgeFeePercentage(address pool, uint256 pct) external onlyOwner {
        _ensurePct(pct);
        _poolCfg[pool].maxSurgeFeePercentage = pct.toUint64();
        emit MaxSurgeFeePercentageChanged(pool, pct);
    }

    function setSurgeThresholdPercentage(address pool, uint256 pct) external onlyOwner {
        _ensurePct(pct);
        _poolCfg[pool].thresholdPercentage = pct.toUint64();
        emit ThresholdPercentageChanged(pool, pct);
    }

    // ========= Dynamic fee =========
    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata p,
        address pool,
        uint256 staticSwapFee
    ) public view override returns (bool, uint256) {
        if (!_poolCfg[pool].initialized) return (true, staticSwapFee);

        ComputeLocals memory local;

        // Resolve tokens by index (PoolSwapParams does not include tokens)
        if (p.indexIn >= _poolCfg[pool].tokensByIndex.length || p.indexOut >= _poolCfg[pool].tokensByIndex.length) {
            return (true, staticSwapFee);
        }
        local.tokenIn  = _poolCfg[pool].tokensByIndex[p.indexIn];
        local.tokenOut = _poolCfg[pool].tokensByIndex[p.indexOut];

        // 1) Ask the Weighted pool to compute the counter-amount (external call)
        try WeightedPool(pool).onSwap(p) returns (uint256 amt) {
            local.calcAmountScaled18 = amt;
        } catch {
            return (true, staticSwapFee);
        }

        // 2) Build post-trade balances (scaled 1e18)
        local.n = p.balancesScaled18.length;
        local.newBalances = new uint256[](local.n);
        for (uint256 i = 0; i < local.n; ++i) local.newBalances[i] = p.balancesScaled18[i];

        if (p.kind == SwapKind.EXACT_IN) {
            local.newBalances[p.indexIn]  += p.amountGivenScaled18;
            local.newBalances[p.indexOut] -= local.calcAmountScaled18;
        } else {
            local.newBalances[p.indexIn]  += local.calcAmountScaled18;
            local.newBalances[p.indexOut] -= p.amountGivenScaled18;
        }

        // 3) Fetch normalized weights (external)
        try WeightedPool(pool).getNormalizedWeights() returns (uint256[] memory weights) {
            local.w = weights;
        } catch {
            return (true, staticSwapFee);
        }
        if (local.w.length <= p.indexIn || local.w.length <= p.indexOut) return (true, staticSwapFee);

        // P_pool = (B_out/w_out) / (B_in/w_in) = (B_out * w_in) / (B_in * w_out)
        local.poolPx = _pairSpotFromBalancesWeights(
            local.newBalances[p.indexIn],  local.w[p.indexIn],
            local.newBalances[p.indexOut], local.w[p.indexOut]
        );
        if (local.poolPx == 0) return (true, staticSwapFee);

        // 4) External prices (p_out / p_in), from Hyperliquid or USD peg
        local.pxIn  = _extPrice18(_poolCfg[pool].tokenCfg[local.tokenIn]);   // may revert "price"/"dec"
        local.pxOut = _extPrice18(_poolCfg[pool].tokenCfg[local.tokenOut]);  // may revert "price"/"dec"
        if (local.pxIn == 0) return (true, staticSwapFee);
        local.extPx = local.pxOut.divDown(local.pxIn);
        if (local.extPx == 0) return (true, staticSwapFee);

        // 5) Deviation and complement-based ramp up to max cap (original curve)
        local.deviation = _relAbsDiff(local.poolPx, local.extPx); // |pool - ext| / ext
        local.threshold = uint256(_poolCfg[pool].thresholdPercentage);
        if (local.deviation <= local.threshold) return (true, staticSwapFee);
        if (local.threshold >= FixedPoint.ONE) return (true, staticSwapFee);

        local.maxPct = uint256(_poolCfg[pool].maxSurgeFeePercentage);
        local.increment = (local.maxPct - staticSwapFee)
            .mulDown((local.deviation - local.threshold).divDown(local.threshold.complement()));

        local.surgeFee = staticSwapFee + local.increment;
        if (local.surgeFee > local.maxPct) local.surgeFee = local.maxPct;
        return (true, local.surgeFee);
    }

    // ===== Internals =====

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

    /// @dev Returns px18 = 1e18 if USD-quoted; otherwise converts Hyper spot to 1e18 scale.
    ///      Uses original revert tags via the helper libraries (no try/catch).
    function _extPrice18(TokenPriceCfg memory c) internal view returns (uint256 px18) {
        if (c.isUsdQuote) return 1e18;
        require(c.pairIndex != 0, "price"); // treat missing mapping as price failure

        uint64 raw = HyperPrice.spot(c.pairIndex);  // reverts "price" on failure
        uint8 s   = c.szDecimals;                  // set at config-time (may be zero if USD)
        require(s <= 6, "dec");

        uint256 divisor = 10 ** (6 - s);          // convert HL’s 6-dec format to 1e18
        px18 = (uint256(raw) * 1e18) / divisor;
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
