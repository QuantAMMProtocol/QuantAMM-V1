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

    function _hlSetSpot(uint32 pairIdx, uint32 price_1e6) internal {
        bytes32 slot = keccak256(abi.encode(bytes32(uint256(pairIdx)), bytes32(uint256(0))));
        vm.store(HL_PRICE_PRECOMPILE, slot, bytes32(uint256(price_1e6)));
    }

    function _hlSetSzDecimals(uint32 tokenIdx, uint8 sz) internal {
        bytes32 slot = keccak256(abi.encode(bytes32(uint256(tokenIdx)), bytes32(uint256(0))));
        vm.store(HL_TOKENINFO_PRECOMPILE, slot, bytes32(uint256(sz)));
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
        uint8 sz = uint8(bound(szSeed, 1, 8));
        uint32 base = uint32(bound(uint256(basePairSeed), 21, type(uint32).max - nUsed - 21));
        for (uint8 i = 0; i < nUsed; ++i) {
            uint32 pairIdx = base + i; // non-zero, distinct
            uint32 tokenIdx = base + i + 20; // 0..nUsed-1
            _hlSetSzDecimals(tokenIdx, sz); // 0..6
            _hlSetSpot(pairIdx, 1); // raw=1 (ratio stability)
            vm.prank(admin);
            hook.setTokenPriceConfigIndex(address(pool), i, pairIdx, tokenIdx);
        }
    }

    /// Small, permissive thresholds in ppb (1e9)
    function _configThresholds() internal {
        vm.startPrank(admin);
        hook.setMaxSurgeFeePercentage(address(pool), 50_000_000_000000000, IHyperSurgeHook.TradeType.NOISE); // 5%
        hook.setSurgeThresholdPercentage(address(pool), 1_000_000_000000000, IHyperSurgeHook.TradeType.NOISE); // 0.1%
        hook.setCapDeviationPercentage(address(pool), 500_000_000_000000000, IHyperSurgeHook.TradeType.NOISE); // 50%
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

    /// CASE 1: Starts outside threshold and worsens ⇒ must BLOCK.
    /// Old: token0 5% BELOW proportional (above-price, |dev|=5%).
    /// Remove: further 2% from token0 ⇒ |dev| increases (remains outside).
    function testFuzz_onAfterRemoveLiquidity_case1_outside_worsens_blocks_n(
        uint8 nSeed,
        uint32 pairSeed,
        uint8 szSeed
    ) public {
        uint8 n = _registerBasePoolWithPoolN(uint8(bound(nSeed, 2, 8)));
        _configHLForAll(n, pairSeed, szSeed);
        _configThresholds(); // ~2%

        // Balanced baseline
        uint256[] memory base = _balancesProportionalToWeights(n);

        // Old state O: token0 reduced by 5%
        uint256 d5 = base[0] / 20;
        if (d5 == 0) d5 = 1;
        uint256[] memory deviatedBalances = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            deviatedBalances[k] = base[k];
        }
        deviatedBalances[0] = base[0] - d5;

        // Post B' : remove an additional 2% from token0
        uint256 d2 = base[0] / 50;
        if (d2 == 0) d2 = 1;
        uint256[] memory Bprime = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            Bprime[k] = deviatedBalances[k];
        }
        Bprime[0] = deviatedBalances[0] - d2;

        // Amounts = O - B'
        uint256[] memory amountsScaled18 = new uint256[](n);
        uint256[] memory amountsRaw = new uint256[](n);
        amountsScaled18[0] = deviatedBalances[0] - Bprime[0];
        amountsRaw[0] = amountsScaled18[0];

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

        assertFalse(ok, "outside + worsened must block");
    }

    /// CASE 2: Starts outside threshold, improves but still outside ⇒ must ALLOW.
    /// Old: token0 5% BELOW proportional (|dev|=5%).
    /// Remove: 1% from token1 ⇒ shrinks |dev| to ~4% (>2%) but improves.
    function testFuzz_onAfterRemoveLiquidity_case2_outside_improves_but_outside_allows_n(
        uint8 nSeed,
        uint32 pairSeed,
        uint8 szSeed
    ) public {
        uint8 n = _registerBasePoolWithPoolN(uint8(bound(nSeed, 2, 8)));
        _configHLForAll(n, pairSeed, szSeed);
        _configThresholds();

        uint256[] memory base = _balancesProportionalToWeights(n);

        // Old O: token0 5% low
        uint256 d5 = base[0] / 20;
        if (d5 == 0) {
            d5 = 1;
        }
        uint256[] memory deviatedBalances = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            deviatedBalances[k] = base[k];
        }
        deviatedBalances[0] = base[0] - d5;

        // Post B' : remove 1% from token1 -> reduces deviation but stays > 2%
        uint256 d1 = base[1] / 100;
        if (d1 == 0) {
            d1 = 1;
        }
        uint256[] memory Bprime = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            Bprime[k] = deviatedBalances[k];
        }
        Bprime[1] = deviatedBalances[1] - d1;

        uint256[] memory amountsScaled18 = new uint256[](n);
        uint256[] memory amountsRaw = new uint256[](n);
        amountsScaled18[1] = deviatedBalances[1] - Bprime[1];
        amountsRaw[1] = amountsScaled18[1];

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

        assertTrue(ok, "outside but improving (still outside) must allow");
    }

    /// CASE 3: Starts inside threshold, worsens but stays inside ⇒ must ALLOW.
    /// Old: token0 1% BELOW proportional (|dev|=1% < 2%).
    /// Remove: extra 0.5% from token0 ⇒ |dev|~1.5% still inside.
    function testFuzz_onAfterRemoveLiquidity_case3_inside_worsens_but_inside_allows_n(
        uint8 nSeed,
        uint32 pairSeed,
        uint8 szSeed
    ) public {
        uint8 n = _registerBasePoolWithPoolN(uint8(bound(nSeed, 2, 8)));
        _configHLForAll(n, pairSeed, szSeed);
        _configThresholds();

        vm.startPrank(admin);
        // 2% in ppm9 (2e7); use NOISE lane because onAfterRemoveLiquidity checks NOISE
        hook.setSurgeThresholdPercentage(address(pool), 20_000_000_000000000, IHyperSurgeHook.TradeType.NOISE);
        vm.stopPrank();

        uint256[] memory base = _balancesProportionalToWeights(n);

        uint256 d1 = base[0] / 100;
        if (d1 == 0) {
            d1 = 1;
        } // 1%
        uint256 d05 = base[0] / 200;
        if (d05 == 0) {
            d05 = 1;
        } // 0.5%

        uint256[] memory deviatedBalances = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            deviatedBalances[k] = base[k];
        }
        deviatedBalances[0] = base[0] - d1;

        uint256[] memory Bprime = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            Bprime[k] = deviatedBalances[k];
        }
        Bprime[0] = deviatedBalances[0] - d05; // worsens but still <= 2%

        uint256[] memory amountsScaled18 = new uint256[](n);
        uint256[] memory amountsRaw = new uint256[](n);
        amountsScaled18[0] = deviatedBalances[0] - Bprime[0];
        amountsRaw[0] = amountsScaled18[0];

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

        assertTrue(ok, "inside but worsening (still inside) must allow");
    }

    /// CASE 4: Starts inside threshold, worsens but stays inside (opposite orientation) ⇒ ALLOW.
    /// Old: token0 1% ABOVE proportional (below-price, |dev|=1%).
    /// Remove: 0.5% from token1 (reduces token1) ⇒ increases relative excess of token0 but still < 2%.
    function testFuzz_onAfterRemoveLiquidity_case4_inside_worsens_but_inside_allows_alt_n(
        uint8 nSeed,
        uint32 pairSeed,
        uint8 szSeed
    ) public {
        uint8 n = _registerBasePoolWithPoolN(uint8(bound(nSeed, 2, 8)));
        _configHLForAll(n, pairSeed, szSeed);
        _configThresholds();

        vm.startPrank(admin);
        // 2% in ppm9 (2e7); use NOISE lane because onAfterRemoveLiquidity checks NOISE
        hook.setSurgeThresholdPercentage(address(pool), 20_000_000_000000000, IHyperSurgeHook.TradeType.NOISE);
        vm.stopPrank();

        uint256[] memory base = _balancesProportionalToWeights(n);

        uint256 d1 = base[0] / 100;
        if (d1 == 0) {
            d1 = 1;
        } // 1%
        uint256 d05 = base[1] / 200;
        if (d05 == 0) {
            d05 = 1;
        } // 0.5%

        uint256[] memory deviatedBalances = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            deviatedBalances[k] = base[k];
        }
        deviatedBalances[0] = base[0] + d1; // token0 too large (below-price orientation)

        uint256[] memory Bprime = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            Bprime[k] = deviatedBalances[k];
        }
        Bprime[1] = deviatedBalances[1] - d05; // makes token0 relatively larger ⇒ worsens but still inside

        uint256[] memory amountsScaled18 = new uint256[](n);
        uint256[] memory amountsRaw = new uint256[](n);
        amountsScaled18[1] = deviatedBalances[1] - Bprime[1];
        amountsRaw[1] = amountsScaled18[1];

        vm.startPrank(address(vault));
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
        vm.stopPrank();

        assertTrue(ok, "inside but worsening (alt orientation) must allow");
    }

    /// CASE 5: Starts outside ABOVE-price, ends outside BELOW-price ⇒ must BLOCK.
    /// Old: token0 5% BELOW proportional (above-price).
    /// Remove: 10% from token1 ⇒ cross to the other side with |dev| ≈ 5.6% (>2%).
    function testFuzz_onAfterRemoveLiquidity_case5_outside_above_to_outside_below_blocks_n(
        uint8 nSeed,
        uint32 pairSeed,
        uint8 szSeed
    ) public {
        uint8 n = _registerBasePoolWithPoolN(uint8(bound(nSeed, 2, 8)));
        _configHLForAll(n, pairSeed, szSeed);
        _configThresholds();

        uint256[] memory base = _balancesProportionalToWeights(n);

        uint256 d5 = base[0] / 20;
        if (d5 == 0) {
            d5 = 1;
        } // 5%
        uint256 d10 = base[1] / 10;
        if (d10 == 0) {
            d10 = 1;
        } // 10%

        uint256[] memory deviatedBalances = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            deviatedBalances[k] = base[k];
        }
        deviatedBalances[0] = base[0] - d5; // above-price

        uint256[] memory Bprime = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            Bprime[k] = deviatedBalances[k];
        }
        Bprime[1] = deviatedBalances[1] - d10; // strong remove from token1 ⇒ flip and still outside

        uint256[] memory amountsScaled18 = new uint256[](n);
        uint256[] memory amountsRaw = new uint256[](n);
        amountsScaled18[1] = deviatedBalances[1] - Bprime[1];
        amountsRaw[1] = amountsScaled18[1];

        vm.startPrank(address(vault));
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
        vm.stopPrank();

        assertFalse(ok, "outside above -> outside below (worsened) must block");
    }

    /// CASE 6: Starts outside BELOW-price, ends outside ABOVE-price ⇒ must BLOCK.
    /// Old: token0 5% ABOVE proportional (below-price).
    /// Remove: amount so token0 ends ~0.95 * base (≈5% above-price) ⇒ still outside and worsened.
    function testFuzz_onAfterRemoveLiquidity_case6_outside_below_to_same_above_allows_n(
        uint8 nSeed,
        uint32 pairSeed,
        uint8 szSeed
    ) public {
        uint8 n = _registerBasePoolWithPoolN(uint8(bound(nSeed, 2, 8)));
        _configHLForAll(n, pairSeed, szSeed);
        _configThresholds();

        uint256[] memory base = _balancesProportionalToWeights(n);

        uint256 d5 = base[0] / 20;
        if (d5 == 0) {
            d5 = 1;
        } // 5%

        // Old O: token0 5% high (below-price)
        uint256[] memory deviatedBalances = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            deviatedBalances[k] = base[k];
        }
        deviatedBalances[0] = base[0] + d5;

        // Target post: token0 ≈ 95% of base ⇒ remove d = O0 - 0.95*base0 = (1.05 - 0.95)*base0 = 0.10*base0
        uint256 dTarget = base[0] / 10;
        if (dTarget == 0) dTarget = 1;

        uint256[] memory Bprime = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            Bprime[k] = deviatedBalances[k];
        }
        // Safe by construction: O0 = 1.05*base0 ≥ base0/10
        Bprime[0] = deviatedBalances[0] - dTarget;

        uint256[] memory amountsScaled18 = new uint256[](n);
        uint256[] memory amountsRaw = new uint256[](n);
        amountsScaled18[0] = deviatedBalances[0] - Bprime[0];
        amountsRaw[0] = amountsScaled18[0];

        vm.startPrank(address(vault));
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
        vm.stopPrank();

        assertTrue(ok, "must be greater than, equal is fine");
    }

    /// CASE 6 (worsened): Starts outside BELOW-price, ends outside ABOVE-price with *larger* deviation ⇒ must BLOCK.
    /// Old: token0 slightly ABOVE proportional (≈2.5% → below-price).
    /// Post: token0 well BELOW proportional (≈10% → above-price).
    /// With _configThresholds() (e.g., ≈2%), both states are outside, and afterDev > beforeDev ⇒ hook blocks.
    function testFuzz_onAfterRemoveLiquidity_case6_outside_below_to_outside_above_blocks_n(
        uint8 nSeed,
        uint32 pairSeed,
        uint8 szSeed
    ) public {
        // Pool & oracle config (HL sets 1:1 ext px so deviations are driven by balances)
        uint8 n = _registerBasePoolWithPoolN(uint8(bound(nSeed, 2, 8)));
        _configHLForAll(n, pairSeed, szSeed);
        _configThresholds(); // ensure a small threshold (≈2%) so both sides are outside

        // Balanced baseline (proportional to weights)
        uint256[] memory base = _balancesProportionalToWeights(n);

        // Choose before/after magnitudes: before ≈ 2.5%, after ≈ 10% (both > threshold, and after > before).
        uint256 dBefore = base[0] / 40; // 2.5%
        if (dBefore == 0) {
            dBefore = 1;
        }
        uint256 dAfter = base[0] / 10; // 10%
        if (dAfter == 0) {
            dAfter = 1;
        }

        // Old O: token0 2.5% HIGH (below-price side)
        uint256[] memory deviatedBalances = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            deviatedBalances[k] = base[k];
        }
        deviatedBalances[0] = base[0] + dBefore;

        // Post B': token0 10% LOW (above-price side); other tokens remain at base
        uint256[] memory Bprime = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            Bprime[k] = deviatedBalances[k];
        }
        Bprime[0] = base[0] - dAfter;

        // SINGLE_TOKEN_EXACT_IN remove: amounts = O - B' (only index 0 non-zero)
        uint256[] memory amountsScaled18 = new uint256[](n);
        uint256[] memory amountsRaw = new uint256[](n);
        amountsScaled18[0] = deviatedBalances[0] - Bprime[0]; // dBefore + dAfter
        amountsRaw[0] = amountsScaled18[0];

        // Call must be from vault
        vm.startPrank(address(vault));
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
        vm.stopPrank();

        // Crossed sides and deviation magnitude increased -> afterDev > beforeDev and afterDev > threshold -> block
        assertFalse(ok, "outside below -> outside above (worsened) must block");
    }

    /// CASE 7: Starts outside BELOW-price, ends inside ABOVE-price ⇒ must ALLOW (improves into threshold).
    /// Old: token0 5% ABOVE proportional (below-price).
    /// Remove: amount so token0 ends ~0.99 * base (≈1% above-price) ⇒ inside threshold and improved.
    function testFuzz_onAfterRemoveLiquidity_case7_outside_below_to_inside_above_allows_n(
        uint8 nSeed,
        uint32 pairSeed,
        uint8 szSeed
    ) public {
        uint8 n = _registerBasePoolWithPoolN(uint8(bound(nSeed, 2, 8)));
        _configHLForAll(n, pairSeed, szSeed);
        _configThresholds();

        uint256[] memory base = _balancesProportionalToWeights(n);

        uint256 d5 = base[0] / 20;
        if (d5 == 0) {
            d5 = 1;
        } // 5%
        uint256 d06 = base[0] / 16;
        if (d06 == 0) {
            d06 = 1;
        } // ~6.25% (≈ from 1.05 -> ~0.9875), close enough; still < 2% if tuned

        // Old: 5% high
        uint256[] memory deviatedBalances = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            deviatedBalances[k] = base[k];
        }
        deviatedBalances[0] = base[0] + d5;

        // Post: remove ~6% of base0 from token0 so it crosses to slightly low (~<=1–1.5%), inside threshold.
        uint256[] memory Bprime = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            Bprime[k] = deviatedBalances[k];
        }
        if (d06 >= deviatedBalances[0]) {
            d06 = deviatedBalances[0] - 1;
        } // safety
        Bprime[0] = deviatedBalances[0] - d06;

        uint256[] memory amountsScaled18 = new uint256[](n);
        uint256[] memory amountsRaw = new uint256[](n);
        amountsScaled18[0] = deviatedBalances[0] - Bprime[0];
        amountsRaw[0] = amountsScaled18[0];

        vm.startPrank(address(vault));
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
        vm.stopPrank();

        assertTrue(ok, "outside below -> inside above must allow");
    }

    /// CASE 8: Starts outside ABOVE-price, ends inside BELOW-price ⇒ must ALLOW (improves into threshold).
    /// Old: token0 5% BELOW proportional (above-price).
    /// Remove: ~6% from token1 ⇒ cross to slight below-price but |dev|<2%.
    function testFuzz_onAfterRemoveLiquidity_case8_outside_above_to_inside_below_allows_n(
        uint8 nSeed,
        uint32 pairSeed,
        uint8 szSeed
    ) public {
        uint8 n = _registerBasePoolWithPoolN(uint8(bound(nSeed, 2, 8)));
        _configHLForAll(n, pairSeed, szSeed);
        _configThresholds();

        uint256[] memory base = _balancesProportionalToWeights(n);

        uint256 d5 = base[0] / 20;
        if (d5 == 0) {
            d5 = 1;
        } // 5%
        uint256 d06 = base[1] / 16;
        if (d06 == 0) {
            d06 = 1;
        } // ~6.25%

        // Old: token0 5% low
        uint256[] memory deviatedBalances = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            deviatedBalances[k] = base[k];
        }
        deviatedBalances[0] = base[0] - d5;

        // Post: remove ~6% from token1 so the relative goes slightly to the other side but inside threshold
        uint256[] memory Bprime = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            Bprime[k] = deviatedBalances[k];
        }
        if (d06 >= deviatedBalances[1]) {
            d06 = deviatedBalances[1] - 1;
        } // safety
        Bprime[1] = deviatedBalances[1] - d06;

        uint256[] memory amountsScaled18 = new uint256[](n);
        uint256[] memory amountsRaw = new uint256[](n);
        amountsScaled18[1] = deviatedBalances[1] - Bprime[1];
        amountsRaw[1] = amountsScaled18[1];

        vm.startPrank(address(vault));
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
        vm.stopPrank();

        assertTrue(ok, "outside above -> inside below must allow");
    }
}
