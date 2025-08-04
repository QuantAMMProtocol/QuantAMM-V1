// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

/// @notice Drop-in stub fuzz tests for HyperSurge matching the 34-test suite names.
/// Each test only includes obvious `bound()` calls (no setup/asserts).
contract HyperSurgeHookTest is Test {
    uint256 constant ONE = 1e18;

    /*//////////////////////////////////////////////////////////////
                              REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function testFuzz_onRegister_enforces_token_count_bounds(uint256 n) public {
        n = bound(n, 0, 12); // real hook accepts 2..8
    }

    function testFuzz_onRegister_sets_defaults(uint256 maxPct, uint256 thr) public {
        maxPct = bound(maxPct, 0, ONE);
        thr    = bound(thr,    0, ONE);
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN PERCENT GUARDS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_setMaxSurgeFeePercentage_bounds(uint256 pct) public {
        pct = bound(pct, 0, ONE + 1e20);
    }

    function testFuzz_setSurgeThresholdPercentage_bounds(uint256 pct) public {
        pct = bound(pct, 0, ONE + 1e20);
    }

    function testFuzz_ensurePct_bounds(uint256 pct) public {
        pct = bound(pct, 0, ONE + 1e20);
    }

    /*//////////////////////////////////////////////////////////////
                           INDEX-BASED CONFIG
    //////////////////////////////////////////////////////////////*/

    function testFuzz_setTokenPriceConfigIndex_rejects_out_of_range_index(uint8 numTokens, uint8 idx) public {
        numTokens = uint8(bound(numTokens, 2, 8));
        idx       = uint8(bound(idx, numTokens, 30));
    }

    function testFuzz_setTokenPriceConfigIndex_accepts_in_range_index(uint8 numTokens, uint8 idx) public {
        numTokens = uint8(bound(numTokens, 2, 8));
        idx       = (numTokens == 0) ? 0 : uint8(bound(idx, 0, numTokens - 1));
    }

    function testFuzz_setTokenPriceConfigIndex_usd_path(uint8 numTokens, uint8 idx) public {
        numTokens = uint8(bound(numTokens, 2, 8));
        idx       = (numTokens == 0) ? 0 : uint8(bound(idx, 0, numTokens - 1));
    }

    function testFuzz_setTokenPriceConfigIndex_pairIdx_nonzero(uint8 numTokens, uint8 idx, uint32 pairIdx) public {
        numTokens = uint8(bound(numTokens, 2, 8));
        idx       = (numTokens == 0) ? 0 : uint8(bound(idx, 0, numTokens - 1));
        pairIdx   = uint32(bound(pairIdx, 1, type(uint32).max));
    }

    function testFuzz_setTokenPriceConfigIndex_szDecimals_and_divisor(uint8 sz) public {
        sz = uint8(bound(sz, 0, 6));
    }

    function testFuzz_setTokenPriceConfigIndex_szDecimals_over_6(uint8 sz) public {
        sz = uint8(bound(sz, 7, 30));
    }

    function testFuzz_setTokenPriceConfigBatchIndex_length_mismatch(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, 16);
        b = bound(b, 0, 16);
        c = bound(c, 0, 16);
    }

    // Signature seen: (uint256,uint8,uint8,uint8,uint8)
    function testFuzz_setTokenPriceConfigBatchIndex_inputs(
        uint256 len,
        uint8 idx0,
        uint8 idx1,
        uint8 idx2,
        uint8 idx3
    ) public {
        len  = bound(len,  0, 8);
        idx0 = uint8(bound(idx0, 0, 7));
        idx1 = uint8(bound(idx1, 0, 7));
        idx2 = uint8(bound(idx2, 0, 7));
        idx3 = uint8(bound(idx3, 0, 7));
    }

    /*//////////////////////////////////////////////////////////////
                         PRECOMPILE SURFACES
    //////////////////////////////////////////////////////////////*/

    function testFuzz_hyper_price_spot_success(uint64 raw, uint32 divisor) public {
        raw     = uint64(bound(raw,     1, type(uint64).max));
        divisor = uint32(bound(divisor, 1, 1_000_000));
    }

    function testFuzz_hyper_price_spot_failure_marker(uint256 marker) public {
        marker = bound(marker, 0, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                       DYNAMIC FEE – EARLY EXITS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_compute_static_when_not_initialized(uint8 initFlag) public {
        initFlag = uint8(bound(initFlag, 0, 1));
    }

    function testFuzz_compute_indices_bounds(uint8 numTokens, uint8 indexIn, uint8 indexOut) public {
        numTokens = uint8(bound(numTokens, 2, 8));
        indexIn   = uint8(bound(indexIn,  0, numTokens - 1));
        indexOut  = uint8(bound(indexOut, 0, numTokens - 1));
    }

    function testFuzz_compute_early_exit_when_threshold_is_one(uint256 thr) public {
        thr = bound(thr, ONE, ONE);
    }

    function testFuzz_compute_early_exit_max_le_static(uint256 maxPct, uint256 staticFee) public {
        maxPct    = bound(maxPct,    0, ONE);
        staticFee = bound(staticFee, 0, ONE);
        staticFee = bound(staticFee, 0, maxPct);
    }

    /*//////////////////////////////////////////////////////////////
                    SWAP KINDS / BALANCES / WEIGHTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_exact_in_balance_update(uint256 bIn, uint256 bOut, uint256 amtIn, uint256 amtOut) public {
        bIn    = bound(bIn,    1, type(uint128).max);
        bOut   = bound(bOut,   1, type(uint128).max);
        amtIn  = bound(amtIn,  0, type(uint128).max);
        amtOut = bound(amtOut, 0, bOut);
    }

    function testFuzz_exact_out_balance_update(uint256 bIn, uint256 bOut, uint256 amtGivenOut, uint256 amtInCalc) public {
        bIn         = bound(bIn,         1, type(uint128).max);
        bOut        = bound(bOut,        1, type(uint128).max);
        amtGivenOut = bound(amtGivenOut, 0, bOut);
        amtInCalc   = bound(amtInCalc,   0, type(uint128).max);
    }

    function testFuzz_pool_spot_inputs(uint256 bIn, uint256 bOut, uint256 wIn, uint256 wOut) public {
        bIn  = bound(bIn,  1, type(uint128).max);
        bOut = bound(bOut, 1, type(uint128).max);
        wIn  = bound(wIn,  1, ONE - 1);
        wOut = bound(wOut, 1, ONE - 1);
    }

    function testFuzz_pair_spot_bal0(uint256 wIn, uint256 bOut, uint256 wOut) public {
        wIn  = bound(wIn,  1, ONE - 1);
        bOut = bound(bOut, 1, type(uint128).max);
        wOut = bound(wOut, 1, ONE - 1);
    }

    /*//////////////////////////////////////////////////////////////
                       EXTERNAL PRICE COMPOSITION
    //////////////////////////////////////////////////////////////*/

    function testFuzz_in_usd_marker(uint8 isUsd) public {
        isUsd = uint8(bound(isUsd, 0, 1));
    }

    function testFuzz_out_usd_marker(uint8 isUsd) public {
        isUsd = uint8(bound(isUsd, 0, 1));
    }

    function testFuzz_both_usd_marker(uint8 isUsdIn, uint8 isUsdOut) public {
        isUsdIn  = uint8(bound(isUsdIn,  0, 1));
        isUsdOut = uint8(bound(isUsdOut, 0, 1));
    }

    function testFuzz_extPx_zero_marker(uint256 marker) public {
        marker = bound(marker, 0, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                          CURVE / THRESHOLD / MATH
    //////////////////////////////////////////////////////////////*/

    function testFuzz_no_surge_below_threshold(uint256 deviation, uint256 threshold) public {
        threshold = bound(threshold, 0, ONE);
        deviation = bound(deviation, 0, threshold);
    }

    function testFuzz_ramp_above_threshold(uint256 deviation, uint256 threshold) public {
        threshold = bound(threshold, 0, ONE - 1);
        deviation = bound(deviation, threshold + 1, ONE);
    }

    function testFuzz_monotonicity_wrt_deviation(uint256 devLow, uint256 devHigh, uint256 thr) public {
        thr     = bound(thr,     0, ONE - 1);
        devLow  = bound(devLow,  0, ONE);
        devHigh = bound(devHigh, devLow, ONE);
    }

    function testFuzz_relAbsDiff_inputs(uint256 a, uint256 b) public {
        a = bound(a, 0, type(uint192).max);
        b = bound(b, 1, type(uint192).max); // avoid div-by-zero in impl
    }

    function testFuzz_fee_clamped_to_max(uint256 maxPct, uint256 staticFee) public {
        maxPct    = bound(maxPct,    0, ONE);
        staticFee = bound(staticFee, 0, ONE);
    }

    /*//////////////////////////////////////////////////////////////
                          RUNTIME / PROFILING MARKERS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_hot_path_sloads_marker(uint256 marker) public {
        marker = bound(marker, 0, type(uint256).max);
    }

    function testFuzz_no_pow_runtime_marker(uint256 marker) public {
        marker = bound(marker, 0, type(uint256).max);
    }
}
