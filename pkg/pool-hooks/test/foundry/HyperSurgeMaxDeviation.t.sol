// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { HyperSurgeHookMock } from "../../contracts/test/HyperSurgeHookMock.sol";
import { PoolSwapParams, SwapKind } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";

/// @notice Drop-in replacement for the "find max deviation" fuzz tests.
/// This suite focuses on the surge-fee ramp behavior by fuzzing the
/// number of tokens and weights, while *overriding two prices* to
/// land (1) below threshold, (2) above cap, and (3) between.
/// It mirrors the helper-style used in the original tests and uses
/// the hook's ComputeSurgeFee pure entrypoint.
contract HyperSurgeFindMaxFeeRampTest is BaseVaultTest {
    uint256 constant ONE = 1e18;
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
        require(uint256(n) * WEIGHT_MIN <= ONE, "min too big");
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
        uint256 rem = ONE - base;
        uint256 acc;
        for (uint8 i = 0; i < n; ++i) {
            uint256 share = (r[i] * rem) / sumR;
            w[i] = WEIGHT_MIN + share;
            acc += w[i];
        }
        if (acc != ONE) {
            if (acc < ONE) w[0] += (ONE - acc);
            else {
                uint256 over = acc - ONE;
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

    // We set pxIn = 1e18 and pxOut so that extPx = pxOut/pxIn = P / (1 + D), using the same divDown rounding.
    function _localsForDeviation(
        uint256 P, // pair spot (1e18)
        uint256 D // target deviation (1e18)
    ) internal pure returns (uint256 pxIn, uint256 pxOut) {
        pxIn = ONE;
        // extPx = P / (1 + D)  (use hook-style rounding)
        pxOut = _divDown(P, ONE + D);
    }

    // Instantiate ComputeSurgeFeeLocals with common pool details (NOISE lane),
    // with b/w and px values provided by the caller.
    function _makeLocals(
        uint256 bIn,
        uint256 wIn,
        uint256 bOut,
        uint256 wOut,
        uint256 pxIn,
        uint256 pxOut
    ) internal pure returns (HyperSurgeHookMock.ComputeSurgeFeeLocals memory L) {
        L.bIn = bIn;
        L.wIn = wIn;
        L.bOut = bOut;
        L.wOut = wOut;
        L.pxIn = pxIn;
        L.pxOut = pxOut;

        // Configure NOISE lane (used when deviation does not worsen).
        L.poolDetails.noiseThresholdPercentage9 = uint32(DEFAULT_THRESHOLD_PPM9);
        L.poolDetails.noiseMaxSurgeFee9 = uint32(DEFAULT_MAX_SURGE_FEE_PPM9);
        L.poolDetails.noiseCapDeviationPercentage9 = uint32(DEFAULT_CAP_DEV_PPM9);

        // Set ARB lane too (not used here, but keep consistent).
        L.poolDetails.arbThresholdPercentage9 = uint32(DEFAULT_THRESHOLD_PPM9);
        L.poolDetails.arbMaxSurgeFee9 = uint32(DEFAULT_MAX_SURGE_FEE_PPM9);
        L.poolDetails.arbCapDeviationPercentage9 = uint32(DEFAULT_CAP_DEV_PPM9);
    }

    // 1e18 fixed-point helpers identical to Balancer's FixedPoint
    function _mulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / 1e18;
    }

    function _divDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * 1e18) / b;
    }

    function _relAbsDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? _divDown(a - b, b) : _divDown(b - a, b);
    }

    // Replace any existing pair-spot helper with this:
    function _pairSpotFromBalancesWeights(
        uint256 bIn,
        uint256 wIn,
        uint256 bOut,
        uint256 wOut
    ) internal pure returns (uint256) {
        uint256 num = _mulDown(bOut, wIn);
        uint256 den = _mulDown(bIn, wOut);
        if (den == 0) return 0;
        return _divDown(num, den);
    }

    function _expectedFeeFromLocals(uint256 poolPx, uint256 pxIn, uint256 pxOut) internal pure returns (uint256) {
        uint256 extPx = _divDown(pxOut, pxIn); // identical to hook’s locals.extPx
        uint256 deviation = _relAbsDiff(poolPx, extPx);

        uint256 threshold = DEFAULT_THRESHOLD_PPM9 * 1e9;
        uint256 capDev = DEFAULT_CAP_DEV_PPM9 * 1e9;
        uint256 maxPct = DEFAULT_MAX_SURGE_FEE_PPM9 * 1e9;

        if (deviation <= threshold) return STATIC_SWAP_FEE;

        uint256 span = capDev - threshold;
        uint256 norm = _divDown(deviation - threshold, span);
        if (norm > ONE) norm = ONE;

        uint256 incr = _mulDown(maxPct - STATIC_SWAP_FEE, norm);
        uint256 fee = STATIC_SWAP_FEE + incr;
        if (fee > maxPct) fee = maxPct;
        return fee;
    }


    /// 1) Below threshold ⇒ the dynamic fee must equal the static (minimum) fee.
    function testFuzz_feeBelowThreshold_min(uint8 nSeed, uint256 wSeed, uint256 bSeed, uint256 dSeed) public view {
        uint8 n = uint8(bound(nSeed, 2, 8));
        uint256[] memory w = _normWeights(n, wSeed);
        uint256[] memory b = _balances(n, bSeed);

        // Pick a pair i!=j.
        uint8 i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 1))), 0, n - 1));
        uint8 j = uint8(bound(uint256(keccak256(abi.encode(dSeed, 2))), 0, n - 1));
        if (j == i) j = (i + 1) % n;

        uint256 P = _pairSpotFromBalancesWeights(b[i], w[i], b[j], w[j]);

        vm.assume(P > 0);

        uint256 threshold = DEFAULT_THRESHOLD_PPM9;
        // target deviation in [0 .. threshold] (inclusive lower range)
        uint256 D = uint256(keccak256(abi.encode(dSeed))) % (threshold + 1);

        (uint256 pxIn, uint256 pxOut) = _localsForDeviation(P, D);
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory L = _makeLocals(b[i], w[i], b[j], w[j], pxIn, pxOut);

        PoolSwapParams memory p; // zero-initialized; p.kind defaults to 0 (= EXACT_IN)
        p.kind = SwapKind.EXACT_IN; // keep before==after so we take the NOISE lane

        (bool ok, uint256 fee) = hook.ComputeSurgeFee(L, p, STATIC_SWAP_FEE);
        assertTrue(ok, "compute must succeed");
        assertEq(fee, STATIC_SWAP_FEE, "below threshold must return static fee");
    }

    /// 2) Above cap deviation ⇒ the dynamic fee must equal the configured maximum.
    function testFuzz_feeAboveCap_max(uint8 nSeed, uint256 wSeed, uint256 bSeed, uint256 dSeed) public view {
        uint8 n = uint8(bound(nSeed, 2, 8));
        uint256[] memory w = _normWeights(n, wSeed);
        uint256[] memory b = _balances(n, bSeed);

        uint8 i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 3))), 0, n - 1));
        uint8 j = uint8(bound(uint256(keccak256(abi.encode(dSeed, 4))), 0, n - 1));
        if (j == i) j = (i + 1) % n;

        uint256 P = _pairSpotFromBalancesWeights(b[i], w[i], b[j], w[j]);
        vm.assume(P > 0);

        uint256 capDev = DEFAULT_CAP_DEV_PPM9 * 1e9;

        // Choose a deviation D >= capDev (push comfortably above to avoid rounding back below).
        uint256 extra = (ONE - capDev) / 4; // up to +25% beyond cap (bounded to keep pxOut > 0)
        uint256 D = capDev + (uint256(keccak256(abi.encode(dSeed, 5))) % (extra + 1));

        (uint256 pxIn, uint256 pxOut) = _localsForDeviation(P, D);
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory L = _makeLocals(b[i], w[i], b[j], w[j], pxIn, pxOut);

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;

        (bool ok, uint256 fee) = hook.ComputeSurgeFee(L, p, STATIC_SWAP_FEE);
        assertTrue(ok, "compute must succeed");

        uint256 maxPct = DEFAULT_MAX_SURGE_FEE_PPM9 * 1e9;
        assertEq(fee, maxPct, "above cap must return max fee");
    }

    /// 3) Between threshold and cap ⇒ the dynamic fee must be a linear ramp between static and max.
    function testFuzz_feeBetween_linear(uint8 nSeed, uint256 wSeed, uint256 bSeed, uint256 dSeed) public view {
        uint8 n = uint8(bound(nSeed, 2, 8));
        uint256[] memory w = _normWeights(n, wSeed);
        uint256[] memory b = _balances(n, bSeed);

        uint8 i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 6))), 0, n - 1));
        uint8 j = uint8(bound(uint256(keccak256(abi.encode(dSeed, 7))), 0, n - 1));
        if (j == i) j = (i + 1) % n;

        uint256 P = _pairSpotFromBalancesWeights(b[i], w[i], b[j], w[j]);
        vm.assume(P > 0);

        uint256 threshold = DEFAULT_THRESHOLD_PPM9;
        uint256 capDev = DEFAULT_CAP_DEV_PPM9;
        uint256 span = capDev - threshold;

        // Target a deviation strictly inside (threshold, capDev):
        uint256 D = threshold + 1 + (uint256(keccak256(abi.encode(dSeed, 8))) % (span - 1));

        (uint256 pxIn, uint256 pxOut) = _localsForDeviation(P, D);
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory L = _makeLocals(b[i], w[i], b[j], w[j], pxIn, pxOut);

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;

        (bool ok, uint256 fee) = hook.ComputeSurgeFee(L, p, STATIC_SWAP_FEE);
        assertTrue(ok, "compute must succeed");

        // Compute expected with identical rounding.
        uint256 expected = _expectedFeeFromLocals(P, pxIn, pxOut);
        assertEq(fee, expected, "fee must follow linear ramp between min and max");
    }

    function _ppm9To1e18(uint32 v) internal pure returns (uint256) {
        // 1 ppm9 unit = 1e-9 in 1e18 fixed => multiply by 1e9
        return uint256(v) * 1e9;
    }

    // Expected fee with custom lane parameters (all in ppm9 for the lane fields).
    function _expectedFeeWithParams(
        uint256 poolPx,
        uint256 pxIn,
        uint256 pxOut,
        uint256 staticSwapFee,
        uint32 thresholdPPM9,
        uint32 capDevPPM9,
        uint32 maxFeePPM9
    ) internal pure returns (uint256) {
        uint256 extPx = _divDown(pxOut, pxIn);
        uint256 deviation = _relAbsDiff(poolPx, extPx);

        uint256 threshold = _ppm9To1e18(thresholdPPM9);
        uint256 capDev = _ppm9To1e18(capDevPPM9);
        uint256 maxPct = _ppm9To1e18(maxFeePPM9);

        if (deviation <= threshold) return staticSwapFee;

        uint256 span = capDev - threshold;
        uint256 norm = _divDown(deviation - threshold, span);
        if (norm > ONE) norm = ONE;

        uint256 incr = _mulDown(maxPct - staticSwapFee, norm);
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
        uint256 pxIn;
        uint256 pxOut;
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

        (locals.pxIn, locals.pxOut) = _localsForDeviation(locals.price, locals.deviation);
        (uint256 pxIn2, uint256 pxOut2) = _localsForDeviation(locals.price, locals.expected);

        HyperSurgeHookMock.ComputeSurgeFeeLocals memory L1 = _makeLocals(
            b[locals.i],
            w[locals.i],
            b[locals.j],
            w[locals.j],
            locals.pxIn,
            locals.pxOut
        );
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory L2 = _makeLocals(
            b[locals.i],
            w[locals.i],
            b[locals.j],
            w[locals.j],
            pxIn2,
            pxOut2
        );

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;

        (locals.ok, locals.fee) = hook.ComputeSurgeFee(L1, p, STATIC_SWAP_FEE);
        (, uint256 fee2) = hook.ComputeSurgeFee(L2, p, STATIC_SWAP_FEE);

        assertLe(locals.fee, fee2, "fee must be non-decreasing with deviation");
    }

    function testFuzz_swapSymmetry_sameLaneParams(
        uint8 nSeed,
        uint256 wSeed,
        uint256 bSeed,
        uint256 dSeed
    ) public view {
        uint8 n = uint8(bound(nSeed, 2, 8));
        uint256[] memory w = _normWeights(n, wSeed);
        uint256[] memory b = _balances(n, bSeed);

        uint8 i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 1))), 0, n - 1));
        uint8 j = (i + 1 + uint8(bound(uint256(keccak256(abi.encode(dSeed, 2))), 0, n - 2))) % n;

        // Pool spot for (i -> j) using the same rounding/staging as the hook
        uint256 P_ij = _pairSpotFromBalancesWeights(b[i], w[i], b[j], w[j]);
        vm.assume(P_ij > 0);

        // Pick some deviation (bounded safely below 1 to keep pxOut > 0 in _localsForDeviation)
        uint256 capDev = DEFAULT_CAP_DEV_PPM9;
        uint256 D = uint256(keccak256(abi.encode(dSeed))) % (capDev + capDev / 2 + 1);

        (uint256 pxIn, uint256 pxOut) = _localsForDeviation(P_ij, D);

        // Orientation A (i -> j)
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory LA = _makeLocals(b[i], w[i], b[j], w[j], pxIn, pxOut);
        // Orientation B (j -> i) with inverted external prices
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory LB = _makeLocals(b[j], w[j], b[i], w[i], pxOut, pxIn);

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;

        (bool okA, uint256 feeA) = hook.ComputeSurgeFee(LA, p, STATIC_SWAP_FEE);
        (bool okB, uint256 feeB) = hook.ComputeSurgeFee(LB, p, STATIC_SWAP_FEE);
        assertTrue(okA && okB, "compute must succeed");

        // Measure deviations exactly like the hook does in each orientation
        uint256 extA = _divDown(LA.pxOut, LA.pxIn);
        uint256 devA = _relAbsDiff(P_ij, extA);

        // Compute the swapped pool spot with the SAME rounding (don’t assume 1/P)
        uint256 P_ji = _pairSpotFromBalancesWeights(LB.bIn, LB.wIn, LB.bOut, LB.wOut);
        uint256 extB = _divDown(LB.pxOut, LB.pxIn);
        uint256 devB = _relAbsDiff(P_ji, extB);

        // Correct directional assertion:
        if (devA > devB) {
            // allow 1 wei to avoid knife-edge floor rounding flips
            assertGe(feeA + 1, feeB, "larger deviation must not yield smaller fee (A vs B)");
        } else if (devB > devA) {
            assertGe(feeB + 1, feeA, "larger deviation must not yield smaller fee (B vs A)");
        } else {
            assertApproxEqAbs(feeA, feeB, 1, "equal deviations should give equal fees (1 wei)");
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
        uint256 pxIn;
        uint256 pxOut;
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

        (locals.pxIn, locals.pxOut) = _localsForDeviation(locals.price, locals.deviation);

        // Choose static fee in [0 .. maxPct]
        uint256 maxPct = DEFAULT_MAX_SURGE_FEE_PPM9;
        uint256 staticFee = uint256(staticFeeSeed) % (maxPct + 1);

        HyperSurgeHookMock.ComputeSurgeFeeLocals memory L = _makeLocals(
            b[locals.i],
            w[locals.i],
            b[locals.j],
            w[locals.j],
            locals.pxIn,
            locals.pxOut
        );

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;

        (locals.ok, locals.fee) = hook.ComputeSurgeFee(L, p, staticFee);
        assertTrue(locals.ok, "compute must succeed");

        locals.expected = _expectedFeeWithParams(
            _pairSpotFromBalancesWeights(b[locals.i], w[locals.i], b[locals.j], w[locals.j]),
            locals.pxIn,
            locals.pxOut,
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
        uint256 pxIn;
        uint256 pxOut;
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

        (locals.pxIn, locals.pxOut) = _localsForDeviation(locals.price, locals.deviation);

        // Orientation A (i -> j)
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory LA = _makeLocals(
            b[locals.i],
            w[locals.i],
            b[locals.j],
            w[locals.j],
            locals.pxIn,
            locals.pxOut
        );
        // Orientation B (j -> i) with inverted external prices
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory LB = _makeLocals(
            b[locals.j],
            w[locals.j],
            b[locals.i],
            w[locals.i],
            locals.pxOut,
            locals.pxIn
        );

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;

        (locals.ok, locals.fee) = hook.ComputeSurgeFee(LA, p, STATIC_SWAP_FEE);
        (bool okB, uint256 feeB) = hook.ComputeSurgeFee(LB, p, STATIC_SWAP_FEE);
        assertTrue(locals.ok && okB, "compute must succeed");

        // Measure deviations exactly like the hook does
        uint256 extA = _divDown(LA.pxOut, LA.pxIn);
        uint256 extB = _divDown(LB.pxOut, LB.pxIn);
        uint256 devA = _relAbsDiff(locals.price, extA);
        uint256 devB = _relAbsDiff(_pairSpotFromBalancesWeights(LB.bIn, LB.wIn, LB.bOut, LB.wOut), extB); // equals 1/P vs 1/ext due to swap

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
        uint256 P;
        uint256 threshold;
        uint256 capDev;
        int8[5] offs;
        uint256 Dt;
        uint256 pxInT;
        uint256 pxOutT;
        uint256 extT;
        uint256 expectedT;
        uint256 Dc;
        uint256 pxInC;
        uint256 pxOutC;
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
        uint256[] memory w = _normWeights(locals.n, wSeed);
        uint256[] memory b = _balances(locals.n, bSeed);

        locals.i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 1))), 0, locals.n - 1));
        locals.j = (locals.i + 1 + uint8(bound(uint256(keccak256(abi.encode(dSeed, 2))), 0, locals.n - 2))) % locals.n;

        locals.P = _pairSpotFromBalancesWeights(b[locals.i], w[locals.i], b[locals.j], w[locals.j]);
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
            (locals.pxInT, locals.pxOutT) = _localsForDeviation(locals.P, locals.Dt);
            HyperSurgeHookMock.ComputeSurgeFeeLocals memory LT = _makeLocals(
                b[locals.i],
                w[locals.i],
                b[locals.j],
                w[locals.j],
                locals.pxInT,
                locals.pxOutT
            );

            PoolSwapParams memory p;
            p.kind = SwapKind.EXACT_IN;

            (bool okT, uint256 feeT) = hook.ComputeSurgeFee(LT, p, STATIC_SWAP_FEE);
            assertTrue(okT, "compute must succeed (threshold ring)");

            locals.extT = _divDown(locals.pxOutT, locals.pxInT);
            locals.expectedT = _expectedFeeFromLocals(locals.P, locals.pxInT, locals.pxOutT);
            // Exact match to the hook’s rounding-based expected value
            assertEq(feeT, locals.expectedT, "threshold ring fee mismatch");

            // --- Around CAP ---
            if (locals.offs[k] < 0) {
                uint256 deltaC = uint256(uint8(-locals.offs[k]));
                locals.Dc = locals.capDev > deltaC ? locals.capDev - deltaC : 0;
            } else {
                // guard upper bound to avoid overflow in _localsForDeviation denominator
                uint256 room = ONE > locals.capDev ? (ONE - locals.capDev) : 0;
                uint256 add = uint256(uint8(locals.offs[k]));
                locals.Dc = locals.capDev + (add <= room ? add : room);
            }
            (locals.pxInC, locals.pxOutC) = _localsForDeviation(locals.P, locals.Dc);
            HyperSurgeHookMock.ComputeSurgeFeeLocals memory LC = _makeLocals(
                b[locals.i],
                w[locals.i],
                b[locals.j],
                w[locals.j],
                locals.pxInC,
                locals.pxOutC
            );

            (bool okC, uint256 feeC) = hook.ComputeSurgeFee(LC, p, STATIC_SWAP_FEE);
            assertTrue(okC, "compute must succeed (cap ring)");

            locals.expectedC = _expectedFeeFromLocals(locals.P, locals.pxInC, locals.pxOutC);
            assertEq(feeC, locals.expectedC, "cap ring fee mismatch");
        }
    }

    /// Balance scaling invariance (unchanged idea, included for completeness).
    function testFuzz_balanceScalingInvariance(
        uint8 nSeed,
        uint256 wSeed,
        uint256 bSeed,
        uint256 dSeed,
        uint64 scaleSeed
    ) public view {
        uint8 n = uint8(bound(nSeed, 2, 8));
        uint256[] memory w = _normWeights(n, wSeed);
        uint256[] memory b = _balances(n, bSeed);

        uint8 i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 1))), 0, n - 1));
        uint8 j = (i + 1 + uint8(bound(uint256(keccak256(abi.encode(dSeed, 2))), 0, n - 2))) % n;

        uint256 P = _pairSpotFromBalancesWeights(b[i], w[i], b[j], w[j]);
        vm.assume(P > 0);

        uint256 capDev = DEFAULT_CAP_DEV_PPM9;
        uint256 D = uint256(keccak256(abi.encode(dSeed))) % (capDev + capDev / 3 + 1);

        (uint256 pxIn, uint256 pxOut) = _localsForDeviation(P, D);

        HyperSurgeHookMock.ComputeSurgeFeeLocals memory L1 = _makeLocals(b[i], w[i], b[j], w[j], pxIn, pxOut);

        uint256 k = 1 + (uint256(scaleSeed) % 1_000_000_000); // [1 .. 1e9]
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory L2 = _makeLocals(b[i] * k, w[i], b[j] * k, w[j], pxIn, pxOut);

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;

        (, uint256 fee1) = hook.ComputeSurgeFee(L1, p, STATIC_SWAP_FEE);
        (, uint256 fee2) = hook.ComputeSurgeFee(L2, p, STATIC_SWAP_FEE);

        assertApproxEqAbs(fee1, fee2, 1, "fee must be invariant to balance scaling");
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
