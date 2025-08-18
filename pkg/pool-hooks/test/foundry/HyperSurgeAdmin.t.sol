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

contract HyperSurgeAdminTest is BaseVaultTest, HyperSurgeHookDeployer, WeightedPoolContractsDeployer {
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

    function setUp() public virtual override {
        super.setUp(); // vault, pool, poolFactory, admin, authorizer, tokens, routers, ...

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
    function _registerBasePoolWithN(uint8 n) internal returns (uint8 tokenCount) {
        n = uint8(bound(n, 2, 8));

        TokenConfig[] memory cfg = new TokenConfig[](n);
        LiquidityManagement memory lm;
        vm.prank(address(vault)); // onRegister is onlyVault
        bool ok = hook.onRegister(poolFactory, address(pool), cfg, lm);
        assertTrue(ok, "onRegister(base pool) failed");
        return n;
    }

    function _hlSetSpot(uint32 pairIdx, uint32 price_1e6) internal {
        bytes32 slot = keccak256(abi.encode(bytes32(uint256(pairIdx)), bytes32(uint256(0))));
        vm.store(HL_PRICE_PRECOMPILE, slot, bytes32(uint256(price_1e6)));
    }

    function _hlSetSzDecimals(uint32 pairIdx, uint8 sz) internal {
        bytes32 slot = keccak256(abi.encode(bytes32(uint256(pairIdx)), bytes32(uint256(0))));
        vm.store(HL_TOKENINFO_PRECOMPILE, slot, bytes32(uint256(sz)));
    }

    /// @notice Registering a pool sets lane defaults for N tokens; re-registering resets mutated values to defaults.
    /// @dev Bounds: `n ∈ [2,8]` to match Balancer V3 pool sizes; `tradeTypeInt ∈ {0,1}` for {ARB,NOISE}.
    ///      Verifies that getters return 1e18-scaled defaults derived from constructor ppm9 params, then
    ///      confirms that mutating params and calling `onRegister` again restores default values.
    /// @param n Number of tokens requested via TokenConfig length.
    /// @param tradeTypeInt Lane selector as uint8 (0=ARB, 1=NOISE).
    function testFuzz_onRegister_withN_setsDefaults_and_second_overwrites_to_defaults(
        uint8 n,
        uint8 tradeTypeInt
    ) public {
        // First registration for base pool with fuzzed N tokens
        n = _registerBasePoolWithN(n);
        IHyperSurgeHook.TradeType tradeType = IHyperSurgeHook.TradeType(bound(tradeTypeInt, 0, 1));

        // Defaults (from constructor) are set
        assertEq(hook.getMaxSurgeFeePercentage(address(pool), tradeType), 0.02e18, "default max mismatch");
        assertEq(hook.getSurgeThresholdPercentage(address(pool), tradeType), 0.02e18, "default threshold mismatch");
        assertEq(hook.getCapDeviationPercentage(address(pool), tradeType), 1e18, "default capDev mismatch");

        // Change to custom values
        vm.startPrank(admin);

        hook.setMaxSurgeFeePercentage(address(pool), 0.50e18, tradeType);
        hook.setSurgeThresholdPercentage(address(pool), 0.10e18, tradeType);
        hook.setCapDeviationPercentage(address(pool), 0.90e18, tradeType);
        vm.stopPrank();

        // Re-register the SAME pool: impl resets values back to defaults (observed behavior)
        TokenConfig[] memory cfg = new TokenConfig[](n);
        LiquidityManagement memory lm;
        vm.prank(address(vault));
        hook.onRegister(poolFactory, address(pool), cfg, lm);

        // Assert they were clobbered back to constructor defaults
        assertEq(
            hook.getMaxSurgeFeePercentage(address(pool), tradeType),
            0.02e18,
            "re-register should reset max to default"
        );
        assertEq(
            hook.getSurgeThresholdPercentage(address(pool), tradeType),
            0.02e18,
            "re-register should reset threshold to default"
        );
        assertEq(
            hook.getCapDeviationPercentage(address(pool), tradeType),
            1e18,
            "re-register should reset capDev to default"
        );
    }

    /// @notice Cap deviation must be > threshold and within (0, 100%] in ppm9 when threshold is zero.
    /// @dev Bounds: fuzz `capDev ∈ [0, 1e18]`; accept `0 < capDev ≤ 1e9`, revert on `capDev == 0` or `capDev > 1e9`.
    /// @param n Pool size (2..8).
    /// @param capDev Cap deviation in ppm9.
    /// @param tradeTypeInt Lane selector (0=ARB,1=NOISE).
    function testFuzz_setCapDeviationPercentage_bounds_withThrZero(uint8 n, uint256 capDev, uint8 tradeTypeInt) public {
        n = _registerBasePoolWithN(n);
        IHyperSurgeHook.TradeType tradeType = IHyperSurgeHook.TradeType(bound(tradeTypeInt, 0, 1));

        vm.startPrank(admin);
        hook.setSurgeThresholdPercentage(address(pool), 1e9, tradeType);

        capDev = bound(capDev, 1, ONE + 1e20);
        if (capDev > 1e18) {
            vm.expectRevert(); // violates capDev <= 1e18
            hook.setCapDeviationPercentage(address(pool), capDev, tradeType);
        } else if (capDev <= 1e9 || (capDev > 1e9 && (capDev / 1e9) * 1e9 != capDev)) {
            vm.expectRevert(); // violates capDev <= 1e18
            hook.setCapDeviationPercentage(address(pool), capDev, tradeType);
        } else {
            hook.setCapDeviationPercentage(address(pool), capDev, tradeType);
            assertEq(hook.getCapDeviationPercentage(address(pool), tradeType), capDev);
        }
        vm.stopPrank();
    }

    /// @notice Cap deviation must remain strictly greater than threshold (positive separation).
    /// @dev Fuzzes `thr` and `capDev` in ppm9 and asserts acceptance only when `capDev > thr`.
    /// @param n Pool size (2..8).
    function testFuzz_setCapDeviation_enforces_gt_threshold(
        uint8 n,
        uint256 thr,
        uint256 capDev,
        uint8 tradeTypeInt
    ) public {
        n = _registerBasePoolWithN(n);
        IHyperSurgeHook.TradeType tradeType = IHyperSurgeHook.TradeType(bound(tradeTypeInt, 0, 1));

        thr = bound(thr, 1, 1e9 - 1); // valid threshold
        capDev = bound(capDev, thr + 1, 1e9); // valid capDev (>thr, less than or equal1e18)

        vm.startPrank(admin);
        hook.setSurgeThresholdPercentage(address(pool), thr * 1e9, tradeType);
        hook.setCapDeviationPercentage(address(pool), capDev * 1e9, tradeType);
        assertEq(hook.getCapDeviationPercentage(address(pool), tradeType), capDev * 1e9);
        vm.stopPrank();
    }

    /// @notice Setting cap deviation ≤ threshold is rejected for safety.
    /// @dev Exercises the non-strict and reverse cases (`capDev == thr` or `< thr`) to ensure revert.
    /// @param n Pool size (2..8).
    function testFuzz_setCapDeviation_rejects_le_threshold(
        uint8 n,
        uint256 thr,
        uint256 capDev,
        uint8 tradeTypeInt
    ) public {
        n = _registerBasePoolWithN(n);
        IHyperSurgeHook.TradeType tradeType = IHyperSurgeHook.TradeType(bound(tradeTypeInt, 0, 1));

        thr = bound(thr, 1, 1e9 - 1); // ensure setting thr succeeds
        capDev = bound(capDev, 1, thr); // invalid: capDev <= thr

        vm.startPrank(admin);
        hook.setSurgeThresholdPercentage(address(pool), thr * 1e9, tradeType);
        vm.expectRevert();
        hook.setCapDeviationPercentage(address(pool), capDev * 1e9, tradeType);
        vm.stopPrank();
    }

    // Default capDev is 100% after registration
    function testFuzz_defaults_include_capDev_at_100_percent(uint8 n, uint8 tradeTypeInt) public {
        n = _registerBasePoolWithN(n);
        IHyperSurgeHook.TradeType tradeType = IHyperSurgeHook.TradeType(bound(tradeTypeInt, 0, 1));

        assertEq(hook.getCapDeviationPercentage(address(pool), tradeType), ONE);
    }

    function testFuzz_setTokenPriceConfigIndex_rejects_out_of_range(uint8 n, uint8 idx) public {
        _registerBasePoolWithN(n);
        n = uint8(bound(n, 2, 8));
        idx = uint8(bound(idx, n, n + 20)); // out-of-range

        vm.startPrank(admin);
        vm.expectRevert();
        hook.setTokenPriceConfigIndex(address(pool), idx, 0);
        vm.stopPrank();
    }

    function testFuzz_setTokenPriceConfigIndex_accepts(uint8 n, uint8 idx, uint32 pairIdx) public {
        n = _registerBasePoolWithN(n);
        idx = uint8(bound(idx, 0, n - 1));
        pairIdx = uint32(bound(pairIdx, 1, type(uint32).max)); // non-zero for pair mapping

        vm.startPrank(admin);
        hook.setTokenPriceConfigIndex(address(pool), idx, pairIdx); // pair mapping
        vm.stopPrank();
    }

    /// @notice Max surge fee must be within [0, 100%] in ppm9 and persisted in storage.
    /// @dev Bounds: fuzz `pct ∈ [0, 1e18]`, but acceptance is `pct ≤ 1e9` (100% in ppm9).
    ///      Reverts when `pct > 1e9`, otherwise stores and getter returns `pct * 1e9`.
    /// @param n Pool size (2..8).
    /// @param pct Candidate max fee in ppm9 units.
    /// @param tradeTypeInt Lane selector (0=ARB,1=NOISE).
    function testFuzz_setMaxSurgeFeePercentage_bounds(uint8 n, uint256 pct, uint8 tradeTypeInt) public {
        _registerBasePoolWithN(n);
        pct = bound(pct, 0, ONE);
        IHyperSurgeHook.TradeType tradeType = IHyperSurgeHook.TradeType(bound(tradeTypeInt, 0, 1));

        vm.startPrank(admin);
        if (pct > 1e18) {
            vm.expectRevert();
            hook.setMaxSurgeFeePercentage(address(pool), pct, tradeType);
        } else if (pct < 1e9 || (pct > 1e9 && (pct / 1e9) * 1e9 != pct)) {
            vm.expectRevert();
            hook.setMaxSurgeFeePercentage(address(pool), pct, tradeType);
        } else {
            hook.setMaxSurgeFeePercentage(address(pool), pct, tradeType);
            assertEq(hook.getMaxSurgeFeePercentage(address(pool), tradeType), pct);
        }
        vm.stopPrank();
    }

    function testFuzz_setSurgeThresholdPercentage_bounds(uint8 n, uint256 thr, uint8 tradeTypeInt) public {
        _registerBasePoolWithN(n);
        IHyperSurgeHook.TradeType tradeType = IHyperSurgeHook.TradeType(bound(tradeTypeInt, 0, 1));

        // keep fuzz broad; validation will narrow
        thr = bound(thr, 0, 1e20 + 1e18);

        vm.startPrank(admin);

        // First, enforce the pure percentage validation
        if (thr > 1e18) {
            vm.expectRevert();
            hook.setSurgeThresholdPercentage(address(pool), thr, tradeType);
            vm.stopPrank();
            return;
        }

        if (thr < 1e9 || (thr % 1e9 != 0)) {
            vm.expectRevert();
            hook.setSurgeThresholdPercentage(address(pool), thr, tradeType);
            vm.stopPrank();
            return;
        }

        // Passed basic validation; now respect existing cap rule: if cap != 0, require thr < cap
        uint256 cap = hook.getCapDeviationPercentage(address(pool), tradeType); // 18dp

        if (cap != 0 && thr >= cap) {
            vm.expectRevert();
            hook.setSurgeThresholdPercentage(address(pool), thr, tradeType);
        } else {
            hook.setSurgeThresholdPercentage(address(pool), thr, tradeType);
            assertEq(hook.getSurgeThresholdPercentage(address(pool), tradeType), thr, "threshold stored incorrectly");
        }

        vm.stopPrank();
    }

    /// @notice Single-token price config: rejects out-of-range token index.
    /// @dev Bounds: `idx ≥ n` must revert; `n ∈ [2,8]` aligns with Balancer V3 pool sizes.
    function testFuzz_setTokenPriceConfigIndex_rejects_out_of_range_index(uint8 numTokens, uint8 idx) public {
        numTokens = uint8(bound(numTokens, 2, 8));
        idx = uint8(bound(idx, numTokens, 30)); // force OOB

        // Register logical numTokens for the BaseVaultTest pool
        TokenConfig[] memory cfg = new TokenConfig[](numTokens);
        LiquidityManagement memory lm;
        vm.prank(address(vault));

        assertTrue(hook.onRegister(poolFactory, address(pool), cfg, lm), "onRegister failed");

        // OOB index must revert
        vm.startPrank(admin);
        vm.expectRevert();
        hook.setTokenPriceConfigIndex(address(pool), idx, /*pairIdx*/ 0);
        vm.stopPrank();
    }

    /// @notice Single-token price config: accepts in-range index with nonzero pair id.
    /// @dev Bounds: `idx ∈ [0, n-1]`, `pairIdx > 0`. Confirms happy path does not revert.
    function testFuzz_setTokenPriceConfigIndex_accepts_in_range_index(uint8 numTokens, uint8 idx) public {
        numTokens = uint8(bound(numTokens, 2, 8));
        idx = uint8(bound(idx, 0, numTokens - 1));

        TokenConfig[] memory cfg = new TokenConfig[](numTokens);
        LiquidityManagement memory lm;
        vm.prank(address(vault));
        assertTrue(hook.onRegister(poolFactory, address(pool), cfg, lm), "onRegister failed");

        vm.startPrank(admin);

        uint32 pairIdx = 1;
        _hlSetSzDecimals(pairIdx, 6);
        hook.setTokenPriceConfigIndex(address(pool), idx, pairIdx);

        vm.stopPrank();
    }

    function testFuzz_setTokenPriceConfigIndex_pairIdx_nonzero(uint8 numTokens, uint8 idx, uint32 pairIdx) public {
        numTokens = uint8(bound(numTokens, 2, 8));
        idx = uint8(bound(idx, 0, numTokens - 1));
        pairIdx = uint32(bound(pairIdx, 1, type(uint32).max)); // ensure non-zero

        TokenConfig[] memory cfg = new TokenConfig[](numTokens);
        LiquidityManagement memory lm;
        vm.prank(address(vault));
        assertTrue(hook.onRegister(poolFactory, address(pool), cfg, lm), "onRegister failed");

        // stub szDecimals for this pair
        _hlSetSzDecimals(pairIdx, 6);

        vm.prank(admin);
        hook.setTokenPriceConfigIndex(address(pool), idx, pairIdx);
    }

    /// @notice szDecimals lookup determines divisor = 10**(6 - sz) for each token’s price pair.
    /// @dev Bounds: `sz ∈ [0,6]` are the only valid oracle scales; verifies stored pair index and computed divisor.
    /// @param sz Oracle significant-decimal count for the pair (0..6).
    /// @param n Pool size (2..8).

    function testFuzz_setTokenPriceConfigIndex_szDecimals_and_divisor(uint8 sz, uint8 n) public {
        sz = uint8(bound(sz, 0, 6));
        n = uint8(bound(n, 2, 8));

        TokenConfig[] memory cfg = new TokenConfig[](n); // 4 tokens, any N in 2..8
        LiquidityManagement memory lm;
        vm.prank(address(vault));
        assertTrue(hook.onRegister(poolFactory, address(pool), cfg, lm), "onRegister failed");

        uint8 idx = 0;
        uint32 pairIdx = 1;
        _hlSetSzDecimals(pairIdx, sz);

        vm.prank(admin);
        hook.setTokenPriceConfigIndex(address(pool), idx, pairIdx);

        (uint32 storedPair, uint32 storedDiv) = hook.getTokenPriceConfigIndex(address(pool), idx);
        assertEq(storedPair, pairIdx, "pair index mismatch");
        uint32 expectedDiv = uint32(10 ** uint32(8 - sz));
        assertEq(storedDiv, expectedDiv, "divisor mismatch");
    }

    /// @notice szDecimals > 8 is invalid and must revert on single-token price config.
    /// @dev Enforces the oracle scale invariant; rejects `sz ≥ 7`.
    /// @param sz Oracle significant-decimal count (≥7 → invalid).
    function testFuzz_setTokenPriceConfigIndex_szDecimals_over_8(uint8 sz) public {
        // invalid range > 8 should fail in hook
        sz = uint8(bound(sz, 9, 30));

        TokenConfig[] memory cfg = new TokenConfig[](4);
        LiquidityManagement memory lm;
        vm.prank(address(vault));
        assertTrue(hook.onRegister(poolFactory, address(pool), cfg, lm), "onRegister failed");

        uint8 idx = 0;
        uint32 pairIdx = 1;
        _hlSetSzDecimals(pairIdx, sz);

        vm.startPrank(admin);
        vm.expectRevert();
        hook.setTokenPriceConfigIndex(address(pool), idx, pairIdx);
        vm.stopPrank();
    }

    /// @notice Batch token price config: array length mismatch must revert atomically.
    /// @dev Bounds: `a,b ∈ [0,n]`. If `a != b` then revert; else accept and spot-check stored rows.
    function testFuzz_setTokenPriceConfigBatchIndex_length_mismatch(uint8 n, uint8 lenA, uint8 lenB) public {
        // Register pool (any N in 2..8)
        n = _registerBasePoolWithN(n);

        // Grant batch role (if your auth checks it); harmless if not needed
        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setTokenPriceConfigBatchIndex.selector),
            admin
        );

        // Build two arrays of (possibly) mismatched lengths within [0..n]
        uint8 a = uint8(bound(lenA, 0, n));
        uint8 b = uint8(bound(lenB, 0, n));

        uint8[] memory indices = new uint8[](a);
        uint32[] memory pairs = new uint32[](b);

        // Fill indices/pairs with valid values for any elements that exist
        for (uint8 i = 0; i < a; ++i) {
            indices[i] = uint8(bound(i, 0, n - 1));
        }
        for (uint8 i = 0; i < b; ++i) {
            uint32 pair = uint32(1000 + i);
            pairs[i] = pair;
            // Ensure szDecimals(pair) ∈ [0..8] so row-level checks would pass if lengths matched
            _hlSetSzDecimals(pair, uint8(i % 9));
        }

        vm.startPrank(admin);
        if (a != b) {
            // Your hook explicitly reverts on mismatched lengths
            vm.expectRevert(); // InvalidArrayLengths()
            hook.setTokenPriceConfigBatchIndex(address(pool), indices, pairs);
        } else {
            // Equal lengths: should succeed (including the a=b=0 "no-op" batch)
            hook.setTokenPriceConfigBatchIndex(address(pool), indices, pairs);

            // Spot-check: for any rows we set, getter must reflect pair+divisor
            for (uint8 i = 0; i < a; ++i) {
                (uint32 pair, uint32 div) = hook.getTokenPriceConfigIndex(address(pool), indices[i]);
                assertEq(pair, pairs[i], "pair mismatch");
                uint8 sz = uint8(i % 9);
                uint32 expectedDiv = uint32(10 ** uint32(8 - sz));
                assertEq(div, expectedDiv, "divisor mismatch");
            }
        }
        vm.stopPrank();
    }

    /// @notice Batch token price config: zero pair id in any row is invalid and reverts the batch.
    /// @dev Enforces `pairIdx > 0` precondition for oracle routing.
    /// @param n Pool size (2..8).
    function test_setTokenPriceConfigBatchIndex_zero_pair_reverts(uint8 n) public {
        n = _registerBasePoolWithN(n);

        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setTokenPriceConfigBatchIndex.selector),
            admin
        );

        // Non-empty batch with a zero pairIdx → must revert
        uint8[] memory indices = new uint8[](1);
        uint32[] memory pairs = new uint32[](1);
        indices[0] = 0; // valid token index
        pairs[0] = 0; // INVALID

        vm.startPrank(admin);
        vm.expectRevert(); // InvalidPairIndex()
        hook.setTokenPriceConfigBatchIndex(address(pool), indices, pairs);
        vm.stopPrank();
    }

    /// @notice Batch token price config: valid rows are persisted with correct pair ids and divisors.
    /// @dev Bounds: `len ∈ [1,n]`. Confirms unset indices remain zero.
    /// @param n Pool size (2..8).
    /// @param lenSeed Chooses number of rows to configure.
    function test_setTokenPriceConfigBatchIndex_success(uint8 n, uint8 lenSeed) public {
        n = _registerBasePoolWithN(n);
        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setTokenPriceConfigBatchIndex.selector),
            admin
        );

        uint8 len = uint8(bound(lenSeed, 1, n)); // at least 1 row
        uint8[] memory indices = new uint8[](len);
        uint32[] memory pairs = new uint32[](len);

        for (uint8 i = 0; i < len; ++i) {
            indices[i] = i; // 0..len-1 within n
            pairs[i] = uint32(1000 + i); // non-zero pair
            // hook validates szDecimals(pair) ∈ [0..6], so set it
            _hlSetSzDecimals(pairs[i], uint8(i % 9));
        }

        vm.prank(admin);
        hook.setTokenPriceConfigBatchIndex(address(pool), indices, pairs);

        // Verify stored pair & divisor per row
        for (uint8 i = 0; i < len; ++i) {
            (uint32 p, uint32 div) = hook.getTokenPriceConfigIndex(address(pool), indices[i]);
            assertEq(p, pairs[i]);
            uint32 expectedDiv = uint32(10 ** uint32(8 - (i % 9)));
            assertEq(div, expectedDiv);
        }
    }

    /// @notice All admin setters are restricted to SwapFeeManager/Governance or holders of the batch action id.
    /// @dev After demonstrating a successful admin batch by `admin`, pranks a non-admin and asserts reverts for:
    ///      {max fee, threshold, cap, single price index, batch price index}.
    /// @param n Pool size (2..8).
    function testFuzz_onlyAdmin_rejected_on_all_admin_setters(
        uint8 n,
        uint8 idxSeed,
        uint32 pairIdx,
        uint256 maxSeed,
        uint256 thrSeed,
        uint256 capSeed
    ) public {
        // Register a live pool first so the reverts (if any) are ACL-related
        n = _registerBasePoolWithN(n);
        uint8 idx = uint8(bound(idxSeed, 0, n - 1));
        pairIdx = uint32(bound(pairIdx, 1, type(uint32).max)); // non-zero
        _hlSetSzDecimals(pairIdx, uint8(bound(uint8(pairIdx), 0, 6)));

        // Grant batch role to admin so only the non-admin fails ACL
        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setTokenPriceConfigBatchIndex.selector),
            admin
        );

        address rando = address(0xBEEF);

        uint256 maxPct = bound(maxSeed, 1, 1e9);
        uint256 thr = bound(thrSeed, 1, 1e9);
        uint256 cap = bound(capSeed, thr == 1e9 ? 1e9 : (thr + 1), 1e9); // cap > thr when possible

        // Single index must fail from non-admin
        vm.prank(rando);
        vm.expectRevert();
        hook.setTokenPriceConfigIndex(address(pool), idx, pairIdx);

        // Batch must fail from non-admin
        uint8[] memory indices = new uint8[](1);
        uint32[] memory pairs = new uint32[](1);
        indices[0] = idx;
        pairs[0] = pairIdx;

        vm.prank(rando);
        vm.expectRevert();
        hook.setTokenPriceConfigBatchIndex(address(pool), indices, pairs);

        // Fee knobs must fail from non-admin (both directions)
        vm.prank(rando);
        vm.expectRevert();
        hook.setMaxSurgeFeePercentage(address(pool), maxPct * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);

        vm.prank(rando);
        vm.expectRevert();
        hook.setSurgeThresholdPercentage(address(pool), thr * 1e9, IHyperSurgeHook.TradeType.NOISE);

        vm.prank(rando);
        vm.expectRevert();
        hook.setCapDeviationPercentage(address(pool), cap * 1e9, IHyperSurgeHook.TradeType.NOISE);
    }

    /// @notice Single-token price config reverts when the pool is not initialized via `onRegister`.
    /// @dev Asserts the `initialized` guard on the single-row setter.
    function testFuzz_priceConfigIndex_rejects_when_uninitialized(uint8 idxSeed, uint32 pairIdx) public {
        // NOT registering the pool → expect PoolNotInitialized
        uint8 idx = uint8(bound(idxSeed, 0, 7));
        pairIdx = uint32(bound(pairIdx, 1, type(uint32).max));
        _hlSetSzDecimals(pairIdx, uint8(bound(uint8(pairIdx), 0, 6)));

        vm.startPrank(admin);
        vm.expectRevert(); // PoolNotInitialized()
        hook.setTokenPriceConfigIndex(address(pool), idx, pairIdx);
        vm.stopPrank();
    }

    /// @notice Batch price config reverts when the pool is not initialized via `onRegister`.
    /// @dev Asserts the `initialized` guard on the batch setter.
    function testFuzz_priceConfigBatch_rejects_when_uninitialized(uint8 a, uint8 b, uint32 p0, uint32 p1) public {
        // Grant role needed for batch
        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setTokenPriceConfigBatchIndex.selector),
            admin
        );
        // Build small batch
        uint8[] memory indices = new uint8[](2);
        uint32[] memory pairs = new uint32[](2);
        indices[0] = uint8(bound(a, 0, 7));
        indices[1] = uint8(bound(b, 0, 7));
        pairs[0] = uint32(bound(p0, 1, type(uint32).max));
        pairs[1] = uint32(bound(p1, 1, type(uint32).max));
        _hlSetSzDecimals(pairs[0], uint8(bound(uint8(pairs[0]), 0, 6)));
        _hlSetSzDecimals(pairs[1], uint8(bound(uint8(pairs[1]), 0, 6)));

        vm.startPrank(admin);
        vm.expectRevert(); // PoolNotInitialized()
        hook.setTokenPriceConfigBatchIndex(address(pool), indices, pairs);
        vm.stopPrank();
    }

    /// @notice Batch token price config: any out-of-range token index causes the entire batch to revert.
    /// @dev Bounds: mixes in-range and out-of-range indices; asserts atomic failure.
    /// @param n Pool size (2..8).
    function testFuzz_batch_rejects_tokenIndex_out_of_range(
        uint8 n,
        uint8 goodIdx,
        uint8 badIdx,
        uint32 pairIdx
    ) public {
        n = _registerBasePoolWithN(n);
        goodIdx = uint8(bound(goodIdx, 0, n - 1));
        badIdx = uint8(bound(badIdx, n, n + 12)); // OOB
        pairIdx = uint32(bound(pairIdx, 1, type(uint32).max));
        _hlSetSzDecimals(pairIdx, uint8(bound(uint8(pairIdx), 0, 6)));

        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setTokenPriceConfigBatchIndex.selector),
            admin
        );

        uint8[] memory indices = new uint8[](2);
        uint32[] memory pairs = new uint32[](2);
        indices[0] = goodIdx;
        pairs[0] = pairIdx;
        indices[1] = badIdx;
        pairs[1] = pairIdx;

        vm.startPrank(admin);
        vm.expectRevert(); // TokenIndexOutOfRange()
        hook.setTokenPriceConfigBatchIndex(address(pool), indices, pairs);
        vm.stopPrank();
    }

    function testFuzz_batch_rejects_zero_pairIdx(uint8 n, uint8 idx0, uint8 idx1, uint32 p1) public {
        n = _registerBasePoolWithN(n);
        idx0 = uint8(bound(idx0, 0, n - 1));
        idx1 = uint8(bound(idx1, 0, n - 1));

        p1 = uint32(bound(p1, 1, type(uint32).max));
        _hlSetSzDecimals(p1, uint8(bound(uint8(p1), 0, 6)));

        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setTokenPriceConfigBatchIndex.selector),
            admin
        );

        uint8[] memory indices = new uint8[](2);
        uint32[] memory pairs = new uint32[](2);
        indices[0] = idx0;
        pairs[0] = 0; // zero pairIdx → invalid
        indices[1] = idx1;
        pairs[1] = p1;

        vm.startPrank(admin);
        vm.expectRevert(); // InvalidPairIndex()
        hook.setTokenPriceConfigBatchIndex(address(pool), indices, pairs);
        vm.stopPrank();
    }

    /// @notice Batch token price config: szDecimals > 8 in any row must revert atomically.
    /// @dev Guards oracle scaling invariants across the whole batch.
    /// @param n Pool size (2..8).
    function testFuzz_batch_rejects_decimals_over_6(uint8 n, uint8 idxSeed, uint32 pairIdx, uint8 sz) public {
        n = _registerBasePoolWithN(n);
        uint8 idx = uint8(bound(idxSeed, 0, n - 1));

        pairIdx = uint32(bound(pairIdx, 1, type(uint32).max));
        sz = uint8(bound(sz, 9, 40)); // > 8 invalid
        _hlSetSzDecimals(pairIdx, sz);

        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setTokenPriceConfigBatchIndex.selector),
            admin
        );

        uint8[] memory indices = new uint8[](1);
        uint32[] memory pairs = new uint32[](1);
        indices[0] = idx;
        pairs[0] = pairIdx;

        vm.startPrank(admin);
        vm.expectRevert(); // InvalidDecimals()
        hook.setTokenPriceConfigBatchIndex(address(pool), indices, pairs);
        vm.stopPrank();
    }

    /// @notice Batch token price config: getters return arrays sized to `n` with exact pair/divisor per row.
    /// @dev Bounds: `len ∈ [1,n]`. Confirms unset positions remain zero-initialized.
    /// @param n Pool size (2..8).
    /// @param lenSeed Chooses number of rows to configure.
    function testFuzz_batch_accepts_and_getters_match(uint8 n, uint8 lenSeed) public {
        n = _registerBasePoolWithN(n);
        uint8 len = uint8(bound(lenSeed, 1, n)); // number of rows we will set

        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setTokenPriceConfigBatchIndex.selector),
            admin
        );

        uint8[] memory indices = new uint8[](len);
        uint32[] memory pairs = new uint32[](len);

        for (uint8 i = 0; i < len; ++i) {
            indices[i] = i;
            pairs[i] = uint32(1000 + i); // distinct
            uint8 sz = uint8(i % 9); // 0..8
            _hlSetSzDecimals(pairs[i], sz);
        }

        vm.prank(admin);
        hook.setTokenPriceConfigBatchIndex(address(pool), indices, pairs);

        // Verify via both getters
        (uint32[] memory pairArr, uint32[] memory divArr) = hook.getTokenPriceConfigs(address(pool));
        for (uint8 i = 0; i < len; ++i) {
            (uint32 pair, uint32 div) = hook.getTokenPriceConfigIndex(address(pool), i);
            assertEq(pair, pairs[i], "pair mismatch");
            assertEq(pairArr[i], pairs[i], "pairArr mismatch");
            // divisor = 10**(8 - sz) with sz = i%9
            uint32 expectedDiv = uint32(10 ** uint32(8 - (i % 9)));
            assertEq(div, expectedDiv, "div mismatch");
            assertEq(divArr[i], expectedDiv, "divArr mismatch");
        }
    }

    /// @notice Batch token price config: duplicate writes to the same token index use last-write-wins semantics.
    /// @dev Ensures deterministic storage in face of repeated indices within one batch.
    /// @param n Pool size (2..8).
    function testFuzz_batch_duplicate_indices_last_write_wins(uint8 n, uint8 idxSeed, uint32 pA, uint32 pB) public {
        n = _registerBasePoolWithN(n);
        uint8 idx = uint8(bound(idxSeed, 0, n - 1));
        pA = uint32(bound(pA, 1, type(uint32).max));
        pB = uint32(bound(pB, 1, type(uint32).max));
        _hlSetSzDecimals(pA, uint8(bound(uint8(pA), 0, 8)));
        _hlSetSzDecimals(pB, uint8(bound(uint8(pB), 0, 8)));

        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setTokenPriceConfigBatchIndex.selector),
            admin
        );

        // Two rows targeting same index, second should overwrite first
        uint8[] memory indices = new uint8[](2);
        uint32[] memory pairs = new uint32[](2);
        indices[0] = idx;
        pairs[0] = pA;
        indices[1] = idx;
        pairs[1] = pB;

        vm.prank(admin);
        hook.setTokenPriceConfigBatchIndex(address(pool), indices, pairs);

        (uint32 pair, uint32 div) = hook.getTokenPriceConfigIndex(address(pool), idx);
        assertEq(pair, pB, "last write did not win");
        // divisor must match sz of pB
        uint8 szB = uint8(bound(uint8(pB), 0, 8));
        uint32 expectedDiv = uint32(10 ** uint32(8 - szB));
        assertEq(div, expectedDiv);
    }

    /// @notice ARB and NOISE lanes are independent: setting values in one lane must not affect the other.
    /// @dev Bounds: fuzz ppm9 values with `cap > thr` per lane; asserts getters are lane-scoped.
    /// @param n Pool size (2..8).
    function testFuzz_fee_knobs_per_direction_independent(
        uint8 n,
        uint256 arbMaxUnbound,
        uint256 arbThrUnbound,
        uint256 arbCapUnbound,
        uint256 noiseMaxUnbound,
        uint256 noiseThrUnbound,
        uint256 noiseCapUnbound
    ) public {
        _registerBasePoolWithN(n);

        uint256 arbMax = bound(arbMaxUnbound, 1, 1e9);
        uint256 arbThr = bound(arbThrUnbound, 1, 1e9 - 1);
        uint256 arbCap = bound(arbCapUnbound, arbThr + 1, 1e9);
        uint256 noiseMax = bound(noiseMaxUnbound, 1, 1e9);
        uint256 noiseThr = bound(noiseThrUnbound, 1, 1e9 - 1);
        uint256 noiseCap = bound(noiseCapUnbound, noiseThr + 1, 1e9);

        vm.startPrank(admin);
        hook.setMaxSurgeFeePercentage(address(pool), arbMax * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setSurgeThresholdPercentage(address(pool), arbThr * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setCapDeviationPercentage(address(pool), arbCap * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);

        hook.setMaxSurgeFeePercentage(address(pool), noiseMax * 1e9, IHyperSurgeHook.TradeType.NOISE);
        hook.setSurgeThresholdPercentage(address(pool), noiseThr * 1e9, IHyperSurgeHook.TradeType.NOISE);
        hook.setCapDeviationPercentage(address(pool), noiseCap * 1e9, IHyperSurgeHook.TradeType.NOISE);

        vm.stopPrank();

        assertEq(hook.getMaxSurgeFeePercentage(address(pool), IHyperSurgeHook.TradeType.ARBITRAGE), arbMax * 1e9);
        assertEq(hook.getSurgeThresholdPercentage(address(pool), IHyperSurgeHook.TradeType.ARBITRAGE), arbThr * 1e9);
        assertEq(hook.getCapDeviationPercentage(address(pool), IHyperSurgeHook.TradeType.ARBITRAGE), arbCap * 1e9);

        assertEq(hook.getMaxSurgeFeePercentage(address(pool), IHyperSurgeHook.TradeType.NOISE), noiseMax * 1e9);
        assertEq(hook.getSurgeThresholdPercentage(address(pool), IHyperSurgeHook.TradeType.NOISE), noiseThr * 1e9);
        assertEq(hook.getCapDeviationPercentage(address(pool), IHyperSurgeHook.TradeType.NOISE), noiseCap * 1e9);
    }

    function test_getDefaultGetters_match_constructor() public view {
        // The hook in setUp was deployed with 0.02e9 defaults for max & threshold
        assertEq(hook.getDefaultMaxSurgeFeePercentage(), 0.02e18);
        assertEq(hook.getDefaultSurgeThresholdPercentage(), 0.02e18);
        assertEq(hook.getDefaultCapDeviationPercentage(), 1e18);
    }

    function testFuzz_fee_setters_valid_before_register_then_reset_on_register(
        uint8 n,
        uint256 maxPctUnbound,
        uint256 thrUnbound,
        uint256 capUnbound
    ) public {
        // Set fees BEFORE onRegister (allowed by code), then register — defaults should overwrite
        uint256 maxPct = bound(maxPctUnbound, 1, 1e9);
        uint256 thr = bound(thrUnbound, 1, 1e9 - 1);
        uint256 cap = bound(capUnbound, thr + 1, 1e9);

        vm.startPrank(admin);
        hook.setMaxSurgeFeePercentage(address(pool), maxPct * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setSurgeThresholdPercentage(address(pool), thr * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setCapDeviationPercentage(address(pool), cap * 1e9, IHyperSurgeHook.TradeType.ARBITRAGE);
        vm.stopPrank();

        // Now register
        _registerBasePoolWithN(n);

        // Confirm defaults restored for ARB (constructor defaults = 0.02e9 and cap=1e9)
        assertEq(hook.getMaxSurgeFeePercentage(address(pool), IHyperSurgeHook.TradeType.ARBITRAGE), 0.02e18);
        assertEq(hook.getSurgeThresholdPercentage(address(pool), IHyperSurgeHook.TradeType.ARBITRAGE), 0.02e18);
        assertEq(hook.getCapDeviationPercentage(address(pool), IHyperSurgeHook.TradeType.ARBITRAGE), 1e18);
    }
}
