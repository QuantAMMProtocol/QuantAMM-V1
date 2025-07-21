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

/// @title HyperPrice
/// @notice Utility library to fetch spot prices from the Hyperliquid `spotPx` precompile (0x…0808).
/// @dev Returns raw `uint64` prices which must be rescaled by the caller.
library HyperPrice {
    /// @notice Address of the Hyperliquid `spotPx` precompile.
    /// @dev Hard‑coded because the address is reserved by HyperEVM.
    address internal constant PRECOMPILE = 0x0000000000000000000000000000000000000808; // Hyperliquid spotPx precompile

    /// @notice Fetches the latest raw price for a given Hyperliquid pair.
    /// @param pairIndex The universe pair index as defined by Hyperliquid.
    /// @return price The raw price value encoded as `uint64`.
    function spot(uint32 pairIndex) public view returns (uint64 price) {
        (bool ok, bytes memory out) = PRECOMPILE.staticcall(abi.encode(pairIndex)); // single EVM call to the native precompile
        require(ok, "price");
        price = abi.decode(out, (uint64));
    }
}

/// @title HyperTokenInfo
/// @notice Utility library to fetch token metadata, specifically `szDecimals`, from the Hyperliquid token‑info precompile (0x…0807).
library HyperTokenInfo {
    /// @notice Address of the Hyperliquid `tokenInfo` precompile.
    address internal constant PRECOMPILE = 0x0000000000000000000000000000000000000807; // Hyperliquid tokenInfo precompile

    /// @notice Returns the `szDecimals` value associated with `pairIndex`.
    /// @param pairIndex The universe pair index.
    /// @return dec The number of *size decimals* for the pair.
    function szDecimals(uint32 pairIndex) internal view returns (uint8 dec) {
        // Retrieve size‑decimals so we can convert HyperCore's 6‑dec prices to 18‑dec Balancer units
        (bool ok, bytes memory out) = PRECOMPILE.staticcall(abi.encode(pairIndex));
        require(ok, "dec");
        dec = abi.decode(out, (uint8));
    }
}

/// @title HyperSurgeHook
/// @notice Balancer dynamic‑fee hook that surges when the pool price deviates from Hyperliquid spot beyond a threshold.
/// @dev Supports two‑token pools where token 0 is the *base* (volatile) asset and token 1 is the *quote* asset.
contract HyperSurgeHook is BaseHooks, VaultGuard, SingletonAuthentication, Ownable {
    using FixedPoint for uint256;
    using SafeCast for uint256;

    /// @notice Configuration stored per‑pool.
    /// @param pairIndex   Hyperliquid universe pair index used for pricing.
    /// @param maxSurgeFeePercentage Maximum fee applied when deviation → 100 % (18‑dec fixed point).
    /// @param thresholdPercentage   Deviation required before surging begins (18‑dec fixed point).
    /// @param szDecimals  Size‑decimal parameter for the pair as returned by Hyperliquid.
    struct PoolConfig {
        uint32 pairIndex;
        uint64 maxSurgeFeePercentage;
        uint64 thresholdPercentage;
        uint8 szDecimals;
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
        address,
        address pool,
        TokenConfig[] memory,
        LiquidityManagement calldata
    ) public override onlyVault returns (bool) {
        _poolConfig[pool] = PoolConfig({
            pairIndex: 0,
            maxSurgeFeePercentage: uint64(_defaultMaxSurgeFee),
            thresholdPercentage: uint64(_defaultThreshold),
            szDecimals: 0
        });
        return true;
    }

    /// @notice Links a Balancer pool with a Hyperliquid market and caches its decimal metadata.
    function setPairIndex(address pool, uint32 pair) external onlyOwner {
        uint8 dec = HyperTokenInfo.szDecimals(pair); // single precompile call to fetch szDecimals
        require(dec <= 6, "dec");
        _poolConfig[pool].pairIndex = pair;
        _poolConfig[pool].szDecimals = dec;
    }

    function setMaxSurgeFeePercentage(address pool, uint256 pct) external onlyOwner {
        _ensurePct(pct);
        _poolConfig[pool].maxSurgeFeePercentage = pct.toUint64();
    }

    function setSurgeThresholdPercentage(address pool, uint256 pct) external onlyOwner {
        _ensurePct(pct);
        _poolConfig[pool].thresholdPercentage = pct.toUint64();
    }

    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata p,
        address pool,
        uint256 staticSwapFee
    ) public view override returns (bool, uint256) {
        PoolConfig memory cfg = _poolConfig[pool];
        if (cfg.pairIndex == 0) return (true, staticSwapFee);

        uint256 amountOutScaled18 = WeightedPool(pool).onSwap(p);
        uint256[2] memory balances = [p.balancesScaled18[0], p.balancesScaled18[1]];
        if (p.kind == SwapKind.EXACT_IN) {
            balances[p.indexIn] += p.amountGivenScaled18;
            balances[p.indexOut] -= amountOutScaled18;
        } else {
            balances[p.indexIn] += amountOutScaled18;
            balances[p.indexOut] -= p.amountGivenScaled18;
        }

        // ─── Hyperliquid spot price lookup via helper ───────────────────────────
        uint64 raw;
        try HyperPrice.spot(cfg.pairIndex) returns (uint64 priceRaw) {
            raw = priceRaw; // retrieve raw uint64 price through library helper
        } catch {
            return (true, staticSwapFee); // revert to static fee if precompile fails
        }

        // Convert Hyperliquid's 6‑dec fixed‑point price to 18‑dec units expected by Balancer's 6‑dec fixed‑point price to 18‑dec units expected by Balancer
        uint256 divisor = 10 ** (6 - cfg.szDecimals); // uses cached szDecimals
        uint256 pegPx = (uint256(raw) * 1e18) / divisor;
        // ───────────────────────────────────────────────────────────────────────

        uint256 poolPx = _poolImpliedPrice(balances);
        uint256 deviation = poolPx > pegPx ? (poolPx - pegPx).divDown(pegPx) : (pegPx - poolPx).divDown(pegPx);
        if (deviation <= uint256(cfg.thresholdPercentage)) return (true, staticSwapFee);

        uint256 surgeFee = staticSwapFee +
            (uint256(cfg.maxSurgeFeePercentage) - staticSwapFee).mulDown(
                (deviation - uint256(cfg.thresholdPercentage)).divDown(uint256(cfg.thresholdPercentage).complement())
            );

        //max/min surgeFee.

        return (true, surgeFee);
    }

    function _poolImpliedPrice(uint256[2] memory bal) internal pure returns (uint256 price18) {
        require(bal[0] > 0, "bal0");
        price18 = bal[1].divDown(bal[0]);
    }

    function _ensurePct(uint256 pct) private pure {
        if (pct > FixedPoint.ONE) revert("pct");
    }
}
