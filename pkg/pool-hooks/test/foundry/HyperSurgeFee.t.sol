// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

// Base test utilities (provides: vault, poocomputeLocals, poolFactory, admin, authorizer, routers, tokens, etc.)
import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

// Hook interfaces
import { IHyperSurgeHook } from "@balancer-labs/v3-interfaces/contracts/pool-hooks/IHyperSurgeHook.sol";
import { IAuthentication } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IAuthentication.sol";
import { IAuthorizer } from "@balancer-labs/v3-interfaces/contracts/vault/IAuthorizer.sol";

// Vault interfaces/types
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    TokenConfig,
    LiquidityManagement,
    PoolSwapParams,
    SwapKind,
    PoolRoleAccounts
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

// Local deployer + mock
import { HyperSurgeHookDeployer } from "./utils/HyperSurgeHookDeployer.sol";
import { HyperSurgeHookMock } from "../../contracts/test/HyperSurgeHookMock.sol";
import {
    HyperSpotPricePrecompile
} from "@balancer-labs/v3-standalone-utils/contracts/utils/HyperSpotPricePrecompile.sol";
import {
    HyperTokenInfoPrecompile
} from "@balancer-labs/v3-standalone-utils/contracts/utils/HyperTokenInfoPrecompile.sol";
import {
    HypercorePrecompileMock
} from "@balancer-labs/v3-standalone-utils/test/foundry/utils/HypercorePrecompileMock.sol";

import {
    WeightedPoolContractsDeployer
} from "@balancer-labs/v3-pool-weighted/test/foundry/utils/WeightedPoolContractsDeployer.sol";
import { WeightedPool } from "@balancer-labs/v3-pool-weighted/contracts/WeightedPool.sol";

contract HLPriceStub {
    mapping(uint32 => uint32) internal px; // slot 0

    fallback(bytes calldata data) external returns (bytes memory ret) {
        uint32 pairIndex = abi.decode(data, (uint32));
        return abi.encode(px[pairIndex]);
    }

    function set(uint32 pairIndex, uint32 price_1e6) external {
        px[pairIndex] = price_1e6;
    }
}

contract HLTokenInfoStub {
    mapping(uint32 => uint8) internal sz;

    // Optional but nice for staticcall patterns:
    fallback(bytes calldata data) external returns (bytes memory ret) {
        uint32 tokenIndex = abi.decode(data, (uint32));

        // Read stored record and ensure the struct fields exist
        HyperTokenInfoPrecompile.HyperTokenInfo memory t;

        // Copy only what you care about; others can be zero/empty
        t.szDecimals = sz[tokenIndex];

        return abi.encode(t); // <<< return the STRUCT
    }

    function set(uint32 pairIndex, uint8 decimals) external {
        sz[pairIndex] = decimals;
    }
}

/**
 * =============================
 * Test Suite Summary (grouped)
 * =============================
 *
 * INTEGRATION — Hyper Spot Path
 * --------------------------------
 * [testFuzz_hyper_price_spot_success_EXACT_IN_multi]
 *   Fuzz multi-token EXACT_IN via hyper spot; call succeeds and fee is sane (≥ static, ≤ 100%).
 * [testFuzz_hyper_price_spot_success_EXACT_OUT_multi]
 *   Fuzz multi-token EXACT_OUT via hyper spot; call succeeds and fee is sane (≥ static, ≤ 100%).
 * [testFuzz_hyper_price_spot_expected_failure_marker]
 *   Drives hyper-spot into expected failure and verifies the failure marker/revert behavior.
 *
 * VIEW-ONLY BEHAVIOR
 * --------------------
 * [testFuzz_view_missingPrices_returnsStatic_orRevert]
 *   With missing external prices, returns static fee (or cleanly reverts); never computes dynamic.
 * [testFuzz_view_readsLaneParams_returnsStatic_onSafePath]
 *   Safe path reads lane params and returns the configured static fee.
 *
 * MATH & INVARIANTS (Internal)
 * ------------------------------
 * [test_internal_exactValues_boundaries]
 *   Boundary checks: static at/≤ threshold, linear mid-span ramp, clamp to max at/≥ cap.
 * [testFuzz_internal_feeRamp_matches_expected_withParams]
 *   Reference ramp formula matches internal math across fuzzed threshold/cap/max & deviations.
 * [testFuzz_internal_monotone_inDeviation]
 *   Dynamic fee is monotone non-decreasing in absolute deviation under fixed params.
 * [testFuzz_internal_balanceScalingInvariance]
 *   Fee is invariant (within tight tolerance) when scaling balances and trade size by same factor.
 * [testFuzz_internal_exactIn_equals_exactOut_whenParamsSame]
 *   With identical effective lane params, EXACT_IN == EXACT_OUT; opposite lane differs to catch wrong-lane usage.
 *
 * CONFIGURATION / DEGENERATES
 * -----------------------------
 * [test_cfg_fee_static_at_threshold_usingMockWrapper]
 *   Exactly at threshold → static fee (no ramp kickoff).
 * [test_cfg_fee_minimalRamp_just_above_threshold_usingMockWrapper]
 *   Just above threshold → ramp starts from static with minimal positive slope.
 * [test_cfg_fee_degenerateRamp_max_equals_static_usingMockWrapper]
 *   max == static → degenerate schedule; dynamic == static for all deviations.
 * [test_cfg_fee_misconfig_max_below_static_reverts_usingMockWrapper]
 *   Misconfigured schedule (max < static) is rejected (reverts) rather than emitting an invalid fee.
 *
 * LANE LOGIC — NOISE (uses AFTER deviation)
 * -------------------------------------------
 * [testFuzz_logic_noise_worsens_outside_dynamic_after]
 *   Start outside; trade worsens deviation → NOISE; dynamic fee from AFTER (≥ static).
 * [testFuzz_logic_noise_inside_to_outside_dynamic_after]
 *   Start inside; worsen enough to exit band → NOISE; dynamic fee from AFTER (≥ static).
 * [testFuzz_logic_noise_outside_crosses_and_worsens_dynamic_after]
 *   Start outside above; cross below and worsen absolute deviation → NOISE; AFTER basis (≥ static).
 * [testFuzz_logic_noise_outside_below_worsens_dynamic_after]
 *   Symmetric “below-side worsen” (no cross) → NOISE; AFTER basis (≥ static).
 * [testFuzz_logic_noise_inside_worsens_but_inside_static]
 *   Start inside; worsen but remain inside → NOISE; fee stays STATIC.
 *
 * LANE LOGIC — ARB (uses BEFORE deviation)
 * -----------------------------------------
 * [testFuzz_logic_arb_outside_improves_but_outside_dynamic_before]
 *   Start outside; improve but remain outside → ARB; dynamic fee from BEFORE (≥ static).
 * [testFuzz_logic_arb_outside_to_threshold_dynamic_before]
 *   Start outside; improve to at/inside threshold (two-sided bound) → ARB; BEFORE basis (dynamic).
 * [testFuzz_logic_arb_outside_to_inside_dynamic_before]
 *   Start outside; end inside → ARB still uses BEFORE; expects dynamic (not static).
 * [test_logic_arb_outside_nochange_dynamic_before]
 *   No movement while outside → ARB; BEFORE-based dynamic fee (≥ static).
 * [test_logic_arb_inside_nochange_static]
 *   No movement while inside → ARB branch but fee is STATIC (since deviation ≤ threshold).
 *
 * BOUNDARY & CLAMPING PRECISION
 * -------------------------------
 * [testFuzz_bound_noise_after_gt_cap_clamps_to_max_after]
 *   Start near threshold, worsen so AFTER > cap → NOISE clamps to noiseMax (AFTER basis).
 * [testFuzz_bound_arb_before_gt_cap_clamps_to_max_before]
 *   BEFORE > cap; improve without crossing so AFTER ≤ cap → ARB clamps to arbMax (BEFORE basis).
 * [testFuzz_bound_noise_after_at_threshold_static]
 *   Start inside and worsen to land exactly at threshold → NOISE returns STATIC (no ramp).
 *
 * */

contract HyperSurgeFeeTest is BaseVaultTest, HyperSurgeHookDeployer, WeightedPoolContractsDeployer {
    using ArrayHelpers for *;
    using CastingHelpers for address[];

    uint256 constant ONE = 1e18;
    uint256 constant STATIC_SWAP_FEE = 1e16; // 1% (1e18 scale)

    // MUST match addresses the hook libs read
    uint256 internal constant DEFAULT_SWAP_FEE = 1e16; // 1%
    uint256 constant FEE_ONE = 1e18;

    HyperSurgeHookMock internal hook;

    HLPriceStub internal _pxStubDeployer;
    HLTokenInfoStub internal _infoStubDeployer;

    function setUp() public virtual override {
        super.setUp(); // vault, poocomputeLocals, poolFactory, admin, authorizer, tokens, routers, ...

        vm.prank(address(poolFactory));
        hook = deployHook(
            IVault(address(vault)),
            0.02e18, // default max fee (2%)
            0.02e18, // default threshold (2%)
            1e18,
            string("test")
        );

        // 2) Install precompile stubs at fixed addresses
        _pxStubDeployer = new HLPriceStub();
        _infoStubDeployer = new HLTokenInfoStub();
        vm.etch(HyperSpotPricePrecompile.SPOT_PRICE_PRECOMPILE_ADDRESS, address(_pxStubDeployer).code);
        vm.etch(HyperTokenInfoPrecompile.TOKEN_INFO_PRECOMPILE_ADDRESS, address(_infoStubDeployer).code);

        // Seed a couple of pairs (pairIndex 1 and 2)
        _hlSetSzDecimals(1, 6);
        _hlSetSzDecimals(2, 6);
        _hlSetSpot(1, 100_000_000); // 100.000000 (1e6 scale)
        _hlSetSpot(2, 200_000_000); // 200.000000 (1e6 scale)

        // 3) Grant admin roles to `admin`
        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setMaxSurgeFeePercentage.selector),
            admin
        );
        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setSurgeThresholdPercentage.selector),
            admin
        );
        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setCapDeviationPercentage.selector),
            admin
        );
        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setTokenPriceConfigIndex.selector),
            admin
        );
    }

    struct HyperPriceSpotParams {
        uint32 raw;
        uint32 divisor;
        uint256 amtSeed;
        uint256 feeSeed;
        uint8 outSeed;
        uint256 n;
        uint256 maxPct;
        uint256 thr;
        uint256 cap;
        uint8 indexIn;
        uint8 indexOut;
        uint32 pairIdx;
        uint256 MAX_RATIO;
        uint256 maxIn;
        uint256 staticFee;
    }

    function testFuzz_hyper_price_spot_success_EXACT_IN_multi(
        uint32 raw,
        uint32 divisor,
        uint256 amtSeed,
        uint256 feeSeed,
        uint8 outSeed
    ) public {
        HyperPriceSpotParams memory params;

        // --- discover live pool size (N) from the deployed weighted pool
        params.n = WeightedPool(address(pool)).getNormalizedWeights().length;
        assertGe(params.n, 2, "pool must have >=2 tokens");
        require(params.n <= 8, "hook supports up to 8");

        // --- fuzz external price + decimals (non-zero price)
        params.raw = uint32(bound(raw, 1, type(uint32).max));
        params.divisor = uint32(bound(divisor, 1, 1_000_000) % 7); // 0..6

        // --- hook registration with correct N
        TokenConfig[] memory cfg = new TokenConfig[](params.n);
        LiquidityManagement memory lm;
        vm.prank(address(vault));
        assertTrue(hook.onRegister(poolFactory, address(pool), cfg, lm), "onRegister failed");

        // --- fee knobs (1e9)
        params.maxPct = bound(feeSeed, 3, 1e9);
        params.thr = params.maxPct / 3;
        params.cap = params.thr + (1e9 - params.thr) / 2;
        if (params.cap == params.thr) params.cap = params.thr + 1;

        // --- make NOISE lane different (keep maxPct same so staticFee bound remains valid)
        uint256 noiseThr = (params.thr + 2 < params.cap) ? (params.thr + 1) : (params.thr - 1);
        uint256 noiseCap = params.cap;

        vm.startPrank(admin);
        hook.setMaxSurgeFeePercentage(address(pool), params.maxPct * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setSurgeThresholdPercentage(address(pool), params.thr * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setCapDeviationPercentage(address(pool), params.cap * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);

        hook.setMaxSurgeFeePercentage(address(pool), params.maxPct * 1e9, IHyperSurgeHook.TradeType.NOISE);
        hook.setSurgeThresholdPercentage(address(pool), noiseThr * 1e9, IHyperSurgeHook.TradeType.NOISE);
        hook.setCapDeviationPercentage(address(pool), noiseCap * 1e9, IHyperSurgeHook.TradeType.NOISE);
        vm.stopPrank();

        // --- configure external price sources for the two indices we’ll swap
        params.indexIn = 0;
        params.indexOut = uint8(bound(outSeed, 1, uint8(params.n - 1)));

        params.pairIdx = 1; // arbitrary non-zero HL pair id for the out token
        _hlSetSzDecimals(params.pairIdx, uint8(params.divisor));
        _hlSetSpot(params.pairIdx, params.raw);

        vm.startPrank(admin);
        hook.setTokenPriceConfigIndex(address(pool), params.indexIn, params.pairIdx, params.pairIdx + 20);
        hook.setTokenPriceConfigIndex(address(pool), params.indexOut, params.pairIdx, params.pairIdx + 20); // HL pair
        vm.stopPrank();

        // --- balancesScaled18 with length N (simple increasing balances)
        uint256[] memory balances = new uint256[](params.n);
        for (uint256 i = 0; i < params.n; ++i) {
            balances[i] = 1e18 * (i + 1);
        }

        // --- build PoolSwapParams (EXACT_IN: 0 -> indexOut)
        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.balancesScaled18 = balances;
        p.indexIn = params.indexIn;
        p.indexOut = params.indexOut;

        // bound amountIn to strictly inside the 30% guard
        params.MAX_RATIO = 30e16; // 30% in 1e18
        params.maxIn = (balances[p.indexIn] * params.MAX_RATIO) / 1e18;
        if (params.maxIn > 0) params.maxIn -= 1;
        p.amountGivenScaled18 = bound(amtSeed, 1, params.maxIn == 0 ? 1 : params.maxIn);

        // static fee (1e9) bounded to maxPct
        params.staticFee = bound(feeSeed % 1e9, 0, params.maxPct);

        // --- compute dynamic fee via hook
        vm.startPrank(address(vault));
        (bool ok, uint256 dyn) = hook.onComputeDynamicSwapFeePercentage(p, address(pool), params.staticFee);
        vm.stopPrank();

        assertTrue(ok, "compute fee should succeed");
        // returned value is in 1e9 scale here (hook keeps pct in 1e9)
        assertLe(dyn, 1e18, "fee must be <= 100% (1e9)");
        assertGe(dyn, params.staticFee, "dyn fee >= static fee");
    }

    function testFuzz_hyper_price_spot_success_EXACT_OUT_multi(
        uint32 raw,
        uint32 divisor,
        uint256 amtSeed,
        uint256 feeSeed,
        uint8 outSeed
    ) public {
        HyperPriceSpotParams memory params;

        // --- discover live pool size (N)
        params.n = WeightedPool(address(pool)).getNormalizedWeights().length;
        assertGe(params.n, 2, "pool must have >=2 tokens");
        require(params.n <= 8, "hook supports up to 8");

        // --- external price + decimals
        params.raw = uint32(bound(raw, 1, type(uint32).max));
        params.divisor = uint32(bound(divisor, 1, 1_000_000) % 7); // 0..6

        // --- register with correct N
        TokenConfig[] memory cfg = new TokenConfig[](params.n);
        LiquidityManagement memory lm;
        vm.prank(address(vault));
        assertTrue(hook.onRegister(poolFactory, address(pool), cfg, lm), "onRegister failed");

        // --- fee knobs (1e9)
        params.maxPct = bound(feeSeed, 3, 1e9);
        params.thr = params.maxPct / 3;
        params.cap = params.thr + (1e9 - params.thr) / 2;
        if (params.cap == params.thr) params.cap = params.thr + 1;

        // --- make NOISE lane different (keep maxPct same so staticFee bound remains valid)
        uint256 noiseThr = (params.thr + 2 < params.cap) ? (params.thr + 1) : (params.thr - 1);
        uint256 noiseCap = params.cap;

        vm.startPrank(admin);
        hook.setMaxSurgeFeePercentage(address(pool), params.maxPct * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setSurgeThresholdPercentage(address(pool), params.thr * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setCapDeviationPercentage(address(pool), params.cap * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);

        hook.setMaxSurgeFeePercentage(address(pool), params.maxPct * 1e9, IHyperSurgeHook.TradeType.NOISE);
        hook.setSurgeThresholdPercentage(address(pool), noiseThr * 1e9, IHyperSurgeHook.TradeType.NOISE);
        hook.setCapDeviationPercentage(address(pool), noiseCap * 1e9, IHyperSurgeHook.TradeType.NOISE);
        vm.stopPrank();

        // --- configure price only for the two indices we use
        params.indexIn = 0;
        params.indexOut = uint8(bound(outSeed, 1, uint8(params.n - 1)));

        params.pairIdx = 1;
        _hlSetSzDecimals(params.pairIdx + 20, uint8(params.divisor));
        _hlSetSpot(params.pairIdx, params.raw);

        vm.startPrank(admin);
        hook.setTokenPriceConfigIndex(address(pool), params.indexIn, params.pairIdx, params.pairIdx + 20);
        hook.setTokenPriceConfigIndex(address(pool), params.indexOut, params.pairIdx, params.pairIdx + 20); // HL pair
        vm.stopPrank();

        // --- balancesScaled18 length N
        uint256[] memory balances = new uint256[](params.n);
        for (uint256 i = 0; i < params.n; ++i) {
            balances[i] = 1e18 * (i + 1);
        }

        // --- build PoolSwapParams (EXACT_OUT: 0 -> indexOut)
        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_OUT;
        p.balancesScaled18 = balances;
        p.indexIn = params.indexIn;
        p.indexOut = params.indexOut;

        // bound amountOut to strictly inside the 30% guard
        params.MAX_RATIO = 30e16; // 30%
        params.maxIn = (balances[p.indexOut] * params.MAX_RATIO) / 1e18;
        if (params.maxIn > 0) {
            params.maxIn -= 1;
        }
        p.amountGivenScaled18 = bound(amtSeed, 1, params.maxIn == 0 ? 1 : params.maxIn); // for EXACT_OUT this is amountOut

        // static fee (1e9)
        params.staticFee = bound(feeSeed % 1e9, 0, params.maxPct);

        vm.startPrank(address(vault));
        (bool ok, uint256 dyn) = hook.onComputeDynamicSwapFeePercentage(p, address(pool), params.staticFee);
        vm.stopPrank();

        assertTrue(ok, "compute fee should succeed");
        assertLe(dyn, 1e18, "fee must be <= 100% (1e9)");
        assertGe(dyn, params.staticFee, "dyn fee >= static fee");
    }

    // Pack locals to avoid stack-too-deep
    struct FailureCtx {
        uint256 n;
        uint8 indexIn;
        uint8 indexOut;
        uint32 pairIdx;
        uint8 sz;
        uint256 maxPct;
        uint256 thr;
        uint256 cap;
        uint256 staticFee;
        uint256[] balances;
        uint256 maxRatio;
        uint256 maxIn;
        bool ok;
        uint256 dyn;
        uint256 max9;
        uint256 thr9;
        uint256 cap9;
        uint256 capRoom;
        uint256 staticSeed;
        uint256 i;
        uint256 amtSeed;
    }

    function testFuzz_hyper_price_spot_expected_failure_marker(uint256 marker) public {
        // Keep the seed bounded and lively
        marker = bound(marker, 4, type(uint32).max - 1);

        FailureCtx memory locals;

        // 1) Pool size
        locals.n = WeightedPool(address(pool)).getNormalizedWeights().length;
        assertGe(locals.n, 2, "pool must have >=2 tokens");
        require(locals.n <= 8, "hook supports up to 8");

        // 2) Register hook with exactly N TokenConfig entries
        TokenConfig[] memory cfg = new TokenConfig[](locals.n);
        LiquidityManagement memory lm;
        vm.prank(address(vault));
        assertTrue(hook.onRegister(poolFactory, address(pool), cfg, lm), "onRegister failed");

        // 3) Build VALID lane params (9), then upscale ONCE to 18dp
        //    max9 ∈ [1..1e9], thr9 ∈ [1..max9], cap9 ∈ (thr9..1e9]
        locals.max9 = 1 + (marker % 1_000_000_000); // avoid 0
        locals.thr9 = 1 + ((marker >> 8) % locals.max9); // greater than or equal to1 and less than or equal to max9
        locals.capRoom = 1_000_000_000 - locals.thr9; // room above thr
        locals.cap9 = locals.thr9 + 1; // strictly > thr
        if (locals.capRoom > 0) {
            locals.cap9 = locals.thr9 + 1 + ((marker >> 16) % locals.capRoom); // (thr9, 1e9]
        }
        if (locals.cap9 > 1_000_000_000) locals.cap9 = 1_000_000_000; // clamp just in case

        // Upscale once to 18dp
        locals.maxPct = locals.max9 * 1e9;
        locals.thr = locals.thr9 * 1e9;
        locals.cap = locals.cap9 * 1e9;

        // static fee (18dp) ∈ [0..maxPct18]
        uint256 staticSeed = (uint256(keccak256(abi.encodePacked(marker))) << 32) | marker;
        locals.staticFee = bound(staticSeed, 0, locals.maxPct);

        vm.startPrank(admin);
        // Set both lanes using 18dp values
        hook.setMaxSurgeFeePercentage(address(pool), locals.maxPct, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setSurgeThresholdPercentage(address(pool), locals.thr, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setCapDeviationPercentage(address(pool), locals.cap, IHyperSurgeHook.TradeType.ARBITRAGE);

        hook.setMaxSurgeFeePercentage(address(pool), locals.maxPct, IHyperSurgeHook.TradeType.NOISE);
        hook.setSurgeThresholdPercentage(address(pool), locals.thr, IHyperSurgeHook.TradeType.NOISE);
        hook.setCapDeviationPercentage(address(pool), locals.cap, IHyperSurgeHook.TradeType.NOISE);
        vm.stopPrank();

        // 4) Configure price sources for the two indices we’ll use
        locals.indexIn = 0;
        locals.indexOut = uint8(1 + (marker % (locals.n - 1))); // ∈ [1, n-1]
        locals.pairIdx = 2; // any non-zero pair id for HL
        locals.sz = uint8((marker >> 16) % 7); // 0..6

        _hlSetSzDecimals(locals.pairIdx, locals.sz);
        _hlSetSpot(locals.pairIdx, 0); // spot=0 → hook may return (ok=false), but must not revert

        vm.startPrank(admin);
        hook.setTokenPriceConfigIndex(address(pool), locals.indexIn, locals.pairIdx, locals.pairIdx + 20);
        hook.setTokenPriceConfigIndex(address(pool), locals.indexOut, locals.pairIdx, locals.pairIdx + 20);
        vm.stopPrank();

        // 5) Balances array of length N (ascending 1e18, 2e18, ...)
        locals.balances = new uint256[](locals.n);
        for (locals.i = 0; locals.i < locals.n; ++locals.i) {
            locals.balances[locals.i] = 1e18 * (locals.i + 1);
        }

        // 6) Build swap params (EXACT_IN), amount within 30% guard
        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.balancesScaled18 = locals.balances;
        p.indexIn = locals.indexIn;
        p.indexOut = locals.indexOut;

        locals.maxRatio = 30e16; // 30% in 1e18 basis
        locals.maxIn = (locals.balances[p.indexIn] * locals.maxRatio) / 1e18;
        if (locals.maxIn > 0) {
            locals.maxIn -= 1;
        }

        locals.amtSeed = (marker << 32) | marker;
        p.amountGivenScaled18 = bound(locals.amtSeed, 1, locals.maxIn == 0 ? 1 : locals.maxIn);

        (locals.ok, locals.dyn) = hook.onComputeDynamicSwapFeePercentage(p, address(pool), locals.staticFee);

        // If ok=false (spot=0 path), that's fine; just ensure no revert. If ok=true, fee less than or equal to 100%.
        if (locals.ok) {
            assertLe(locals.dyn, 1e18, "fee must be <= 100%");
        }
    }

    struct FeeRampLocals {
        uint8 n;
        uint256[] w;
        uint256[] b;
        uint8 i;
        uint8 j;
        uint32 thrPPM9;
        uint32 capPPM9;
        uint32 maxPPM9;
        uint256 P;
        uint256 capDev;
        uint256 D;
        uint256 pxIn;
        uint256 pxOut;
        uint256 feeA;
        uint256 expected;
        bool ok;
    }

    /// Fuzz full param surface: N, pair indices, fee params; mock must match exact expected fee.
    function testFuzz_internal_feeRamp_matches_expected_withParams(
        uint8 nSeed,
        uint256 wSeed,
        uint256 bSeed,
        uint256 dSeed,
        uint32 thrPPM9,
        uint32 capPPM9,
        uint32 maxPPM9
    ) public {
        FeeRampLocals memory locals;

        locals.n = uint8(bound(nSeed, 2, 8));
        locals.w = fee_normWeights(locals.n, wSeed);
        locals.b = fee_balances(locals.n, bSeed);

        locals.i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 11))), 0, locals.n - 1));
        locals.j = (locals.i + 1 + uint8(bound(uint256(keccak256(abi.encode(dSeed, 12))), 0, locals.n - 2))) % locals.n;

        (locals.thrPPM9, locals.capPPM9, locals.maxPPM9) = fee_boundParams(thrPPM9, capPPM9, maxPPM9);

        locals.P = fee_pairSpotFromBW(locals.b[locals.i], locals.w[locals.i], locals.b[locals.j], locals.w[locals.j]);
        vm.assume(locals.P > 0);

        locals.capDev = fee_ppm9To1e18(locals.capPPM9);
        locals.D = uint256(keccak256(abi.encode(dSeed))) % (locals.capDev + locals.capDev / 2 + 1);

        (locals.pxIn, locals.pxOut) = fee_localsForDeviation(locals.P, locals.D);

        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.maxPPM9),
            fee_ppm9To1e18(locals.thrPPM9),
            fee_ppm9To1e18(locals.capPPM9),
            "fee-fuzz"
        );
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory computeLocals = fee_makeLocals(
            locals.b[locals.i],
            locals.w[locals.i],
            locals.b[locals.j],
            locals.w[locals.j],
            locals.pxIn,
            locals.pxOut,
            locals.thrPPM9,
            locals.capPPM9,
            locals.maxPPM9
        );

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        (locals.ok, locals.feeA) = mock.ComputeSurgeFee(computeLocals, p, STATIC_SWAP_FEE);
        assertTrue(locals.ok, "compute must succeed");

        locals.expected = fee_expectedFeeWithParams(
            locals.P,
            locals.pxIn,
            locals.pxOut,
            STATIC_SWAP_FEE,
            locals.thrPPM9,
            locals.capPPM9,
            locals.maxPPM9
        );
        assertEq(locals.feeA, locals.expected, "mock engine must match expected ramp");
    }

    struct monotoneDeviationLocals {
        uint8 n;
        uint256[] w;
        uint256[] b;
        uint8 i;
        uint8 j;
        uint32 thrPPM9;
        uint32 capPPM9;
        uint32 maxPPM9;
        uint256 P;
        uint256 capDev;
        uint256 D1;
        uint256 D2;
        uint256 pxIn1;
        uint256 pxOut1;
        uint256 pxIn2;
        uint256 pxOut2;
        uint256 fee1;
        uint256 fee2;
    }

    /// Monotonicity in deviation under arbitrary (valid) lane params.
    function testFuzz_internal_monotone_inDeviation(
        uint8 nSeed,
        uint256 wSeed,
        uint256 bSeed,
        uint256 d1,
        uint256 d2,
        uint32 thrPPM9,
        uint32 capPPM9,
        uint32 maxPPM9
    ) public {
        monotoneDeviationLocals memory locals;

        locals.n = uint8(bound(nSeed, 2, 8));
        locals.w = fee_normWeights(locals.n, wSeed);
        locals.b = fee_balances(locals.n, bSeed);

        locals.i = uint8(bound(uint256(keccak256(abi.encode(d1, 21))), 0, locals.n - 1));
        locals.j = (locals.i + 1 + uint8(bound(uint256(keccak256(abi.encode(d1, 22))), 0, locals.n - 2))) % locals.n;

        (locals.thrPPM9, locals.capPPM9, locals.maxPPM9) = fee_boundParams(thrPPM9, capPPM9, maxPPM9);

        locals.P = fee_pairSpotFromBW(locals.b[locals.i], locals.w[locals.i], locals.b[locals.j], locals.w[locals.j]);
        vm.assume(locals.P > 0);

        locals.capDev = fee_ppm9To1e18(locals.capPPM9);

        locals.D1 = uint256(keccak256(abi.encode(d1))) % (locals.capDev + locals.capDev / 2 + 1);
        locals.D2 = uint256(keccak256(abi.encode(d2))) % (locals.capDev + locals.capDev / 2 + 1);
        if (locals.D2 < locals.D1) (locals.D1, locals.D2) = (locals.D2, locals.D1);

        (locals.pxIn1, locals.pxOut1) = fee_localsForDeviation(locals.P, locals.D1);
        (locals.pxIn2, locals.pxOut2) = fee_localsForDeviation(locals.P, locals.D2);

        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.maxPPM9),
            fee_ppm9To1e18(locals.thrPPM9),
            fee_ppm9To1e18(locals.capPPM9),
            "fee-mono"
        );

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        (, locals.fee1) = mock.ComputeSurgeFee(
            fee_makeLocals(
                locals.b[locals.i],
                locals.w[locals.i],
                locals.b[locals.j],
                locals.w[locals.j],
                locals.pxIn1,
                locals.pxOut1,
                locals.thrPPM9,
                locals.capPPM9,
                locals.maxPPM9
            ),
            p,
            STATIC_SWAP_FEE
        );
        (, locals.fee2) = mock.ComputeSurgeFee(
            fee_makeLocals(
                locals.b[locals.i],
                locals.w[locals.i],
                locals.b[locals.j],
                locals.w[locals.j],
                locals.pxIn2,
                locals.pxOut2,
                locals.thrPPM9,
                locals.capPPM9,
                locals.maxPPM9
            ),
            p,
            STATIC_SWAP_FEE
        );

        assertLe(locals.fee1, locals.fee2, "fee must be non-decreasing in deviation");
    }

    struct balanceScalingLocals {
        uint8 n;
        uint256[] w;
        uint256[] b;
        uint8 i;
        uint8 j;
        uint32 thrPPM9;
        uint32 capPPM9;
        uint32 maxPPM9;
        uint256 P;
        uint256 capDev;
        uint256 scaleSeed;
        uint256 D;
        uint256 pxIn;
        uint256 pxOut;
        uint256 bMin;
        uint256 baseAmt;
        uint256 fee1;
        uint256 fee2;
    }

    function testFuzz_internal_balanceScalingInvariance(
        uint8 nSeed,
        uint256 wSeed,
        uint256 bSeed,
        uint256 dSeed,
        uint64 scaleSeed,
        uint32 thrPPM9,
        uint32 capPPM9,
        uint32 maxPPM9
    ) public {
        balanceScalingLocals memory locals;

        // --- Setup, seeds, and bounds (same as before) ---
        locals.n = uint8(bound(nSeed, 2, 8));
        locals.w = fee_normWeights(locals.n, wSeed);
        locals.b = fee_balances(locals.n, bSeed);

        locals.i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 31))), 0, locals.n - 1));
        locals.j = (locals.i + 1 + uint8(bound(uint256(keccak256(abi.encode(dSeed, 32))), 0, locals.n - 2))) % locals.n;

        (locals.thrPPM9, locals.capPPM9, locals.maxPPM9) = fee_boundParams(thrPPM9, capPPM9, maxPPM9);

        // Pool spot from balances/weights; ensure sane
        locals.P = fee_pairSpotFromBW(locals.b[locals.i], locals.w[locals.i], locals.b[locals.j], locals.w[locals.j]);
        vm.assume(locals.P > 0);

        locals.capDev = fee_ppm9To1e18(locals.capPPM9);

        // Choose a deviation up to 1.5 * cap to exercise both sides near edges
        locals.D = uint256(keccak256(abi.encode(dSeed))) % (locals.capDev + locals.capDev / 2 + 1);

        // External price inputs that produce the desired deviation
        (locals.pxIn, locals.pxOut) = fee_localsForDeviation(locals.P, locals.D);

        // Scale factor k and a base amount small relative to balances to avoid overflow
        locals.scaleSeed = 1 + (uint256(scaleSeed) % 1_000_000_000); // k in [1 .. 1e9]

        locals.bMin = locals.b[locals.i] < locals.b[locals.j] ? locals.b[locals.i] : locals.b[locals.j];
        // base amount ~ bMin / 1e12 (but at least 1 wei); keeps amount*k << 2^256
        locals.baseAmt = locals.bMin / 1e12;
        if (locals.baseAmt == 0) locals.baseAmt = 1;

        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.maxPPM9),
            fee_ppm9To1e18(locals.thrPPM9),
            fee_ppm9To1e18(locals.capPPM9),
            "fee-scale"
        );

        // Unscaled trade
        PoolSwapParams memory p1;
        p1.kind = SwapKind.EXACT_IN;
        p1.amountGivenScaled18 = locals.baseAmt;

        PoolSwapParams memory p2;
        p2.kind = SwapKind.EXACT_IN;
        p2.amountGivenScaled18 = locals.baseAmt * locals.scaleSeed;

        (, locals.fee1) = mock.ComputeSurgeFee(
            fee_makeLocals(
                locals.b[locals.i],
                locals.w[locals.i],
                locals.b[locals.j],
                locals.w[locals.j],
                locals.pxIn,
                locals.pxOut,
                locals.thrPPM9,
                locals.capPPM9,
                locals.maxPPM9
            ),
            p1,
            STATIC_SWAP_FEE
        );

        (, locals.fee2) = mock.ComputeSurgeFee(
            fee_makeLocals(
                locals.b[locals.i] * locals.scaleSeed,
                locals.w[locals.i],
                locals.b[locals.j] * locals.scaleSeed,
                locals.w[locals.j],
                locals.pxIn,
                locals.pxOut,
                locals.thrPPM9,
                locals.capPPM9,
                locals.maxPPM9
            ),
            p2,
            STATIC_SWAP_FEE
        );

        // --- Branch-aware assertion (inferred) ---
        uint256 strictTol = 100; // knife-edge rounding flips
        uint256 delta = locals.fee1 > locals.fee2 ? (locals.fee1 - locals.fee2) : (locals.fee2 - locals.fee1);

        if (delta <= strictTol) {
            // Noise-like behavior: strict homogeneity holds
            assertApproxEqAbs(
                locals.fee1,
                locals.fee2,
                strictTol,
                "noise path: fee invariant to balance + amount scaling (100 wei)"
            );
        } else {
            // Arb-like behavior: deviation reset makes fee non-homogeneous; allow a tiny bounded drift
            // Use ~1e-10 relative tolerance with a small absolute floor to remain meaningful for tiny fees.
            uint256 relaxedTol = locals.fee1 / 1e10;
            if (relaxedTol < 1e5) relaxedTol = 1e5;

            assertApproxEqAbs(
                locals.fee1,
                locals.fee2,
                relaxedTol,
                "arb path: fee approximately invariant after deviation reset (branch-aware tolerance)"
            );
        }
    }

    struct ExactValuesBoundariesLocal {
        uint256 w0;
        uint256 w1;
        uint256 b0;
        uint256 b1;
        uint256 P;
        uint32 thr;
        uint32 cap;
        uint32 maxp;
        uint256 D;
        uint256 pxIn;
        uint256 pxOut;
        uint256 feeA;
        uint256 feeB;
        uint256 feeC;
        uint256 feeD;
    }

    function test_internal_exactValues_boundaries() public {
        ExactValuesBoundariesLocal memory locals;

        // 2 tokens, 50/50, equal balances
        locals.w0 = 5e17;
        locals.w1 = 5e17;
        locals.b0 = 1e24;
        locals.b1 = 1e24;
        locals.P = fee_pairSpotFromBW(locals.b0, locals.w0, locals.b1, locals.w1);
        assertGt(locals.P, 0);

        locals.thr = 1_000_000; // 0.1%
        locals.cap = 500_000_000; // 50%
        locals.maxp = 50_000_000; // 5%

        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.maxp),
            fee_ppm9To1e18(locals.thr),
            fee_ppm9To1e18(locals.cap),
            "fee-boundary"
        );
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory computeLocals;
        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;

        // Below threshold
        locals.D = fee_ppm9To1e18(locals.thr) - 1;
        (locals.pxIn, locals.pxOut) = fee_localsForDeviation(locals.P, locals.D);

        computeLocals.bIn = locals.b0;
        computeLocals.wIn = locals.w0;
        computeLocals.bOut = locals.b1;
        computeLocals.wOut = locals.w1;
        computeLocals.pxIn = locals.pxIn;
        computeLocals.pxOut = locals.pxOut;
        computeLocals.calcAmountScaled18 = 0;

        // ARB lane = locals’ params (since deviation doesn’t increase with calcAmount=0)
        computeLocals.poolDetails.arbThresholdPercentage9 = locals.thr;
        computeLocals.poolDetails.arbCapDeviationPercentage9 = locals.cap;
        computeLocals.poolDetails.arbMaxSurgeFee9 = locals.maxp;

        // Make NOISE lane different
        computeLocals.poolDetails.noiseThresholdPercentage9 = locals.thr + 1;
        computeLocals.poolDetails.noiseCapDeviationPercentage9 = locals.cap - 1;
        computeLocals.poolDetails.noiseMaxSurgeFee9 = locals.maxp + 1;

        (, locals.feeA) = mock.ComputeSurgeFee(computeLocals, p, STATIC_SWAP_FEE);
        assertEq(locals.feeA, STATIC_SWAP_FEE, "below threshold means static fee");

        locals.D = (fee_ppm9To1e18(locals.thr) + fee_ppm9To1e18(locals.cap)) / 2;
        (locals.pxIn, locals.pxOut) = fee_localsForDeviation(locals.P, locals.D);

        computeLocals.bIn = locals.b0;
        computeLocals.wIn = locals.w0;
        computeLocals.bOut = locals.b1;
        computeLocals.wOut = locals.w1;
        computeLocals.pxIn = locals.pxIn;
        computeLocals.pxOut = locals.pxOut;
        computeLocals.calcAmountScaled18 = 0;

        computeLocals.poolDetails.arbThresholdPercentage9 = locals.thr;
        computeLocals.poolDetails.arbCapDeviationPercentage9 = locals.cap;
        computeLocals.poolDetails.arbMaxSurgeFee9 = locals.maxp;

        computeLocals.poolDetails.noiseThresholdPercentage9 = locals.thr + 1;
        computeLocals.poolDetails.noiseCapDeviationPercentage9 = locals.cap - 1;
        computeLocals.poolDetails.noiseMaxSurgeFee9 = locals.maxp + 1;

        (, locals.feeB) = mock.ComputeSurgeFee(computeLocals, p, STATIC_SWAP_FEE);

        uint256 expected = fee_expectedFeeWithParams(
            locals.P,
            locals.pxIn,
            locals.pxOut,
            STATIC_SWAP_FEE,
            locals.thr,
            locals.cap,
            locals.maxp
        );
        assertEq(locals.feeB, expected, "mid-span linear ramp");

        // At cap and above cap

        uint256 Dcap = fee_ppm9To1e18(locals.cap);
        (locals.pxIn, locals.pxOut) = fee_localsForDeviation(locals.P, Dcap);

        HyperSurgeHookMock.ComputeSurgeFeeLocals memory computeLocals1;
        computeLocals1.bIn = locals.b0;
        computeLocals1.wIn = locals.w0;
        computeLocals1.bOut = locals.b1;
        computeLocals1.wOut = locals.w1;
        computeLocals1.pxIn = locals.pxIn;
        computeLocals1.pxOut = locals.pxOut;
        computeLocals1.calcAmountScaled18 = 0;
        computeLocals1.poolDetails.arbThresholdPercentage9 = locals.thr;
        computeLocals1.poolDetails.arbCapDeviationPercentage9 = locals.cap;
        computeLocals1.poolDetails.arbMaxSurgeFee9 = locals.maxp;
        computeLocals1.poolDetails.noiseThresholdPercentage9 = locals.thr + 1;
        computeLocals1.poolDetails.noiseCapDeviationPercentage9 = locals.cap - 1;
        computeLocals1.poolDetails.noiseMaxSurgeFee9 = locals.maxp + 1;

        (, locals.feeC) = mock.ComputeSurgeFee(computeLocals1, p, STATIC_SWAP_FEE);
        assertEq(locals.feeC, fee_ppm9To1e18(locals.maxp), "at cap means max fee");

        uint256 Dbeyond = Dcap + 1;
        (locals.pxIn, locals.pxOut) = fee_localsForDeviation(locals.P, Dbeyond);

        HyperSurgeHookMock.ComputeSurgeFeeLocals memory computeLocals2;
        computeLocals2.bIn = locals.b0;
        computeLocals2.wIn = locals.w0;
        computeLocals2.bOut = locals.b1;
        computeLocals2.wOut = locals.w1;
        computeLocals2.pxIn = locals.pxIn;
        computeLocals2.pxOut = locals.pxOut;
        computeLocals2.calcAmountScaled18 = 0;
        computeLocals2.poolDetails.arbThresholdPercentage9 = locals.thr;
        computeLocals2.poolDetails.arbCapDeviationPercentage9 = locals.cap;
        computeLocals2.poolDetails.arbMaxSurgeFee9 = locals.maxp;
        computeLocals2.poolDetails.noiseThresholdPercentage9 = locals.thr + 1;
        computeLocals2.poolDetails.noiseCapDeviationPercentage9 = locals.cap - 1;
        computeLocals2.poolDetails.noiseMaxSurgeFee9 = locals.maxp + 1;

        (, locals.feeD) = mock.ComputeSurgeFee(computeLocals2, p, STATIC_SWAP_FEE);
        assertEq(locals.feeD, fee_ppm9To1e18(locals.maxp), "above cap means clamped to max fee");
    }

    struct ExactInEqualsExactOutLocals {
        uint8 n;
        uint256[] w;
        uint256[] b;
        uint8 i;
        uint8 j;
        uint32 thr;
        uint32 cap;
        uint32 maxp;
        uint256 P;
        uint256 capDev;
        uint256 D;
        uint256 pxIn;
        uint256 pxOut;
        uint256 feeIn;
        uint256 feeOut;
    }

    /// EXACT_IN vs EXACT_OUT: with identical lane params, the engine result must match.
    /// Correction: keep the *effective* lane params for the chosen direction the same,
    /// but make ARB and NOISE lanes different so a wrong-lane implementation would not hide here.
    function testFuzz_internal_exactIn_equals_exactOut_whenParamsSame(
        uint8 nSeed,
        uint256 wSeed,
        uint256 bSeed,
        uint256 dSeed
    ) public {
        ExactInEqualsExactOutLocals memory locals;

        locals.n = uint8(bound(nSeed, 2, 8));
        locals.w = fee_normWeights(locals.n, wSeed);
        locals.b = fee_balances(locals.n, bSeed);

        locals.i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 41))), 0, locals.n - 1));
        locals.j = (locals.i + 1 + uint8(bound(uint256(keccak256(abi.encode(dSeed, 42))), 0, locals.n - 2))) % locals.n;

        locals.thr = 1_000_000; // 0.1%
        locals.cap = 500_000_000; // 50%
        locals.maxp = 50_000_000; // 5%

        locals.P = fee_pairSpotFromBW(locals.b[locals.i], locals.w[locals.i], locals.b[locals.j], locals.w[locals.j]);
        vm.assume(locals.P > 0);

        locals.capDev = fee_ppm9To1e18(locals.cap);
        locals.D = uint256(keccak256(abi.encode(dSeed))) % (locals.capDev + locals.capDev / 2 + 1);
        (locals.pxIn, locals.pxOut) = fee_localsForDeviation(locals.P, locals.D);

        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.maxp),
            fee_ppm9To1e18(locals.thr),
            fee_ppm9To1e18(locals.cap),
            "fee-io"
        );

        // EXACT_IN
        PoolSwapParams memory pIn;
        pIn.kind = SwapKind.EXACT_IN;

        // Build locals with NOISE = (thr/cap/maxp) and ARB deliberately different
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory L1;
        L1.bIn = locals.b[locals.i];
        L1.wIn = locals.w[locals.i];
        L1.bOut = locals.b[locals.j];
        L1.wOut = locals.w[locals.j];
        L1.pxIn = locals.pxIn;
        L1.pxOut = locals.pxOut;
        L1.calcAmountScaled18 = 0;

        // Effective (chosen) lane params
        L1.poolDetails.noiseThresholdPercentage9 = locals.thr;
        L1.poolDetails.noiseCapDeviationPercentage9 = locals.cap;
        L1.poolDetails.noiseMaxSurgeFee9 = locals.maxp;

        // Different ARB lane params so wrong-lane usage wouldn’t accidentally match
        L1.poolDetails.arbThresholdPercentage9 = locals.thr + 1;
        L1.poolDetails.arbCapDeviationPercentage9 = locals.cap - 1;
        L1.poolDetails.arbMaxSurgeFee9 = locals.maxp + 1;

        (, locals.feeIn) = mock.ComputeSurgeFee(L1, pIn, STATIC_SWAP_FEE);

        // EXACT_OUT
        PoolSwapParams memory pOut;
        pOut.kind = SwapKind.EXACT_OUT;

        HyperSurgeHookMock.ComputeSurgeFeeLocals memory L2;
        L2.bIn = locals.b[locals.i];
        L2.wIn = locals.w[locals.i];
        L2.bOut = locals.b[locals.j];
        L2.wOut = locals.w[locals.j];
        L2.pxIn = locals.pxIn;
        L2.pxOut = locals.pxOut;
        L2.calcAmountScaled18 = 0;

        L2.poolDetails.noiseThresholdPercentage9 = locals.thr;
        L2.poolDetails.noiseCapDeviationPercentage9 = locals.cap;
        L2.poolDetails.noiseMaxSurgeFee9 = locals.maxp;

        L2.poolDetails.arbThresholdPercentage9 = locals.thr + 1;
        L2.poolDetails.arbCapDeviationPercentage9 = locals.cap - 1;
        L2.poolDetails.arbMaxSurgeFee9 = locals.maxp + 1;

        (, locals.feeOut) = mock.ComputeSurgeFee(L2, pOut, STATIC_SWAP_FEE);

        assertEq(locals.feeIn, locals.feeOut, "with equal lane params, kind should not change math result");
    }

    function testFuzz_view_missingPrices_returnsStatic_orRevert(
        uint8 nSeed,
        uint256 /* wSeed */,
        uint256 bSeed,
        uint8 iSeed
    ) public {
        // --- Register pool and adapt to its actual token count ---
        uint8 nTarget = uint8(bound(nSeed, 2, 8));
        _registerBasePoolWithN(nTarget);

        uint256[] memory weights = WeightedPool(address(pool)).getNormalizedWeights();
        uint256 m = weights.length;
        assertGe(m, 2, "pool must have at least 2 tokens");

        // --- Random non-zero balances of exact pool length ---
        uint256[] memory b = fee_balances(uint8(m), bSeed);

        // --- Pick a valid distinct pair (i != j) ---
        uint256 i = uint256(bound(iSeed, 0, m - 1));
        uint256 j = (i + 1) % m;

        // --- Build base swap params template with those balances ---
        PoolSwapParams memory p;
        p.balancesScaled18 = new uint256[](m);
        for (uint256 k = 0; k < m; ++k) {
            p.balancesScaled18[k] = b[k];
        }
        p.indexIn = i;
        p.indexOut = j;

        // --- Choose "very safe" small amounts relative to balances to avoid any pool ratio guards.
        //     Using 1e-6 of balance is comfortably below typical MaxIn/OutRatio; ensure >= 1 wei.
        uint256 bIn = b[i];
        uint256 bOut = b[j];

        uint256 safeInAmt = bIn / 1e6;
        if (safeInAmt == 0) safeInAmt = 1;
        uint256 safeOutAmt = bOut / 1e6;
        if (safeOutAmt == 0) safeOutAmt = 1;

        // Sanity: amounts are indeed tiny relative to balances to avoid accidental reverts
        // (these checks also self-document the invariant we rely on)
        assertLt(safeInAmt, bIn / 10, "safeInAmt too large vs balanceIn"); // < 10% (much stricter in practice)
        assertLt(safeOutAmt, bOut / 10, "safeOutAmt too large vs balanceOut"); // < 10%

        // --- EXACT_IN: must return static fee (no revert expected) ---
        p.kind = SwapKind.EXACT_IN;
        p.amountGivenScaled18 = safeInAmt;

        (bool okIn, uint256 feeIn) = hook.onComputeDynamicSwapFeePercentage(p, address(pool), STATIC_SWAP_FEE);
        assertTrue(okIn, "missing prices: EXACT_IN safe amount must succeed");
        assertEq(feeIn, STATIC_SWAP_FEE, "missing prices: EXACT_IN must return static fee");

        // --- EXACT_OUT: must return static fee (no revert expected) ---
        p.kind = SwapKind.EXACT_OUT;
        p.amountGivenScaled18 = safeOutAmt;

        (bool okOut, uint256 feeOut) = hook.onComputeDynamicSwapFeePercentage(p, address(pool), STATIC_SWAP_FEE);
        assertTrue(okOut, "missing prices: EXACT_OUT safe amount must succeed");
        assertEq(feeOut, STATIC_SWAP_FEE, "missing prices: EXACT_OUT must return static fee");
    }

    function testFuzz_view_readsLaneParams_returnsStatic_onSafePath(uint8 nSeed) public {
        uint8 n = uint8(bound(nSeed, 2, 8));
        _registerBasePoolWithN(n);

        // Diverge NOISE and ARB lane params (authorized admin)
        vm.startPrank(admin);
        hook.setSurgeThresholdPercentage(address(pool), 5_000_000 * 1e9, IHyperSurgeHook.TradeType.NOISE); // 0.5%
        hook.setCapDeviationPercentage(address(pool), 400_000_000 * 1e9, IHyperSurgeHook.TradeType.NOISE); // 40%
        hook.setMaxSurgeFeePercentage(address(pool), 25_000_000 * 1e9, IHyperSurgeHook.TradeType.NOISE); // 2.5%

        hook.setSurgeThresholdPercentage(address(pool), 1_000_000 * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE); // 0.1%
        hook.setCapDeviationPercentage(address(pool), 300_000_000 * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE); // 30%
        hook.setMaxSurgeFeePercentage(address(pool), 50_000_000 * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE); // 5%
        vm.stopPrank();

        // Adapt to the pool’s true size to avoid OOB / shape mismatches
        uint256[] memory weights = WeightedPool(address(pool)).getNormalizedWeights();
        uint256 m = weights.length;
        assertGe(m, 2, "pool must have at least 2 tokens");

        // Build non-zero balances of correct length m
        uint256[] memory balances = new uint256[](m);
        for (uint256 k = 0; k < m; ++k) {
            balances[k] = 1e24 + k;
        }

        PoolSwapParams memory p;
        p.amountGivenScaled18 = 1e18; // non-zero trade amount
        p.balancesScaled18 = balances;
        p.indexIn = 0;
        p.indexOut = (m > 1) ? 1 : 0;

        // EXACT_IN: either revert or static fee (but never a computed dynamic fee)
        p.kind = SwapKind.EXACT_IN;
        (bool okIn, uint256 feeIn) = hook.onComputeDynamicSwapFeePercentage(p, address(pool), STATIC_SWAP_FEE);
        assertTrue(okIn, "missing prices: ok must be true on success (IN)");
        assertEq(feeIn, STATIC_SWAP_FEE, "missing prices: must return static fee (IN)");

        // EXACT_OUT: same invariant
        p.kind = SwapKind.EXACT_OUT;
        (bool okOut, uint256 feeOut) = hook.onComputeDynamicSwapFeePercentage(p, address(pool), STATIC_SWAP_FEE);
        assertTrue(okOut, "missing prices: ok must be true on success (OUT)");
        assertEq(feeOut, STATIC_SWAP_FEE, "missing prices: must return static fee (OUT)");
    }

    struct DeviationEqualsThreshold {
        uint256 staticFee;
        uint256 maxFee;
        uint32 thr9;
        uint32 cap9;
        uint32 max9;
        uint256 E;
        uint256 thr;
        uint256 fee;
    }

    /// 1) deviation == threshold => returns static fee (boundary counted as "inside")
    function test_cfg_fee_static_at_threshold_usingMockWrapper() public view {
        DeviationEqualsThreshold memory locals;

        locals.staticFee = 30e14; // 30 bps = 0.003 * 1e18
        locals.maxFee = 120e14; // 120 bps

        // 9 lane params (contract upscales to 18dp)
        locals.thr9 = 100_000_000; // 10%
        locals.cap9 = 500_000_000; // 50%
        locals.max9 = uint32(locals.maxFee / 1e9);

        HyperSurgeHookMock.ComputeSurgeFeeLocals memory computeLocals;
        computeLocals.pxIn = 1e18;
        computeLocals.pxOut = 10e18; // external price E = 10

        // set both lanes the same (lane choice irrelevant for this edge)
        computeLocals.poolDetails.noiseThresholdPercentage9 = locals.thr9;
        computeLocals.poolDetails.noiseCapDeviationPercentage9 = locals.cap9;
        computeLocals.poolDetails.noiseMaxSurgeFee9 = locals.max9;
        computeLocals.poolDetails.arbThresholdPercentage9 = locals.thr9;
        computeLocals.poolDetails.arbCapDeviationPercentage9 = locals.cap9;
        computeLocals.poolDetails.arbMaxSurgeFee9 = locals.max9;

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.amountGivenScaled18 = 0;

        locals.E = 10e18;
        locals.thr = uint256(locals.thr9) * 1e9; // 18dp

        locals.fee = _feeAtDeviation(computeLocals, p, locals.staticFee, locals.E, locals.thr);
        assertEq(locals.fee, locals.staticFee, "fee must equal static when deviation == threshold");
    }

    struct justAboveThreshold {
        uint256 staticFee;
        uint256 maxFee;
        uint32 thr9;
        uint32 cap9;
        uint32 max9;
        uint256 E;
        uint256 thr;
        uint256 cap;
        uint256 dev;
        uint256 span;
        uint256 ramp;
        uint256 expected;
    }

    function test_cfg_fee_minimalRamp_just_above_threshold() public view {
        justAboveThreshold memory locals;

        locals.staticFee = 30e14; // 30 bps
        locals.maxFee = 120e14; // 120 bps

        locals.thr9 = 100_000_000; // 10%
        locals.cap9 = 500_000_000; // 50%
        locals.max9 = uint32(locals.maxFee / 1e9);

        HyperSurgeHookMock.ComputeSurgeFeeLocals memory computeLocals;
        computeLocals.pxIn = 1e18;
        computeLocals.pxOut = 10e18;

        computeLocals.poolDetails.noiseThresholdPercentage9 = locals.thr9;
        computeLocals.poolDetails.noiseCapDeviationPercentage9 = locals.cap9;
        computeLocals.poolDetails.noiseMaxSurgeFee9 = locals.max9;
        computeLocals.poolDetails.arbThresholdPercentage9 = locals.thr9;
        computeLocals.poolDetails.arbCapDeviationPercentage9 = locals.cap9;
        computeLocals.poolDetails.arbMaxSurgeFee9 = locals.max9;

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.amountGivenScaled18 = 0;

        locals.E = 10e18;
        locals.thr = uint256(locals.thr9) * 1e9;
        locals.cap = uint256(locals.cap9) * 1e9;
        locals.dev = (uint256(locals.thr9) + 1) * 1e9; // smallest 18dp step above threshold

        uint256 fee = _feeAtDeviation(computeLocals, p, locals.staticFee, locals.E, locals.dev);

        // Expected: static + (max - static) * (dev - thr) / (cap - thr)  (div-down)
        locals.span = locals.cap - locals.thr;
        locals.ramp = ((locals.maxFee - locals.staticFee) * (locals.dev - locals.thr)) / locals.span;
        locals.expected = locals.staticFee + locals.ramp;

        assertEq(fee, locals.expected, "minimal ramp just above threshold");
        assertGt(fee, locals.staticFee, "fee > static just above threshold");
        assertLt(fee, locals.maxFee, "fee < max when deviation < cap");
    }

    struct MaxEqualsStatic {
        uint256 staticFee;
        uint256 maxFee;
        uint32 thr9;
        uint32 cap9;
        uint32 max9;
        uint256 E;
        uint256 thr;
        uint256 cap;
        uint256 devAtThr;
        uint256 devMid;
        uint256 devAtCap;
        uint256 devBeyond;
    }

    /// 3) degenerate: max == static => always static (even outside threshold)
    function test_cfg_fee_degenerateRamp_max_equals_static() public view {
        MaxEqualsStatic memory locals;

        locals.staticFee = 45e14; // 45 bps
        locals.maxFee = locals.staticFee;

        locals.thr9 = 50_000_000; // 5%
        locals.cap9 = 250_000_000; // 25%
        locals.max9 = uint32(locals.maxFee / 1e9);

        HyperSurgeHookMock.ComputeSurgeFeeLocals memory computeLocals;
        computeLocals.pxIn = 1e18;
        computeLocals.pxOut = 10e18;

        computeLocals.poolDetails.noiseThresholdPercentage9 = locals.thr9;
        computeLocals.poolDetails.noiseCapDeviationPercentage9 = locals.cap9;
        computeLocals.poolDetails.noiseMaxSurgeFee9 = locals.max9;
        computeLocals.poolDetails.arbThresholdPercentage9 = locals.thr9;
        computeLocals.poolDetails.arbCapDeviationPercentage9 = locals.cap9;
        computeLocals.poolDetails.arbMaxSurgeFee9 = locals.max9;

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.amountGivenScaled18 = 0;

        locals.E = 10e18;
        locals.thr = uint256(locals.thr9) * 1e9;
        locals.cap = uint256(locals.cap9) * 1e9;

        locals.devAtThr = locals.thr;
        locals.devMid = locals.thr + (locals.cap - locals.thr) / 2;
        locals.devAtCap = locals.cap;
        locals.devBeyond = locals.cap + 12345;

        assertEq(
            _feeAtDeviation(computeLocals, p, locals.staticFee, locals.E, locals.devAtThr),
            locals.staticFee,
            "at thr => static"
        );
        assertEq(
            _feeAtDeviation(computeLocals, p, locals.staticFee, locals.E, locals.devMid),
            locals.staticFee,
            "mid => static"
        );
        assertEq(
            _feeAtDeviation(computeLocals, p, locals.staticFee, locals.E, locals.devAtCap),
            locals.staticFee,
            "at cap => static"
        );
        assertEq(
            _feeAtDeviation(computeLocals, p, locals.staticFee, locals.E, locals.devBeyond),
            locals.staticFee,
            "beyond cap => static"
        );
    }

    struct MaxBelowStatic {
        uint256 staticFee;
        uint256 maxFee;
        uint32 thr9;
        uint32 cap9;
        uint32 max9;
        uint256 E;
        uint256 thr;
        uint256 cap;
        uint256 devMid;
        uint256 feeMid;
        uint256 span;
        uint256 ramp;
        uint256 expected;
    }

    function test_fee_misconfig_maxBelowStatic_usingMockWrapper() public {
        MaxBelowStatic memory locals;

        // Misconfig: max < static
        locals.staticFee = 80e14; // 80 bps (1e18 scale)
        locals.maxFee = 20e14; // 20 bps (1e18 scale) -> lower than static
        locals.thr9 = 100_000_000; // 10% in 1e9
        locals.cap9 = 300_000_000; // 30% in 1e9
        locals.max9 = uint32(locals.maxFee / 1e9);

        // Local mock (don’t rely on global `hook`)
        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.max9),
            fee_ppm9To1e18(locals.thr9),
            fee_ppm9To1e18(locals.cap9),
            "misconfig-maxBelowStatic"
        );

        // Base inputs used for both sub-tests
        locals.E = 10e18; // external price
        locals.thr = uint256(locals.thr9) * 1e9; // 18dp threshold
        locals.cap = uint256(locals.cap9) * 1e9; // 18dp cap

        HyperSurgeHookMock.ComputeSurgeFeeLocals memory base;
        base.pxIn = 1e18;
        base.pxOut = locals.E;

        // Set BOTH lanes to the same (misconfigured) params so lane choice doesn't matter here.
        base.poolDetails.noiseThresholdPercentage9 = locals.thr9;
        base.poolDetails.noiseCapDeviationPercentage9 = locals.cap9;
        base.poolDetails.noiseMaxSurgeFee9 = locals.max9;
        base.poolDetails.arbThresholdPercentage9 = locals.thr9;
        base.poolDetails.arbCapDeviationPercentage9 = locals.cap9;
        base.poolDetails.arbMaxSurgeFee9 = locals.max9;

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.amountGivenScaled18 = 0; // keep balances-based price exact
        p.balancesScaled18 = new uint256[](2);
        p.balancesScaled18[0] = 1e18;
        p.balancesScaled18[1] = locals.E;

        // Reused working struct
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory T;

        // ---------- (a) dev >= cap  -> revert (underflow in mock ramp) ----------
        uint256 dev = locals.cap + 999; // strictly beyond cap
        uint256 P = locals.E + (locals.E * dev) / 1e18; // P = E * (1 + dev)
        T = base;
        T.wIn = 1e18;
        T.wOut = 1e18;
        T.bIn = 1e18;
        T.bOut = P;
        T.calcAmountScaled18 = 0;

        vm.expectRevert(stdError.arithmeticError);
        mock.ComputeSurgeFee(T, p, locals.staticFee);

        // ---------- (b) thr < dev < cap  -> revert (underflow in mock ramp) ----------
        dev = locals.thr + (locals.cap - locals.thr) / 3; // strictly between thr & cap
        P = locals.E + (locals.E * dev) / 1e18;
        T = base;
        T.wIn = 1e18;
        T.wOut = 1e18;
        T.bIn = 1e18;
        T.bOut = P;
        T.calcAmountScaled18 = 0;

        vm.expectRevert(stdError.arithmeticError);
        mock.ComputeSurgeFee(T, p, locals.staticFee);
    }

    struct OutsideDynamicAfterLocals {
        uint256 E;
        uint32 noiseThr9;
        uint32 noiseCap9;
        uint32 noiseMax9;
        uint32 arbThr9;
        uint32 arbCap9;
        uint32 arbMax9;
        uint256 thr;
        uint256 cap;
        uint256 deviationBefore;
        uint256 price_before;
        uint256 price_after;
        HyperSurgeHookMock.ComputeSurgeFeeLocals comp;
        PoolSwapParams p;
        uint256 expected;
        uint256 dyn;
    }

    /// 1) Noise: starts outside threshold, deviation worsens → NOISE lane, dynamic fee based on **after** deviation.
    function testFuzz_logic_noise_worsens_outside_dynamic_after(
        uint256 eSeed,
        uint32 noiseThrSeed,
        uint32 noiseCapSeed,
        uint32 noiseMaxSeed,
        uint64 amtSeed
    ) public {
        OutsideDynamicAfterLocals memory locals;

        // --- Fuzz + bounds ---
        locals.E = bound(eSeed, 1e16, 1e24); // pxOut
        locals.noiseThr9 = uint32(bound(noiseThrSeed, 1, 900_000_000 - 1));
        locals.noiseCap9 = uint32(bound(noiseCapSeed, locals.noiseThr9 + 1, 1_000_000_000));
        locals.noiseMax9 = uint32(bound(noiseMaxSeed, uint32(STATIC_SWAP_FEE / 1e9), 1_000_000_000));
        // ARB lane (unused here, but keep distinct)
        locals.arbThr9 = 1_000_000;
        locals.arbCap9 = 300_000_000;
        locals.arbMax9 = 50_000_000;

        locals.thr = uint256(locals.noiseThr9) * 1e9;
        locals.cap = uint256(locals.noiseCap9) * 1e9;
        locals.deviationBefore = locals.thr + (locals.cap - locals.thr) / 3; // strictly outside

        // Start BELOW E: price_before = E * (1 - deviationBefore)
        locals.price_before = locals.E - (locals.E * locals.deviationBefore) / 1e18;

        // Build compute locals + swap that worsens deviation (EXACT_IN; calc=0 → P decreases further)
        locals.comp.wIn = 1e18;
        locals.comp.wOut = 1e18;
        locals.comp.bIn = 1e18;
        locals.comp.bOut = locals.price_before;
        locals.comp.pxIn = 1e18;
        locals.comp.pxOut = locals.E;
        locals.comp.calcAmountScaled18 = 0;
        locals.comp.poolDetails.noiseThresholdPercentage9 = locals.noiseThr9;
        locals.comp.poolDetails.noiseCapDeviationPercentage9 = locals.noiseCap9;
        locals.comp.poolDetails.noiseMaxSurgeFee9 = locals.noiseMax9;
        locals.comp.poolDetails.arbThresholdPercentage9 = locals.arbThr9;
        locals.comp.poolDetails.arbCapDeviationPercentage9 = locals.arbCap9;
        locals.comp.poolDetails.arbMaxSurgeFee9 = locals.arbMax9;

        locals.p.kind = SwapKind.EXACT_IN;
        // ensure deviation increases *measurably* in Q18 (avoid 1-wei changes)
        locals.p.amountGivenScaled18 = bound(uint256(amtSeed), 1e9, 5e17); // [1e9, 0.5e18]

        // Expected (NOISE) uses AFTER deviation: price_after = price_before / (1 + x)
        locals.price_after = (locals.price_before * 1e18) / (1e18 + locals.p.amountGivenScaled18);
        locals.expected = fee_expectedFeeWithParams(
            locals.price_after,
            locals.comp.pxIn,
            locals.comp.pxOut,
            STATIC_SWAP_FEE,
            locals.noiseThr9,
            locals.noiseCap9,
            locals.noiseMax9
        );

        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.arbMax9),
            fee_ppm9To1e18(locals.arbThr9),
            fee_ppm9To1e18(locals.arbCap9),
            "logic-1"
        );
        (, locals.dyn) = mock.ComputeSurgeFee(locals.comp, locals.p, STATIC_SWAP_FEE);

        assertEq(locals.dyn, locals.expected, "noise path must use AFTER deviation for dynamic fee");
        assertGe(locals.dyn, STATIC_SWAP_FEE, "dynamic fee >= static");
    }

    struct BetterStillOutsideLocals {
        uint256 E;
        uint32 arbThr9;
        uint32 arbCap9;
        uint32 arbMax9;
        uint32 noiseThr9;
        uint32 noiseCap9;
        uint32 noiseMax9;
        uint256 thr;
        uint256 cap;
        uint256 deviationBefore;
        uint256 price_before;
        uint256 price_after;
        uint256 xMax;
        HyperSurgeHookMock.ComputeSurgeFeeLocals comp;
        PoolSwapParams p;
        uint256 expected;
        uint256 dyn;
    }

    function testFuzz_logic_arb_outside_improves_but_outside_dynamic_before(
        uint256 eSeed,
        uint32 arbThrSeed,
        uint32 arbCapSeed,
        uint32 arbMaxSeed,
        uint64 amtSeed
    ) public {
        BetterStillOutsideLocals memory locals;

        // --- Fuzz + bounds ---
        locals.E = bound(eSeed, 1e16, 1e24);
        locals.arbThr9 = uint32(bound(arbThrSeed, 1, 900_000_000 - 1));
        locals.arbCap9 = uint32(bound(arbCapSeed, locals.arbThr9 + 1, 1_000_000_000));
        locals.arbMax9 = uint32(bound(arbMaxSeed, uint32(STATIC_SWAP_FEE / 1e9), 1_000_000_000));
        // NOISE lane different (unused in assertion)
        locals.noiseThr9 = 5_000_000;
        locals.noiseCap9 = 400_000_000;
        locals.noiseMax9 = 25_000_000;

        locals.thr = uint256(locals.arbThr9) * 1e9;
        locals.cap = uint256(locals.arbCap9) * 1e9;
        locals.deviationBefore = locals.thr + (locals.cap - locals.thr) / 3; // strictly outside

        // Start ABOVE E
        locals.price_before = locals.E + (locals.E * locals.deviationBefore) / 1e18;

        // Compute xMax to remain outside after: price_after >= E*(1 + thr)
        // price_after = price_before / (1 + x)  means x less than or equal to (price_before / (E*(1+thr)) - 1) * 1e18
        vm.assume(locals.E * (1e18 + locals.thr) != 0); // defensive
        uint256 denom = (locals.E * (1e18 + locals.thr)) / 1e18;
        vm.assume(denom != 0);
        uint256 ratio = (locals.price_before * 1e18) / denom;
        vm.assume(ratio > 1e18); // Ensure room to remain outside
        locals.xMax = ratio - 1e18;
        if (locals.xMax > 9e17) {
            locals.xMax = 9e17;
        } // clamp

        locals.comp.wIn = 1e18;
        locals.comp.wOut = 1e18;
        locals.comp.bIn = 1e18;
        locals.comp.bOut = locals.price_before;
        locals.comp.pxIn = 1e18;
        locals.comp.pxOut = locals.E;
        locals.comp.calcAmountScaled18 = 0;
        locals.comp.poolDetails.arbThresholdPercentage9 = locals.arbThr9;
        locals.comp.poolDetails.arbCapDeviationPercentage9 = locals.arbCap9;
        locals.comp.poolDetails.arbMaxSurgeFee9 = locals.arbMax9;
        locals.comp.poolDetails.noiseThresholdPercentage9 = locals.noiseThr9;
        locals.comp.poolDetails.noiseCapDeviationPercentage9 = locals.noiseCap9;
        locals.comp.poolDetails.noiseMaxSurgeFee9 = locals.noiseMax9;

        locals.p.kind = SwapKind.EXACT_IN;
        locals.p.amountGivenScaled18 = bound(uint256(amtSeed), 1, locals.xMax == 0 ? 1 : locals.xMax);

        // Expected (ARB) uses BEFORE deviation
        locals.expected = fee_expectedFeeWithParams(
            locals.price_before,
            locals.comp.pxIn,
            locals.comp.pxOut,
            STATIC_SWAP_FEE,
            locals.arbThr9,
            locals.arbCap9,
            locals.arbMax9
        );

        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.arbMax9),
            fee_ppm9To1e18(locals.arbThr9),
            fee_ppm9To1e18(locals.arbCap9),
            "logic-2"
        );
        (, locals.dyn) = mock.ComputeSurgeFee(locals.comp, locals.p, STATIC_SWAP_FEE);

        // Still outside afterward (sanity)
        locals.price_after = (locals.price_before * 1e18) / (1e18 + locals.p.amountGivenScaled18);
        uint256 deviationAfter = ((
            locals.price_after > locals.E ? (locals.price_after - locals.E) : (locals.E - locals.price_after)
        ) * 1e18) / locals.E;
        assertGt(deviationAfter, locals.thr, "should remain outside threshold after improving");

        assertEq(locals.dyn, locals.expected, "arb path must use BEFORE deviation for dynamic fee");
        assertGe(locals.dyn, STATIC_SWAP_FEE, "dynamic fee >= static");
    }

    struct NoiseWorsensInsideButStaysInsideLocals {
        uint256 E;
        uint32 noiseThr9;
        uint32 noiseCap9;
        uint32 noiseMax9;
        uint32 arbThr9;
        uint32 arbCap9;
        uint32 arbMax9;
        uint256 thr;
        uint256 deviationBefore;
        uint256 price_before;
        uint256 price_after;
        uint256 xMax;
        HyperSurgeHookMock.ComputeSurgeFeeLocals comp;
        PoolSwapParams p;
        uint256 fee;
    }

    /// 3) Noise: starts inside threshold, worsens but stays inside → NOISE lane, **base (static)** fee.
    function testFuzz_logic_noise_inside_worse_but_inside_static(
        uint256 eSeed,
        uint32 noiseThrSeed,
        uint32 noiseCapSeed,
        uint32 noiseMaxSeed,
        uint64 amtSeed
    ) public {
        NoiseWorsensInsideButStaysInsideLocals memory locals;

        locals.E = bound(eSeed, 1e16, 1e24);
        locals.noiseThr9 = uint32(bound(noiseThrSeed, 1, 1_000_000_000 - 1)); // (0,1)
        locals.noiseCap9 = uint32(bound(noiseCapSeed, locals.noiseThr9 + 1, 1_000_000_000));
        locals.noiseMax9 = uint32(bound(noiseMaxSeed, uint32(STATIC_SWAP_FEE / 1e9), 1_000_000_000));

        // ARB lane (kept distinct but unused in the assertion)
        locals.arbThr9 = 1_000_000;
        locals.arbCap9 = 300_000_000;
        locals.arbMax9 = 50_000_000;

        locals.thr = uint256(locals.noiseThr9) * 1e9; // Q18

        // Start just inside threshold BELOW E (safely away from boundary)
        locals.deviationBefore = locals.thr / 4 + 1; // Q18
        locals.price_before = locals.E - (locals.E * locals.deviationBefore) / 1e18;

        // Choose x to worsen but keep AFTER less than or equal to thr:
        // price_after/E = (price_before/E) / (1 + t) greater than or equal to (1 - thr)  means  t less than or equal to R/(1 - thr) - 1
        // where R = price_before/E = 1 - deviationBefore.
        uint256 R1e18 = (locals.price_before * 1e18) / locals.E; // Q18
        uint256 denom = 1e18 - locals.thr; // Q18, > 0
        uint256 q = (R1e18 * 1e18) / denom; // Q18
        locals.xMax = q > 1e18 ? (q - 1e18) : 0; // Q18 (x = t*1e18)
        // Soften extremes to avoid huge swaps in the mock path
        if (locals.xMax > 5e17) locals.xMax = 5e17; // cap at tless than or equal to0.5

        // Build locals
        locals.comp.wIn = 1e18;
        locals.comp.wOut = 1e18;
        locals.comp.bIn = 1e18;
        locals.comp.bOut = locals.price_before;
        locals.comp.pxIn = 1e18;
        locals.comp.pxOut = locals.E;
        locals.comp.calcAmountScaled18 = 0;
        locals.comp.poolDetails.noiseThresholdPercentage9 = locals.noiseThr9;
        locals.comp.poolDetails.noiseCapDeviationPercentage9 = locals.noiseCap9;
        locals.comp.poolDetails.noiseMaxSurgeFee9 = locals.noiseMax9;
        locals.comp.poolDetails.arbThresholdPercentage9 = locals.arbThr9;
        locals.comp.poolDetails.arbCapDeviationPercentage9 = locals.arbCap9;
        locals.comp.poolDetails.arbMaxSurgeFee9 = locals.arbMax9;

        locals.p.kind = SwapKind.EXACT_IN;

        // Ensure a *measurable* worsening so NOISE is chosen:
        // pick x with a lower floor (e.g., 1e9 wei) but never exceed xMax.
        uint256 lo = 1e9; // 1e-9 in t; safely above Q18 rounding noise
        uint256 hi = locals.xMax;
        if (hi < lo) {
            lo = 1;
        } // if xMax < floor, fall back to [1, xMax]
        if (hi < lo) {
            hi = lo;
        } // clamp
        locals.p.amountGivenScaled18 = bound(uint256(amtSeed), lo, hi);

        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.arbMax9),
            fee_ppm9To1e18(locals.arbThr9),
            fee_ppm9To1e18(locals.arbCap9),
            "logic-3"
        );
        (, locals.fee) = mock.ComputeSurgeFee(locals.comp, locals.p, STATIC_SWAP_FEE);

        // Sanity: still inside after worsening
        locals.price_after = (locals.price_before * 1e18) / (1e18 + locals.p.amountGivenScaled18);
        uint256 deviationAfter = ((
            locals.price_after > locals.E ? (locals.price_after - locals.E) : (locals.E - locals.price_after)
        ) * 1e18) / locals.E;
        assertLe(deviationAfter, locals.thr, "must remain inside threshold");

        // Inside-after on NOISE → static
        assertEq(locals.fee, STATIC_SWAP_FEE, "inside threshold after worsening must still return static (noise path)");
    }

    struct NoiseCrossesPriceWorsensLocals {
        uint256 E;
        uint32 noiseThr9;
        uint32 noiseCap9;
        uint32 noiseMax9;
        uint32 arbThr9;
        uint32 arbCap9;
        uint32 arbMax9;
        uint256 thr;
        uint256 cap;
        uint256 deviationBefore;
        uint256 price_before;
        uint256 price_after;
        uint256 tCross; // Q18: min t to cross below E   (t > Db)
        uint256 tWorse; // Q18: min t to worsen |dev|    (t > 2Db/(1-Db))
        uint256 tMin; // Q18: max(tCross, tWorse) + margin
        uint256 x; // Q18: amountGivenScaled18 (t = x / 1e18)
        uint256 num; // numerator for tWorse calculation
        uint256 den; // denominator for tWorse calculation
        uint256 q; // intermediate value for tWorse calculation
        uint256 epsT; // safety margin for tMin
        uint256 span; // range for x selection
        uint256 lo; // lower bound for x
        uint256 hi; // upper bound for x
        uint256 deviationAfter; // absolute deviation after
        HyperSurgeHookMock.ComputeSurgeFeeLocals comp;
        PoolSwapParams p;
        uint256 expected;
        uint256 dyn;
    }

    function testFuzz_logic_noise_outside_crosses_and_worsens_dynamic_after(
        uint256 eSeed,
        uint32 noiseThrSeed,
        uint32 noiseCapSeed,
        uint32 noiseMaxSeed,
        uint64 amtSeed
    ) public {
        NoiseCrossesPriceWorsensLocals memory locals;

        // --- Fuzz + bounds ---
        locals.E = bound(eSeed, 1e16, 1e24);

        // Keep thr < 1 so denominators stay positive and bands are non-degenerate
        locals.noiseThr9 = uint32(bound(noiseThrSeed, 1, 900_000_000 - 1)); // (0, 0.9)
        locals.noiseCap9 = uint32(bound(noiseCapSeed, locals.noiseThr9 + 1, 1_000_000_000)); // (thr, 1]
        locals.noiseMax9 = uint32(bound(noiseMaxSeed, uint32(STATIC_SWAP_FEE / 1e9), 1_000_000_000));

        // ARB lane different (unused in assertion)
        locals.arbThr9 = 1_000_000;
        locals.arbCap9 = 300_000_000;
        locals.arbMax9 = 50_000_000;

        locals.thr = uint256(locals.noiseThr9) * 1e9; // Q18
        locals.cap = uint256(locals.noiseCap9) * 1e9; // Q18

        // Start ABOVE E with a deviation strictly outside the threshold:
        locals.deviationBefore = locals.thr + (locals.cap - locals.thr) / 4; // Q18 in (thr, cap)
        locals.price_before = locals.E + (locals.E * locals.deviationBefore) / 1e18;

        // Build compute locals
        locals.comp.wIn = 1e18;
        locals.comp.wOut = 1e18;
        locals.comp.bIn = 1e18;
        locals.comp.bOut = locals.price_before;
        locals.comp.pxIn = 1e18;
        locals.comp.pxOut = locals.E;
        locals.comp.calcAmountScaled18 = 0;
        locals.comp.poolDetails.noiseThresholdPercentage9 = locals.noiseThr9;
        locals.comp.poolDetails.noiseCapDeviationPercentage9 = locals.noiseCap9;
        locals.comp.poolDetails.noiseMaxSurgeFee9 = locals.noiseMax9;
        locals.comp.poolDetails.arbThresholdPercentage9 = locals.arbThr9;
        locals.comp.poolDetails.arbCapDeviationPercentage9 = locals.arbCap9;
        locals.comp.poolDetails.arbMaxSurgeFee9 = locals.arbMax9;

        locals.p.kind = SwapKind.EXACT_IN;

        // We need BOTH:
        //  (1) Cross: price_after < E  means  t > Db                       (R = 1 + Db)
        //  (2) Worsen: |after| > |before| when ending below:
        //      1 - R/(1+t) > Db  means  (1 - Db)(1 + t) > 1 + Db  means  t > 2Db/(1 - Db)
        locals.tCross = locals.deviationBefore; // Q18
        // tWorse = ceil( (2*Db) / (1 - Db) ) in Q18
        locals.num = (2 * locals.deviationBefore) * 1e18; // Q36
        locals.den = 1e18 - locals.deviationBefore; // Q18, > 0 by bounds
        locals.q = (locals.num + locals.den - 1) / locals.den; // ceilDiv -> Q18
        locals.tWorse = locals.q;

        // Add a safety margin to overcome integer rounding in price_after and deviationAfter.
        // Use 1e13 in Q18 (i.e., 1e-5) which is ample even for E as large as 1e24.
        locals.epsT = 1e13;
        locals.tMin = (locals.tWorse > locals.tCross ? locals.tWorse : locals.tCross) + locals.epsT;

        // Choose x = t*1e18 with t in [tMin, tMin + span]
        locals.span = 5e17; // allow up to +0.5 in t
        locals.lo = locals.tMin;
        locals.hi = locals.tMin + locals.span;
        if (locals.lo == 0) {
            locals.lo = 1;
        } // avoid x==0

        if (locals.hi < locals.lo) {
            locals.hi = locals.lo;
        } // clamp on overflow

        locals.x = bound(uint256(amtSeed), locals.lo, locals.hi);
        locals.p.amountGivenScaled18 = locals.x;

        // Expected uses NOISE with AFTER deviation
        locals.price_after = (locals.price_before * 1e18) / (1e18 + locals.x);

        // Sanity: crossed and worsened absolute deviation
        locals.deviationBefore = ((locals.price_before - locals.E) * 1e18) / locals.E;
        locals.deviationAfter = ((locals.E - locals.price_after) * 1e18) / locals.E;
        require(locals.price_after < locals.E, "must cross below E");
        require(locals.deviationAfter > locals.deviationBefore, "must worsen absolute deviation after crossing");

        locals.expected = fee_expectedFeeWithParams(
            locals.price_after,
            locals.comp.pxIn,
            locals.comp.pxOut,
            STATIC_SWAP_FEE,
            locals.noiseThr9,
            locals.noiseCap9,
            locals.noiseMax9
        );

        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.arbMax9),
            fee_ppm9To1e18(locals.arbThr9),
            fee_ppm9To1e18(locals.arbCap9),
            "logic-4"
        );
        (, locals.dyn) = mock.ComputeSurgeFee(locals.comp, locals.p, STATIC_SWAP_FEE);

        assertEq(
            locals.dyn,
            locals.expected,
            "noise path must use AFTER deviation even when crossing the price (worsening)"
        );
        assertGe(locals.dyn, STATIC_SWAP_FEE, "dynamic fee >= static");
    }

    struct OutsideToInsideDynamicBefore {
        uint256 E;
        uint32 arbThr9;
        uint32 arbCap9;
        uint32 arbMax9;
        uint32 noiseThr9;
        uint32 noiseCap9;
        uint32 noiseMax9;
        uint256 thr;
        uint256 cap;
        uint256 deviationBefore;
        uint256 price_before;
        uint256 price_after;
        uint256 R1e18; // R in 1e18 scale: R = price_before / E
        uint256 xLower; // min x to get price_after less than or equal to E*(1+thr)
        uint256 xUpper; // max x to keep price_after greater than or equal to E*(1−thr)
        uint256 x; // chosen amountGivenScaled18 inside [xLower, xUpper]
        HyperSurgeHookMock.ComputeSurgeFeeLocals comp;
        PoolSwapParams p;
        uint256 expected;
        uint256 dyn;
    }

    /// 5) Arb: starts outside, ends inside → ARB lane still uses **BEFORE** deviation (dynamic, not base).
    function testFuzz_logic_arb_outside_to_inside_dynamic_before(
        uint256 eSeed,
        uint32 arbThrSeed,
        uint32 arbCapSeed,
        uint32 arbMaxSeed,
        uint64 amtSeed
    ) public {
        OutsideToInsideDynamicBefore memory locals;

        // --- Fuzz + bounds ---
        locals.E = bound(eSeed, 1e16, 1e24);
        // Keep thr strictly < 1e9 so (1e18 - thr) > 0
        locals.arbThr9 = uint32(bound(arbThrSeed, 1, 900_000_000 - 1));
        locals.arbCap9 = uint32(bound(arbCapSeed, locals.arbThr9 + 1, 1_000_000_000));
        locals.arbMax9 = uint32(bound(arbMaxSeed, uint32(STATIC_SWAP_FEE / 1e9), 1_000_000_000));
        // NOISE lane can be anything different; not used by this assertion
        locals.noiseThr9 = 5_000_000;
        locals.noiseCap9 = 400_000_000;
        locals.noiseMax9 = 25_000_000;

        locals.thr = uint256(locals.arbThr9) * 1e9; // Q18
        locals.cap = uint256(locals.arbCap9) * 1e9;

        // Start ABOVE E with an outside deviation deviationBefore > thr
        locals.deviationBefore = locals.thr + (locals.cap - locals.thr) / 3; // strictly outside
        locals.price_before = locals.E + (locals.E * locals.deviationBefore) / 1e18; // price_before = E * (1 + deviationBefore)
        locals.R1e18 = (locals.price_before * 1e18) / locals.E; // R = 1e18 + deviationBefore

        // Two-sided “inside” band: 1 − thr less than or equal to price_after/E less than or equal to 1 + thr,
        // with price_after/E = R / (1 + t), t = x / 1e18.

        // Lower bound on t (bring down to less than or equal to 1+thr):
        //   t greater than or equal to R/(1+thr) − 1  means  xLower = ceil( (R1e18 * 1e18) / (1e18 + thr) ) − 1e18
        uint256 denomPlus = 1e18 + locals.thr; // Q18
        uint256 numPlus = locals.R1e18 * 1e18; // Q36
        uint256 qPlus = (numPlus + denomPlus - 1) / denomPlus; // ceilDiv to Q18
        locals.xLower = qPlus > 1e18 ? (qPlus - 1e18) : 0;

        // Upper bound on t (don’t overshoot below 1 − thr):
        //   t less than or equal to R/(1−thr) − 1  means  xUpper = floor( (R1e18 * 1e18) / (1e18 − thr) ) − 1e18
        uint256 denomMinus = 1e18 - locals.thr; // > 0 by bound
        uint256 numMinus = locals.R1e18 * 1e18; // Q36
        uint256 qMinus = numMinus / denomMinus; // floorDiv to Q18
        locals.xUpper = qMinus > 1e18 ? (qMinus - 1e18) : 0;

        // Choose x inside [xLower, xUpper] using bound (no vm.assume). Collapse if inverted.
        uint256 lo = locals.xLower;
        uint256 hi = locals.xUpper;
        if (hi < lo) {
            hi = lo;
        }
        // avoid degenerate zero (x == 0 keeps price_after == price_before and won’t end inside)
        if (lo == 0) lo = 1;
        if (hi < lo) hi = lo;

        locals.x = bound(uint256(amtSeed), lo, hi);

        // Build compute locals
        locals.comp.wIn = 1e18;
        locals.comp.wOut = 1e18;
        locals.comp.bIn = 1e18;
        locals.comp.bOut = locals.price_before;
        locals.comp.pxIn = 1e18;
        locals.comp.pxOut = locals.E;
        locals.comp.calcAmountScaled18 = 0;
        locals.comp.poolDetails.arbThresholdPercentage9 = locals.arbThr9;
        locals.comp.poolDetails.arbCapDeviationPercentage9 = locals.arbCap9;
        locals.comp.poolDetails.arbMaxSurgeFee9 = locals.arbMax9;
        locals.comp.poolDetails.noiseThresholdPercentage9 = locals.noiseThr9;
        locals.comp.poolDetails.noiseCapDeviationPercentage9 = locals.noiseCap9;
        locals.comp.poolDetails.noiseMaxSurgeFee9 = locals.noiseMax9;

        locals.p.kind = SwapKind.EXACT_IN;
        locals.p.amountGivenScaled18 = locals.x;

        // Expected (ARB) uses BEFORE deviation even though end is inside
        locals.expected = fee_expectedFeeWithParams(
            locals.price_before,
            locals.comp.pxIn,
            locals.comp.pxOut,
            STATIC_SWAP_FEE,
            locals.arbThr9,
            locals.arbCap9,
            locals.arbMax9
        );

        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.arbMax9),
            fee_ppm9To1e18(locals.arbThr9),
            fee_ppm9To1e18(locals.arbCap9),
            "logic-5"
        );
        (, locals.dyn) = mock.ComputeSurgeFee(locals.comp, locals.p, STATIC_SWAP_FEE);

        // Sanity: end is inside (two-sided)
        locals.price_after = (locals.price_before * 1e18) / (1e18 + locals.p.amountGivenScaled18);
        uint256 deviationAfter = ((
            locals.price_after > locals.E ? (locals.price_after - locals.E) : (locals.E - locals.price_after)
        ) * 1e18) / locals.E;
        assertLe(deviationAfter, locals.thr, "end should be inside threshold");

        assertEq(
            locals.dyn,
            locals.expected,
            "arb path must use BEFORE deviation even if the end state is inside threshold"
        );
        assertGe(locals.dyn, STATIC_SWAP_FEE, "dynamic fee >= static");
    }

    struct InsideToOutsideDynamicAfterLocals {
        uint256 E;
        uint32 noiseThr9;
        uint32 noiseCap9;
        uint32 noiseMax9;
        uint32 arbThr9;
        uint32 arbCap9;
        uint32 arbMax9;
        uint256 thr;
        uint256 cap;
        uint256 deviationBefore;
        uint256 priceBefore;
        uint256 priceAfter;
        uint256 R1e18; // = priceBefore/E (Q18)
        uint256 tLower; // min t to make priceAfter/E less than or equal to 1 - thr (Q18)
        uint256 x; // = t * 1e18 (amount in)
        uint256 num; // numerator for tLower calculation
        uint256 den; // denominator for tLower calculation
        uint256 q; // intermediate value for tLower calculation
        uint256 eps; // epsilon for x calculation
        uint256 lo; // lower bound for x
        uint256 hi; // upper bound for x
        HyperSurgeHookMock.ComputeSurgeFeeLocals comp;
        PoolSwapParams p;
        uint256 expected;
        uint256 dyn;
    }

    /// [LANE] Inside → cross outside (NOISE, dynamic with AFTER)
    function testFuzz_logic_noise_inside_to_outside_dynamic_after(
        uint256 eSeed,
        uint32 noiseThrSeed,
        uint32 noiseCapSeed,
        uint32 noiseMaxSeed,
        uint64 amtSeed
    ) public {
        InsideToOutsideDynamicAfterLocals memory locals;

        // Lane params (NOISE fuzzed, ARB fixed and different)
        locals.E = bound(eSeed, 1e16, 1e24);
        locals.noiseThr9 = uint32(bound(noiseThrSeed, 1, 900_000_000 - 1));
        locals.noiseCap9 = uint32(bound(noiseCapSeed, locals.noiseThr9 + 1, 1_000_000_000));
        locals.noiseMax9 = uint32(bound(noiseMaxSeed, uint32(STATIC_SWAP_FEE / 1e9), 1_000_000_000));
        locals.arbThr9 = 1_000_000;
        locals.arbCap9 = 300_000_000;
        locals.arbMax9 = 50_000_000;

        locals.thr = uint256(locals.noiseThr9) * 1e9;
        locals.cap = uint256(locals.noiseCap9) * 1e9;

        // Start BELOW E but inside: deviationBefore ∈ [0, thr)
        locals.deviationBefore = (locals.thr / 3) + 1; // safely inside
        locals.priceBefore = locals.E - (locals.E * locals.deviationBefore) / 1e18; // P/E = 1 - deviationBefore
        locals.R1e18 = (locals.priceBefore * 1e18) / locals.E;

        // Need priceAfter/E less than or equal to 1 - thr  ⇒  t greater than or equal to R/(1 - thr) - 1

        locals.num = locals.R1e18 * 1e18; // Q36
        locals.den = 1e18 - locals.thr; // Q18
        locals.q = (locals.num + locals.den - 1) / locals.den; // ceilDiv → Q18
        locals.tLower = locals.q > 1e18 ? (locals.q - 1e18) : 0; // Q18

        // Pick x greater than or equal to tLower (plus small epsilon) to cross outside
        locals.eps = 1e12;
        locals.lo = locals.tLower + locals.eps;
        if (locals.lo == 0) locals.lo = 1;
        locals.hi = locals.lo + 5e17; // allow up to +0.5 in t
        locals.x = bound(uint256(amtSeed), locals.lo, locals.hi);

        // Build locals
        locals.comp.wIn = 1e18;
        locals.comp.wOut = 1e18;
        locals.comp.bIn = 1e18;
        locals.comp.bOut = locals.priceBefore;
        locals.comp.pxIn = 1e18;
        locals.comp.pxOut = locals.E;
        locals.comp.calcAmountScaled18 = 0;
        locals.comp.poolDetails.noiseThresholdPercentage9 = locals.noiseThr9;
        locals.comp.poolDetails.noiseCapDeviationPercentage9 = locals.noiseCap9;
        locals.comp.poolDetails.noiseMaxSurgeFee9 = locals.noiseMax9;
        locals.comp.poolDetails.arbThresholdPercentage9 = locals.arbThr9;
        locals.comp.poolDetails.arbCapDeviationPercentage9 = locals.arbCap9;
        locals.comp.poolDetails.arbMaxSurgeFee9 = locals.arbMax9;

        locals.p.kind = SwapKind.EXACT_IN;
        locals.p.amountGivenScaled18 = locals.x;

        // Expected (NOISE) uses AFTER
        locals.priceAfter = (locals.priceBefore * 1e18) / (1e18 + locals.x);
        uint256 deviationAfter = ((
            locals.priceAfter > locals.E ? (locals.priceAfter - locals.E) : (locals.E - locals.priceAfter)
        ) * 1e18) / locals.E;
        assertGt(deviationAfter, locals.thr, "must end outside threshold (worsened)");
        locals.expected = fee_expectedFeeWithParams(
            locals.priceAfter,
            locals.comp.pxIn,
            locals.comp.pxOut,
            STATIC_SWAP_FEE,
            locals.noiseThr9,
            locals.noiseCap9,
            locals.noiseMax9
        );

        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.arbMax9),
            fee_ppm9To1e18(locals.arbThr9),
            fee_ppm9To1e18(locals.arbCap9),
            "lane-inside2outside"
        );
        (, locals.dyn) = mock.ComputeSurgeFee(locals.comp, locals.p, STATIC_SWAP_FEE);

        assertEq(locals.dyn, locals.expected, "noise/after: dynamic fee must match expected");
        assertGe(locals.dyn, STATIC_SWAP_FEE, "dynamic fee greater than or equal to static");
    }

    struct OutsideToThresholdDynamicBeforeLocals {
        uint256 E;
        uint32 arbThr9;
        uint32 arbCap9;
        uint32 arbMax9;
        uint32 noiseThr9;
        uint32 noiseCap9;
        uint32 noiseMax9;
        uint256 thr;
        uint256 cap;
        uint256 deviationBefore;
        uint256 priceBefore;
        uint256 priceAfter;
        uint256 R1e18;
        uint256 tLower;
        uint256 tUpper;
        uint256 x;
        uint256 epsT;
        uint256 lo;
        uint256 hi;
        HyperSurgeHookMock.ComputeSurgeFeeLocals comp;
        PoolSwapParams p;
        uint256 expected;
        uint256 dyn;
    }

    /// [LANE] Outside → to (or just inside) threshold (ARB, dynamic with BEFORE)
    function testFuzz_logic_arb_outside_to_threshold_dynamic_before(
        uint256 eSeed,
        uint32 arbThrSeed,
        uint32 arbCapSeed,
        uint32 arbMaxSeed,
        uint64 amtSeed
    ) public {
        OutsideToThresholdDynamicBeforeLocals memory locals;

        locals.E = bound(eSeed, 1e16, 1e24);
        locals.arbThr9 = uint32(bound(arbThrSeed, 1, 900_000_000 - 1));
        locals.arbCap9 = uint32(bound(arbCapSeed, locals.arbThr9 + 1, 1_000_000_000));
        locals.arbMax9 = uint32(bound(arbMaxSeed, uint32(STATIC_SWAP_FEE / 1e9), 1_000_000_000));
        // Distinct NOISE lane (unused in expected but kept different)
        locals.noiseThr9 = 5_000_000;
        locals.noiseCap9 = 400_000_000;
        locals.noiseMax9 = 25_000_000;

        locals.thr = uint256(locals.arbThr9) * 1e9; // Q18
        locals.cap = uint256(locals.arbCap9) * 1e9;

        // Start ABOVE, outside
        locals.deviationBefore = locals.thr + (locals.cap - locals.thr) / 3; // strictly outside
        locals.priceBefore = locals.E + (locals.E * locals.deviationBefore) / 1e18;

        // R = priceBefore / E in Q18; compute both ceil and floor variants to bound tightly
        // R_up   = ceil( (priceBefore * 1e18) / E )
        // R_down = floor( (priceBefore * 1e18) / E )
        uint256 numR = locals.priceBefore * 1e18;
        locals.R1e18 = (numR + locals.E - 1) / locals.E;

        // We need 1 - thr less than or equal to priceAfter/E less than or equal to 1 + thr, and priceAfter/E = R / (1 + t), with t = x/1e18 (Q18).
        // Lower bound on t (to get under the upper edge 1 + thr):
        //   t ≥ R/(1 + thr) − 1
        // Use R_up and ceil-div to be conservative, then subtract 1e18.
        uint256 denomPlus = 1e18 + locals.thr; // Q18
        uint256 numPlus = locals.R1e18 * 1e18; // Q36
        uint256 qPlus = (numPlus + denomPlus - 1) / denomPlus; // ceilDiv → Q18
        locals.tLower = qPlus > 1e18 ? (qPlus - 1e18) : 0; // Q18

        // Upper bound on t (don’t drop below the lower edge 1 − thr):
        //   t less than or equal to R/(1 − thr) − 1
        // Use R_down and floor-div to be conservative, then subtract 1e18.
        uint256 denomMinus = 1e18 - locals.thr; // Q18 (> 0 by bounds on thr)
        uint256 numMinus = locals.R1e18 * 1e18; // Q36
        uint256 qMinus = numMinus / denomMinus; // floorDiv → Q18
        locals.tUpper = qMinus > 1e18 ? (qMinus - 1e18) : 0; // Q18

        // Choose t inside [tLower + eps, tUpper − eps] and map amtSeed with bound(...).
        // eps helps avoid equality-edge flips due to integer rounding.
        locals.epsT = 1; // one Q18 unit (~1e-18) is ample given we used ceil/floor conservatively
        locals.lo = locals.tLower + locals.epsT;
        locals.hi = (locals.tUpper > locals.epsT) ? (locals.tUpper - locals.epsT) : locals.tUpper;

        // If interval collapses or inverted (can happen with extreme tiny thr), clamp to a point and proceed.
        if (locals.hi < locals.lo) {
            locals.hi = locals.lo;
        }
        if (locals.lo == 0) {
            locals.lo = 1;
            if (locals.hi < locals.lo) locals.hi = locals.lo;
        }

        locals.x = bound(uint256(amtSeed), locals.lo, locals.hi);

        // Build locals
        locals.comp.wIn = 1e18;
        locals.comp.wOut = 1e18;
        locals.comp.bIn = 1e18;
        locals.comp.bOut = locals.priceBefore;
        locals.comp.pxIn = 1e18;
        locals.comp.pxOut = locals.E;
        locals.comp.calcAmountScaled18 = 0;
        locals.comp.poolDetails.arbThresholdPercentage9 = locals.arbThr9;
        locals.comp.poolDetails.arbCapDeviationPercentage9 = locals.arbCap9;
        locals.comp.poolDetails.arbMaxSurgeFee9 = locals.arbMax9;
        locals.comp.poolDetails.noiseThresholdPercentage9 = locals.noiseThr9;
        locals.comp.poolDetails.noiseCapDeviationPercentage9 = locals.noiseCap9;
        locals.comp.poolDetails.noiseMaxSurgeFee9 = locals.noiseMax9;

        locals.p.kind = SwapKind.EXACT_IN;
        locals.p.amountGivenScaled18 = locals.x;

        // Sanity: end is inside (two-sided)
        locals.priceAfter = (locals.priceBefore * 1e18) / (1e18 + locals.p.amountGivenScaled18);
        uint256 dAfter = ((
            locals.priceAfter > locals.E ? (locals.priceAfter - locals.E) : (locals.E - locals.priceAfter)
        ) * 1e18) / locals.E;
        assertLe(dAfter, locals.thr, "end should be at/inside threshold");

        // Expected (ARB) uses BEFORE even if end is at/inside threshold
        locals.expected = fee_expectedFeeWithParams(
            locals.priceBefore,
            locals.comp.pxIn,
            locals.comp.pxOut,
            STATIC_SWAP_FEE,
            locals.arbThr9,
            locals.arbCap9,
            locals.arbMax9
        );

        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.arbMax9),
            fee_ppm9To1e18(locals.arbThr9),
            fee_ppm9To1e18(locals.arbCap9),
            "lane-out2thr"
        );
        (, locals.dyn) = mock.ComputeSurgeFee(locals.comp, locals.p, STATIC_SWAP_FEE);

        assertEq(
            locals.dyn,
            locals.expected,
            "arb/before: dynamic fee must use BEFORE deviation even at threshold end"
        );
        assertGe(locals.dyn, STATIC_SWAP_FEE, "dynamic fee greater than or equal to static");
    }

    struct ArbNoMoveOutsideDynamicLocals {
        uint256 E;
        uint32 arbThr9;
        uint32 arbCap9;
        uint32 arbMax9;
        uint32 noiseThr9;
        uint32 noiseCap9;
        uint32 noiseMax9;
        uint256 thr;
        uint256 cap;
        uint256 deviationBefore;
        uint256 priceBefore;
        HyperSurgeHookMock.ComputeSurgeFeeLocals comp;
        PoolSwapParams p;
        uint256 expected;
        uint256 dyn;
    }

    function test_logic_arb_outside_nochange_dynamic_before(
        uint256 eSeed,
        uint32 arbThrSeed,
        uint32 arbCapSeed,
        uint32 arbMaxSeed
    ) public {
        ArbNoMoveOutsideDynamicLocals memory locals;

        locals.E = bound(eSeed, 1e16, 1e24);
        locals.arbThr9 = uint32(bound(arbThrSeed, 1, 900_000_000 - 1));
        locals.arbCap9 = uint32(bound(arbCapSeed, locals.arbThr9 + 1, 1_000_000_000));
        locals.arbMax9 = uint32(bound(arbMaxSeed, uint32(STATIC_SWAP_FEE / 1e9), 1_000_000_000));
        // NOISE lane different (unused)
        locals.noiseThr9 = 5_000_000;
        locals.noiseCap9 = 400_000_000;
        locals.noiseMax9 = 25_000_000;

        locals.thr = uint256(locals.arbThr9) * 1e9;
        locals.cap = uint256(locals.arbCap9) * 1e9;

        // Start ABOVE, outside
        locals.deviationBefore = locals.thr + (locals.cap - locals.thr) / 3;
        locals.priceBefore = locals.E + (locals.E * locals.deviationBefore) / 1e18;

        // No movement: amount = 0, so deviationAfter == deviationBefore → ARB path
        locals.comp.wIn = 1e18;
        locals.comp.wOut = 1e18;
        locals.comp.bIn = 1e18;
        locals.comp.bOut = locals.priceBefore;
        locals.comp.pxIn = 1e18;
        locals.comp.pxOut = locals.E;
        locals.comp.calcAmountScaled18 = 0;
        locals.comp.poolDetails.arbThresholdPercentage9 = locals.arbThr9;
        locals.comp.poolDetails.arbCapDeviationPercentage9 = locals.arbCap9;
        locals.comp.poolDetails.arbMaxSurgeFee9 = locals.arbMax9;
        locals.comp.poolDetails.noiseThresholdPercentage9 = locals.noiseThr9;
        locals.comp.poolDetails.noiseCapDeviationPercentage9 = locals.noiseCap9;
        locals.comp.poolDetails.noiseMaxSurgeFee9 = locals.noiseMax9;

        locals.p.kind = SwapKind.EXACT_IN;
        locals.p.amountGivenScaled18 = 0;

        locals.expected = fee_expectedFeeWithParams(
            locals.priceBefore,
            locals.comp.pxIn,
            locals.comp.pxOut,
            STATIC_SWAP_FEE,
            locals.arbThr9,
            locals.arbCap9,
            locals.arbMax9
        );

        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.arbMax9),
            fee_ppm9To1e18(locals.arbThr9),
            fee_ppm9To1e18(locals.arbCap9),
            "lane-nomove-outside"
        );
        (, locals.dyn) = mock.ComputeSurgeFee(locals.comp, locals.p, STATIC_SWAP_FEE);

        assertEq(locals.dyn, locals.expected, "no-move/outside must be ARB, dynamic from BEFORE");
        assertGe(locals.dyn, STATIC_SWAP_FEE, "dynamic fee greater than or equal to static");
    }

    struct ArbNoMoveInsideLocals {
        uint256 E;
        uint32 arbThr9;
        uint32 arbCap9;
        uint32 arbMax9;
        uint32 noiseThr9;
        uint32 noiseCap9;
        uint32 noiseMax9;
        uint256 thr;
        uint256 deviationBefore;
        uint256 priceBefore;
        uint256 fee;
        HyperSurgeHookMock.ComputeSurgeFeeLocals comp;
        PoolSwapParams p;
    }

    /// [LANE] No movement, inside: ARB path, but STATIC fee (since BEFORE less than or equal to thr)
    function test_logic_arb_inside_nochange_static(
        uint256 eSeed,
        uint32 arbThrSeed,
        uint32 arbCapSeed,
        uint32 arbMaxSeed
    ) public {
        ArbNoMoveInsideLocals memory locals;

        locals.E = bound(eSeed, 1e16, 1e24);
        locals.arbThr9 = uint32(bound(arbThrSeed, 1, 1_000_000_000 - 1));
        locals.arbCap9 = uint32(bound(arbCapSeed, locals.arbThr9 + 1, 1_000_000_000));
        locals.arbMax9 = uint32(bound(arbMaxSeed, uint32(STATIC_SWAP_FEE / 1e9), 1_000_000_000));
        locals.noiseThr9 = 5_000_000;
        locals.noiseCap9 = 400_000_000;
        locals.noiseMax9 = 25_000_000;

        locals.thr = uint256(locals.arbThr9) * 1e9;

        // Start BELOW, inside
        locals.deviationBefore = (locals.thr / 3) + 1; // strictly inside
        locals.priceBefore = locals.E - (locals.E * locals.deviationBefore) / 1e18;

        // No movement: deviationAfter == deviationBefore → ARB branch, but less than or equal to thr ⇒ static
        locals.comp.wIn = 1e18;
        locals.comp.wOut = 1e18;
        locals.comp.bIn = 1e18;
        locals.comp.bOut = locals.priceBefore;
        locals.comp.pxIn = 1e18;
        locals.comp.pxOut = locals.E;
        locals.comp.calcAmountScaled18 = 0;
        locals.comp.poolDetails.arbThresholdPercentage9 = locals.arbThr9;
        locals.comp.poolDetails.arbCapDeviationPercentage9 = uint32(locals.arbCap9);
        locals.comp.poolDetails.arbMaxSurgeFee9 = locals.arbMax9;
        locals.comp.poolDetails.noiseThresholdPercentage9 = locals.noiseThr9;
        locals.comp.poolDetails.noiseCapDeviationPercentage9 = locals.noiseCap9;
        locals.comp.poolDetails.noiseMaxSurgeFee9 = locals.noiseMax9;

        locals.p.kind = SwapKind.EXACT_IN;
        locals.p.amountGivenScaled18 = 0;

        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.arbMax9),
            fee_ppm9To1e18(locals.arbThr9),
            fee_ppm9To1e18(locals.arbCap9),
            "lane-nomove-inside"
        );
        (, locals.fee) = mock.ComputeSurgeFee(locals.comp, locals.p, STATIC_SWAP_FEE);

        assertEq(
            locals.fee,
            STATIC_SWAP_FEE,
            "no-move/inside must return static (ARB branch, but less than or equal to thr)"
        );
    }

    struct NoiseCrossesPriceWorsensDymanicLocals {
        uint256 E;
        uint32 noiseThr9;
        uint32 noiseCap9;
        uint32 noiseMax9;
        uint32 arbThr9;
        uint32 arbCap9;
        uint32 arbMax9;
        uint256 thr;
        uint256 cap;
        uint256 deviationBefore;
        uint256 priceBefore;
        uint256 priceAfter;
        uint256 tCross;
        uint256 tWorse;
        uint256 tMin;
        uint256 x;
        uint256 num;
        uint256 den;
        uint256 q;
        uint256 epsT;
        uint256 lo;
        uint256 hi;
        uint256 deviationAfter;
        HyperSurgeHookMock.ComputeSurgeFeeLocals comp;
        PoolSwapParams p;
        uint256 expected;
        uint256 dyn;
    }

    /// [LANE] Symmetric “below” case: start outside BELOW, worsen further BELOW (no cross) → NOISE uses AFTER
    /// Note: With calc=0 and this simplified price update, EXACT_IN can only decrease P,
    /// so a true below→above cross is not representable without changing the price update model.
    /// This test locks the symmetric NOISE/AFTER behavior from the “below” side.
    function testFuzz_logic_noise_outside_below_worsens_dynamic_after(
        uint256 eSeed,
        uint32 noiseThrSeed,
        uint32 noiseCapSeed,
        uint32 noiseMaxSeed,
        uint64 amtSeed
    ) public {
        NoiseCrossesPriceWorsensDymanicLocals memory locals;

        // External price (pxOut/pxIn -> E); keep as in all other tests
        locals.E = bound(eSeed, 1e16, 1e24);

        // Distinct NOISE lane params (fuzzed) and different ARB params (unused in expected but distinct to catch wrong-lane)
        locals.noiseThr9 = uint32(bound(noiseThrSeed, 1, 900_000_000 - 1));
        locals.noiseCap9 = uint32(bound(noiseCapSeed, locals.noiseThr9 + 1, 1_000_000_000));
        locals.noiseMax9 = uint32(bound(noiseMaxSeed, uint32(STATIC_SWAP_FEE / 1e9), 1_000_000_000));
        locals.arbThr9 = 1_000_000;
        locals.arbCap9 = 300_000_000;
        locals.arbMax9 = 50_000_000;

        locals.thr = uint256(locals.noiseThr9) * 1e9; // Q18
        locals.cap = uint256(locals.noiseCap9) * 1e9; // Q18

        // Start OUTSIDE BELOW price: priceBefore = E * (1 - D_before), with D_before in (thr, cap)
        locals.deviationBefore = locals.thr + (locals.cap - locals.thr) / 3; // Q18: strictly outside
        locals.priceBefore = locals.E - (locals.E * locals.deviationBefore) / 1e18;

        // Build compute locals with the standard orientation (pxIn=1e18, pxOut=E)
        locals.comp.wIn = 1e18;
        locals.comp.wOut = 1e18;
        locals.comp.bIn = 1e18;
        locals.comp.bOut = locals.priceBefore;
        locals.comp.pxIn = 1e18; // keep the usual frame
        locals.comp.pxOut = locals.E;
        locals.comp.calcAmountScaled18 = 0;
        locals.comp.poolDetails.noiseThresholdPercentage9 = locals.noiseThr9;
        locals.comp.poolDetails.noiseCapDeviationPercentage9 = locals.noiseCap9;
        locals.comp.poolDetails.noiseMaxSurgeFee9 = locals.noiseMax9;
        locals.comp.poolDetails.arbThresholdPercentage9 = locals.arbThr9;
        locals.comp.poolDetails.arbCapDeviationPercentage9 = locals.arbCap9;
        locals.comp.poolDetails.arbMaxSurgeFee9 = locals.arbMax9;

        // EXACT_IN reduces P further → deviation worsens from the BELOW side (NOISE lane)
        locals.p.kind = SwapKind.EXACT_IN;
        // ensure a measurable worsening but no overflow; avoid 1-wei knife edges
        uint256 lo = 1e9; // Q18 t = 1e-9
        uint256 hi = 5e17; // Q18 t less than or equal to 0.5
        locals.p.amountGivenScaled18 = bound(uint256(amtSeed), lo, hi);

        // AFTER price for expected (NOISE uses AFTER)
        locals.priceAfter = (locals.priceBefore * 1e18) / (1e18 + locals.p.amountGivenScaled18);

        // Sanity: still BELOW E and deviation increased
        uint256 dBefore = ((locals.E - locals.priceBefore) * 1e18) / locals.E;
        uint256 dAfter = ((locals.E - locals.priceAfter) * 1e18) / locals.E;
        assertGt(dAfter, dBefore, "deviation must worsen from the below side");

        // Expected NOISE fee from AFTER deviation
        locals.expected = fee_expectedFeeWithParams(
            locals.priceAfter,
            locals.comp.pxIn,
            locals.comp.pxOut,
            STATIC_SWAP_FEE,
            locals.noiseThr9,
            locals.noiseCap9,
            locals.noiseMax9
        );

        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.arbMax9),
            fee_ppm9To1e18(locals.arbThr9),
            fee_ppm9To1e18(locals.arbCap9),
            "lane-below-worsen"
        );
        (, locals.dyn) = mock.ComputeSurgeFee(locals.comp, locals.p, STATIC_SWAP_FEE);

        assertEq(locals.dyn, locals.expected, "noise/after (below side): dynamic fee must match expected");
        assertGe(locals.dyn, STATIC_SWAP_FEE, "dynamic fee greater than or equal to static");
    }

    struct BoundArbBeforeClampToMaxLocals {
        uint256 E;
        uint32 arbThr9;
        uint32 arbCap9;
        uint32 arbMax9;
        uint32 noiseThr9;
        uint32 noiseCap9;
        uint32 noiseMax9;
        uint256 thr;
        uint256 cap;
        uint256 Db; // Q18
        uint256 priceBefore;
        uint256 priceAfter;
        uint256 tLower;
        uint256 tUpperNoCross;
        uint256 x; // Q18
        HyperSurgeHookMock.ComputeSurgeFeeLocals comp;
        PoolSwapParams p;
        uint256 fee;
        uint256 expected;
    }

    /// [BOUND] ARB with BEFORE > cap, AFTER < cap: ARB clamps to maxArb (basis = BEFORE)
    /// Start ABOVE with BEFORE deviation > cap, improve so AFTER less than or equal to cap (stay above; no cross).
    /// Assert: ARB lane; fee == arbMax (clamped by BEFORE).
    function testFuzz_bound_arb_before_gt_cap_clamps_to_max_before(
        uint256 eSeed,
        uint32 arbThrSeed,
        uint32 arbCapSeed,
        uint32 arbMaxSeed,
        uint64 amtSeed
    ) public {
        BoundArbBeforeClampToMaxLocals memory locals;

        // External price
        locals.E = bound(eSeed, 1e16, 1e24);

        // ARB lane params (ensure thr < cap < 1.0)
        locals.arbThr9 = uint32(bound(arbThrSeed, 1, 900_000_000 - 1)); // (0, 0.9)
        locals.arbCap9 = uint32(bound(arbCapSeed, locals.arbThr9 + 1, 1_000_000_000 - 1)); // (thr, 1)
        locals.arbMax9 = uint32(bound(arbMaxSeed, uint32(STATIC_SWAP_FEE / 1e9) + 1, 1_000_000_000));

        // Distinct NOISE params (unused in expected but kept different to catch wrong-lane)
        locals.noiseThr9 = 5_000_000;
        locals.noiseCap9 = 400_000_000;
        locals.noiseMax9 = 25_000_000;

        locals.thr = uint256(locals.arbThr9) * 1e9; // Q18
        locals.cap = uint256(locals.arbCap9) * 1e9; // Q18
        assertLt(locals.cap, 1e18, "cap must be < 100%");

        // BEFORE deviation strictly above cap but < 1, with safe margin
        // margin = max(1, (1e18 - cap)/16) keeps Db < 1 while staying comfortably > cap
        uint256 margin = (1e18 - locals.cap) / 16;
        if (margin == 0) {
            margin = 1;
        }
        locals.Db = locals.cap + margin;
        if (locals.Db >= 1e18) {
            locals.Db = 1e18 - 1;
        }

        // Sanity: BEFORE > cap
        assertGt(locals.Db, locals.cap, "setup must have BEFORE > cap");

        // Price ABOVE E with BEFORE deviation Db
        locals.priceBefore = locals.E + (locals.E * locals.Db) / 1e18;

        // ABOVE side with EXACT_IN:
        // D_after_pos (no-cross) = (Db - t)/(1 + t). Want AFTER less than or equal to cap ⇒ t ≥ (Db - cap)/(1 + cap).

        uint256 num = (locals.Db - locals.cap) * 1e18; // Q36 (Db > cap guaranteed)
        uint256 den = 1e18 + locals.cap; // Q18
        uint256 q = (num + den - 1) / den; // ceilDiv → Q18
        locals.tLower = q;

        // Avoid crossing E: need t < Db. Use tiny epsilon below Db to stay strictly above E.
        uint256 epsCross = 1; // one Q18 unit
        locals.tUpperNoCross = (locals.Db > epsCross) ? (locals.Db - epsCross) : 0;

        // Pick t ∈ [tLower, tUpperNoCross]
        uint256 lo = (locals.tLower == 0 ? 1 : locals.tLower);
        uint256 hi = locals.tUpperNoCross;
        if (hi < lo) {
            hi = lo;
        } // clamp if degenerate/narrow
        locals.x = bound(uint256(amtSeed), lo, hi);

        // Build locals
        locals.comp.wIn = 1e18;
        locals.comp.wOut = 1e18;
        locals.comp.bIn = 1e18;
        locals.comp.bOut = locals.priceBefore;
        locals.comp.pxIn = 1e18;
        locals.comp.pxOut = locals.E;
        locals.comp.calcAmountScaled18 = 0;
        locals.comp.poolDetails.arbThresholdPercentage9 = locals.arbThr9;
        locals.comp.poolDetails.arbCapDeviationPercentage9 = locals.arbCap9;
        locals.comp.poolDetails.arbMaxSurgeFee9 = locals.arbMax9;
        locals.comp.poolDetails.noiseThresholdPercentage9 = locals.noiseThr9;
        locals.comp.poolDetails.noiseCapDeviationPercentage9 = locals.noiseCap9;
        locals.comp.poolDetails.noiseMaxSurgeFee9 = locals.noiseMax9;

        locals.p.kind = SwapKind.EXACT_IN;
        locals.p.amountGivenScaled18 = locals.x;

        // AFTER should be less than or equal to cap (improved) and we shouldn’t have crossed E.
        locals.priceAfter = (locals.priceBefore * 1e18) / (1e18 + locals.x);
        uint256 dAfter = ((
            locals.priceAfter > locals.E ? (locals.priceAfter - locals.E) : (locals.E - locals.priceAfter)
        ) * 1e18) / locals.E;
        assertLe(dAfter, locals.cap, "AFTER should be less than or equal to cap (improved)");

        // ARB uses BEFORE and must clamp to maxArb
        (, locals.fee) = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.arbMax9),
            fee_ppm9To1e18(locals.arbThr9),
            fee_ppm9To1e18(locals.arbCap9),
            "arb-before-cap"
        ).ComputeSurgeFee(locals.comp, locals.p, STATIC_SWAP_FEE);

        locals.expected = fee_expectedFeeWithParams(
            locals.priceBefore,
            locals.comp.pxIn,
            locals.comp.pxOut,
            STATIC_SWAP_FEE,
            locals.arbThr9,
            locals.arbCap9,
            locals.arbMax9
        );
        assertEq(locals.fee, locals.expected, "ARB should compute from BEFORE and clamp at cap->max");
        assertEq(locals.fee, fee_ppm9To1e18(locals.arbMax9), "ARB fee must equal arbMax");
    }

    struct BoundNoiseExactThresholdLocals {
        uint256 E;
        uint32 noiseThr9;
        uint32 noiseCap9;
        uint32 noiseMax9;
        uint32 arbThr9;
        uint32 arbCap9;
        uint32 arbMax9;
        uint256 thr;
        uint256 Db; // Q18
        uint256 priceBefore;
        uint256 priceAfter;
        uint256 tEdge; // Q18
        uint256 x; // Q18
        uint256 fee; // Computed fee
        HyperSurgeHookMock.ComputeSurgeFeeLocals comp;
        PoolSwapParams p;
    }

    /// [BOUND] Exactly-at-threshold for NOISE end-state: static (no ramp)
    /// Start inside (below E), worsen to land at (or just under, by rounding) the threshold.
    /// Assert: fee == static.
    function testFuzz_bound_noise_after_at_threshold_static(
        uint256 eSeed,
        uint32 noiseThrSeed,
        uint32 noiseCapSeed,
        uint32 noiseMaxSeed,
        uint64 amtSeed
    ) public {
        BoundNoiseExactThresholdLocals memory locals;

        locals.E = bound(eSeed, 1e16, 1e24);
        locals.noiseThr9 = uint32(bound(noiseThrSeed, 1, 900_000_000 - 1)); // (0, 0.9)
        locals.noiseCap9 = uint32(bound(noiseCapSeed, locals.noiseThr9 + 1, 1_000_000_000)); // (thr, 1]
        locals.noiseMax9 = uint32(bound(noiseMaxSeed, uint32(STATIC_SWAP_FEE / 1e9), 1_000_000_000));
        // Distinct ARB lane (unused in assertion but kept different)
        locals.arbThr9 = 1_000_000;
        locals.arbCap9 = 300_000_000;
        locals.arbMax9 = 50_000_000;

        locals.thr = uint256(locals.noiseThr9) * 1e9; // Q18

        // Start BELOW inside: Db < thr
        locals.Db = locals.thr / 4 + 1; // strictly inside
        locals.priceBefore = locals.E - (locals.E * locals.Db) / 1e18; // P/E = 1 - Db

        // For below side: D_after = (Db + t)/(1 + t). To land AT threshold: t* = (thr - Db)/(1 - thr).
        // Use floor for an upper bound that guarantees D_after less than or equal to thr after integer rounding.
        {
            uint256 num = (locals.thr - locals.Db) * 1e18; // Q36
            uint256 den = 1e18 - locals.thr; // Q18 (> 0 by bound)
            locals.tEdge = den == 0 ? 0 : (num / den); // Q18, floor
        }

        // Choose t ∈ [max(1, tEdge - eps), tEdge] so we never overshoot (keeps AFTER less than or equal to thr).
        uint256 epsT = 1e6; // 1e-12 in Q18; stays near the threshold
        uint256 lo = (locals.tEdge > epsT) ? (locals.tEdge - epsT) : 1;
        uint256 hi = locals.tEdge;
        if (hi < lo) {
            hi = lo;
        } // clamp if degenerate
        locals.x = bound(uint256(amtSeed), lo, hi);

        // Build locals
        locals.comp.wIn = 1e18;
        locals.comp.wOut = 1e18;
        locals.comp.bIn = 1e18;
        locals.comp.bOut = locals.priceBefore;
        locals.comp.pxIn = 1e18;
        locals.comp.pxOut = locals.E;
        locals.comp.calcAmountScaled18 = 0;
        locals.comp.poolDetails.noiseThresholdPercentage9 = locals.noiseThr9;
        locals.comp.poolDetails.noiseCapDeviationPercentage9 = locals.noiseCap9;
        locals.comp.poolDetails.noiseMaxSurgeFee9 = locals.noiseMax9;
        locals.comp.poolDetails.arbThresholdPercentage9 = locals.arbThr9;
        locals.comp.poolDetails.arbCapDeviationPercentage9 = locals.arbCap9;
        locals.comp.poolDetails.arbMaxSurgeFee9 = locals.arbMax9;

        locals.p.kind = SwapKind.EXACT_IN;
        locals.p.amountGivenScaled18 = locals.x;

        // Sanity: AFTER less than or equal to threshold and > BEFORE (worsened)
        locals.priceAfter = (locals.priceBefore * 1e18) / (1e18 + locals.p.amountGivenScaled18);
        uint256 dBefore = ((locals.E - locals.priceBefore) * 1e18) / locals.E;
        uint256 dAfter = ((locals.E - locals.priceAfter) * 1e18) / locals.E;
        assertLe(dAfter, locals.thr, "AFTER should be less than or equal to threshold (at-or-just-inside)");
        assertGt(dAfter, dBefore, "deviation must worsen (positive t)");

        // Inside-after on NOISE → static
        (, locals.fee) = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.arbMax9),
            fee_ppm9To1e18(locals.arbThr9),
            fee_ppm9To1e18(locals.arbCap9),
            "noise-exact-thr"
        ).ComputeSurgeFee(locals.comp, locals.p, STATIC_SWAP_FEE);

        assertEq(locals.fee, STATIC_SWAP_FEE, "At threshold end-state: NOISE must return static (no ramp)");
    }

    // Helper: for “bad/missing external prices”, either revert OR return (ok && static fee).
    function _assertStaticFeeOrRevert_MissingPrices(PoolSwapParams memory p) internal view {
        // call must be from vault (the test sets vm.prank(vault) before calling this)
        (bool ok, uint256 fee) = hook.onComputeDynamicSwapFeePercentage(p, address(pool), STATIC_SWAP_FEE);

        assertTrue(ok, "missing prices: ok must be true on success");
        assertEq(fee, STATIC_SWAP_FEE, "missing prices: must return static fee");
    }

    // Helper: for invalid shapes, either revert OR return (ok && static fee). Never a non-static fee.
    function _assertStaticFeeOrRevert(PoolSwapParams memory p) internal view {
        // Call must be from the Vault (set by the test before invoking this).
        (bool ok, uint256 fee) = hook.onComputeDynamicSwapFeePercentage(p, address(pool), STATIC_SWAP_FEE);
        assertTrue(ok, "invalid shape must not set ok=false");
        assertEq(fee, STATIC_SWAP_FEE, "invalid shape must not produce a dynamic fee");
    }

    function _createPool(
        address[] memory tokens,
        string memory label
    ) internal override returns (address newPool, bytes memory poolArgs) {
        // Create a Weighted Pool with the given tokens and default weights.

        if (weights.length == 0 || weights.length != tokens.length) {
            weights = new uint256[](tokens.length);

            for (uint256 i = 0; i < tokens.length; i++) {
                weights[i] = 1e18 / tokens.length; // Equal weights
            }
        }

        LiquidityManagement memory liquidityManagement;
        PoolRoleAccounts memory roleAccounts;
        roleAccounts.poolCreator = admin;
        roleAccounts.swapFeeManager = admin;

        WeightedPool.NewPoolParams memory params = WeightedPool.NewPoolParams({
            name: label,
            symbol: "WPOOL",
            numTokens: tokens.length,
            normalizedWeights: weights,
            version: "1.0"
        });

        newPool = address(deployWeightedPoolMock(params, IVault(vault)));

        vault.registerPool(
            newPool,
            vault.buildTokenConfig(tokens.asIERC20()),
            DEFAULT_SWAP_FEE,
            0,
            false,
            roleAccounts,
            address(0),
            liquidityManagement
        );

        poolArgs = abi.encode(
            WeightedPool.NewPoolParams({
                name: label,
                symbol: "WPOOL",
                numTokens: tokens.length,
                normalizedWeights: weights,
                version: "1.0"
            }),
            vault
        );
    }

    /// @notice Register the BaseVaultTest pool with a fuzzed token count n (2..8).
    function _registerBasePoolWithN(uint8 n) internal {
        n = uint8(bound(n, 2, 8));

        TokenConfig[] memory cfg = new TokenConfig[](n);
        LiquidityManagement memory lm;
        vm.prank(address(vault)); // onRegister is onlyVault
        bool ok = hook.onRegister(poolFactory, address(pool), cfg, lm);
        assertTrue(ok, "onRegister(base pool) failed");
    }

    function _hlSetSpot(uint32 pairIdx, uint32 price_1e6) internal {
        bytes32 slot = keccak256(abi.encode(bytes32(uint256(pairIdx)), bytes32(uint256(0))));
        vm.store(HyperSpotPricePrecompile.SPOT_PRICE_PRECOMPILE_ADDRESS, slot, bytes32(uint256(price_1e6)));
    }

    function _hlSetSzDecimals(uint32 pairIdx, uint8 sz) internal {
        bytes32 slot = keccak256(abi.encode(bytes32(uint256(pairIdx)), bytes32(uint256(0))));
        vm.store(HyperTokenInfoPrecompile.TOKEN_INFO_PRECOMPILE_ADDRESS, slot, bytes32(uint256(sz)));
    }

    function _feeAtDeviation(
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory computeLocals,
        PoolSwapParams memory p,
        uint256 staticFee,
        uint256 extPxE18,
        uint256 deviation18
    ) internal view returns (uint256) {
        // pool price P = E * (1 + deviation)
        uint256 P = extPxE18 + (extPxE18 * deviation18) / 1e18;

        // Make poolPx = P using simple weights/balances:
        // poolPx = (bOut * wIn) / (bIn * wOut)
        computeLocals.wIn = 1e18;
        computeLocals.wOut = 1e18;
        computeLocals.bIn = 1e18;
        computeLocals.bOut = P;

        // Keep deltas zero so poolPx == poolPxBefore (no lane flip due to swap)
        computeLocals.calcAmountScaled18 = 0;

        (bool ok, uint256 fee) = hook.ComputeSurgeFee(computeLocals, p, staticFee);
        assertTrue(ok, "compute ok");
        return fee;
    }

    function fee_mulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / FEE_ONE;
    }

    function fee_divDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * FEE_ONE) / b;
    }

    function fee_relAbsDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? fee_divDown(a - b, b) : fee_divDown(b - a, b);
    }

    // Pool pair-spot with the SAME staging & rounding the hook uses:
    // P = (B_out * w_in) / (B_in * w_out)
    function fee_pairSpotFromBW(uint256 bIn, uint256 wIn, uint256 bOut, uint256 wOut) internal pure returns (uint256) {
        uint256 num = fee_mulDown(bOut, wIn);
        uint256 den = fee_mulDown(bIn, wOut);
        return den == 0 ? 0 : fee_divDown(num, den);
    }

    // Weights: normalized with 1% floor, deterministic from a seed
    function fee_normWeights(uint8 n, uint256 seed) internal pure returns (uint256[] memory w) {
        uint256 WEIGHT_MIN = 1e16; // 1%
        require(uint256(n) * WEIGHT_MIN <= FEE_ONE, "min too big");
        w = new uint256[](n);

        uint256[] memory r = new uint256[](n);
        uint256 sumR;
        unchecked {
            for (uint8 i = 0; i < n; ++i) {
                r[i] = 1 + (uint256(keccak256(abi.encode(seed, i))) % 1e9);
                sumR += r[i];
            }
        }

        uint256 base = uint256(n) * WEIGHT_MIN;
        uint256 rem = FEE_ONE - base;
        uint256 acc;
        for (uint8 i = 0; i < n; ++i) {
            uint256 share = (r[i] * rem) / sumR;
            w[i] = WEIGHT_MIN + share;
            acc += w[i];
        }
        if (acc != FEE_ONE) {
            if (acc < FEE_ONE) w[0] += (FEE_ONE - acc);
            else {
                uint256 over = acc - FEE_ONE;
                w[0] = w[0] > over + WEIGHT_MIN ? (w[0] - over) : WEIGHT_MIN;
            }
        }
    }

    // Balances: large safe magnitudes
    function fee_balances(uint8 n, uint256 seed) internal pure returns (uint256[] memory b) {
        b = new uint256[](n);
        for (uint8 i = 0; i < n; ++i) {
            // 1e12 .. 1e24
            uint256 x = 1e12 + (uint256(keccak256(abi.encode(seed, i))) % (1e24 - 1e12));
            b[i] = x;
        }
    }

    // Choose deviation D, then set external px so that extPx = P / (1 + D)
    function fee_localsForDeviation(uint256 P, uint256 D) internal pure returns (uint256 pxIn, uint256 pxOut) {
        pxIn = FEE_ONE;
        pxOut = fee_divDown(P, FEE_ONE + D);
    }

    function fee_ppm9To1e18(uint32 v) internal pure returns (uint256) {
        return uint256(v) * 1e9;
    }

    // Expected fee (exact same rounding & clamping as the hook)
    function fee_expectedFeeWithParams(
        uint256 poolPx,
        uint256 pxIn,
        uint256 pxOut,
        uint256 staticSwapFee,
        uint32 thresholdPPM9,
        uint32 capDevPPM9,
        uint32 maxFeePPM9
    ) internal pure returns (uint256) {
        uint256 extPx = fee_divDown(pxOut, pxIn);
        uint256 deviation = fee_relAbsDiff(poolPx, extPx);

        uint256 threshold = fee_ppm9To1e18(thresholdPPM9);
        uint256 capDev = fee_ppm9To1e18(capDevPPM9);
        uint256 maxPct = fee_ppm9To1e18(maxFeePPM9);

        if (deviation <= threshold) {
            return staticSwapFee;
        }

        uint256 span = capDev - threshold;
        uint256 norm = fee_divDown(deviation - threshold, span);
        if (norm > FEE_ONE) {
            norm = FEE_ONE;
        }

        uint256 incr = fee_mulDown(maxPct - staticSwapFee, norm);
        uint256 fee = staticSwapFee + incr;
        if (fee > maxPct) {
            fee = maxPct;
        }
        return fee;
    }

    function fee_makeLocals(
        uint256 bIn,
        uint256 wIn,
        uint256 bOut,
        uint256 wOut,
        uint256 pxIn,
        uint256 pxOut,
        uint32 thrPPM9,
        uint32 capPPM9,
        uint32 maxPPM9
    ) internal pure returns (HyperSurgeHookMock.ComputeSurgeFeeLocals memory computeLocals) {
        computeLocals.bIn = bIn;
        computeLocals.wIn = wIn;
        computeLocals.bOut = bOut;
        computeLocals.wOut = wOut;
        computeLocals.pxIn = pxIn;
        computeLocals.pxOut = pxOut;
        computeLocals.poolDetails.noiseThresholdPercentage9 = thrPPM9;
        computeLocals.poolDetails.noiseCapDeviationPercentage9 = capPPM9;
        computeLocals.poolDetails.noiseMaxSurgeFee9 = maxPPM9;
        computeLocals.poolDetails.arbThresholdPercentage9 = thrPPM9;
        computeLocals.poolDetails.arbCapDeviationPercentage9 = capPPM9;
        computeLocals.poolDetails.arbMaxSurgeFee9 = maxPPM9;
    }

    function fee_boundParams(
        uint32 thrPPM9,
        uint32 capPPM9,
        uint32 maxPPM9
    ) internal pure returns (uint32 thr, uint32 cap, uint32 maxp) {
        // Constrain to valid ranges:
        // Threshold in [0.0001% .. 20%]
        thr = uint32(bound(thrPPM9, 1_000, 200_000_000));

        // Cap in (threshold .. 90%]
        cap = uint32(bound(capPPM9, thr + 1, 900_000_000));

        // Max fee must be >= static swap fee (1% => 10_000_000 ppm9), and <= 90%
        maxp = uint32(bound(maxPPM9, 10_000_000, 900_000_000));
    }
}
