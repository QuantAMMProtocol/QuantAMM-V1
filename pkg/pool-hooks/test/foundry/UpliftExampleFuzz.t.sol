// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    LiquidityManagement,
    PoolRoleAccounts,
    RemoveLiquidityKind,
    AfterSwapParams,
    SwapKind,
    AddLiquidityKind
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVaultExtension } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultExtension.sol";
import { IVaultAdmin } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultAdmin.sol";
import { IVaultExplorer } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultExplorer.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IVaultMock } from "@balancer-labs/v3-interfaces/contracts/test/IVaultMock.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IHooks.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { BasicAuthorizerMock } from "@balancer-labs/v3-vault/contracts/test/BasicAuthorizerMock.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { BaseTest } from "@balancer-labs/v3-solidity-utils/test/foundry/utils/BaseTest.sol";
import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { BatchRouterMock } from "@balancer-labs/v3-vault/contracts/test/BatchRouterMock.sol";
import { PoolFactoryMock } from "@balancer-labs/v3-vault/contracts/test/PoolFactoryMock.sol";
import { BalancerPoolToken } from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import { RouterMock } from "@balancer-labs/v3-vault/contracts/test/RouterMock.sol";
import { PoolMock } from "@balancer-labs/v3-vault/contracts/test/PoolMock.sol";

import { MockUpdateWeightRunner } from "pool-quantamm/contracts/mock/MockUpdateWeightRunner.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { UpliftOnlyExample } from "../../contracts/hooks-quantamm/UpliftOnlyExample.sol";
import { LPNFT } from "../../contracts/hooks-quantamm/LPNFT.sol";

contract UpliftOnlyExampleFuzzTest is BaseVaultTest {
    using CastingHelpers for address[];
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    uint256 internal daiIdx;
    uint256 internal usdcIdx;

    address internal owner;
    address internal addr1;
    address internal addr2;

    uint64 private constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16;
    uint64 private constant _MAX_SWAP_FEE_PERCENTAGE = 10e16;
    uint64 private constant _MAX_UPLIFT_WITHDRAWAL_FEE = 20e16;

    uint256 internal constant DEFAULT_AMP_FACTOR = 200;

    MockUpdateWeightRunner internal updateWeightRunner;

    UpliftOnlyExample internal upliftOnlyRouter;

    function setUp() public virtual override {
        BaseTest.setUp();
        (address ownerLocal, address addr1Local, address addr2Local) = (vm.addr(1), vm.addr(2), vm.addr(3));
        owner = ownerLocal;
        addr1 = addr1Local;
        addr2 = addr2Local;

        vault = deployVaultMock();
        vm.label(address(vault), "vault");
        vaultExtension = IVaultExtension(vault.getVaultExtension());
        vm.label(address(vaultExtension), "vaultExtension");
        vaultAdmin = IVaultAdmin(vault.getVaultAdmin());
        vm.label(address(vaultAdmin), "vaultAdmin");
        authorizer = BasicAuthorizerMock(address(vault.getAuthorizer()));
        vm.label(address(authorizer), "authorizer");
        factoryMock = PoolFactoryMock(address(vault.getPoolFactoryMock()));
        vm.label(address(factoryMock), "factory");
        router = deployRouterMock(IVault(address(vault)), weth, permit2);
        vm.label(address(router), "router");
        batchRouter = deployBatchRouterMock(IVault(address(vault)), weth, permit2);
        vm.label(address(batchRouter), "batch router");
        feeController = vault.getProtocolFeeController();
        vm.label(address(feeController), "fee controller");

        vm.startPrank(address(vaultAdmin));
        updateWeightRunner = new MockUpdateWeightRunner(address(vaultAdmin), address(addr2), true);
        vm.label(address(updateWeightRunner), "updateWeightRunner");
        updateWeightRunner.setQuantAMMSwapFeeTake(0);

        vm.stopPrank();

        vm.startPrank(owner);
        upliftOnlyRouter = new UpliftOnlyExample(
            IVault(address(vault)),
            weth,
            permit2,
            200,
            5,
            address(updateWeightRunner),
            "Uplift LiquidityPosition v1",
            "Uplift LiquidityPosition v1",
            "Uplift LiquidityPosition v1"
        );
        vm.stopPrank();
        vm.label(address(upliftOnlyRouter), "upliftOnlyRouter");

        poolHooksContract = address(upliftOnlyRouter);
        (pool, ) = createPool();

        for (uint256 i = 0; i < users.length; ++i) {
            address user = users[i];
            vm.startPrank(user);
            approveForSender();
            vm.stopPrank();
        }
        if (pool != address(0)) {
            approveForPool(IERC20(pool));
        }

        initPool();

        (daiIdx, usdcIdx) = getSortedIndexes(address(dai), address(usdc));
    }

    function approveForSender() internal override {
        for (uint256 i = 0; i < tokens.length; ++i) {
            tokens[i].approve(address(permit2), type(uint256).max);
            permit2.approve(address(tokens[i]), address(router), type(uint160).max, type(uint48).max);
            permit2.approve(address(tokens[i]), address(batchRouter), type(uint160).max, type(uint48).max);
            permit2.approve(address(tokens[i]), address(upliftOnlyRouter), type(uint160).max, type(uint48).max);
        }
    }

    // Overrides approval to include upliftOnlyRouter.
    function approveForPool(IERC20 bpt) internal override {
        for (uint256 i = 0; i < users.length; ++i) {
            vm.startPrank(users[i]);

            bpt.approve(address(router), type(uint256).max);
            bpt.approve(address(batchRouter), type(uint256).max);
            bpt.approve(address(upliftOnlyRouter), type(uint256).max);

            IERC20(bpt).approve(address(permit2), type(uint256).max);
            permit2.approve(address(bpt), address(router), type(uint160).max, type(uint48).max);
            permit2.approve(address(bpt), address(batchRouter), type(uint160).max, type(uint48).max);
            permit2.approve(address(bpt), address(upliftOnlyRouter), type(uint160).max, type(uint48).max);

            vm.stopPrank();
        }
    }

    // Overrides pool creation to set liquidityManagement (disables unbalanced liquidity).
    function _createPool(
        address[] memory tokens,
        string memory label
    ) internal override returns (address newPool, bytes memory poolArgs) {
        string memory name = "Uplift Pool";
        string memory symbol = "Uplift Pool";

        newPool = address(deployPoolMock(IVault(address(vault)), name, symbol));
        vm.label(newPool, label);
        int256[] memory prices = new int256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            prices[i] = int256(i) * 1e18;
        }
        updateWeightRunner.setMockPrices(address(newPool), prices);

        PoolRoleAccounts memory roleAccounts;
        roleAccounts.poolCreator = lp;

        LiquidityManagement memory liquidityManagement;
        liquidityManagement.disableUnbalancedLiquidity = true;
        liquidityManagement.enableDonation = true;

        factoryMock.registerPool(
            newPool,
            vault.buildTokenConfig(tokens.asIERC20()),
            roleAccounts,
            poolHooksContract,
            liquidityManagement
        );

        poolArgs = abi.encode(vault, name, symbol);
    }

    function testFuzz_AddLiquidity(uint96 fuzzBptOut) public {
        uint256 poolSupply = BalancerPoolToken(pool).totalSupply();

        uint256 maxMint = poolSupply == 0 ? type(uint96).max : poolSupply / 10;
        uint256 bptOut = bound(uint256(fuzzBptOut), 1, maxMint);

        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();

        BaseVaultTest.Balances memory before = getBalances(bob);
        uint256 supplyBefore = poolSupply;

        bytes4 AMOUNT_IN_ABOVE_MAX_SELECTOR = bytes4(keccak256("AmountInAboveMax(address,uint256,uint256)"));
        uint256[] memory amountsIn;

        vm.startPrank(bob);
        (bool ok, bytes memory ret) = address(upliftOnlyRouter).call(
            abi.encodeWithSelector(
                upliftOnlyRouter.addLiquidityProportional.selector,
                pool,
                maxAmountsIn,
                bptOut,
                false,
                bytes("")
            )
        );
        vm.stopPrank();

        if (!ok) {
            bytes4 sel;
            assembly {
                sel := mload(add(ret, 32))
            }
            assertEq(sel, AMOUNT_IN_ABOVE_MAX_SELECTOR, "unexpected revert");
            return;
        }

        amountsIn = abi.decode(ret, (uint256[]));

        BaseVaultTest.Balances memory after_ = getBalances(bob);
        uint256 supplyAfter = BalancerPoolToken(pool).totalSupply();

        assertEq(before.bobTokens[daiIdx] - after_.bobTokens[daiIdx], amountsIn[daiIdx], "DAI spent mismatch");
        assertEq(before.bobTokens[usdcIdx] - after_.bobTokens[usdcIdx], amountsIn[usdcIdx], "USDC spent mismatch");

        assertEq(supplyAfter - supplyBefore, bptOut, "BPT minted mismatch");

        UpliftOnlyExample.FeeData memory fd = upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0];

        assertEq(fd.amount, bptOut, "recorded BPT amount wrong");
        assertEq(fd.upliftFeeBps, upliftOnlyRouter.upliftFeeBps(), "upliftFeeBps wrong");
        assertEq(upliftOnlyRouter.nftPool(fd.tokenID), pool, "nftPool lookup wrong");

        assertEq(BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)), bptOut, "router BPT balance wrong");
        assertEq(after_.bobBpt, 0, "Bob should hold no BPT (NFT represents position)");
    }

    function testFuzz_DepositLimit(uint8 depositCountFuzz, uint96 bptPerDepositFuzz) public {
        uint256 depositCount = bound(uint256(depositCountFuzz), 1, 120);

        uint256 poolSupply = BalancerPoolToken(pool).totalSupply();
        uint256 bptPerDeposit = bound(uint256(bptPerDepositFuzz), 1, poolSupply == 0 ? 1e18 : poolSupply / 1000);

        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();

        vm.startPrank(bob);

        for (uint256 i; i < depositCount; ++i) {
            if (i >= 100) {
                vm.expectRevert(abi.encodeWithSelector(UpliftOnlyExample.TooManyDeposits.selector, pool, bob));
            }

            upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptPerDeposit, false, bytes(""));

            if (i >= 100) break;

            skip(2 seconds);
        }

        vm.stopPrank();

        uint256 expectedDeposits = depositCount > 100 ? 100 : depositCount;
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, expectedDeposits, "FeeData length mismatch");
    }

    function testFuzz_TransferDepositsAtRandom(uint256 seed, uint256 depositLength) public {
        uint256 depositBound = bound(depositLength, 1, 10);
        /**
         * This can be changed to the max 98 however it takes some time!
         * uint256 depositBound = bound(depositLength, 1, 98);
         * [PASS] testTransferDepositsAtRandom(uint256,uint256) (runs: 10002, μ: 119097137, ~: 78857000)
            Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 1233.99s (1233.98s CPU time)

            Ran 1 test suite in 1234.00s (1233.99s CPU time): 1 tests passed, 0 failed, 0 skipped (1 total tests)
         * 
         */
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.startPrank(bob);
        uint256 bptAmountDeposit = bptAmount / 150;
        uint256[] memory tokenIndexArray = new uint256[](depositBound);
        for (uint256 i = 0; i < depositBound; i++) {
            tokenIndexArray[i] = i + 1;
            upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmountDeposit, false, bytes(""));
            skip(1 days);
        }
        vm.stopPrank();

        // Shuffle the array using the seed
        uint[] memory shuffledArray = shuffle(tokenIndexArray, seed);

        LPNFT lpNft = upliftOnlyRouter.lpNFT();

        for (uint256 i = 0; i < depositBound; i++) {
            vm.startPrank(bob);

            lpNft.transferFrom(bob, alice, shuffledArray[i]);
            UpliftOnlyExample.FeeData[] memory aliceFees = upliftOnlyRouter.getUserPoolFeeData(pool, alice);
            UpliftOnlyExample.FeeData[] memory bobFees = upliftOnlyRouter.getUserPoolFeeData(pool, bob);

            assertEq(aliceFees.length, i + 1, "alice should have all transfers");
            assertEq(
                aliceFees[aliceFees.length - 1].tokenID,
                shuffledArray[i],
                "last transferred tokenId should match"
            );

            assertEq(bobFees.length, depositBound - (i + 1), "bob should have all transferred last");

            uint[] memory orderedArrayWithoutShuffled = new uint[](depositBound - (i + 1));
            uint lastPopulatedIndex = 0;
            for (uint256 j = 1; j <= depositBound; j++) {
                bool inPreviousShuffled = false;
                for (uint256 k = 0; k < i + 1; k++) {
                    if (shuffledArray[k] == j) {
                        inPreviousShuffled = true;
                        break;
                    }
                }
                if (!inPreviousShuffled) {
                    orderedArrayWithoutShuffled[lastPopulatedIndex] = j;
                    lastPopulatedIndex++;
                }
            }

            for (uint256 j = 0; j < bobFees.length; j++) {
                assertEq(bobFees[j].tokenID, orderedArrayWithoutShuffled[j], "bob should have ordered tokenID");
            }

            vm.stopPrank();
        }
    }

    //Function to generate a shuffled array of unique uints between 0 and 10
    function shuffle(uint[] memory array, uint seed) internal pure returns (uint[] memory) {
        uint length = array.length;
        for (uint i = length - 1; i > 0; i--) {
            uint j = seed % (i + 1); // Pseudo-random index based on the seed
            (array[i], array[j]) = (array[j], array[i]); // Swap elements
            seed /= (i + 1); // Adjust seed to vary indices in next iteration
        }
        return array;
    }

    function _grossTokenOut(
        uint256 poolReservesBefore,
        uint256 poolSupplyBefore,
        uint256 bptIn
    ) internal pure returns (uint256) {
        return (poolReservesBefore * bptIn) / poolSupplyBefore;
    }

    /// @dev Net amount after charging `feeBps` (0 … 10_000).
    function _netAfterFee(uint256 grossAmount, uint256 feeBps) internal pure returns (uint256) {
        return grossAmount - (grossAmount * feeBps) / 10_000;
    }

    function testFuzz_removeLiquidity_noProtocolTake(uint16 withdrawalFeeBps) public {
        _runFuzz(withdrawalFeeBps, 0);
    }

    function testFuzz_removeLiquidity_withProtocolTake(uint16 withdrawalFeeBps, uint64 protocolTakeE18) public {
        _runFuzz(withdrawalFeeBps, protocolTakeE18);
    }

    struct FuzzParams {
        uint256 grossDai;
        uint256 grossUsdc;
        uint256 expectedDai;
        uint256 expectedUsdc;
        uint256 expectedNet;
        uint256 upliftBpt;
        uint256 protoShare;
        uint256 routerKeep;
        uint256 expectedRouterBpt;
    }

    function _runFuzz(uint16 withdrawalFeeBps, uint64 protocolTakeE18) internal {
        withdrawalFeeBps = uint16(bound(withdrawalFeeBps, 0, 50));
        protocolTakeE18 = uint64(bound(protocolTakeE18, 0, 1e18));

        vm.prank(address(vaultAdmin));
        updateWeightRunner.setQuantAMMUpliftFeeTake(protocolTakeE18);
        vm.stopPrank();

        vm.startPrank(owner);
        upliftOnlyRouter = new UpliftOnlyExample(
            IVault(address(vault)),
            weth,
            permit2,
            withdrawalFeeBps,
            5,
            address(updateWeightRunner),
            "Uplift LiquidityPosition v1",
            "Uplift LiquidityPosition v1",
            "Uplift LiquidityPosition v1"
        );
        vm.stopPrank();

        poolHooksContract = address(upliftOnlyRouter);
        (pool, ) = createPool();
        _approveAllUsers();
        initPool();

        vm.prank(owner);
        UpliftOnlyExample(payable(poolHooksContract)).transferOwnership(poolHooksContract); /* Bob’s current balances */

        uint256 bobDai = dai.balanceOf(bob);
        uint256 bobUsdc = usdc.balanceOf(bob);

        uint256[] memory maxIn = [bobDai + 5, bobUsdc + 5].toMemoryArray();

        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxIn, bptAmount, false, "");
        vm.stopPrank();

        uint256 withdrawBpt = bptAmount / 2;
        uint256[] memory minsOut = [uint256(0), uint256(0)].toMemoryArray();

        BaseVaultTest.Balances memory before = getBalances(bob);

        vm.prank(bob);
        upliftOnlyRouter.removeLiquidityProportional(withdrawBpt, minsOut, false, pool);
        vm.stopPrank();

        BaseVaultTest.Balances memory after_ = getBalances(bob);

        FuzzParams memory params;

        params.grossDai = _grossTokenOut(before.poolTokens[daiIdx], before.poolSupply, withdrawBpt);
        params.grossUsdc = _grossTokenOut(before.poolTokens[usdcIdx], before.poolSupply, withdrawBpt);

        uint256 feeBps = upliftOnlyRouter.minWithdrawalFeeBps(); // ← always 5
        params.expectedDai = _netAfterFee(params.grossDai, feeBps);
        params.expectedUsdc = _netAfterFee(params.grossUsdc, feeBps);

        assertApproxEqAbs(
            after_.bobTokens[daiIdx] - before.bobTokens[daiIdx],
            params.expectedDai,
            1,
            "bob DAI mismatch"
        );

        assertApproxEqAbs(
            after_.bobTokens[usdcIdx] - before.bobTokens[usdcIdx],
            params.expectedUsdc,
            1,
            "bob USDC mismatch"
        );

        params.expectedNet = _netAfterFee(withdrawBpt, feeBps);

        params.upliftBpt = withdrawBpt - params.expectedNet;
        params.protoShare = (params.upliftBpt * protocolTakeE18) / 1e18;
        params.routerKeep = params.upliftBpt - params.protoShare;

        assertEq(before.poolSupply - after_.poolSupply, withdrawBpt - params.protoShare, "pool supply mismatch");

        params.expectedRouterBpt = bptAmount - withdrawBpt;
        assertEq(BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)), params.expectedRouterBpt, "router BPT");

        assertEq(after_.userBpt, params.protoShare, "admin BPT");
        assertEq(after_.bobBpt, 0, "bob BPT");
        assertEq(BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)), params.expectedRouterBpt, "router BPT");
    }

    function _approveAllUsers() internal {
        for (uint256 i; i < users.length; ++i) {
            vm.startPrank(users[i]);
            approveForSender();
            vm.stopPrank();
        }
        if (pool != address(0)) {
            approveForPool(IERC20(pool));
        }
    }

    function testFuzz_FeeSwapExactIn(uint256 swapAmount, uint64 hookFeePercentage) public {
        swapAmount = bound(swapAmount, POOL_MINIMUM_TOTAL_SUPPLY, poolInitAmount);

        hookFeePercentage = uint64(bound(hookFeePercentage, _MIN_SWAP_FEE_PERCENTAGE, _MAX_SWAP_FEE_PERCENTAGE));

        vm.expectEmit();
        emit UpliftOnlyExample.HookSwapFeePercentageChanged(poolHooksContract, hookFeePercentage);

        vm.prank(owner);
        UpliftOnlyExample(payable(poolHooksContract)).setHookSwapFeePercentage(hookFeePercentage);
        uint256 hookFee = swapAmount.mulUp(hookFeePercentage);

        BaseVaultTest.Balances memory balancesBefore = getBalances(owner);

        vm.prank(bob);
        vm.expectCall(
            address(poolHooksContract),
            abi.encodeCall(
                IHooks.onAfterSwap,
                AfterSwapParams({
                    kind: SwapKind.EXACT_IN,
                    tokenIn: dai,
                    tokenOut: usdc,
                    amountInScaled18: swapAmount,
                    amountOutScaled18: swapAmount,
                    tokenInBalanceScaled18: poolInitAmount + swapAmount,
                    tokenOutBalanceScaled18: poolInitAmount - swapAmount,
                    amountCalculatedScaled18: swapAmount,
                    amountCalculatedRaw: swapAmount,
                    router: address(router),
                    pool: pool,
                    userData: bytes("")
                })
            )
        );

        if (hookFee > 0) {
            vm.expectEmit();
            emit UpliftOnlyExample.SwapHookFeeCharged(poolHooksContract, IERC20(usdc), hookFee);
        }

        router.swapSingleTokenExactIn(address(pool), dai, usdc, swapAmount, 0, MAX_UINT256, false, bytes(""));

        BaseVaultTest.Balances memory balancesAfter = getBalances(owner);

        assertEq(
            balancesBefore.bobTokens[daiIdx] - balancesAfter.bobTokens[daiIdx],
            swapAmount,
            "Bob DAI balance is wrong"
        );
        assertEq(balancesBefore.userTokens[daiIdx], balancesAfter.userTokens[daiIdx], "Hook DAI balance is wrong");
        assertEq(
            balancesAfter.bobTokens[usdcIdx] - balancesBefore.bobTokens[usdcIdx],
            swapAmount - hookFee,
            "Bob USDC balance is wrong"
        );
        assertEq(
            balancesAfter.userTokens[usdcIdx] - balancesBefore.userTokens[usdcIdx],
            hookFee,
            "Hook USDC balance is wrong"
        );

        _checkPoolAndVaultBalancesAfterSwap(balancesBefore, balancesAfter, swapAmount);
    }

    function testFuzz_FeeSwapExactOut(uint256 swapAmount, uint64 hookFeePercentage) public {
        swapAmount = bound(swapAmount, POOL_MINIMUM_TOTAL_SUPPLY, poolInitAmount);

        hookFeePercentage = uint64(bound(hookFeePercentage, _MIN_SWAP_FEE_PERCENTAGE, _MAX_SWAP_FEE_PERCENTAGE));

        vm.expectEmit();
        emit UpliftOnlyExample.HookSwapFeePercentageChanged(poolHooksContract, hookFeePercentage);

        vm.prank(owner);
        UpliftOnlyExample(payable(poolHooksContract)).setHookSwapFeePercentage(hookFeePercentage);
        uint256 hookFee = swapAmount.mulUp(hookFeePercentage);

        BaseVaultTest.Balances memory balancesBefore = getBalances(owner);

        vm.prank(bob);
        vm.expectCall(
            address(poolHooksContract),
            abi.encodeCall(
                IHooks.onAfterSwap,
                AfterSwapParams({
                    kind: SwapKind.EXACT_OUT,
                    tokenIn: dai,
                    tokenOut: usdc,
                    amountInScaled18: swapAmount,
                    amountOutScaled18: swapAmount,
                    tokenInBalanceScaled18: poolInitAmount + swapAmount,
                    tokenOutBalanceScaled18: poolInitAmount - swapAmount,
                    amountCalculatedScaled18: swapAmount,
                    amountCalculatedRaw: swapAmount,
                    router: address(router),
                    pool: pool,
                    userData: bytes("")
                })
            )
        );

        if (hookFee > 0) {
            vm.expectEmit();
            emit UpliftOnlyExample.SwapHookFeeCharged(poolHooksContract, IERC20(dai), hookFee);
        }

        router.swapSingleTokenExactOut(
            address(pool),
            dai,
            usdc,
            swapAmount,
            MAX_UINT256,
            MAX_UINT256,
            false,
            bytes("")
        );

        BaseVaultTest.Balances memory balancesAfter = getBalances(owner);

        assertEq(
            balancesAfter.bobTokens[usdcIdx] - balancesBefore.bobTokens[usdcIdx],
            swapAmount,
            "Bob USDC balance is wrong"
        );
        assertEq(balancesBefore.userTokens[usdcIdx], balancesAfter.userTokens[usdcIdx], "Hook USDC balance is wrong");
        assertEq(
            balancesBefore.bobTokens[daiIdx] - balancesAfter.bobTokens[daiIdx],
            swapAmount + hookFee,
            "Bob DAI balance is wrong"
        );
        assertEq(
            balancesAfter.userTokens[daiIdx] - balancesBefore.userTokens[daiIdx],
            hookFee,
            "Hook DAI balance is wrong"
        );

        _checkPoolAndVaultBalancesAfterSwap(balancesBefore, balancesAfter, swapAmount);
    }

    function _checkPoolAndVaultBalancesAfterSwap(
        BaseVaultTest.Balances memory balancesBefore,
        BaseVaultTest.Balances memory balancesAfter,
        uint256 poolBalanceChange
    ) private view {
        assertEq(
            balancesAfter.poolTokens[daiIdx] - balancesBefore.poolTokens[daiIdx],
            poolBalanceChange,
            "Pool DAI balance is wrong"
        );
        assertEq(
            balancesBefore.poolTokens[usdcIdx] - balancesAfter.poolTokens[usdcIdx],
            poolBalanceChange,
            "Pool USDC balance is wrong"
        );
        assertEq(
            balancesAfter.vaultTokens[daiIdx] - balancesBefore.vaultTokens[daiIdx],
            poolBalanceChange,
            "Vault DAI balance is wrong"
        );
        assertEq(
            balancesBefore.vaultTokens[usdcIdx] - balancesAfter.vaultTokens[usdcIdx],
            poolBalanceChange,
            "Vault USDC balance is wrong"
        );
    }

    function testFuzz_removeLiquidityNegativePriceChange_noProtocolTake(uint16 withdrawalFeeBps) public {
        _runFuzzNegative(withdrawalFeeBps, 0);
    }

    function testFuzz_removeLiquidityNegativePriceChange_withProtocolTake(
        uint16 withdrawalFeeBps,
        uint64 protocolTakeE18
    ) public {
        _runFuzzNegative(withdrawalFeeBps, protocolTakeE18);
    }

    struct FuzzNegativeParams {
        uint256 amountOut;
        uint256 hookFee;
        uint256 upliftBpt;
        uint256 protoShare;
        uint256 routerKeep;
    }

    function _runFuzzNegative(uint16 withdrawalFeeBps, uint64 protocolTakeE18) internal {
        withdrawalFeeBps = uint16(bound(withdrawalFeeBps, 0, 50));
        protocolTakeE18 = uint64(bound(protocolTakeE18, 0, 1e18));

        vm.prank(address(vaultAdmin));
        updateWeightRunner.setQuantAMMUpliftFeeTake(protocolTakeE18);
        vm.stopPrank();

        vm.startPrank(owner);
        upliftOnlyRouter = new UpliftOnlyExample(
            IVault(address(vault)),
            weth,
            permit2,
            withdrawalFeeBps,
            5,
            address(updateWeightRunner),
            "Uplift LiquidityPosition v1",
            "Uplift LiquidityPosition v1",
            "Uplift LiquidityPosition v1"
        );
        vm.stopPrank();

        poolHooksContract = address(upliftOnlyRouter);
        (pool, ) = createPool();
        _approveAllUsers();
        initPool();

        vm.prank(owner);
        UpliftOnlyExample(payable(poolHooksContract)).transferOwnership(poolHooksContract);

        uint256 bobDai = dai.balanceOf(bob);
        uint256 bobUsdc = usdc.balanceOf(bob);
        uint256[] memory maxIn = [bobDai + 5, bobUsdc + 5].toMemoryArray(); // small head-room

        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxIn, bptAmount, false, "");
        vm.stopPrank();

        int256[] memory prices = new int256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            prices[i] = (int256(i) * 1e18) / 2; // half previous price
        }
        updateWeightRunner.setMockPrices(pool, prices);

        uint256[] memory minsOut = [uint256(0), uint256(0)].toMemoryArray();

        BaseVaultTest.Balances memory before = getBalances(
            protocolTakeE18 == 0 ? bob : updateWeightRunner.getQuantAMMAdmin()
        );

        vm.prank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, minsOut, false, pool);
        vm.stopPrank();

        BaseVaultTest.Balances memory after_ = getBalances(
            protocolTakeE18 == 0 ? bob : updateWeightRunner.getQuantAMMAdmin()
        );

        FuzzNegativeParams memory params;

        params.amountOut = bptAmount / 2;

        uint64 exitFeePctE18 = upliftOnlyRouter.minWithdrawalFeeBps() * 1e14; // 5 → 5 × 1e14 = 5e14
        params.hookFee = params.amountOut.mulDown(exitFeePctE18);

        assertEq(
            after_.bobTokens[daiIdx] - before.bobTokens[daiIdx],
            params.amountOut - params.hookFee,
            "bob DAI wrong"
        );
        assertEq(
            after_.bobTokens[usdcIdx] - before.bobTokens[usdcIdx],
            params.amountOut - params.hookFee,
            "bob USDC wrong"
        );

        assertEq(
            before.poolTokens[daiIdx] - after_.poolTokens[daiIdx],
            params.amountOut - params.hookFee,
            "pool DAI wrong"
        );
        assertEq(
            before.poolTokens[usdcIdx] - after_.poolTokens[usdcIdx],
            params.amountOut - params.hookFee,
            "pool USDC wrong"
        );

        params.upliftBpt = params.hookFee;
        params.protoShare = (params.upliftBpt * protocolTakeE18) / 1e18;
        params.routerKeep = params.upliftBpt - params.protoShare;

        assertEq(before.poolSupply - after_.poolSupply, bptAmount - params.protoShare, "pool supply wrong");

        assertEq(after_.userBpt, params.protoShare, "admin BPT wrong");
        assertEq(BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)), 0, "router BPT wrong");

        assertEq(after_.bobBpt, 0, "bob still holds BPT");
    }

    /* ────────────────────────────  FUZZ: POSITIVE P&L  ─────────────────────────── */

    function testFuzz_removeLiquidityPositive_noProtocolTake(uint16 withdrawalFeeBps_, uint256 priceMulE18_) public {
        _runPositiveFuzz(withdrawalFeeBps_, 0, priceMulE18_);
    }

    function testFuzz_removeLiquidityPositive_withProtocolTake(
        uint16 withdrawalFeeBps_,
        uint64 protocolTakeE18_,
        uint256 priceMulE18_
    ) public {
        _runPositiveFuzz(withdrawalFeeBps_, protocolTakeE18_, priceMulE18_);
    }

    function _runPositiveFuzz(uint16 withdrawalFeeBps_, uint64 protocolTakeE18_, uint256 priceMulE18_) internal {
        /* ──────── bounds ──────── */
        withdrawalFeeBps_ = uint16(bound(withdrawalFeeBps_, 0, 50));
        protocolTakeE18_ = uint64(bound(protocolTakeE18_, 0, 1e18));
        priceMulE18_ = bound(priceMulE18_, 1e18, 10_000e18);

        /* ──────── fresh router ──────── */
        vm.prank(owner);
        upliftOnlyRouter = new UpliftOnlyExample(
            IVault(address(vault)),
            weth,
            permit2,
            withdrawalFeeBps_, // upliftFeeBps
            5, // minWithdrawalFeeBps (5 bps, constant)
            address(updateWeightRunner),
            "Uplift LP v1",
            "Uplift LP v1",
            "Uplift LP v1"
        );
        vm.stopPrank();

        poolHooksContract = address(upliftOnlyRouter);
        (pool, ) = createPool();
        _approveAllUsers();
        initPool();

        /* ──────── deposit (bob) ──────── */
        uint256[] memory maxIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxIn, bptAmount, false, "");
        vm.stopPrank();

        /* ──────── pretend price ↑ ──────── */
        int256[] memory prices = new int256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) prices[i] = int256(i) * int256(priceMulE18_);
        updateWeightRunner.setMockPrices(pool, prices);

        /* ──────── withdraw ──────── */
        uint256[] memory minsOut = [uint256(0), uint256(0)].toMemoryArray();
        address observer = protocolTakeE18_ == 0 ? bob : updateWeightRunner.getQuantAMMAdmin();

        BaseVaultTest.Balances memory before = getBalances(observer);

        vm.prank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, minsOut, false, pool);
        vm.stopPrank();

        BaseVaultTest.Balances memory after_ = getBalances(observer);

        uint256 upliftRatioE18 = ((priceMulE18_ - 1e18) * 1e18) / priceMulE18_; // 0‥1 e18

        uint256 upliftFeePctE18 = (upliftRatioE18 * upliftOnlyRouter.upliftFeeBps()) / 10_000;

        uint256 minFeePctE18 = uint256(upliftOnlyRouter.minWithdrawalFeeBps()) * 1e14; // 5 bps → 5 e14

        uint256 effectiveFeePctE18 = upliftFeePctE18 > minFeePctE18 ? upliftFeePctE18 : minFeePctE18;

        uint256 amountOut = bptAmount / 2; // per-token
        uint256 hookFeeTokens = amountOut.mulDown(effectiveFeePctE18);

        assertEq(after_.bobTokens[daiIdx] - before.bobTokens[daiIdx], amountOut - hookFeeTokens, "bob DAI");

        assertEq(after_.bobTokens[usdcIdx] - before.bobTokens[usdcIdx], amountOut - hookFeeTokens, "bob USDC");

        assertEq(before.poolTokens[daiIdx] - after_.poolTokens[daiIdx], amountOut - hookFeeTokens, "pool DAI");

        assertEq(before.poolTokens[usdcIdx] - after_.poolTokens[usdcIdx], amountOut - hookFeeTokens, "pool USDC");

        assertEq(before.vaultTokens[daiIdx] - after_.vaultTokens[daiIdx], amountOut - hookFeeTokens, "vault DAI");

        assertEq(before.vaultTokens[usdcIdx] - after_.vaultTokens[usdcIdx], amountOut - hookFeeTokens, "vault USDC");

        /* ──────── supply: allow tiny rounding error (< 2 BPT) ──────── */
        uint256 supplyDiff = before.poolSupply - after_.poolSupply;
        assertApproxEqAbs(supplyDiff, bptAmount /* burned */ - hookFeeTokens /* ≈ BPT minted */, 2, "pool supply");

        /* ──────── BPT holdings ──────── */
        assertEq(BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)), 0, "router holds BPT");
        assertEq(after_.bobBpt, 0, "bob BPT");

        if (protocolTakeE18_ == 0) {
            assertEq(after_.userBpt, 0, "admin BPT");
        } else {
            // we can only guarantee the admin received *something* (mint rounding):
            assertGt(after_.userBpt, 0, "admin BPT > 0");
        }
    }
}
