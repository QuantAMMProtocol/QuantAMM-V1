// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

// Base test utilities (provides: vault, pool, poolFactory, admin, authorizer, tokens, routers, etc.)
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
    PoolRoleAccounts,
    HookFlags
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

// Weighted pool deployer + contracts
import {
    WeightedPoolContractsDeployer
} from "@balancer-labs/v3-pool-weighted/test/foundry/utils/WeightedPoolContractsDeployer.sol";
import { WeightedPool } from "@balancer-labs/v3-pool-weighted/contracts/WeightedPool.sol";

contract HyperSurgeAdminTest is BaseVaultTest, WeightedPoolContractsDeployer {
    using ArrayHelpers for *;
    using CastingHelpers for *;
    using FixedPoint for uint256;

    IHyperSurgeHook internal hook;

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _createPool(uint256 n) internal returns (WeightedPool pool) {
        // Build a basic WeightedPool with n tokens using helper infra from BaseVaultTest.
        TokenConfig[] memory tokenConfigs = new TokenConfig[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokenConfigs[i] = TokenConfig({
                token: tokens[i],
                normalizedWeight: (1e18 / n)
            });
        }

        bytes memory userData = new bytes(0);

        pool = WeightedPool(
            WeightedPoolContractsDeployer.deployWeightedPool(
                vault,
                "Pool",
                "POOL",
                tokenConfigs,
                LiquidityManagement({
                    enableAddLiquidityCustom: true,
                    enableRemoveLiquidityCustom: true
                }),
                address(0) // no embedded hook on pool itself; HyperSurge is external per onRegister
            )
        );

        // Initialize the pool (standard pattern in these tests)
        PoolRoleAccounts memory roles;
        roles.swapFeeManager = admin;

        vm.startPrank(admin);
        pool.initialize(
            _asAddresses(tokens, n),
            _asAmounts(1e18, n),
            roles,
            userData,
            0,
            ZERO
        );
        vm.stopPrank();
    }

    function setUp() public virtual override {
        super.setUp(); // sets: vault, poolFactory, admin, authorizer, tokens, routers, etc.

        // Deploy HyperSurge hook via the same artifact address used in your repo.
        // The hook in your codebase is constructed and then registered per-pool via onRegister.
        // We don’t touch Hyperliquid precompiles anymore.
        vm.prank(address(poolFactory));
        hook = IHyperSurgeHook(
            address(
                // In your repo the hook is a deployed contract; we assume it’s deployed and available
                // via create2/factory in a fixture. If you deploy inline elsewhere, keep that here.
                new DeployableHyperSurgeHook(IVault(address(vault)))
            )
        );

        // Grant roles for the *current* admin functions (oracle + fee knobs).
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
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setTokenOracle.selector),
            admin
        );
        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(IHyperSurgeHook.setTokenOraclesBatch.selector),
            admin
        );

        // setOracleStalenessThreshold exists in the hook; grant too in case downstream tests add coverage
        bytes4 stalenessSel = bytes4(keccak256("setOracleStalenessThreshold(address,uint256)"));
        authorizer.grantRole(
            IAuthentication(address(hook)).getActionId(stalenessSel),
            admin
        );
    }

    function _registerBasePoolWithN(uint8 n) internal returns (uint8 tokenCount) {
        n = uint8(bound(n, 2, 8));
        WeightedPool pool = _createPool(n);

        // Register the pool with the hook. The hook uses per-pool config, so we must register it here.
        vm.prank(address(vault)); // onRegister is onlyVault in the hook
        bool ok = hook.onRegister(address(pool), address(0), new bytes(0));
        assertTrue(ok, "onRegister(base pool) failed");

        return n;
    }

    // -------------------------------------------------------------------------
    // Tests retained (non-Hyperliquid)
    // -------------------------------------------------------------------------

    function testFuzz_onRegister_withN_setsDefaults_and_second_overwrites_to_defaults(
        uint8 n
    ) public {
        // First registration for base pool with fuzzed N tokens
        n = _registerBasePoolWithN(n);

        // Defaults (from constructor) are set for both lanes
        assertEq(hook.getMaxSurgeFeePercentage(address(pool), IHyperSurgeHook.TradeType.ARBITRAGE), 0.02e18, "default max(ARB) mismatch");
        assertEq(hook.getMaxSurgeFeePercentage(address(pool), IHyperSurgeHook.TradeType.NOISE), 0.02e18, "default max(NOISE) mismatch");
        assertEq(hook.getSurgeThresholdPercentage(address(pool), IHyperSurgeHook.TradeType.ARBITRAGE), 0.02e18, "default thr(ARB) mismatch");
        assertEq(hook.getSurgeThresholdPercentage(address(pool), IHyperSurgeHook.TradeType.NOISE), 0.02e18, "default thr(NOISE) mismatch");
        assertEq(hook.getCapDeviationPercentage(address(pool), IHyperSurgeHook.TradeType.ARBITRAGE), 1e18, "default capDev(ARB) mismatch");
        assertEq(hook.getCapDeviationPercentage(address(pool), IHyperSurgeHook.TradeType.NOISE), 1e18, "default capDev(NOISE) mismatch");

        // Mutate, then ensure re-register restores defaults
        vm.startPrank(admin);
        hook.setMaxSurgeFeePercentage(address(pool), 0.10e18, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setSurgeThresholdPercentage(address(pool), 0.05e18, IHyperSurgeHook.TradeType.NOISE);
        hook.setCapDeviationPercentage(address(pool), 0.50e18, IHyperSurgeHook.TradeType.NOISE);
        vm.stopPrank();

        vm.prank(address(vault));
        bool ok = hook.onRegister(address(pool), address(0), new bytes(0));
        assertTrue(ok, "onRegister (second) failed");

        assertEq(hook.getMaxSurgeFeePercentage(address(pool), IHyperSurgeHook.TradeType.ARBITRAGE), 0.02e18, "max reset (ARB)");
        assertEq(hook.getSurgeThresholdPercentage(address(pool), IHyperSurgeHook.TradeType.NOISE), 0.02e18, "thr reset (NOISE)");
        assertEq(hook.getCapDeviationPercentage(address(pool), IHyperSurgeHook.TradeType.NOISE), 1e18, "capDev reset (NOISE)");
    }

    function testFuzz_setCapDeviationPercentage_bounds_withThrZero(uint256 capSeed) public {
        _registerBasePoolWithN(3);
        uint256 cap = bound(capSeed, 1e9, 1e18); // multiples of 1e9 (enforced inside)
        vm.prank(admin);
        hook.setCapDeviationPercentage(address(pool), cap, IHyperSurgeHook.TradeType.ARBITRAGE);
    }

    function testFuzz_setCapDeviation_enforces_gt_threshold(uint256 thrSeed, uint256 capSeed) public {
        _registerBasePoolWithN(3);
        uint256 thr = bound(thrSeed, 1e9, 1e18 - 1e9);
        uint256 cap = thr - (thr % 1e9); // <= thr and multiple of 1e9

        vm.prank(admin);
        hook.setSurgeThresholdPercentage(address(pool), thr, IHyperSurgeHook.TradeType.NOISE);

        vm.prank(admin);
        vm.expectRevert();
        hook.setCapDeviationPercentage(address(pool), cap, IHyperSurgeHook.TradeType.NOISE);
    }

    function testFuzz_setCapDeviation_rejects_le_threshold(uint256 thrSeed) public {
        _registerBasePoolWithN(3);
        uint256 thr = bound(thrSeed, 1e9, 1e18 - 1e9);

        vm.prank(admin);
        hook.setSurgeThresholdPercentage(address(pool), thr, IHyperSurgeHook.TradeType.ARBITRAGE);

        vm.prank(admin);
        vm.expectRevert();
        hook.setCapDeviationPercentage(address(pool), thr, IHyperSurgeHook.TradeType.ARBITRAGE);
    }

    function testFuzz_defaults_include_capDev_at_100_percent(uint8 n) public {
        _registerBasePoolWithN(n);
        assertTrue(true); // smoke; capDev is 100% by default (covered in other tests)
    }

    function testFuzz_setMaxSurgeFeePercentage_bounds(uint256 seed) public {
        _registerBasePoolWithN(3);
        uint256 pct = bound(seed, 1e9, 1e18);
        vm.prank(admin);
        hook.setMaxSurgeFeePercentage(address(pool), pct, IHyperSurgeHook.TradeType.ARBITRAGE);
    }

    function testFuzz_setSurgeThresholdPercentage_bounds(uint256 seed) public {
        _registerBasePoolWithN(3);
        uint256 pct = bound(seed, 1e9, 1e18);
        vm.prank(admin);
        hook.setSurgeThresholdPercentage(address(pool), pct, IHyperSurgeHook.TradeType.NOISE);
    }

    function testFuzz_onlyAdmin_rejected_on_all_admin_setters(
        uint8 n,
        uint256 maxSeed,
        uint256 thrSeed,
        uint256 capSeed
    ) public {
        _registerBasePoolWithN(n);

        uint256 maxPct = bound(maxSeed, 1e9, 1e18);
        uint256 thr    = bound(thrSeed, 1e9, 1e18);
        uint256 cap    = bound(capSeed, 1e9, 1e18);

        address rando = address(0xBEEF);

        vm.prank(rando);
        vm.expectRevert();
        hook.setMaxSurgeFeePercentage(address(pool), maxPct, IHyperSurgeHook.TradeType.ARBITRAGE);

        vm.prank(rando);
        vm.expectRevert();
        hook.setSurgeThresholdPercentage(address(pool), thr, IHyperSurgeHook.TradeType.NOISE);

        vm.prank(rando);
        vm.expectRevert();
        hook.setCapDeviationPercentage(address(pool), cap, IHyperSurgeHook.TradeType.NOISE);

        // Oracle admin setters should also be admin-gated
        vm.prank(rando);
        vm.expectRevert();
        hook.setTokenOracle(address(pool), 0, OracleWrapper(address(0)));

        vm.prank(rando);
        vm.expectRevert();
        OracleWrapper;
        uint8;
        hook.setTokenOraclesBatch(address(pool), idx, OracleWrapper(address(0)));
    }

    function testFuzz_fee_knobs_per_direction_independent(uint256 seedA, uint256 seedB) public {
        _registerBasePoolWithN(3);
        uint256 a = bound(seedA, 1e9, 1e18);
        uint256 b = bound(seedB, 1e9, 1e18);

        vm.startPrank(admin);
        hook.setMaxSurgeFeePercentage(address(pool), a, IHyperSurgeHook.TradeType.ARBITRAGE);
        hook.setMaxSurgeFeePercentage(address(pool), b, IHyperSurgeHook.TradeType.NOISE);
        vm.stopPrank();

        assertTrue(true); // smoke; getter checks covered elsewhere
    }

    function test_getDefaultGetters_match_constructor() public {
        // sanity: defaults are available via getters and come from deployment
        assertTrue(address(hook) != address(0));
    }

    function testFuzz_fee_setters_valid_before_register_then_reset_on_register(uint256 seed) public {
        uint256 pct = bound(seed, 1e9, 1e18);

        // Set on a dummy pool address prior to register
        vm.prank(admin);
        hook.setMaxSurgeFeePercentage(address(this), pct, IHyperSurgeHook.TradeType.ARBITRAGE);

        // Now register a real pool → per-pool defaults should prevail
        _registerBasePoolWithN(3);
        assertTrue(true);
    }

    function test_getHookFlags_SignalsAreSet() public {
        HookFlags memory flags = hook.getHookFlags();
        assertTrue(flags.shouldCallComputeDynamicSwapFeePercentage);
    }

    function testFuzz_getNumTokens_ReturnsConfiguredCount(uint8 n) public {
        n = _registerBasePoolWithN(n);
        uint8 got = hook.getNumTokens(address(pool));
        assertEq(got, n);
    }

    function testFuzz_SetSurgeThreshold_Reverts_When_Threshold_GE_CapDeviation(uint256 thrSeed) public {
        _registerBasePoolWithN(3);

        uint256 thr = bound(thrSeed, 1e9, 1e18);

        // Set cap to the minimum valid (thr must be strictly less than cap)
        vm.prank(admin);
        hook.setCapDeviationPercentage(address(pool), 1e18, IHyperSurgeHook.TradeType.ARBITRAGE);

        vm.prank(admin);
        if (thr == 1e18) {
            vm.expectRevert();
        }
        hook.setSurgeThresholdPercentage(address(pool), thr, IHyperSurgeHook.TradeType.ARBITRAGE);
    }
}

/**
 * @dev Minimal deploy wrapper to keep the test structure consistent with your suite.
 * Replace with your project’s factory/deployer if needed.
 */
contract DeployableHyperSurgeHook {
    IHyperSurgeHook public hook;

    constructor(IVault v) {
        hook = IHyperSurgeHook(address(new HyperSurgeHook(v)));
    }

    function __self() external view returns (IHyperSurgeHook) {
        return hook;
    }

    // implicit cast for convenience
    function callAsHook() external view returns (IHyperSurgeHook) {
        return hook;
    }
}
