// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

// Base test utilities (provides: vault, poolocalCompute, poolFactory, admin, authorizer, routers, tokens, etc.)
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
    mapping(uint32 => uint8) internal sz; // slot 0

    fallback(bytes calldata data) external returns (bytes memory ret) {
        uint32 pairIndex = abi.decode(data, (uint32));
        return abi.encode(sz[pairIndex]);
    }

    function set(uint32 pairIndex, uint8 decimals) external {
        sz[pairIndex] = decimals;
    }
}

contract HyperSurgeFeeTest is BaseVaultTest, HyperSurgeHookDeployer, WeightedPoolContractsDeployer {
    using ArrayHelpers for *;
    using CastingHelpers for address[];

    uint256 constant ONE = 1e18;
    uint256 constant STATIC_SWAP_FEE = 1e16; // 1% (1e18 scale)

    // MUST match addresses the hook libs read
    address constant HL_PRICE_PRECOMPILE = 0x0000000000000000000000000000000000000808;
    address constant HL_TOKENINFO_PRECOMPILE = 0x0000000000000000000000000000000000000807;
    uint256 internal constant DEFAULT_SWAP_FEE = 1e16; // 1%
    uint256 constant FEE_ONE = 1e18;

    HyperSurgeHookMock internal hook;

    HLPriceStub internal _pxStubDeployer;
    HLTokenInfoStub internal _infoStubDeployer;

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

    function setUp() public virtual override {
        super.setUp(); // vault, poolocalCompute, poolFactory, admin, authorizer, tokens, routers, ...

        vm.prank(address(poolFactory)); // some repos require factory to deploy
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
        vm.etch(HL_PRICE_PRECOMPILE, address(_pxStubDeployer).code);
        vm.etch(HL_TOKENINFO_PRECOMPILE, address(_infoStubDeployer).code);

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
        vm.store(HL_PRICE_PRECOMPILE, slot, bytes32(uint256(price_1e6)));
    }

    function _hlSetSzDecimals(uint32 pairIdx, uint8 sz) internal {
        bytes32 slot = keccak256(abi.encode(bytes32(uint256(pairIdx)), bytes32(uint256(0))));
        vm.store(HL_TOKENINFO_PRECOMPILE, slot, bytes32(uint256(sz)));
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
        uint32 raw, // external spot (HL precompile)
        uint32 divisor, // choose szDecimals in [0..6]
        uint256 amtSeed, // fuzz trade amount (EXACT_IN)
        uint256 feeSeed, // fuzz fee seed
        uint8 outSeed // fuzz which token is indexOut
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

        // --- fee knobs in 1e9 scale; static must be <= maxPct
        params.maxPct = bound(feeSeed, 3, 1e9);
        params.thr = params.maxPct / 3;
        params.cap = params.thr + (1e9 - params.thr) / 2;
        if (params.cap == params.thr) params.cap = params.thr + 1;

        vm.startPrank(admin);
        // set both ARB & NOISE so the branch chosen by price movement is always initialized
        hook.setMaxSurgeFeePercentage(address(pool), params.maxPct * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setSurgeThresholdPercentage(address(pool), params.thr * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setCapDeviationPercentage(address(pool), params.cap * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);

        hook.setMaxSurgeFeePercentage(address(pool), params.maxPct * 1e9, IHyperSurgeHook.TradeType.NOISE);
        hook.setSurgeThresholdPercentage(address(pool), params.thr * 1e9, IHyperSurgeHook.TradeType.NOISE);
        hook.setCapDeviationPercentage(address(pool), params.cap * 1e9, IHyperSurgeHook.TradeType.NOISE);
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

        vm.startPrank(admin);
        hook.setMaxSurgeFeePercentage(address(pool), params.maxPct * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setSurgeThresholdPercentage(address(pool), params.thr * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setCapDeviationPercentage(address(pool), params.cap * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);

        hook.setMaxSurgeFeePercentage(address(pool), params.maxPct * 1e9, IHyperSurgeHook.TradeType.NOISE);
        hook.setSurgeThresholdPercentage(address(pool), params.thr * 1e9, IHyperSurgeHook.TradeType.NOISE);
        hook.setCapDeviationPercentage(address(pool), params.cap * 1e9, IHyperSurgeHook.TradeType.NOISE);
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
        assertLe(dyn, 1e18, "fee must be <= 100% (1e18)");
        assertGe(dyn, params.staticFee, "dyn fee >= static fee");
    }

    // Pack locals to avoid stack-too-deep
    struct FailureCtx {
        uint256 n;
        uint8 indexIn;
        uint8 indexOut;
        // price source (HL) config
        uint32 pairIdx;
        uint8 sz;
        // fee knobs (1e9 scale)
        uint256 maxPct;
        uint256 thr;
        uint256 cap;
        uint256 staticFee;
        // balances + limits
        uint256[] balances;
        uint256 maxRatio; // 30e16 (30% in 1e18 basis)
        uint256 maxIn;
        // results
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

    function testFuzz_hyper_price_spot_failure_marker(uint256 marker) public {
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
        locals.thr9 = 1 + ((marker >> 8) % locals.max9); // ≥1 and ≤ max9
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

        // If ok=false (spot=0 path), that's fine; just ensure no revert. If ok=true, fee ≤ 100%.
        if (locals.ok) {
            assertLe(locals.dyn, 1e18, "fee must be <= 100%");
        }
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
    ) internal pure returns (HyperSurgeHookMock.ComputeSurgeFeeLocals memory localCompute) {
        localCompute.bIn = bIn;
        localCompute.wIn = wIn;
        localCompute.bOut = bOut;
        localCompute.wOut = wOut;
        localCompute.pxIn = pxIn;
        localCompute.pxOut = pxOut;
        localCompute.poolDetails.noiseThresholdPercentage9 = thrPPM9;
        localCompute.poolDetails.noiseCapDeviationPercentage9 = capPPM9;
        localCompute.poolDetails.noiseMaxSurgeFee9 = maxPPM9;
        localCompute.poolDetails.arbThresholdPercentage9 = thrPPM9;
        localCompute.poolDetails.arbCapDeviationPercentage9 = capPPM9;
        localCompute.poolDetails.arbMaxSurgeFee9 = maxPPM9;
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
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory localCompute = fee_makeLocals(
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
        (locals.ok, locals.feeA) = mock.ComputeSurgeFee(localCompute, p, STATIC_SWAP_FEE);
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

    /// Balance scaling invariance under arbitrary params (fixed: keep relative trade size constant).
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

        // --- Setup, seeds, and bounds ---
        locals.n = uint8(bound(nSeed, 2, 8));
        locals.w = fee_normWeights(locals.n, wSeed);
        locals.b = fee_balances(locals.n, bSeed);

        locals.i = uint8(bound(uint256(keccak256(abi.encode(dSeed, 31))), 0, locals.n - 1));
        locals.j = (locals.i + 1 + uint8(bound(uint256(keccak256(abi.encode(dSeed, 32))), 0, locals.n - 2))) % locals.n;

        (locals.thrPPM9, locals.capPPM9, locals.maxPPM9) = fee_boundParams(thrPPM9, capPPM9, maxPPM9);

        locals.P = fee_pairSpotFromBW(locals.b[locals.i], locals.w[locals.i], locals.b[locals.j], locals.w[locals.j]);
        vm.assume(locals.P > 0);

        locals.capDev = fee_ppm9To1e18(locals.capPPM9);
        locals.D = uint256(keccak256(abi.encode(dSeed))) % (locals.capDev + locals.capDev / 2 + 1);

        (locals.pxIn, locals.pxOut) = fee_localsForDeviation(locals.P, locals.D);

        // Scale factor k and a base amount that is small relative to balances to avoid overflow
        locals.scaleSeed = 1 + (uint256(scaleSeed) % 1_000_000_000); // k in [1 .. 1e9]

        locals.bMin = locals.b[locals.i] < locals.b[locals.j] ? locals.b[locals.i] : locals.b[locals.j];
        // choose base amount ~ bMin / 1e12 (but at least 1 wei); this keeps amount*k << 2^256
        locals.baseAmt = locals.bMin / 1e12;
        if (locals.baseAmt == 0) locals.baseAmt = 1;

        // --- Mock + params ---
        HyperSurgeHookMock mock = new HyperSurgeHookMock(
            IVault(vault),
            fee_ppm9To1e18(locals.maxPPM9),
            fee_ppm9To1e18(locals.thrPPM9),
            fee_ppm9To1e18(locals.capPPM9),
            "fee-scale"
        );

        PoolSwapParams memory p1;
        p1.kind = SwapKind.EXACT_IN;
        p1.amountGivenScaled18 = locals.baseAmt; // amount for the unscaled balances

        // Same params but with balances *and* amount scaled by k to preserve relative trade size
        PoolSwapParams memory p2;
        p2.kind = SwapKind.EXACT_IN;
        p2.amountGivenScaled18 = locals.baseAmt * locals.scaleSeed;

        // --- Compute fees ---
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

        // Allow ±2 wei to account for floor rounding flips at knife edges
        assertApproxEqAbs(locals.fee1, locals.fee2, 100, "fee invariant to balance + amount scaling (2 wei)");
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

    /// Exact-value boundary checks (non-fuzz): below threshold, mid-span, at/over cap.
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
        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;

        // Below threshold
        {
            locals.D = fee_ppm9To1e18(locals.thr) - 1;
            (locals.pxIn, locals.pxOut) = fee_localsForDeviation(locals.P, locals.D);
            (, locals.feeA) = mock.ComputeSurgeFee(
                fee_makeLocals(
                    locals.b0,
                    locals.w0,
                    locals.b1,
                    locals.w1,
                    locals.pxIn,
                    locals.pxOut,
                    locals.thr,
                    locals.cap,
                    locals.maxp
                ),
                p,
                STATIC_SWAP_FEE
            );
            assertEq(locals.feeA, STATIC_SWAP_FEE, "below threshold means static fee");
        }

        // Mid-span
        {
            locals.D = (fee_ppm9To1e18(locals.thr) + fee_ppm9To1e18(locals.cap)) / 2;
            (locals.pxIn, locals.pxOut) = fee_localsForDeviation(locals.P, locals.D);
            (, locals.feeB) = mock.ComputeSurgeFee(
                fee_makeLocals(
                    locals.b0,
                    locals.w0,
                    locals.b1,
                    locals.w1,
                    locals.pxIn,
                    locals.pxOut,
                    locals.thr,
                    locals.cap,
                    locals.maxp
                ),
                p,
                STATIC_SWAP_FEE
            );
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
        }

        // At cap and above cap
        {
            uint256 Dcap = fee_ppm9To1e18(locals.cap);
            (locals.pxIn, locals.pxOut) = fee_localsForDeviation(locals.P, Dcap);
            (, locals.feeC) = mock.ComputeSurgeFee(
                fee_makeLocals(
                    locals.b0,
                    locals.w0,
                    locals.b1,
                    locals.w1,
                    locals.pxIn,
                    locals.pxOut,
                    locals.thr,
                    locals.cap,
                    locals.maxp
                ),
                p,
                STATIC_SWAP_FEE
            );
            assertEq(locals.feeC, fee_ppm9To1e18(locals.maxp), "at cap means max fee");

            uint256 Dhi = Dcap + 1;
            (locals.pxIn, locals.pxOut) = fee_localsForDeviation(locals.P, Dhi);
            (, locals.feeD) = mock.ComputeSurgeFee(
                fee_makeLocals(
                    locals.b0,
                    locals.w0,
                    locals.b1,
                    locals.w1,
                    locals.pxIn,
                    locals.pxOut,
                    locals.thr,
                    locals.cap,
                    locals.maxp
                ),
                p,
                STATIC_SWAP_FEE
            );
            assertEq(locals.feeD, fee_ppm9To1e18(locals.maxp), "above cap means clamped to max fee");
        }
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
        (, locals.feeIn) = mock.ComputeSurgeFee(
            fee_makeLocals(
                locals.b[locals.i],
                locals.w[locals.i],
                locals.b[locals.j],
                locals.w[locals.j],
                locals.pxIn,
                locals.pxOut,
                locals.thr,
                locals.cap,
                locals.maxp
            ),
            pIn,
            STATIC_SWAP_FEE
        );

        // EXACT_OUT
        PoolSwapParams memory pOut;
        pOut.kind = SwapKind.EXACT_OUT;
        (, locals.feeOut) = mock.ComputeSurgeFee(
            fee_makeLocals(
                locals.b[locals.i],
                locals.w[locals.i],
                locals.b[locals.j],
                locals.w[locals.j],
                locals.pxIn,
                locals.pxOut,
                locals.thr,
                locals.cap,
                locals.maxp
            ),
            pOut,
            STATIC_SWAP_FEE
        );

        assertEq(locals.feeIn, locals.feeOut, "with equal lane params, kind should not change math result");
    }

    // Helper: for “bad/missing external prices”, either revert OR return (ok && static fee).
    function _assertStaticFeeOrRevert_MissingPrices(PoolSwapParams memory p) internal view {
        // call must be from vault (the test sets vm.prank(vault) before calling this)
        (bool ok, uint256 fee) = hook.onComputeDynamicSwapFeePercentage(p, address(pool), STATIC_SWAP_FEE);

        assertTrue(ok, "missing prices: ok must be true on success");
        assertEq(fee, STATIC_SWAP_FEE, "missing prices: must return static fee");
    }

    /// Missing external prices path: must either revert *or* return the static fee (both kinds).
    /// Adapts to the pool's actual token count to avoid OOB on indices/arrays.
    function testFuzz_view_missingPrices_returnsStatic_orRevert(
        uint8 nSeed,
        uint256 /* wSeed */,
        uint256 bSeed,
        uint8 iSeed
    ) public {
        // Register N; pool mock may internally expose a fixed size — we adapt to the actual size.
        uint8 nTarget = uint8(bound(nSeed, 2, 8));
        _registerBasePoolWithN(nTarget);

        // Read actual pool size and build non-zero balances of that exact length.
        uint256[] memory weights = WeightedPool(address(pool)).getNormalizedWeights();
        uint256 m = weights.length;
        assertGe(m, 2, "pool must have at least 2 tokens");

        uint256[] memory b = fee_balances(uint8(m), bSeed);

        // Choose a valid, distinct pair inside [0, m-1]
        uint256 i = uint256(bound(iSeed, 0, m - 1));
        uint256 j = (i + 1) % m; // ensures i != j since m >= 2

        PoolSwapParams memory p;
        p.amountGivenScaled18 = 1e18; // non-zero trade amount
        p.balancesScaled18 = new uint256[](m);
        for (uint256 k = 0; k < m; ++k) {
            p.balancesScaled18[k] = b[k];
        }
        p.indexIn = i;
        p.indexOut = j;

        // EXACT_IN: either revert somewhere or return static fee
        p.kind = SwapKind.EXACT_IN;
        _assertStaticFeeOrRevert_MissingPrices(p);

        // EXACT_OUT: same invariant
        p.kind = SwapKind.EXACT_OUT;
        _assertStaticFeeOrRevert_MissingPrices(p);
    }

    // Helper: for invalid shapes, either revert OR return (ok && static fee). Never a non-static fee.
    function _assertStaticFeeOrRevert(PoolSwapParams memory p) internal view {
        // Call must be from the Vault (set by the test before invoking this).
        (bool ok, uint256 fee) = hook.onComputeDynamicSwapFeePercentage(p, address(pool), STATIC_SWAP_FEE);
        assertTrue(ok, "invalid shape must not set ok=false");
        assertEq(fee, STATIC_SWAP_FEE, "invalid shape must not produce a dynamic fee");
    }

    function testFuzz_view_readsLaneParams_and_safePath(uint8 nSeed) public {
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

    // ---------- helper (no nested functions) ----------

    function _feeAtDeviation(
        HyperSurgeHookMock.ComputeSurgeFeeLocals memory localCompute,
        PoolSwapParams memory p,
        uint256 staticFee,
        uint256 extPxE18,
        uint256 deviation18
    ) internal view returns (uint256) {
        // pool price P = E * (1 + deviation)
        uint256 P = extPxE18 + (extPxE18 * deviation18) / 1e18;

        // Make poolPx = P using simple weights/balances:
        // poolPx = (bOut * wIn) / (bIn * wOut)
        localCompute.wIn = 1e18;
        localCompute.wOut = 1e18;
        localCompute.bIn = 1e18;
        localCompute.bOut = P;

        // Keep deltas zero so poolPx == poolPxBefore (no lane flip due to swap)
        localCompute.calcAmountScaled18 = 0;

        (bool ok, uint256 fee) = hook.ComputeSurgeFee(localCompute, p, staticFee);
        assertTrue(ok, "compute ok");
        return fee;
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
    function test_fee_static_whenDeviationEqualsThreshold_usingMockWrapper() public view {
        DeviationEqualsThreshold memory locals;

        locals.staticFee = 30e14; // 30 bps = 0.003 * 1e18
        locals.maxFee = 120e14; // 120 bps

        // 9 lane params (contract upscales to 18dp)
        locals.thr9 = 100_000_000; // 10%
        locals.cap9 = 500_000_000; // 50%
        locals.max9 = uint32(locals.maxFee / 1e9);

        HyperSurgeHookMock.ComputeSurgeFeeLocals memory localCompute;
        localCompute.pxIn = 1e18;
        localCompute.pxOut = 10e18; // external price E = 10

        // set both lanes the same (lane choice irrelevant for this edge)
        localCompute.poolDetails.noiseThresholdPercentage9 = locals.thr9;
        localCompute.poolDetails.noiseCapDeviationPercentage9 = locals.cap9;
        localCompute.poolDetails.noiseMaxSurgeFee9 = locals.max9;
        localCompute.poolDetails.arbThresholdPercentage9 = locals.thr9;
        localCompute.poolDetails.arbCapDeviationPercentage9 = locals.cap9;
        localCompute.poolDetails.arbMaxSurgeFee9 = locals.max9;

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.amountGivenScaled18 = 0;

        locals.E = 10e18;
        locals.thr = uint256(locals.thr9) * 1e9; // 18dp

        locals.fee = _feeAtDeviation(localCompute, p, locals.staticFee, locals.E, locals.thr);
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

    /// 2) deviation = threshold + 1 wei => minimal ramp above static
    function test_fee_minimalRamp_justAboveThreshold_usingMockWrapper() public view {
        justAboveThreshold memory locals;

        locals.staticFee = 30e14; // 30 bps
        locals.maxFee = 120e14; // 120 bps

        locals.thr9 = 100_000_000; // 10%
        locals.cap9 = 500_000_000; // 50%
        locals.max9 = uint32(locals.maxFee / 1e9);

        HyperSurgeHookMock.ComputeSurgeFeeLocals memory localCompute;
        localCompute.pxIn = 1e18;
        localCompute.pxOut = 10e18;

        localCompute.poolDetails.noiseThresholdPercentage9 = locals.thr9;
        localCompute.poolDetails.noiseCapDeviationPercentage9 = locals.cap9;
        localCompute.poolDetails.noiseMaxSurgeFee9 = locals.max9;
        localCompute.poolDetails.arbThresholdPercentage9 = locals.thr9;
        localCompute.poolDetails.arbCapDeviationPercentage9 = locals.cap9;
        localCompute.poolDetails.arbMaxSurgeFee9 = locals.max9;

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.amountGivenScaled18 = 0;

        locals.E = 10e18;
        locals.thr = uint256(locals.thr9) * 1e9;
        locals.cap = uint256(locals.cap9) * 1e9;
        locals.dev = (uint256(locals.thr9) + 1) * 1e9; // smallest 18dp step above threshold

        uint256 fee = _feeAtDeviation(localCompute, p, locals.staticFee, locals.E, locals.dev);

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
    function test_fee_degenerateRamp_maxEqualsStatic_usingMockWrapper() public view {
        MaxEqualsStatic memory locals;

        locals.staticFee = 45e14; // 45 bps
        locals.maxFee = locals.staticFee;

        locals.thr9 = 50_000_000; // 5%
        locals.cap9 = 250_000_000; // 25%
        locals.max9 = uint32(locals.maxFee / 1e9);

        HyperSurgeHookMock.ComputeSurgeFeeLocals memory localCompute;
        localCompute.pxIn = 1e18;
        localCompute.pxOut = 10e18;

        localCompute.poolDetails.noiseThresholdPercentage9 = locals.thr9;
        localCompute.poolDetails.noiseCapDeviationPercentage9 = locals.cap9;
        localCompute.poolDetails.noiseMaxSurgeFee9 = locals.max9;
        localCompute.poolDetails.arbThresholdPercentage9 = locals.thr9;
        localCompute.poolDetails.arbCapDeviationPercentage9 = locals.cap9;
        localCompute.poolDetails.arbMaxSurgeFee9 = locals.max9;

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
            _feeAtDeviation(localCompute, p, locals.staticFee, locals.E, locals.devAtThr),
            locals.staticFee,
            "at thr => static"
        );
        assertEq(
            _feeAtDeviation(localCompute, p, locals.staticFee, locals.E, locals.devMid),
            locals.staticFee,
            "mid => static"
        );
        assertEq(
            _feeAtDeviation(localCompute, p, locals.staticFee, locals.E, locals.devAtCap),
            locals.staticFee,
            "at cap => static"
        );
        assertEq(
            _feeAtDeviation(localCompute, p, locals.staticFee, locals.E, locals.devBeyond),
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

    /// 4) misconfig: max < static — current mock underflows in ramp math; assert revert.
    ///    a) deviation >= cap  ⇒ revert (underflow)
    ///    b) thr < deviation < cap ⇒ revert (underflow)
    function test_fee_misconfig_maxBelowStatic_usingMockWrapper() public {
        MaxBelowStatic memory locals;

        locals.staticFee = 80e14; // 80 bps
        locals.maxFee = 20e14; // 20 bps (lower than static) → underflow in mock ramp

        locals.thr9 = 100_000_000; // 10%
        locals.cap9 = 300_000_000; // 30%
        locals.max9 = uint32(locals.maxFee / 1e9);

        HyperSurgeHookMock.ComputeSurgeFeeLocals memory localCompute;
        localCompute.pxIn = 1e18;
        localCompute.pxOut = 10e18;

        localCompute.poolDetails.noiseThresholdPercentage9 = locals.thr9;
        localCompute.poolDetails.noiseCapDeviationPercentage9 = locals.cap9;
        localCompute.poolDetails.noiseMaxSurgeFee9 = locals.max9;
        localCompute.poolDetails.arbThresholdPercentage9 = locals.thr9;
        localCompute.poolDetails.arbCapDeviationPercentage9 = locals.cap9;
        localCompute.poolDetails.arbMaxSurgeFee9 = locals.max9;

        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.amountGivenScaled18 = 0;
        p.balancesScaled18 = new uint256[](2);
        p.balancesScaled18[0] = 1e18;
        p.balancesScaled18[1] = 10e18;

        locals.E = 10e18;
        locals.thr = uint256(locals.thr9) * 1e9;
        locals.cap = uint256(locals.cap9) * 1e9;

        // a) at cap → revert arithmetic (0x11)
        {
            uint256 dev = locals.cap;
            // set up inputs
            HyperSurgeHookMock.ComputeSurgeFeeLocals memory T = localCompute;
            // P = E * (1 + dev)
            uint256 P = locals.E + (locals.E * dev) / 1e18;
            T.wIn = 1e18;
            T.wOut = 1e18;
            T.bIn = 1e18;
            T.bOut = P;
            T.calcAmountScaled18 = 0;

            vm.expectRevert(stdError.arithmeticError);
            hook.ComputeSurgeFee(T, p, locals.staticFee);
        }

        // a) beyond cap → revert arithmetic (0x11)
        {
            uint256 dev = locals.cap + 999;
            HyperSurgeHookMock.ComputeSurgeFeeLocals memory T = localCompute;
            uint256 P = locals.E + (locals.E * dev) / 1e18;
            T.wIn = 1e18;
            T.wOut = 1e18;
            T.bIn = 1e18;
            T.bOut = P;
            T.calcAmountScaled18 = 0;

            vm.expectRevert(stdError.arithmeticError);
            hook.ComputeSurgeFee(T, p, locals.staticFee);
        }

        // b) between thr & cap → revert arithmetic (0x11)
        {
            uint256 dev = locals.thr + (locals.cap - locals.thr) / 3;
            HyperSurgeHookMock.ComputeSurgeFeeLocals memory T = localCompute;
            uint256 P = locals.E + (locals.E * dev) / 1e18;
            T.wIn = 1e18;
            T.wOut = 1e18;
            T.bIn = 1e18;
            T.bOut = P;
            T.calcAmountScaled18 = 0;

            vm.expectRevert(stdError.arithmeticError);
            hook.ComputeSurgeFee(T, p, locals.staticFee);
        }
    }
}
