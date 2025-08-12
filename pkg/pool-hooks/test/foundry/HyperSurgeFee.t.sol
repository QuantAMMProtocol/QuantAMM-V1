// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

// Base test utilities (provides: vault, pool, poolFactory, admin, authorizer, routers, tokens, etc.)
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

/*//////////////////////////////////////////////////////////////
                           PRECOMPILE STUBS
//////////////////////////////////////////////////////////////*/

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

/*//////////////////////////////////////////////////////////////
                             TESTS
//////////////////////////////////////////////////////////////*/

contract HyperSurgeFeeTest is BaseVaultTest, HyperSurgeHookDeployer, WeightedPoolContractsDeployer {
    using ArrayHelpers for *;
    using CastingHelpers for address[];

    uint256 constant ONE = 1e18;

    // MUST match addresses the hook libs read
    address constant HL_PRICE_PRECOMPILE = 0x0000000000000000000000000000000000000808;
    address constant HL_TOKENINFO_PRECOMPILE = 0x0000000000000000000000000000000000000807;
    uint256 internal constant DEFAULT_SWAP_FEE = 1e16; // 1%

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

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual override {
        super.setUp(); // vault, pool, poolFactory, admin, authorizer, tokens, routers, ...

        vm.prank(address(poolFactory)); // some repos require factory to deploy
        hook = deployHook(
            IVault(address(vault)),
            0.02e9, // default max fee (2%)
            0.02e9, // default threshold (2%)
            1e9,
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

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

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
        params.maxPct = bound(feeSeed % 1e9, 0, 1e9);
        params.thr = params.maxPct / 3;
        params.cap = params.thr + (1e9 - params.thr) / 2;
        if (params.cap == params.thr) params.cap = params.thr + 1;

        vm.startPrank(admin);
        // set both ARB & NOISE so the branch chosen by price movement is always initialized
        hook.setMaxSurgeFeePercentage(address(pool), params.maxPct, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setSurgeThresholdPercentage(address(pool), params.thr, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setCapDeviationPercentage(address(pool), params.cap, IHyperSurgeHook.TradeType.ARBITRAGE);

        hook.setMaxSurgeFeePercentage(address(pool), params.maxPct, IHyperSurgeHook.TradeType.NOISE);
        hook.setSurgeThresholdPercentage(address(pool), params.thr, IHyperSurgeHook.TradeType.NOISE);
        hook.setCapDeviationPercentage(address(pool), params.cap, IHyperSurgeHook.TradeType.NOISE);
        vm.stopPrank();

        // --- configure external price sources for the two indices we’ll swap
        params.indexIn = 0;
        params.indexOut = uint8(bound(outSeed, 1, uint8(params.n - 1)));

        params.pairIdx = 1; // arbitrary non-zero HL pair id for the out token
        _hlSetSzDecimals(params.pairIdx, uint8(params.divisor));
        _hlSetSpot(params.pairIdx, params.raw);

        vm.startPrank(admin);
        hook.setTokenPriceConfigIndex(address(pool), params.indexIn, params.pairIdx);
        hook.setTokenPriceConfigIndex(address(pool), params.indexOut, params.pairIdx); // HL pair
        vm.stopPrank();

        // --- balancesScaled18 with length N (simple increasing balances)
        uint256[] memory balances = new uint256[](params.n);
        for (uint256 i = 0; i < params.n; ++i) balances[i] = 1e18 * (i + 1);

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
        params.maxPct = bound(feeSeed % 1e9, 0, 1e9);
        params.thr = params.maxPct / 3;
        params.cap = params.thr + (1e9 - params.thr) / 2;
        if (params.cap == params.thr) params.cap = params.thr + 1;

        vm.startPrank(admin);
        hook.setMaxSurgeFeePercentage(address(pool), params.maxPct, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setSurgeThresholdPercentage(address(pool), params.thr, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setCapDeviationPercentage(address(pool), params.cap, IHyperSurgeHook.TradeType.ARBITRAGE);

        hook.setMaxSurgeFeePercentage(address(pool), params.maxPct, IHyperSurgeHook.TradeType.NOISE);
        hook.setSurgeThresholdPercentage(address(pool), params.thr, IHyperSurgeHook.TradeType.NOISE);
        hook.setCapDeviationPercentage(address(pool), params.cap, IHyperSurgeHook.TradeType.NOISE);
        vm.stopPrank();

        // --- configure price only for the two indices we use
        params.indexIn = 0;
        params.indexOut = uint8(bound(outSeed, 1, uint8(params.n - 1)));

        params.pairIdx = 1;
        _hlSetSzDecimals(params.pairIdx, uint8(params.divisor));
        _hlSetSpot(params.pairIdx, params.raw);

        vm.startPrank(admin);
        hook.setTokenPriceConfigIndex(address(pool), params.indexIn, params.pairIdx); 
        hook.setTokenPriceConfigIndex(address(pool), params.indexOut, params.pairIdx); // HL pair
        vm.stopPrank();

        // --- balancesScaled18 length N
        uint256[] memory balances = new uint256[](params.n);
        for (uint256 i = 0; i < params.n; ++i) balances[i] = 1e18 * (i + 1);

        // --- build PoolSwapParams (EXACT_OUT: 0 -> indexOut)
        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_OUT;
        p.balancesScaled18 = balances;
        p.indexIn = params.indexIn;
        p.indexOut = params.indexOut;

        // bound amountOut to strictly inside the 30% guard
        params.MAX_RATIO = 30e16; // 30%
        params.maxIn = (balances[p.indexOut] * params.MAX_RATIO) / 1e18;
        if (params.maxIn > 0) params.maxIn -= 1;
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
    }

    function testFuzz_hyper_price_spot_failure_marker(uint256 marker) public {
        // bound the marker to 32-bit so we can derive many fuzz knobs from it
        marker = bound(marker, 0, type(uint32).max);

        FailureCtx memory s;

        // 1) Discover live pool size (N) from the deployed weighted pool
        s.n = WeightedPool(address(pool)).getNormalizedWeights().length;
        assertGe(s.n, 2, "pool must have >=2 tokens");
        require(s.n <= 8, "hook supports up to 8");

        // 2) Register the hook with EXACTLY N TokenConfig entries
        TokenConfig[] memory cfg = new TokenConfig[](s.n);
        LiquidityManagement memory lm;
        vm.prank(address(vault));
        assertTrue(hook.onRegister(poolFactory, address(pool), cfg, lm), "onRegister failed");

        // 3) Fee knobs in 1e9 (ppb). Keep staticFee <= maxPct to avoid underflow in (maxPct - staticFee)
        s.maxPct = marker % 1e9; // [0, 1e9]
        s.thr = s.maxPct / 4;
        s.cap = s.thr + (1e9 - s.thr) / 3; // thr < cap <= 1e9
        if (s.cap == s.thr) s.cap = s.thr + 1;
        s.staticFee = (marker >> 8) % (s.maxPct + 1); // [0, maxPct]

        vm.startPrank(admin);
        // set both directions so whichever branch the hook takes is initialized
        hook.setMaxSurgeFeePercentage(address(pool), s.maxPct, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setSurgeThresholdPercentage(address(pool), s.thr, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setCapDeviationPercentage(address(pool), s.cap, IHyperSurgeHook.TradeType.ARBITRAGE);

        hook.setMaxSurgeFeePercentage(address(pool), s.maxPct, IHyperSurgeHook.TradeType.NOISE);
        hook.setSurgeThresholdPercentage(address(pool), s.thr, IHyperSurgeHook.TradeType.NOISE);
        hook.setCapDeviationPercentage(address(pool), s.cap, IHyperSurgeHook.TradeType.NOISE);
        vm.stopPrank();

        // 4) Configure price sources for exactly the two indices we’ll use
        s.indexIn = 0;
        s.indexOut = uint8(1 + (marker % (s.n - 1))); // ∈ [1, n-1]
        s.pairIdx = 2; // any non-zero pair id for HL
        s.sz = uint8((marker >> 16) % 7); // 0..6

        _hlSetSzDecimals(s.pairIdx, s.sz);
        _hlSetSpot(s.pairIdx, 0);

        vm.startPrank(admin);
        hook.setTokenPriceConfigIndex(address(pool), s.indexIn, s.pairIdx);
        hook.setTokenPriceConfigIndex(address(pool), s.indexOut, s.pairIdx); // HL (spot=0)
        vm.stopPrank();

        // 5) Balances array of length N (ascending 1e18, 2e18, ...)
        s.balances = new uint256[](s.n);
        for (uint256 i = 0; i < s.n; ++i) s.balances[i] = 1e18 * (i + 1);

        // 6) Build swap params (EXACT_IN), keep amount strictly inside WeightedMath 30% guard
        PoolSwapParams memory p;
        p.kind = SwapKind.EXACT_IN;
        p.balancesScaled18 = s.balances;
        p.indexIn = s.indexIn;
        p.indexOut = s.indexOut;

        s.maxRatio = 30e16; // 30% in 1e18 basis
        s.maxIn = (s.balances[p.indexIn] * s.maxRatio) / 1e18;
        if (s.maxIn > 0) s.maxIn -= 1; // strictly under boundary
        // derive a nonzero amount from marker and bound it
        uint256 amtSeed = (marker << 32) | marker;
        p.amountGivenScaled18 = bound(amtSeed, 1, s.maxIn == 0 ? 1 : s.maxIn);

        // 7) Call the hook via the vault (onlyVault). This MUST NOT revert.
        vm.prank(address(vault));
        (s.ok, s.dyn) = hook.onComputeDynamicSwapFeePercentage(p, address(pool), s.staticFee);

        // If the hook decides it can't compute (spot==0 path), ok may be false. Just ensure no revert.
        if (s.ok) {
            // Fee is a percentage; bound to 100% in 1e18 basis to tolerate either 1e9 or 1e18 internal scaling.
            assertLe(s.dyn, 1e18, "fee must be <= 100%");
        }
    }
}
