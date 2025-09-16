// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { PoolSwapParams, SwapKind } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { HyperSurgeHookMock } from "../../contracts/test/HyperSurgeHookMock.sol";
import { HyperSurgeHook } from "../../contracts/hooks-quantamm/HyperSurgeHook.sol";

/// @notice Drop-in replacement for the "find max deviation" fuzz tests.
/// This suite focuses on the surge-fee ramp behavior by fuzzing the
/// number of tokens and weights, while *overriding two prices* to
/// land (1) below threshold, (2) above cap, and (3) between.
/// It mirrors the helper-style used in the original tests and uses
/// the hook's ComputeSurgeFee pure entrypoint.
contract HyperSurgeFindMaxFeeRampTest is BaseVaultTest {
    using FixedPoint for uint256;
    using ArrayHelpers for *;

    uint256 constant DEFAULT_MAX_SURGE_FEE_PPM9 = 0.05e9; // 5%
    uint256 constant DEFAULT_THRESHOLD_PPM9 = 0.1e9; // 0.1%
    uint256 constant DEFAULT_CAP_DEV_PPM9 = 0.5e9; // 50%
    uint256 constant STATIC_SWAP_FEE = 1e16; // 1% (1e18 scale)
    uint256 constant WEIGHT_MIN = 1e16; // 1%

    HyperSurgeHookMock internal hook;

    function setUp() public override {
        super.setUp(); // vault

        // Vault is unused by the pure helper; supply a placeholder.
        hook = new HyperSurgeHookMock(
            IVault(vault),
            DEFAULT_MAX_SURGE_FEE_PPM9 * 1e9,
            DEFAULT_THRESHOLD_PPM9 * 1e9,
            DEFAULT_CAP_DEV_PPM9 * 1e9,
            "test"
        );
    }

    // Simple normalized weights with a 1% floor, deterministic from a seed.
    function _normWeights(uint8 n, uint256 seed) internal pure returns (uint256[] memory w) {
        require(uint256(n) * WEIGHT_MIN <= FixedPoint.ONE, "min too big");
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
        uint256 rem = FixedPoint.ONE - base;
        uint256 acc;
        for (uint8 i = 0; i < n; ++i) {
            uint256 share = (r[i] * rem) / sumR;
            w[i] = WEIGHT_MIN + share;
            acc += w[i];
        }
        if (acc != FixedPoint.ONE) {
            if (acc < FixedPoint.ONE) w[0] += (FixedPoint.ONE - acc);
            else {
                uint256 over = acc - FixedPoint.ONE;
                w[0] = w[0] > over + WEIGHT_MIN ? (w[0] - over) : WEIGHT_MIN;
            }
        }
    }

    // Pick balances in a safe magnitude to avoid underflow/overflow/zero-denominator.
    function _balances(uint8 n, uint256 seed) internal pure returns (uint256[] memory b) {
        b = new uint256[](n);
        for (uint8 i = 0; i < n; ++i) {
            // 1e12 .. 1e24
            uint256 x = 1e12 + (uint256(keccak256(abi.encode(seed, i))) % (1e24 - 1e12));
            b[i] = x;
        }
    } // Build a locals struct with two overridden prices targeting a desired deviation `D` (1e18 scale).

    // Choose deviation D, then set external px so that extPx = P / (1 + D)
    function fee_computeOraclePriceForDeviation(uint256 P, uint256 deviation) internal pure returns (uint256) {
        return P.divDown(FixedPoint.ONE + deviation);
    }

    function _getDefaultPoolDetails() internal pure returns (HyperSurgeHook.PoolDetails memory poolDetails) {
        // Configure NOISE lane (used when deviation does not worsen).
        poolDetails.noiseThresholdPercentage9 = uint32(DEFAULT_THRESHOLD_PPM9);
        poolDetails.noiseMaxSurgeFee9 = uint32(DEFAULT_MAX_SURGE_FEE_PPM9);
        poolDetails.noiseCapDeviationPercentage9 = uint32(DEFAULT_CAP_DEV_PPM9);

        // Set ARB lane too (not used here, but keep consistent).
        poolDetails.arbThresholdPercentage9 = uint32(DEFAULT_THRESHOLD_PPM9);
        poolDetails.arbMaxSurgeFee9 = uint32(DEFAULT_MAX_SURGE_FEE_PPM9);
        poolDetails.arbCapDeviationPercentage9 = uint32(DEFAULT_CAP_DEV_PPM9);

        poolDetails.numTokens = 2;
    }

    function _relAbsDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? (a - b).divDown(b) : (b - a).divDown(b);
    }

    // Replace any existing pair-spot helper with this:
    function _pairSpotFromBalancesWeights(
        uint256 bIn,
        uint256 wIn,
        uint256 bOut,
        uint256 wOut
    ) internal pure returns (uint256) {
        // If the denominator is zero, the pool price is zero.
        if (bIn == 0 || wOut == 0) return 0;
        return ((bOut * wIn) / wOut).divDown(bIn);
    }

    function _expectedFeeFromLocals(uint256 poolPx, uint256 oraclePrice) internal pure returns (uint256) {
        uint256 deviation = _relAbsDiff(poolPx, oraclePrice);

        uint256 threshold = DEFAULT_THRESHOLD_PPM9 * 1e9;
        uint256 capDev = DEFAULT_CAP_DEV_PPM9 * 1e9;
        uint256 maxPct = DEFAULT_MAX_SURGE_FEE_PPM9 * 1e9;

        if (deviation <= threshold) return STATIC_SWAP_FEE;

        uint256 span = capDev - threshold;
        uint256 norm = (deviation - threshold).divDown(span);
        if (norm > FixedPoint.ONE) norm = FixedPoint.ONE;

        uint256 incr = (maxPct - STATIC_SWAP_FEE).mulDown(norm);
        uint256 fee = STATIC_SWAP_FEE + incr;
        if (fee > maxPct) fee = maxPct;
        return fee;
    }

    /// 1) Below threshold ⇒ the dynamic fee must equal the static (minimum) fee.
    function testFuzz_feeBelowThreshold_min(uint8 nSeed, uint256 wSeed, uint256 bSeed, uint256 dSeed) public view {
        uint8 n = uint8(bound(nSeed, 2, 8));
        uint256[] memory w = _normWeights(n, wSeed);

        // Pick a pair i!=j.
        uint8 i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 1))), 0, n - 1));
        uint8 j = uint8(bound(uint256(keccak256(abi.encode(dSeed, 2))), 0, n - 1));
        if (j == i) j = (i + 1) % n;

        PoolSwapParams memory p; // zero-initialized; p.kind defaults to 0 (= EXACT_IN)
        p.kind = SwapKind.EXACT_IN; // keep before==after so we take the NOISE lane
        p.balancesScaled18 = _balances(n, bSeed);
        p.indexIn = i;
        p.indexOut = j;
        p.amountGivenScaled18 = 0;

        uint256 P = _pairSpotFromBalancesWeights(p.balancesScaled18[i], w[i], p.balancesScaled18[j], w[j]);

        vm.assume(P > 0);

        uint256 threshold = DEFAULT_THRESHOLD_PPM9;
        // target deviation in [0 .. threshold] (inclusive lower range)
        uint256 D = uint256(keccak256(abi.encode(dSeed))) % (threshold + 1);

        uint256 oraclePrice = fee_computeOraclePriceForDeviation(P, D);
        HyperSurgeHook.PoolDetails memory poolDetails = _getDefaultPoolDetails();

        (bool ok, uint256 fee) = hook.ComputeSurgeFee(p, poolDetails, STATIC_SWAP_FEE, w, 0, oraclePrice);
        assertTrue(ok, "compute must succeed");
        assertEq(fee, STATIC_SWAP_FEE, "below threshold must return static fee");
    }

    struct FeeAboveCapLocals {
        uint8 n;
        uint8 i;
        uint8 j;
        uint256[] w;
        uint256[] b;
        uint256 P;
        uint256 capDev;
        uint256 D;
        uint256 oraclePrice;
        uint256 extra;
        bool ok;
        uint256 fee;
        uint256 maxPct;
    }

    /// 2) Above cap deviation ⇒ the dynamic fee must equal the configured maximum.
    function testFuzz_feeAboveCap_max(uint8 nSeed, uint256 wSeed, uint256 bSeed, uint256 dSeed) public view {
        FeeAboveCapLocals memory locals;

        locals.n = uint8(bound(nSeed, 2, 8));
        locals.w = _normWeights(locals.n, wSeed);
        locals.b = _balances(locals.n, bSeed);

        locals.i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 3))), 0, locals.n - 1));
        locals.j = uint8(bound(uint256(keccak256(abi.encode(dSeed, 4))), 0, locals.n - 1));
        if (locals.j == locals.i) locals.j = (locals.i + 1) % locals.n;

        locals.P = _pairSpotFromBalancesWeights(
            locals.b[locals.i],
            locals.w[locals.i],
            locals.b[locals.j],
            locals.w[locals.j]
        );
        vm.assume(locals.P > 0);

        locals.capDev = DEFAULT_CAP_DEV_PPM9 * 1e9;

        // Choose a deviation D >= capDev (push comfortably above to avoid rounding back below).
        locals.extra = (FixedPoint.ONE - locals.capDev) / 4; // up to +25% beyond cap (bounded to keep pxOut > 0)
        locals.D = locals.capDev + (uint256(keccak256(abi.encode(dSeed, 5))) % (locals.extra + 1));

        uint256 oraclePrice = fee_computeOraclePriceForDeviation(locals.P, locals.D);
        HyperSurgeHook.PoolDetails memory poolDetails = _getDefaultPoolDetails();

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.balancesScaled18 = locals.b;
        p.indexIn = locals.i;
        p.indexOut = locals.j;
        p.amountGivenScaled18 = 0;

        (locals.ok, locals.fee) = hook.ComputeSurgeFee(p, poolDetails, STATIC_SWAP_FEE, locals.w, 0, oraclePrice);
        assertTrue(locals.ok, "compute must succeed");

        locals.maxPct = DEFAULT_MAX_SURGE_FEE_PPM9 * 1e9;
        assertEq(locals.fee, locals.maxPct, "above cap must return max fee");
    }

    struct FeeBetweenLinearLocals {
        uint8 n;
        uint8 i;
        uint8 j;
        uint256[] w;
        uint256[] b;
        uint256 P;
        uint256 capDev;
        uint256 D;
        uint256 oraclePrice;
        bool ok;
        uint256 fee;
        uint256 threshold;
        uint256 span;
    }

    /// 3) Between threshold and cap ⇒ the dynamic fee must be a linear ramp between static and max.
    function testFuzz_feeBetween_linear(uint8 nSeed, uint256 wSeed, uint256 bSeed, uint256 dSeed) public view {
        FeeBetweenLinearLocals memory locals;

        locals.n = uint8(bound(nSeed, 2, 8));
        locals.w = _normWeights(locals.n, wSeed);
        locals.b = _balances(locals.n, bSeed);

        locals.i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 6))), 0, locals.n - 1));
        locals.j = uint8(bound(uint256(keccak256(abi.encode(dSeed, 7))), 0, locals.n - 1));
        if (locals.j == locals.i) locals.j = (locals.i + 1) % locals.n;

        locals.P = _pairSpotFromBalancesWeights(
            locals.b[locals.i],
            locals.w[locals.i],
            locals.b[locals.j],
            locals.w[locals.j]
        );
        vm.assume(locals.P > 0);

        locals.threshold = DEFAULT_THRESHOLD_PPM9;
        locals.capDev = DEFAULT_CAP_DEV_PPM9;
        locals.span = locals.capDev - locals.threshold;

        // Target a deviation strictly inside (threshold, capDev):
        locals.D = locals.threshold + 1 + (uint256(keccak256(abi.encode(dSeed, 8))) % (locals.span - 1));

        locals.oraclePrice = fee_computeOraclePriceForDeviation(locals.P, locals.D);
        HyperSurgeHook.PoolDetails memory poolDetails = _getDefaultPoolDetails();

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.balancesScaled18 = locals.b;
        p.indexIn = locals.i;
        p.indexOut = locals.j;
        p.amountGivenScaled18 = 0;

        (locals.ok, locals.fee) = hook.ComputeSurgeFee(
            p,
            poolDetails,
            STATIC_SWAP_FEE,
            locals.w,
            0,
            locals.oraclePrice
        );
        assertTrue(locals.ok, "compute must succeed");

        // Compute expected with identical rounding.
        uint256 expected = _expectedFeeFromLocals(locals.P, locals.oraclePrice);
        assertEq(locals.fee, expected, "fee must follow linear ramp between min and max");
    }

    function _ppm9To1e18(uint32 v) internal pure returns (uint256) {
        // 1 ppm9 unit = 1e-9 in 1e18 fixed => multiply by 1e9
        return uint256(v) * 1e9;
    }

    // Expected fee with custom lane parameters (all in ppm9 for the lane fields).
    function _expectedFeeWithParams(
        uint256 poolPx,
        uint256 oraclePrice,
        uint256 staticSwapFee,
        uint32 thresholdPPM9,
        uint32 capDevPPM9,
        uint32 maxFeePPM9
    ) internal pure returns (uint256) {
        uint256 deviation = _relAbsDiff(poolPx, oraclePrice);

        uint256 threshold = _ppm9To1e18(thresholdPPM9);
        uint256 capDev = _ppm9To1e18(capDevPPM9);
        uint256 maxPct = _ppm9To1e18(maxFeePPM9);

        if (deviation <= threshold) return staticSwapFee;

        uint256 span = capDev - threshold;
        uint256 norm = (deviation - threshold).divDown(span);
        if (norm > FixedPoint.ONE) norm = FixedPoint.ONE;

        uint256 incr = (maxPct - staticSwapFee).mulDown(norm);
        uint256 fee = staticSwapFee + incr;
        if (fee > maxPct) fee = maxPct;
        return fee;
    }

    struct MonotonicInDeviationLocals {
        uint8 n;
        uint8 i;
        uint8 j;
        uint256 deviation;
        uint256 capDev1e18;
        uint256 price;
        uint256 expected;
        uint256 oraclePrice;
        bool ok;
        uint256 fee;
    }

    /// Monotonicity: if the measured deviation increases, the fee must not decrease.
    function testFuzz_feeMonotonicInDeviation(
        uint8 nSeed,
        uint256 wSeed,
        uint256 bSeed,
        uint256 dSeed1,
        uint256 dSeed2
    ) public view {
        MonotonicInDeviationLocals memory locals;
        locals.n = uint8(bound(nSeed, 2, 8));
        uint256[] memory w = _normWeights(locals.n, wSeed);
        uint256[] memory b = _balances(locals.n, bSeed);

        locals.i = uint8(bound(uint256(keccak256(abi.encode(dSeed1, 1))), 0, locals.n - 1));
        locals.j = (locals.i + 1 + uint8(bound(uint256(keccak256(abi.encode(dSeed1, 2))), 0, locals.n - 2))) % locals.n;

        locals.price = _pairSpotFromBalancesWeights(b[locals.i], w[locals.i], b[locals.j], w[locals.j]);
        vm.assume(locals.price > 0);

        locals.capDev1e18 = DEFAULT_CAP_DEV_PPM9;
        // Pick two target deviations in [0, capDev*3/2]
        uint256 D1 = uint256(keccak256(abi.encode(dSeed1))) % (locals.capDev1e18 + locals.capDev1e18 / 2 + 1);
        uint256 D2raw = uint256(keccak256(abi.encode(dSeed2))) % (locals.capDev1e18 + locals.capDev1e18 / 2 + 1);
        (locals.deviation, locals.expected) = D1 <= D2raw ? (D1, D2raw) : (D2raw, D1);

        (locals.oraclePrice) = fee_computeOraclePriceForDeviation(locals.price, locals.deviation);
        uint256 oraclePrice2 = fee_computeOraclePriceForDeviation(locals.price, locals.expected);

        HyperSurgeHook.PoolDetails memory poolDetails = _getDefaultPoolDetails();

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.balancesScaled18 = b;
        p.indexIn = locals.i;
        p.indexOut = locals.j;
        p.amountGivenScaled18 = 0;

        (locals.ok, locals.fee) = hook.ComputeSurgeFee(p, poolDetails, STATIC_SWAP_FEE, w, 0, locals.oraclePrice);
        (, uint256 fee2) = hook.ComputeSurgeFee(p, poolDetails, STATIC_SWAP_FEE, w, 0, oraclePrice2);

        assertLe(locals.fee, fee2, "fee must be non-decreasing with deviation");
    }

    struct SwapSymmetryLocals {
        uint256[] w;
        uint8 i;
        uint8 j;
        uint256 P;
        uint256 oraclePrice;
        bool okA;
        uint256 feeA;
        uint256 devA;
        bool okB;
        uint256 feeB;
        uint256 devB;
    }

    function testFuzz_swapSymmetry_sameLaneParams(uint8 n, uint256 wSeed, uint256 bSeed, uint256 dSeed) public view {
        SwapSymmetryLocals memory locals;

        n = uint8(bound(n, 2, 8));
        locals.w = _normWeights(n, wSeed);

        locals.i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 1))), 0, n - 1));
        locals.j = (locals.i + 1 + uint8(bound(uint256(keccak256(abi.encode(dSeed, 2))), 0, n - 2))) % n;

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.balancesScaled18 = _balances(n, bSeed);
        p.indexIn = locals.i;
        p.indexOut = locals.j;
        p.amountGivenScaled18 = 0;

        // Pool spot for (i -> j) using the same rounding/staging as the hook
        uint256 P_ij = _pairSpotFromBalancesWeights(
            p.balancesScaled18[locals.i],
            locals.w[locals.i],
            p.balancesScaled18[locals.j],
            locals.w[locals.j]
        );
        vm.assume(P_ij > 0);

        // Pick some deviation (bounded safely below 1 to keep pxOut > 0 in _localsForDeviation)
        uint256 capDev = DEFAULT_CAP_DEV_PPM9;
        uint256 D = uint256(keccak256(abi.encode(dSeed))) % (capDev + capDev / 2 + 1);

        locals.oraclePrice = fee_computeOraclePriceForDeviation(P_ij, D);

        HyperSurgeHook.PoolDetails memory poolDetails = _getDefaultPoolDetails();

        // Orientation A (i -> j)
        (locals.okA, locals.feeA) = hook.ComputeSurgeFee(
            p,
            poolDetails,
            STATIC_SWAP_FEE,
            locals.w,
            0,
            locals.oraclePrice
        );
        // Orientation B (j -> i)
        p.balancesScaled18 = [p.balancesScaled18[1], p.balancesScaled18[0]].toMemoryArray();
        (locals.okB, locals.feeB) = hook.ComputeSurgeFee(
            p,
            poolDetails,
            STATIC_SWAP_FEE,
            [locals.w[1], locals.w[0]].toMemoryArray(),
            0,
            FixedPoint.ONE.divDown(locals.oraclePrice)
        );
        assertTrue(locals.okA && locals.okB, "compute must succeed");

        // Measure deviations exactly like the hook does in each orientation
        locals.devA = _relAbsDiff(P_ij, locals.oraclePrice);

        // Compute the swapped pool spot with the SAME rounding (don’t assume 1/P)
        uint256 P_ji = _pairSpotFromBalancesWeights(
            p.balancesScaled18[1],
            locals.w[1],
            p.balancesScaled18[0],
            locals.w[0]
        );
        locals.devB = _relAbsDiff(P_ji, FixedPoint.ONE.divDown(locals.oraclePrice));

        // Correct directional assertion:
        if (locals.devA > locals.devB) {
            // allow 1 wei to avoid knife-edge floor rounding flips
            assertGe(locals.feeA + 1, locals.feeB, "larger deviation must not yield smaller fee (A vs B)");
        } else if (locals.devB > locals.devA) {
            assertGe(locals.feeB + 1, locals.feeA, "larger deviation must not yield smaller fee (B vs A)");
        } else {
            assertApproxEqAbs(locals.feeA, locals.feeB, 1, "equal deviations should give equal fees (1 wei)");
        }
    }

    struct FeeRespectedLocals {
        uint8 n;
        uint8 i;
        uint8 j;
        uint256 deviation;
        uint256 capDev1e18;
        uint256 price;
        uint256 expected;
        uint256 oraclePrice;
        bool ok;
        uint256 fee;
    }

    /// Static fee fuzz: for arbitrary static fees (<= max), the hook's result must match the expected ramp.
    function testFuzz_staticFeeRespected(
        uint8 nSeed,
        uint256 wSeed,
        uint256 bSeed,
        uint256 dSeed,
        uint64 staticFeeSeed
    ) public view {
        FeeRespectedLocals memory locals;
        locals.n = uint8(bound(nSeed, 2, 8));
        uint256[] memory w = _normWeights(locals.n, wSeed);
        uint256[] memory b = _balances(locals.n, bSeed);

        locals.i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 1))), 0, locals.n - 1));
        locals.j = (locals.i + 1 + uint8(bound(uint256(keccak256(abi.encode(dSeed, 2))), 0, locals.n - 2))) % locals.n;

        locals.price = _pairSpotFromBalancesWeights(b[locals.i], w[locals.i], b[locals.j], w[locals.j]);
        vm.assume(locals.price > 0);

        locals.capDev1e18 = DEFAULT_CAP_DEV_PPM9;
        locals.deviation = uint256(keccak256(abi.encode(dSeed))) % (locals.capDev1e18 + locals.capDev1e18 / 2 + 1);

        (locals.oraclePrice) = fee_computeOraclePriceForDeviation(locals.price, locals.deviation);

        // Choose static fee in [0 .. maxPct]
        uint256 maxPct = DEFAULT_MAX_SURGE_FEE_PPM9;
        uint256 staticFee = uint256(staticFeeSeed) % (maxPct + 1);

        HyperSurgeHook.PoolDetails memory poolDetails = _getDefaultPoolDetails();

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.balancesScaled18 = b;
        p.indexIn = locals.i;
        p.indexOut = locals.j;
        p.amountGivenScaled18 = 0;

        (locals.ok, locals.fee) = hook.ComputeSurgeFee(p, poolDetails, staticFee, w, 0, locals.oraclePrice);
        assertTrue(locals.ok, "compute must succeed");

        locals.expected = _expectedFeeWithParams(
            _pairSpotFromBalancesWeights(b[locals.i], w[locals.i], b[locals.j], w[locals.j]),
            locals.oraclePrice,
            staticFee,
            uint32(DEFAULT_THRESHOLD_PPM9),
            uint32(DEFAULT_CAP_DEV_PPM9),
            uint32(DEFAULT_MAX_SURGE_FEE_PPM9)
        );
        assertEq(locals.fee, locals.expected, "fee must respect custom static fee & ramp");
    }

    struct LaneParametersLocals {
        uint8 n;
        uint8 i;
        uint8 j;
        uint256 deviation;
        uint256 capDev1e18;
        uint256 price;
        uint256 expected;
        uint256 oraclePrice;
        bool ok;
        uint256 fee;
    }

    /// Replacement for the old "swap symmetry" test.
    /// Correct property: whichever orientation produces the larger measured deviation
    /// must not have a smaller fee (monotonic ramp).
    function testFuzz_directionalOrdering_sameLaneParams(
        uint8 nSeed,
        uint256 wSeed,
        uint256 bSeed,
        uint256 dSeed
    ) public view {
        LaneParametersLocals memory locals;
        locals.n = uint8(bound(nSeed, 2, 8));
        uint256[] memory w = _normWeights(locals.n, wSeed);
        uint256[] memory b = _balances(locals.n, bSeed);

        locals.i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 1))), 0, locals.n - 1));
        locals.j = (locals.i + 1 + uint8(bound(uint256(keccak256(abi.encode(dSeed, 2))), 0, locals.n - 2))) % locals.n;

        locals.price = _pairSpotFromBalancesWeights(b[locals.i], w[locals.i], b[locals.j], w[locals.j]);
        vm.assume(locals.price > 0);

        locals.capDev1e18 = DEFAULT_CAP_DEV_PPM9;
        locals.deviation = uint256(keccak256(abi.encode(dSeed))) % (locals.capDev1e18 + locals.capDev1e18 / 2 + 1);

        (locals.oraclePrice) = fee_computeOraclePriceForDeviation(locals.price, locals.deviation);

        // Orientation A (i -> j)
        HyperSurgeHook.PoolDetails memory poolDetails = _getDefaultPoolDetails();

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.balancesScaled18 = b;
        p.indexIn = locals.i;
        p.indexOut = locals.j;
        p.amountGivenScaled18 = 0;
        (locals.ok, locals.fee) = hook.ComputeSurgeFee(p, poolDetails, STATIC_SWAP_FEE, w, 0, locals.oraclePrice);

        // Orientation B (j -> i) with inverted external prices
        p.balancesScaled18 = [b[1], b[0]].toMemoryArray();
        (bool okB, uint256 feeB) = hook.ComputeSurgeFee(
            p,
            poolDetails,
            STATIC_SWAP_FEE,
            [w[1], w[0]].toMemoryArray(),
            0,
            FixedPoint.ONE.divDown(locals.oraclePrice)
        );
        assertTrue(locals.ok && okB, "compute must succeed");

        // Measure deviations exactly like the hook does
        uint256 devA = _relAbsDiff(locals.price, locals.oraclePrice);
        uint256 devB = _relAbsDiff(
            _pairSpotFromBalancesWeights(b[1], w[1], b[0], w[0]),
            FixedPoint.ONE.divDown(locals.oraclePrice)
        ); // equals 1/P vs 1/ext due to swap

        // Directional ordering with ±1 wei tolerance for knife-edge rounding
        if (devA > devB) {
            assertGe(locals.fee + 1, feeB, "larger deviation must not yield smaller fee (A vs B)");
        } else if (devB > devA) {
            assertGe(feeB + 1, locals.fee, "larger deviation must not yield smaller fee (B vs A)");
        } else {
            assertApproxEqAbs(locals.fee, feeB, 1, "equal deviations should give equal fees (around1 wei)");
        }
    }

    struct ThresholdAndCap {
        uint8 n;
        uint8 i;
        uint8 j;
        uint256[] w;
        uint256[] b;
        uint256 P;
        uint256 threshold;
        uint256 capDev;
        int8[5] offs;
        uint256 Dt;
        uint256 oraclePriceT;
        uint256 extT;
        uint256 expectedT;
        uint256 Dc;
        uint256 oraclePriceC;
        uint256 expectedC;
    }

    /// Boundary behavior: probe exactly at threshold/cap and within ±2 wei to ensure
    /// step/continuity matches the ramp and clamping, with hook-style rounding.
    function testFuzz_boundaryBehavior_thresholdAndCap(
        uint8 nSeed,
        uint256 wSeed,
        uint256 bSeed,
        uint256 dSeed
    ) public view {
        ThresholdAndCap memory locals;
        locals.n = uint8(bound(nSeed, 2, 8));
        locals.w = _normWeights(locals.n, wSeed);
        locals.b = _balances(locals.n, bSeed);

        locals.i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 1))), 0, locals.n - 1));
        locals.j = (locals.i + 1 + uint8(bound(uint256(keccak256(abi.encode(dSeed, 2))), 0, locals.n - 2))) % locals.n;

        locals.P = _pairSpotFromBalancesWeights(
            locals.b[locals.i],
            locals.w[locals.i],
            locals.b[locals.j],
            locals.w[locals.j]
        );
        vm.assume(locals.P > 0);

        locals.threshold = DEFAULT_THRESHOLD_PPM9;
        locals.capDev = DEFAULT_CAP_DEV_PPM9;

        locals.offs = [-2, -1, 0, 1, 2];

        for (uint256 k = 0; k < locals.offs.length; ++k) {
            // --- Around THRESHOLD ---
            if (locals.offs[k] < 0) {
                uint256 delta = uint256(uint8(-locals.offs[k]));
                locals.Dt = locals.threshold > delta ? locals.threshold - delta : 0;
            } else {
                locals.Dt = locals.threshold + uint256(uint8(locals.offs[k]));
            }
            (locals.oraclePriceT) = fee_computeOraclePriceForDeviation(locals.P, locals.Dt);
            HyperSurgeHook.PoolDetails memory poolDetails = _getDefaultPoolDetails();

            PoolSwapParams memory p;
            p.kind = SwapKind.EXACT_IN;
            p.balancesScaled18 = locals.b;
            p.indexIn = locals.i;
            p.indexOut = locals.j;
            p.amountGivenScaled18 = 0;

            (bool okT, uint256 feeT) = hook.ComputeSurgeFee(
                p,
                poolDetails,
                STATIC_SWAP_FEE,
                locals.w,
                0,
                locals.oraclePriceT
            );
            assertTrue(okT, "compute must succeed (threshold ring)");

            locals.expectedT = _expectedFeeFromLocals(locals.P, locals.oraclePriceT);
            // Exact match to the hook’s rounding-based expected value
            assertEq(feeT, locals.expectedT, "threshold ring fee mismatch");

            // --- Around CAP ---
            if (locals.offs[k] < 0) {
                uint256 deltaC = uint256(uint8(-locals.offs[k]));
                locals.Dc = locals.capDev > deltaC ? locals.capDev - deltaC : 0;
            } else {
                // guard upper bound to avoid overflow in _localsForDeviation denominator
                uint256 room = FixedPoint.ONE > locals.capDev ? (FixedPoint.ONE - locals.capDev) : 0;
                uint256 add = uint256(uint8(locals.offs[k]));
                locals.Dc = locals.capDev + (add <= room ? add : room);
            }
            (locals.oraclePriceC) = fee_computeOraclePriceForDeviation(locals.P, locals.Dc);
            (bool okC, uint256 feeC) = hook.ComputeSurgeFee(
                p,
                poolDetails,
                STATIC_SWAP_FEE,
                locals.w,
                0,
                locals.oraclePriceC
            );

            assertTrue(okC, "compute must succeed (cap ring)");

            locals.expectedC = _expectedFeeFromLocals(locals.P, locals.oraclePriceC);
            assertEq(feeC, locals.expectedC, "cap ring fee mismatch");
        }
    }

    struct BalanceScalingInvarianceLocals {
        uint8 n;
        uint8 i;
        uint8 j;
        uint256[] w;
        uint256[] b;
        uint256 P;
        uint256 capDev;
        uint256 D;
        uint256 oraclePrice;
        uint256 fee1;
        uint256 fee2;
        uint256 k;
    }

    /// Balance scaling invariance (unchanged idea, included for completeness).
    function testFuzz_balanceScalingInvariance(
        uint8 nSeed,
        uint256 wSeed,
        uint256 bSeed,
        uint256 dSeed,
        uint64 scaleSeed
    ) public view {
        BalanceScalingInvarianceLocals memory locals;

        locals.n = uint8(bound(nSeed, 2, 8));
        locals.w = _normWeights(locals.n, wSeed);
        locals.b = _balances(locals.n, bSeed);

        locals.i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 1))), 0, locals.n - 1));
        locals.j = (locals.i + 1 + uint8(bound(uint256(keccak256(abi.encode(dSeed, 2))), 0, locals.n - 2))) % locals.n;

        locals.P = _pairSpotFromBalancesWeights(
            locals.b[locals.i],
            locals.w[locals.i],
            locals.b[locals.j],
            locals.w[locals.j]
        );
        vm.assume(locals.P > 0);

        locals.capDev = DEFAULT_CAP_DEV_PPM9;
        locals.D = uint256(keccak256(abi.encode(dSeed))) % (locals.capDev + locals.capDev / 3 + 1);

        locals.oraclePrice = fee_computeOraclePriceForDeviation(locals.P, locals.D);

        HyperSurgeHook.PoolDetails memory poolDetails = _getDefaultPoolDetails();

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.balancesScaled18 = locals.b;
        p.indexIn = locals.i;
        p.indexOut = locals.j;
        p.amountGivenScaled18 = 0;

        (, locals.fee1) = hook.ComputeSurgeFee(p, poolDetails, STATIC_SWAP_FEE, locals.w, 0, locals.oraclePrice);

        locals.k = 1 + (uint256(scaleSeed) % 1_000_000_000); // [1 .. 1e9]

        p.balancesScaled18 = [locals.b[locals.i] * locals.k, locals.b[locals.j] * locals.k].toMemoryArray();

        (, locals.fee2) = hook.ComputeSurgeFee(
            p,
            poolDetails,
            STATIC_SWAP_FEE,
            [locals.w[locals.i] * locals.k, locals.w[locals.j] * locals.k].toMemoryArray(),
            0,
            locals.oraclePrice
        );

        assertApproxEqAbs(locals.fee1, locals.fee2, 1, "fee must be invariant to balance scaling");
    }

    struct ExactOutArbLaneBoundaryLocals {
        uint8 n;
        uint8 i;
        uint8 j;
        uint32 thrOK;
        uint32 capOK;
        uint32 maxOK;
        uint256 thr;
        uint256 cap;
        uint256 maxFee;
        uint256 span;
        uint256 D;
        uint256 P;
        uint256 pxIn;
        uint256 pxOut;
        uint256 incMax;
        uint256 numer;
        uint256 norm;
        uint256 inc;
        uint256 want;
        uint256 got;
        uint256 wIn;
        uint256 wOut;
        uint256 bIn;
        uint256 bOut;
        uint256 rIn;
        uint256 rOut;
        uint256 feeA;
        uint256 feeB;
        uint256 denom;
        uint256 extPx;
    }
}
