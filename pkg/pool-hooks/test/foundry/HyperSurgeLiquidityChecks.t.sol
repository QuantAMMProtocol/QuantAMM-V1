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
import { AddLiquidityKind, RemoveLiquidityKind } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

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
import { HyperSurgeHook } from ".../../contracts/hooks-quantamm/HyperSurgeHook.sol";
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

contract HyperSurgeLiquidityCheckTest is BaseVaultTest, HyperSurgeHookDeployer, WeightedPoolContractsDeployer {
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

    function _hlSetSpot(uint32 pairIdx, uint32 price_1e6) internal {
        bytes32 slot = keccak256(abi.encode(bytes32(uint256(pairIdx)), bytes32(uint256(0))));
        vm.store(HL_PRICE_PRECOMPILE, slot, bytes32(uint256(price_1e6)));
    }

    function _hlSetSzDecimals(uint32 pairIdx, uint8 sz) internal {
        bytes32 slot = keccak256(abi.encode(bytes32(uint256(pairIdx)), bytes32(uint256(0))));
        vm.store(HL_TOKENINFO_PRECOMPILE, slot, bytes32(uint256(sz)));
    }

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

    /* ───────────────────────── helpers ───────────────────────── */

    function _poolTokenCount() internal view returns (uint8) {
        uint256 len = WeightedPool(address(pool)).getNormalizedWeights().length;
        require(len > 0 && len <= type(uint8).max, "weights");
        return uint8(len);
    }

    /// Register with nUsed = min(bound(n,2..8), poolTokenCount)
    function _registerBasePoolWithPoolN(uint8 n) internal returns (uint8 nUsed) {
        uint8 poolN = _poolTokenCount();
        nUsed = uint8(bound(n, 2, 8));
        if (nUsed > poolN) nUsed = poolN;

        TokenConfig[] memory cfg = new TokenConfig[](nUsed);
        LiquidityManagement memory lm;
        vm.prank(address(vault)); // onlyVault
        bool ok = hook.onRegister(poolFactory, address(pool), cfg, lm);
        assertTrue(ok, "onRegister failed");
    }

    /// Configure HL for all token indices [0..nUsed-1]
    function _configHLForAll(uint8 nUsed, uint32 basePairSeed, uint8 szSeed) internal {
        uint8 sz = uint8(bound(szSeed, 0, 6));
        uint32 base = uint32(bound(uint256(basePairSeed), 1, type(uint32).max - nUsed - 1));
        for (uint8 i = 0; i < nUsed; ++i) {
            uint32 pairIdx = base + i; // non-zero, distinct
            _hlSetSzDecimals(pairIdx, sz); // 0..6
            _hlSetSpot(pairIdx, 1); // raw=1 (ratio stability)
            vm.prank(admin);
            hook.setTokenPriceConfigIndex(address(pool), i, pairIdx);
        }
    }

    /// Small, permissive thresholds in ppb (1e9)
    function _configThresholds() internal {
        vm.startPrank(admin);
        hook.setMaxSurgeFeePercentage(address(pool), 50_000_000, IHyperSurgeHook.TradeType.NOISE); // 5%
        hook.setSurgeThresholdPercentage(address(pool), 1_000_000, IHyperSurgeHook.TradeType.NOISE); // 0.1%
        hook.setCapDeviationPercentage(address(pool), 500_000_000, IHyperSurgeHook.TradeType.NOISE); // 50%
        vm.stopPrank();
    }

    function _balancesEqual(uint8 nUsed) internal pure returns (uint256[] memory balances) {
        balances = new uint256[](nUsed);
        for (uint8 i = 0; i < nUsed; ++i) {
            balances[i] = 1e20;
        }
    }

    function _balancesProportionalToWeights(uint8 nUsed) internal view returns (uint256[] memory balances) {
        uint256[] memory weights = WeightedPool(address(pool)).getNormalizedWeights(); // 1e18 scale, sum=1e18
        balances = new uint256[](nUsed);
        uint256 scale = 1e20; // big scale to reduce rounding noise
        for (uint8 i = 0; i < nUsed; ++i) {
            uint256 bi = (scale * weights[i]) / 1e18;
            balances[i] = bi == 0 ? 1 : bi;
        }
    }

    function testFuzz_onAfterAddLiquidity_proportional_allows_n(
        uint8 n,
        uint32 pairSeed,
        uint8 szSeed,
        uint256 amtSeed
    ) public {
        uint8 nUsed = _registerBasePoolWithPoolN(n);
        _configHLForAll(nUsed, pairSeed, szSeed);
        _configThresholds();

        uint256[] memory balances = _balancesEqual(nUsed);
        uint256[] memory amountsScaled18 = new uint256[](nUsed);
        uint256[] memory amountsRaw = new uint256[](nUsed);

        for (uint8 i = 0; i < nUsed; ++i) {
            uint256 weightScaled = 1e18 * (i + 1);
            uint256 amount = (uint256(keccak256(abi.encode(amtSeed, i))) % (weightScaled / 10 + 1));
            amountsScaled18[i] = amount;
            amountsRaw[i] = amount;
        }

        vm.prank(address(vault));
        (bool ok, ) = hook.onAfterAddLiquidity(
            address(this),
            address(pool),
            AddLiquidityKind.PROPORTIONAL,
            amountsScaled18,
            amountsRaw,
            0,
            balances,
            ""
        );
        assertTrue(ok, "PROPORTIONAL must allow");
    }

    function testFuzz_onAfterAddLiquidity_lengthMismatch_allows_n(
        uint8 n,
        uint32 pairSeed,
        uint8 szSeed,
        uint8 extraSeed
    ) public {
        uint8 nUsed = _registerBasePoolWithPoolN(n);
        _configHLForAll(nUsed, pairSeed, szSeed);
        _configThresholds();

        uint256[] memory balances = _balancesEqual(nUsed);

        // Use LONGER arrays (nUsed + k, k>=1) → hook loops by balances.length; no OOB; still mismatch ⇒ allow
        uint8 k = uint8(1 + (extraSeed % 3));
        uint256[] memory amountScaled18 = new uint256[](nUsed + k);
        uint256[] memory amountsRaw = new uint256[](nUsed + k);

        vm.prank(address(vault));
        (bool ok, ) = hook.onAfterAddLiquidity(
            address(this),
            address(pool),
            AddLiquidityKind.UNBALANCED,
            amountScaled18,
            amountsRaw,
            0,
            balances,
            ""
        );

        assertTrue(ok, "length mismatch must allow");
    }

    function testFuzz_onAfterAddLiquidity_underflow_reverts_n(
        uint8 n,
        uint32 pairSeed,
        uint8 szSeed,
        uint256 bump
    ) public {
        uint8 nUsed = _registerBasePoolWithPoolN(n);
        _configHLForAll(nUsed, pairSeed, szSeed);
        _configThresholds();

        uint256[] memory balances = _balancesEqual(nUsed);
        uint256[] memory amountsScaled18 = new uint256[](nUsed);
        uint256[] memory amountsRaw = new uint256[](nUsed);

        // Force underflow in old = B' - in (index 0): in > B'
        uint256 overflowBump = ((bump % 5) + 1);
        amountsScaled18[0] = balances[0] + overflowBump;
        amountsRaw[0] = amountsScaled18[0];

        vm.startPrank(address(vault));
        vm.expectRevert(); // current hook reverts on this arithmetic underflow
        hook.onAfterAddLiquidity(
            address(this),
            address(pool),
            AddLiquidityKind.UNBALANCED,
            amountsScaled18,
            amountsRaw,
            0,
            balances,
            ""
        );
        vm.stopPrank();
    }

    function testFuzz_onAfterAddLiquidity_improves_allows_n(
        uint8 n,
        uint32 pairSeed,
        uint8 szSeed,
        uint256 delta
    ) public {
        uint8 nUsed = _registerBasePoolWithPoolN(n);
        _configHLForAll(nUsed, pairSeed, szSeed);
        _configThresholds();

        // old imbalanced (old = Bp - d at idx0), after Bp balanced
        uint256[] memory balances = _balancesEqual(nUsed);
        uint256[] memory amountsScaled18 = new uint256[](nUsed);
        uint256[] memory amountsRaw = new uint256[](nUsed);

        delta = bound(delta, 1, balances[0] / 2);
        amountsScaled18[0] = delta;
        amountsRaw[0] = delta; // old = [Bp0 - d, Bp1, ...] → after improves to balanced

        vm.prank(address(vault));
        (bool ok, ) = hook.onAfterAddLiquidity(
            address(this),
            address(pool),
            AddLiquidityKind.UNBALANCED,
            amountsScaled18,
            amountsRaw,
            0,
            balances,
            ""
        );
        assertTrue(ok, "improving/neutral deviation must allow");
    }

    function testFuzz_onAfterRemoveLiquidity_proportional_allows_n(
        uint8 n,
        uint32 pairSeed,
        uint8 szSeed,
        uint256 amtSeed
    ) public {
        uint8 nUsed = _registerBasePoolWithPoolN(n);
        _configHLForAll(nUsed, pairSeed, szSeed);
        _configThresholds();

        uint256[] memory balances = _balancesEqual(nUsed);
        uint256[] memory amountsScaled18 = new uint256[](nUsed);
        uint256[] memory amountsRaw = new uint256[](nUsed);
        for (uint8 i = 0; i < nUsed; ++i) {
            uint256 b = 1e18 * (i + 1);
            uint256 a = (uint256(keccak256(abi.encode(amtSeed, i))) % (b / 10 + 1));
            amountsScaled18[i] = a;
            amountsRaw[i] = a;
        }

        vm.prank(address(vault));
        (bool ok, ) = hook.onAfterRemoveLiquidity(
            address(this),
            address(pool),
            RemoveLiquidityKind.PROPORTIONAL,
            0,
            amountsScaled18,
            amountsRaw,
            balances,
            ""
        );
        assertTrue(ok, "PROPORTIONAL must allow");
    }

    function testFuzz_onAfterRemoveLiquidity_lengthMismatch_allows_n(
        uint8 n,
        uint32 pairSeed,
        uint8 szSeed,
        uint8 extraSeed
    ) public {
        uint8 nUsed = _registerBasePoolWithPoolN(n);
        _configHLForAll(nUsed, pairSeed, szSeed);
        _configThresholds();

        uint256[] memory balances = _balancesEqual(nUsed);

        // longer arrays → mismatch but no OOB
        uint8 k = uint8(1 + (extraSeed % 3));
        uint256[] memory amountsScaled18 = new uint256[](nUsed + k);
        uint256[] memory amountsRaw = new uint256[](nUsed + k);

        vm.prank(address(vault));
        (bool ok, ) = hook.onAfterRemoveLiquidity(
            address(this),
            address(pool),
            RemoveLiquidityKind.SINGLE_TOKEN_EXACT_IN,
            0,
            amountsScaled18,
            amountsRaw,
            balances,
            ""
        );
        assertTrue(ok, "length mismatch must allow");
    }

    function testFuzz_onAfterRemoveLiquidity_overflow_allows_n(uint8 n, uint32 pairSeed, uint8 szSeed) public {
        uint8 nUsed = _registerBasePoolWithPoolN(n);
        _configHLForAll(nUsed, pairSeed, szSeed);
        _configThresholds();

        // Force old = B' + out to overflow at idx 0 → hook should ALLOW (conservative)
        uint256[] memory balances = _balancesEqual(nUsed);
        uint256[] memory amountsScaled18 = new uint256[](nUsed);
        uint256[] memory amountsRaw = new uint256[](nUsed);
        balances[0] = type(uint256).max;
        amountsScaled18[0] = 1;
        amountsRaw[0] = 1;

        vm.prank(address(vault));
        (bool ok, ) = hook.onAfterRemoveLiquidity(
            address(this),
            address(pool),
            RemoveLiquidityKind.SINGLE_TOKEN_EXACT_IN,
            0,
            amountsScaled18,
            amountsRaw,
            balances,
            ""
        );
        assertTrue(ok, "overflow reconstruction should allow");
    }

    function testFuzz_onAfterAddLiquidity_worsens_blocks_n(
        uint8 n,
        uint32 pairSeed,
        uint8 szSeed,
        uint256 deltaSeed
    ) public {
        // Register and configure all tokens with HL pairs (ext ratio = 1)
        uint8 nUsed = _registerBasePoolWithPoolN(n);
        _configHLForAll(nUsed, pairSeed, szSeed);
        _configThresholds(); // default NOISE threshold 2% in 1e9

        // Construct pre-add (old) balances proportional to weights ⇒ beforeDev == 0
        uint256[] memory oldB = _balancesProportionalToWeights(nUsed);

        // Choose a single-sided add on token 0 big enough to exceed the 2% threshold
        uint256 minDelta = (oldB[0] * 3) / 100; // ≥3% to be safely > threshold (2%)
        uint256 maxDelta = oldB[0] / 2; // keep it tame
        uint256 d = bound(deltaSeed, minDelta == 0 ? 1 : minDelta, maxDelta == 0 ? 1 : maxDelta);

        // Post-add balances B' = old + in
        uint256[] memory Bprime = new uint256[](nUsed);
        for (uint8 i = 0; i < nUsed; ++i) {
            Bprime[i] = oldB[i];
        }
        Bprime[0] = Bprime[0] + d;

        // AmountsIn arrays (scaled18/raw) matching B' - old
        uint256[] memory amountsScaled18 = new uint256[](nUsed);
        uint256[] memory amountsRaw = new uint256[](nUsed);
        amountsScaled18[0] = d;
        amountsRaw[0] = d;

        // Call hook as vault
        vm.prank(address(vault));
        (bool ok, ) = hook.onAfterAddLiquidity(
            address(this),
            address(pool),
            AddLiquidityKind.UNBALANCED,
            amountsScaled18,
            amountsRaw,
            0,
            Bprime,
            ""
        );

        // We started on-oracle (beforeDev≈0) and moved away by ≥3% ⇒ must block.
        assertFalse(ok, "worsening deviation must block");
    }

    function testFuzz_onAfterRemoveLiquidity_worsens_blocks_n(
        uint8 n,
        uint32 pairSeed,
        uint8 szSeed,
        uint256 deltaSeed
    ) public {
        // Register and configure all tokens with HL pairs (ext ratio = 1)
        uint8 nUsed = _registerBasePoolWithPoolN(n);
        _configHLForAll(nUsed, pairSeed, szSeed);
        _configThresholds(); // default NOISE threshold 2%

        // Pre-remove "old" balances proportional to weights ⇒ beforeDev == 0
        uint256[] memory oldB = _balancesProportionalToWeights(nUsed);

        // Choose a single-sided removal on token 0 big enough to exceed the 2% threshold
        uint256 minDelta = (oldB[0] * 3) / 100; // ≥3%
        uint256 maxDelta = oldB[0] / 2;
        uint256 d = bound(deltaSeed, minDelta == 0 ? 1 : minDelta, maxDelta == 0 ? 1 : maxDelta);

        // Post-remove balances B' = old − out (make sure it doesn't underflow)
        uint256[] memory Bprime = new uint256[](nUsed);
        for (uint8 i = 0; i < nUsed; ++i) {
            Bprime[i] = oldB[i];
        }
        Bprime[0] = Bprime[0] - d;

        // AmountsOut arrays (scaled18/raw) matching old − B'
        uint256[] memory amountsScaled18 = new uint256[](nUsed);
        uint256[] memory amountsRaw = new uint256[](nUsed);
        amountsScaled18[0] = d;
        amountsRaw[0] = d;

        // Call hook as vault
        vm.prank(address(vault));
        (bool ok, ) = hook.onAfterRemoveLiquidity(
            address(this),
            address(pool),
            RemoveLiquidityKind.SINGLE_TOKEN_EXACT_IN,
            0,
            amountsScaled18,
            amountsRaw,
            Bprime,
            ""
        );

        // From on-oracle to ≥3% away ⇒ must block.
        assertFalse(ok, "worsening deviation must block");
    }

    function testFuzz_onAfterRemoveLiquidity_improves_allows_n(
        uint8 n,
        uint32 pairSeed,
        uint8 szSeed,
        uint256 delta
    ) public {
        uint8 nUsed = _registerBasePoolWithPoolN(n);
        _configHLForAll(nUsed, pairSeed, szSeed);
        _configThresholds();

        // old imbalanced; choose B' balanced by having out only on idx0
        uint256[] memory Bp = _balancesEqual(nUsed);
        uint256[] memory amountsScaled18 = new uint256[](nUsed);
        uint256[] memory amountsRaw = new uint256[](nUsed);

        uint256 d = bound(delta, 1, Bp[0] / 2);
        amountsScaled18[0] = d;
        amountsRaw[0] = d; // old = B' + d at idx0 → imbalanced; after is balanced

        vm.prank(address(vault));
        (bool ok, ) = hook.onAfterRemoveLiquidity(
            address(this),
            address(pool),
            RemoveLiquidityKind.SINGLE_TOKEN_EXACT_IN,
            0,
            amountsScaled18,
            amountsRaw,
            Bp,
            ""
        );
        assertTrue(ok, "improving/neutral deviation must allow");
    }
}
