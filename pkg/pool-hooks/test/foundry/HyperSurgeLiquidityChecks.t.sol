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

    /// @notice UNBALANCED add with a *longer* amounts array must not OOB,
    ///         and if the post-add state is balanced (old is imbalanced), the add improves/keeps deviation ⇒ allow.
    /// @dev    The hook iterates by `balances.length`, so `amounts.length == m+1` is safe (extra tail ignored).
    ///         We adapt to the hook’s actual `numTokens` by reading the price-config arrays length from storage,
    ///         then configure 1:1 external prices for all `m` tokens so deviation is driven purely by balances.
    /// @param  nSeed Pool size seed (bounded to [2,8]) – used by registration helper.
    /// @param  pairSeed Fuzzed seed for pair ids (helper will derive valid, non-zero pair ids).
    /// @param  szSeed Fuzzed seed for szDecimals (helper will clamp to ≤6).
    function testFuzz_onAfterAddLiquidity_lengthMismatch_improves_allows_n(
        uint8 nSeed,
        uint32 pairSeed,
        uint8 szSeed
    ) public {
        uint8 n = uint8(bound(nSeed, 2, 8));
        _registerBasePoolWithPoolN(n);

        // Use the hook’s actual token count (numTokens) from storage-sized arrays.
        (uint32[] memory pairs, ) = hook.getTokenPriceConfigs(address(pool));
        uint256 m = pairs.length;
        assertGe(m, 2, "pool must have at least 2 tokens");

        // Configure external prices for the *actual* m tokens, then thresholds (0.1% etc).
        _configHLForAll(uint8(m), pairSeed, szSeed);
        _configThresholds();

        // Post-add balances: perfectly balanced vector of length m.
        uint256[] memory balancesBalanced = new uint256[](m);
        for (uint256 k = 0; k < m; ++k) {
            balancesBalanced[k] = 1e24;
        }

        // Make "old" imbalanced by setting a nonzero add on index 0; use amounts length m+1 (mismatch).
        uint256 d = balancesBalanced[0] / 50; // 2% > 0.1% threshold
        if (d == 0) {
            d = 1;
        }
        uint256[] memory amountsInScaled18 = new uint256[](m + 1);
        uint256[] memory amountsInRaw = new uint256[](m + 1);
        amountsInScaled18[0] = d;
        amountsInRaw[0] = d;

        (bool ok, ) = hook.onAfterAddLiquidity(
            address(this),
            address(pool),
            AddLiquidityKind.UNBALANCED, // any non-PROPORTIONAL kind
            amountsInScaled18,
            amountsInRaw,
            0, // lpAmount (unused)
            balancesBalanced, // post-add is balanced (dev = 0)
            "" // userData (unused)
        );
        vm.stopPrank();

        assertTrue(ok, "improving/neutral deviation must allow even with longer amounts array");
    }

    /// @notice UNBALANCED add with a *longer* amounts array must not OOB,
    ///         and if the post-add state worsens deviation beyond threshold, it must block.
    /// @dev    We adapt to the hook’s `numTokens` (via price-config length), configure 1:1 prices for `m` tokens,
    ///         then create a post-add imbalance (+10% on idx 0). We set amounts[0]=bump so old = post − bump ⇒ balanced.
    ///         With small threshold (0.1%), this must block.
    /// @param  nSeed Pool size seed (bounded to [2,8]) – used by registration helper.
    /// @param  pairSeed Fuzzed seed for pair ids (helper will derive valid, non-zero pair ids).
    /// @param  szSeed Fuzzed seed for szDecimals (helper will clamp to ≤6).
    function testFuzz_onAfterAddLiquidity_lengthMismatch_worsens_blocks_n(
        uint8 nSeed,
        uint32 pairSeed,
        uint8 szSeed
    ) public {
        uint8 n = uint8(bound(nSeed, 2, 8));
        _registerBasePoolWithPoolN(n);

        (uint32[] memory pairs, ) = hook.getTokenPriceConfigs(address(pool));
        uint256 m = pairs.length;
        assertGe(m, 2, "pool must have at least 2 tokens");

        _configHLForAll(uint8(m), pairSeed, szSeed);
        _configThresholds();

        // Start from balanced vector, then make post-add imbalanced by +10% on index 0.
        uint256[] memory balancesImbalanced = new uint256[](m);
        for (uint256 k = 0; k < m; ++k) {
            balancesImbalanced[k] = 1e24;
        }
        uint256 bump = balancesImbalanced[0] / 10; // 10% >> 0.1% threshold
        if (bump == 0) {
            bump = 1;
        }
        balancesImbalanced[0] += bump;

        // amounts length m+1 (mismatch); set amounts[0]=bump so old = post-add − bump ⇒ balanced.
        uint256[] memory amountsInScaled18 = new uint256[](m + 1);
        uint256[] memory amountsInRaw = new uint256[](m + 1);
        amountsInScaled18[0] = bump;
        amountsInRaw[0] = bump;

        (bool ok, ) = hook.onAfterAddLiquidity(
            address(this),
            address(pool),
            AddLiquidityKind.UNBALANCED,
            amountsInScaled18,
            amountsInRaw,
            0,
            balancesImbalanced, // post-add: imbalanced ⇒ dev ~ 10%
            ""
        );
        vm.stopPrank();

        assertFalse(ok, "worsening deviation above threshold must block even with longer amounts array");
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

    /// @notice With checked arithmetic in onAfterRemoveLiquidity, any overflow while reconstructing
    ///         pre-remove balances (post + out) must revert (fail-fast).
    /// @dev    We fabricate an impossible state to prove the invariant: balances[0] = MAX and
    ///         amountsOutScaled18[0] = 1 ⇒ (balances + out) overflows. In production, the Vault
    ///         would not produce such inputs; this is a harness sanity check. Lengths are kept
    ///         equal to avoid the early "length mismatch ⇒ allow" branch. N is fuzzed 2..8.
    /// @param  nSeed Fuzzed pool size seed (bounded to [2,8]).
    function testFuzz_onAfterRemoveLiquidity_overflow_reverts_n(uint8 nSeed) public {
        uint8 n = uint8(bound(nSeed, 2, 8));
        _registerBasePoolWithPoolN(n);

        // Equal-length arrays to reach the arithmetic path (no early allow).
        uint256[] memory balances = new uint256[](n);
        uint256[] memory amountsOutScaled18 = new uint256[](n);
        uint256[] memory amountsOutRaw = new uint256[](n);

        // Seed sane non-zero balances, then force an overflow at index 0.
        for (uint256 i = 0; i < n; ++i) {
            balances[i] = 1e24;
        }
        balances[0] = type(uint256).max; // impossible in reality, useful to prove fail-fast
        amountsOutScaled18[0] = 1;
        amountsOutRaw[0] = 1;

        vm.expectRevert();
        hook.onAfterRemoveLiquidity(
            address(this), // sender
            address(pool), // pool
            RemoveLiquidityKind.SINGLE_TOKEN_EXACT_IN, // any non-PROPORTIONAL kind
            0, // lpAmount (unused)
            amountsOutScaled18,
            amountsOutRaw,
            balances,
            "" // userData (unused)
        );
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
