// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IHooks.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import {
    PoolSwapParams,
    LiquidityManagement,
    TokenConfig,
    HookFlags,
    AddLiquidityKind,
    RemoveLiquidityKind,
    SwapKind
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";
import { VaultGuard } from "@balancer-labs/v3-vault/contracts/VaultGuard.sol";
import { SingletonAuthentication } from "@balancer-labs/v3-vault/contracts/SingletonAuthentication.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { WeightedPool } from "@balancer-labs/v3-pool-weighted/contracts/WeightedPool.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Sources the peg from Hyperliquid’s price precompile (0x…0808).
library HyperPrice {
    /// @dev Address of the precompile (`spotPx`).
    address internal constant PRECOMPILE = 0x0000000000000000000000000000000000000808;

    /// @param pairIndex Hyperliquid “universe” pair index (e.g. 3 for BTC/USDC)
    /// @return price  64-bit unsigned, units: USD * 10^(6-szDecimals)
    function spot(uint32 pairIndex) internal view returns (uint64 price) {
        (bool ok, bytes memory out) = PRECOMPILE.staticcall(abi.encode(pairIndex));
        require(ok, "HL price call failed");
        price = abi.decode(out, (uint64));
    }
}

/**
 * @title  HyperSurgeHook
 * @notice Dynamic-fee hook that “surges” when the pool price drifts from
 *         Hyperliquid’s spot price beyond a threshold.
 *
 * @dev Assumes a **two-token pool** in the form <volatileAsset, QuoteStable>
 *      e.g. <wBTC, USDC>.  Token 0 = volatile asset, Token 1 = quote.
 *
 *      If you plan to use multi-asset stable pools you will need to extend
 *      the `_poolImpliedPrice()` function accordingly.
 */
contract HyperSurgeHook is BaseHooks, VaultGuard, SingletonAuthentication, Ownable {
    using FixedPoint for uint256;
    using SafeCast for uint256;

    // ───────────────  CONFIG PER POOL  ───────────────

    struct PoolConfig {
        // Hyperliquid pair index (fetch with API / UI tooltip).
        uint32 pairIndex;
        // Largest fee the pool may charge (18-dec FP).
        uint64 maxSurgeFeePercentage;
        // Required deviation (18-dec FP) before surging begins.
        uint64 thresholdPercentage;
    }

    mapping(address => PoolConfig) internal _poolConfig;

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
        _defaultThreshold = defaultThresholdPercentage;
    }

    function getHookFlags() public pure override returns (HookFlags memory f) {
        f.shouldCallComputeDynamicSwapFee = true;
    }

    function onRegister(
        address /* factory */,
        address pool,
        TokenConfig[] memory /* tokens */,
        LiquidityManagement calldata
    ) public override onlyVault returns (bool) {
        _poolConfig[pool] = PoolConfig({
            pairIndex: 0, 
            maxSurgeFeePercentage: uint64(_defaultMaxSurgeFee),
            thresholdPercentage: uint64(_defaultThreshold)
        });

        return true;
    }

    function setPairIndex(address pool, uint32 pair) external onlyOwner {
        _poolConfig[pool].pairIndex = pair;
    }

    function setMaxSurgeFeePercentage(address pool, uint256 pct) external onlyOwner {
        _ensurePct(pct);
        _poolConfig[pool].maxSurgeFeePercentage = pct.toUint64();
    }

    function setSurgeThresholdPercentage(address pool, uint256 pct) external onlyOwner {
        _ensurePct(pct);
        _poolConfig[pool].thresholdPercentage = pct.toUint64();
    }

    /// @inheritdoc IHooks
    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata p,
        address pool,
        uint256 staticSwapFee
    ) public view override onlyVault returns (bool, uint256) {
        PoolConfig memory cfg = _poolConfig[pool];
        require(cfg.pairIndex != 0, "pairIndex not set");

        uint256 amountOutScaled18 = WeightedPool(pool).onSwap(p);
        uint256[2] memory balances = [p.balancesScaled18[0], p.balancesScaled18[1]];

        if (p.kind == SwapKind.EXACT_IN) {
            balances[p.indexIn] += p.amountGivenScaled18;
            balances[p.indexOut] -= amountOutScaled18;
        } else {
            balances[p.indexIn] += amountOutScaled18;
            balances[p.indexOut] -= p.amountGivenScaled18;
        }

        uint256 poolPx = _poolImpliedPrice(balances); // 18-dec USD
        uint256 pegPx = _pegPrice18(cfg.pairIndex); // 18-dec USD

        uint256 deviation = poolPx > pegPx ? (poolPx - pegPx).divDown(pegPx) : (pegPx - poolPx).divDown(pegPx);

        if (deviation <= uint256(cfg.thresholdPercentage)) {
            return (true, staticSwapFee); // below threshold
        }

        uint256 surgeFee = staticSwapFee +
            (uint256(cfg.maxSurgeFeePercentage) - staticSwapFee).mulDown(
                (deviation - uint256(cfg.thresholdPercentage)).divDown(uint256(cfg.thresholdPercentage).complement())
            );

        return (true, surgeFee);
    }

    /// @dev Converts Hyperliquid raw price to 1e18-scaled USD price.
    function _pegPrice18(uint32 pairIdx) internal view returns (uint256) {
        uint64 raw = HyperPrice.spot(pairIdx); // units: USD * 10^(6-szDecimals)
        // For BTC/USDC (szDecimals = 5) divisor = 10¹, for ETH/USDC (sz=5) same …
        // *Important*: In production you should query `tokenInfo` precompile
        // to fetch `szDecimals` dynamically.  Here we hard-code 10¹ for brevity.
        uint256 divisor = 10; // 10^(6-5)
        return (uint256(raw) * 1e18) / divisor;
    }

    /// @dev For a 2-token pool: price = balanceToken1 / balanceToken0.
    function _poolImpliedPrice(uint256[2] memory bal) internal pure returns (uint256) {
        require(bal[0] > 0, "zero base bal");
        return bal[1].divDown(bal[0]); // USD per asset (18-dec)
    }

    function _ensurePct(uint256 pct) private pure {
        if (pct > FixedPoint.ONE) revert("percent>1");
    }
}
