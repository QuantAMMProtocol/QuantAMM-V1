// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

// Base test utilities (provides: vault, pool, poolFactory, admin, authorizer, tokens, routers, etc.)
import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";

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

// Hook interface, oracle type and mock
import { IHyperSurgeHook } from "@balancer-labs/v3-interfaces/contracts/pool-hooks/IHyperSurgeHook.sol";
import { OracleWrapper } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/OracleWrapper.sol";
import { HyperSurgeHookMock } from "../../contracts/test/HyperSurgeHookMock.sol";

contract HyperSurgeAdminTest is BaseVaultTest, WeightedPoolContractsDeployer {
    using FixedPoint for uint256;

    IHyperSurgeHook internal hook;
    WeightedPool internal pool;

    address internal admin;

    uint256 internal DEFAULT_MAX_FEE = 5e16; // 5%
    uint256 internal DEFAULT_THRESHOLD = 2e16; // 2%
    uint256 internal DEFAULT_CAP_DEV = 10e16; // 10%

    function setUp() public virtual override {
        super.setUp();

        admin = makeAddr("admin");

        // Deploy hook (mock extends real) with constructor defaults
        hook = IHyperSurgeHook(
            address(new HyperSurgeHookMock(vault, DEFAULT_MAX_FEE, DEFAULT_THRESHOLD, DEFAULT_CAP_DEV, "test"))
        );

        // Grant auth roles for external admin calls to the hook
        _grantHookAction("setMaxSurgeFeePercentage(address,uint256,uint8)");
        _grantHookAction("setSurgeThresholdPercentage(address,uint256,uint8)");
        _grantHookAction("setCapDeviationPercentage(address,uint256,uint8)");
        _grantHookAction("setTokenOracle(address,uint8,address)");
        _grantHookAction("setTokenOraclesBatch(address,uint8[],address[])");
        _grantHookAction("setOracleStalenessThreshold(uint256,address)");

        // Create and register a pool with 2 tokens for baseline tests
        pool = _createPool(2);

        // Prepare token configs for onRegister and a minimal LiquidityManagement
        TokenConfig[] memory tokenConfigs = new TokenConfig[](2);
        for (uint256 i = 0; i < 2; ++i) {
            tokenConfigs[i] = TokenConfig({ token: tokens[i], normalizedWeight: 5e17 });
        }

        LiquidityManagement memory lm = LiquidityManagement({
            enableAddLiquidityCustom: true,
            enableRemoveLiquidityCustom: true,
            disableUnbalancedLiquidity: false,
            enableDonation: true
        });

        // onRegister is onlyVault; set per-pool defaults
        vm.prank(address(vault));
        // First parameter (hook address) is not used by the hook implementation
        HyperSurgeHookMock(address(hook)).onRegister(address(hook), address(pool), tokenConfigs, lm);
    }

    /*//////////////////////////////////////////////////////////////
                           CREATE + REGISTER HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Necessary fixture: many admin operations are per-pool scoped,
    /// so a ready pool with admin as swapFeeManager is needed in most tests.
    function _createPool(uint256 n) internal returns (WeightedPool) {
        // Build n-token weighted pool configs
        TokenConfig[] memory tokenConfigs = new TokenConfig[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokenConfigs[i] = TokenConfig({ token: tokens[i], normalizedWeight: (1e18 / n) });
        }

        bytes memory userData = new bytes(0);

        WeightedPool wp = WeightedPool(
            WeightedPoolContractsDeployer.deployWeightedPool(
                vault,
                "Pool",
                "POOL",
                tokenConfigs,
                LiquidityManagement({
                    enableAddLiquidityCustom: true,
                    enableRemoveLiquidityCustom: true,
                    disableUnbalancedLiquidity: false,
                    enableDonation: true
                }),
                address(0) // no embedded hook on pool itself; HyperSurge is external per onRegister
            )
        );

        // Initialize the pool (give admin swapFeeManager to satisfy hook access control)
        PoolRoleAccounts memory roles;
        roles.swapFeeManager = admin;

        vm.startPrank(admin);
        wp.initialize(
            _asAddresses(tokens, n),
            _asAmounts(1e18, n),
            roles,
            userData,
            0,
            0 // pause window
        );
        vm.stopPrank();

        return wp;
    }

    /// @dev Older tests used a simple registrar; restore it so fuzz tests can reuse.
    function _registerBasePoolWithN(uint8 n) internal returns (uint8 tokenCount) {
        n = uint8(bound(n, 2, 8));
        WeightedPool p = _createPool(n);

        TokenConfig[] memory tokenConfigs = new TokenConfig[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokenConfigs[i] = TokenConfig({ token: tokens[i], normalizedWeight: uint256(1e18) / n });
        }
        LiquidityManagement memory lm = LiquidityManagement({
            enableAddLiquidityCustom: true,
            enableRemoveLiquidityCustom: true,
            disableUnbalancedLiquidity: false,
            enableDonation:true
        });

        vm.prank(address(vault));
        HyperSurgeHookMock(address(hook)).onRegister(address(hook), address(p), tokenConfigs, lm);

        // update the shared state pool reference for convenience
        pool = p;
        return n;
    }

    function _grantHookAction(string memory signature) internal {
        bytes4 sel = bytes4(keccak256(bytes(signature)));
        bytes32 role = IAuthentication(address(hook)).getActionId(sel);
        IAuthorizer(address(authorizer)).grantRole(role, admin);
    }

    /*//////////////////////////////////////////////////////////////
                          DEFAULTS ON REGISTER
    //////////////////////////////////////////////////////////////*/

    function test_DefaultsAreAppliedOnRegister() public {
        assertEq(hook.getMaxSurgeFeePercentage(address(pool), IHyperSurgeHook.TradeType.ARBITRAGE), DEFAULT_MAX_FEE);
        assertEq(hook.getMaxSurgeFeePercentage(address(pool), IHyperSurgeHook.TradeType.NOISE), DEFAULT_MAX_FEE);

        assertEq(
            hook.getSurgeThresholdPercentage(address(pool), IHyperSurgeHook.TradeType.ARBITRAGE),
            DEFAULT_THRESHOLD
        );
        assertEq(hook.getSurgeThresholdPercentage(address(pool), IHyperSurgeHook.TradeType.NOISE), DEFAULT_THRESHOLD);

        assertEq(hook.getCapDeviationPercentage(address(pool), IHyperSurgeHook.TradeType.ARBITRAGE), DEFAULT_CAP_DEV);
        assertEq(hook.getCapDeviationPercentage(address(pool), IHyperSurgeHook.TradeType.NOISE), DEFAULT_CAP_DEV);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN SETTERS
    //////////////////////////////////////////////////////////////*/

    function test_AdminCanSetMaxSurgeFee() public {
        vm.prank(admin);
        hook.setMaxSurgeFeePercentage(address(pool), 8e16, IHyperSurgeHook.TradeType.ARBITRAGE);
        assertEq(hook.getMaxSurgeFeePercentage(address(pool), IHyperSurgeHook.TradeType.ARBITRAGE), 8e16);
    }

    function test_AdminCanSetThreshold() public {
        vm.prank(admin);
        hook.setSurgeThresholdPercentage(address(pool), 3e16, IHyperSurgeHook.TradeType.NOISE);
        assertEq(hook.getSurgeThresholdPercentage(address(pool), IHyperSurgeHook.TradeType.NOISE), 3e16);
    }

    function test_AdminCanSetCapDeviation() public {
        vm.prank(admin);
        hook.setCapDeviationPercentage(address(pool), 12e16, IHyperSurgeHook.TradeType.NOISE);
        assertEq(hook.getCapDeviationPercentage(address(pool), IHyperSurgeHook.TradeType.NOISE), 12e16);
    }

    function test_RevertIf_PercentageInvalid() public {
        vm.startPrank(admin);
        vm.expectRevert();
        hook.setMaxSurgeFeePercentage(address(pool), 12345, IHyperSurgeHook.TradeType.NOISE);
        vm.expectRevert();
        hook.setSurgeThresholdPercentage(address(pool), 0, IHyperSurgeHook.TradeType.NOISE);
        vm.expectRevert();
        hook.setCapDeviationPercentage(address(pool), 2e18 + 1, IHyperSurgeHook.TradeType.NOISE);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          ORACLE CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_AdminCanSetSingleTokenOracle() public {
        vm.prank(admin);
        hook.setTokenOracle(address(pool), 0, OracleWrapper(address(0xBEEF)));
        OracleWrapper oracle = hook.getTokenOracle(address(pool), 0);
        assertEq(address(oracle), address(0xBEEF));
    }

    function test_RevertIf_TokenIndexOutOfRange_SetSingle() public {
        vm.prank(admin);
        vm.expectRevert();
        hook.setTokenOracle(address(pool), 9, OracleWrapper(address(0xBEEF)));
    }

    function test_AdminCanSetBatchTokenOracles() public {
        uint8[] memory indices = new uint8[](2);
        indices[0] = 0;
        indices[1] = 1;

        OracleWrapper[] memory oracles = new OracleWrapper[](2);
        oracles[0] = OracleWrapper(address(0xA1));
        oracles[1] = OracleWrapper(address(0xB2));

        vm.prank(admin);
        hook.setTokenOraclesBatch(address(pool), indices, oracles);

        assertEq(address(hook.getTokenOracle(address(pool), 0)), address(0xA1));
        assertEq(address(hook.getTokenOracle(address(pool), 1)), address(0xB2));
    }

    function test_RevertIf_LengthMismatch_OnBatch() public {
        uint8[] memory indices = new uint8[](2);
        indices[0] = 0;
        indices[1] = 1;

        OracleWrapper[] memory oracles = new OracleWrapper[](1);
        oracles[0] = OracleWrapper(address(0xA1));

        vm.prank(admin);
        vm.expectRevert();
        hook.setTokenOraclesBatch(address(pool), indices, oracles);
    }

    function test_RevertIf_TokenIndexOutOfRange_OnBatch() public {
        uint8[] memory indices = new uint8[](2);
        indices[0] = 0;
        indices[1] = 7;

        OracleWrapper[] memory oracles = new OracleWrapper[](2);
        oracles[0] = OracleWrapper(address(0xA1));
        oracles[1] = OracleWrapper(address(0xB2));

        vm.prank(admin);
        vm.expectRevert();
        hook.setTokenOraclesBatch(address(pool), indices, oracles);
    }

    /*//////////////////////////////////////////////////////////////
                         ORACLE STALENESS THRESHOLD
    //////////////////////////////////////////////////////////////*/

    function test_SetOracleStalenessThreshold() public {
        vm.prank(admin);
        hook.setOracleStalenessThreshold(60 minutes, address(pool));

        uint256 threshold = HyperSurgeHookMock(address(hook)).oracleStalenessThreshold();
        assertEq(threshold, 60 minutes);
    }

    function test_RevertIf_SetOracleStalenessThreshold_Zero() public {
        vm.prank(admin);
        vm.expectRevert();
        hook.setOracleStalenessThreshold(0, address(pool));
    }

    /*//////////////////////////////////////////////////////////////
                         ACCESS CONTROL NEGATIVE
    //////////////////////////////////////////////////////////////*/

    function test_RevertIf_NonAdminSetsValues() public {
        address bob = makeAddr("bob");
        vm.startPrank(bob);
        vm.expectRevert();
        hook.setMaxSurgeFeePercentage(address(pool), 5e16, IHyperSurgeHook.TradeType.ARBITRAGE);
        vm.expectRevert();
        hook.setSurgeThresholdPercentage(address(pool), 2e16, IHyperSurgeHook.TradeType.NOISE);
        vm.expectRevert();
        hook.setCapDeviationPercentage(address(pool), 10e16, IHyperSurgeHook.TradeType.NOISE);
        vm.expectRevert();
        hook.setTokenOracle(address(pool), 0, OracleWrapper(address(0xC0)));
        vm.expectRevert();
        hook.setTokenOraclesBatch(address(pool), new uint8[](0), new OracleWrapper[](0));
        vm.expectRevert();
        hook.setOracleStalenessThreshold(30 minutes, address(pool));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                UTILITIES
    //////////////////////////////////////////////////////////////*/

    function _asAddresses(IERC20[] memory erc20s, uint256 n) internal pure returns (address[] memory addrs) {
        addrs = new address[](n);
        for (uint256 i = 0; i < n; ++i) addrs[i] = address(erc20s[i]);
    }

    function _asAmounts(uint256 amountEach, uint256 n) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) amounts[i] = amountEach;
    }
}
