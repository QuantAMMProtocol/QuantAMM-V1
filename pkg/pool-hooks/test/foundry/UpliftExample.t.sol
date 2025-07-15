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

contract UpliftOnlyExampleTest is BaseVaultTest {
    using CastingHelpers for address[];
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    uint256 internal daiIdx;
    uint256 internal usdcIdx;

    address internal owner;
    address internal addr1;
    address internal addr2;

    // Maximum exit fee of 10%
    uint64 private constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16; // 0.001%
    uint64 private constant _MAX_SWAP_FEE_PERCENTAGE = 10e16; // 10%
    uint64 private constant _MAX_UPLIFT_WITHDRAWAL_FEE = 20e16; // 20%

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
            200e14,
            5e14,
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
        // Add initial liquidity.
        initPool();

        (daiIdx, usdcIdx) = getSortedIndexes(address(dai), address(usdc));
    }

    // Overrides approval to include upliftOnlyRouter.
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

    function testAddLiquidity() public {
        BaseVaultTest.Balances memory balancesBefore = getBalances(bob);
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        uint256[] memory amountsIn = upliftOnlyRouter.addLiquidityProportional(
            pool,
            maxAmountsIn,
            bptAmount,
            false,
            bytes("")
        );
        vm.stopPrank();

        BaseVaultTest.Balances memory balancesAfter = getBalances(bob);

        assertEq(
            balancesBefore.bobTokens[daiIdx] - balancesAfter.bobTokens[daiIdx],
            amountsIn[daiIdx],
            "bob's DAI amount is wrong"
        );
        assertEq(
            balancesBefore.bobTokens[usdcIdx] - balancesAfter.bobTokens[usdcIdx],
            amountsIn[usdcIdx],
            "bob's USDC amount is wrong"
        );

        uint256 expectedTokenId = 1;

        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 1, "deposit length incorrect");
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].amount, bptAmount, "bptAmount incorrect");
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].blockTimestampDeposit,
            block.timestamp,
            "blockTimestampDeposit incorrect"
        );
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].lpTokenDepositValue,
            500000000000000000,
            "should match sum(amount * price)"
        );
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].upliftFeeBps, 200e14, "fee");

        assertEq(upliftOnlyRouter.nftPool(expectedTokenId), pool, "pool mapping is wrong");

        assertEq(
            BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)),
            bptAmount,
            "UpliftOnlyRouter should hold BPT"
        );
        assertEq(balancesAfter.bobBpt, 0, "bob should not hold any BPT");
    }

    function testAddLiquidityThrowOnLimitDeposits() public {
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.startPrank(bob);
        uint256 bptAmountDeposit = bptAmount / 150;
        for (uint256 i = 0; i < 150; i++) {
            if (i == 100) {
                vm.expectRevert(abi.encodeWithSelector(UpliftOnlyExample.TooManyDeposits.selector, pool, bob));
                upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmountDeposit, false, bytes(""));
                break;
            } else {
                upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmountDeposit, false, bytes(""));
            }

            skip(1 days);
        }
        vm.stopPrank();
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

    function testRemoveLiquidityNoPriceChange() public {
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();

        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        vm.prank(owner);
        UpliftOnlyExample(payable(poolHooksContract)).transferOwnership(poolHooksContract);
        vm.stopPrank();

        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 1, "bptAmount mapping should be 1");
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].amount, bptAmount, "bptAmount mapping should be 0");
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].blockTimestampDeposit,
            block.timestamp,
            "bptAmount mapping should be 0"
        );

        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].lpTokenDepositValue,
            500000000000000000,
            "should match sum(amount * price)"
        );
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].upliftFeeBps, 200e14, "fee");

        uint256 nftTokenId = 0;
        uint256[] memory minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        BaseVaultTest.Balances memory balancesBefore = getBalances(bob);

        vm.startPrank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, minAmountsOut, false, pool);
        vm.stopPrank();
        BaseVaultTest.Balances memory balancesAfter = getBalances(bob);

        uint256 feeAmountAmountPercent = (((bptAmount / 2) * ((uint256(upliftOnlyRouter.minWithdrawalFeeBps())))) /
            ((bptAmount / 2)));
        uint256 amountOut = (bptAmount / 2).mulDown((1e18 - feeAmountAmountPercent));

        assertEq(
            balancesAfter.bobTokens[daiIdx] - balancesBefore.bobTokens[daiIdx],
            amountOut,
            "bob's DAI amount is wrong"
        );
        assertEq(
            balancesAfter.bobTokens[usdcIdx] - balancesBefore.bobTokens[usdcIdx],
            amountOut,
            "bob's USDC amount is wrong"
        );

        assertEq(
            balancesBefore.poolTokens[daiIdx] - balancesAfter.poolTokens[daiIdx],
            amountOut,
            "Pool's DAI amount is wrong"
        );
        assertEq(
            balancesBefore.poolTokens[usdcIdx] - balancesAfter.poolTokens[usdcIdx],
            amountOut,
            "Pool's USDC amount is wrong"
        );

        assertEq(
            balancesBefore.poolSupply - balancesAfter.poolSupply,
            (bptAmount / 2) + (bptAmount / 2).mulDown((1e18 - feeAmountAmountPercent)),
            "BPT supply amount is wrong"
        );

        assertEq(
            balancesBefore.vaultTokens[daiIdx] - balancesAfter.vaultTokens[daiIdx],
            amountOut,
            "Vault's DAI amount is wrong"
        );

        assertEq(
            balancesBefore.vaultTokens[usdcIdx] - balancesAfter.vaultTokens[usdcIdx],
            amountOut,
            "Vault's USDC amount is wrong"
        );

        assertEq(balancesBefore.hookTokens[daiIdx], balancesAfter.hookTokens[daiIdx], "Hook's DAI amount is wrong");
        assertEq(balancesBefore.hookTokens[usdcIdx], balancesAfter.hookTokens[usdcIdx], "Hook's USDC amount is wrong");
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 0, "bptAmount mapping should be 0");
        assertEq(upliftOnlyRouter.nftPool(nftTokenId), address(0), "pool mapping should be 0");

        assertEq(
            BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)),
            0,
            "upliftOnlyRouter should hold no BPT"
        );
        assertEq(balancesAfter.bobBpt, 0, "bob should not hold any BPT");
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

    function testRemoveLiquidityNegativePriceChange() public {
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        vm.prank(owner);
        UpliftOnlyExample(payable(poolHooksContract)).transferOwnership(poolHooksContract);
        vm.stopPrank();

        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 1, "bptAmount mapping should be 1");
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].amount, bptAmount, "bptAmount mapping should be 0");
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].blockTimestampDeposit,
            block.timestamp,
            "bptAmount mapping should be 0"
        );
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].lpTokenDepositValue,
            500000000000000000,
            "should match sum(amount * price)"
        );
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].upliftFeeBps, 200e14, "fee");

        int256[] memory prices = new int256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            prices[i] = (int256(i) * 1e18) / 2;
        }
        updateWeightRunner.setMockPrices(pool, prices);

        uint256 nftTokenId = 0;
        uint256[] memory minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        BaseVaultTest.Balances memory balancesBefore = getBalances(bob);

        vm.startPrank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, minAmountsOut, false, pool);
        vm.stopPrank();
        BaseVaultTest.Balances memory balancesAfter = getBalances(bob);

        // Bob gets original liquidity with no fee applied because of full decay.
        uint64 exitFeePercentage = upliftOnlyRouter.minWithdrawalFeeBps();
        uint256 amountOut = bptAmount / 2;
        uint256 hookFee = amountOut.mulDown(exitFeePercentage);

        assertEq(
            balancesAfter.bobTokens[daiIdx] - balancesBefore.bobTokens[daiIdx],
            amountOut - hookFee,
            "bob's DAI amount is wrong"
        );
        assertEq(
            balancesAfter.bobTokens[usdcIdx] - balancesBefore.bobTokens[usdcIdx],
            amountOut - hookFee,
            "bob's USDC amount is wrong"
        );

        // Pool balances decrease by amountOut.
        assertEq(
            balancesBefore.poolTokens[daiIdx] - balancesAfter.poolTokens[daiIdx],
            amountOut - hookFee,
            "Pool's DAI amount is wrong"
        );
        assertEq(
            balancesBefore.poolTokens[usdcIdx] - balancesAfter.poolTokens[usdcIdx],
            amountOut - hookFee,
            "Pool's USDC amount is wrong"
        );

        //As the bpt value taken in fees is readded to the pool under the router address, the pool supply should remain the same
        assertEq(
            balancesBefore.poolSupply - balancesAfter.poolSupply,
            bptAmount - hookFee,
            "BPT supply amount is wrong"
        );

        // Same happens with Vault balances: decrease by amountOut.
        assertEq(
            balancesBefore.vaultTokens[daiIdx] - balancesAfter.vaultTokens[daiIdx],
            amountOut - hookFee,
            "Vault's DAI amount is wrong"
        );
        assertEq(
            balancesBefore.vaultTokens[usdcIdx] - balancesAfter.vaultTokens[usdcIdx],
            amountOut - hookFee,
            "Vault's USDC amount is wrong"
        );

        // Hook balances remain unchanged.
        assertEq(balancesBefore.hookTokens[daiIdx], balancesAfter.hookTokens[daiIdx], "Hook's DAI amount is wrong");
        assertEq(balancesBefore.hookTokens[usdcIdx], balancesAfter.hookTokens[usdcIdx], "Hook's USDC amount is wrong");

        // Router should set all lp data to 0.
        //User has extracted deposit, now deposit was deleted and popped from the mapping
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 0, "bptAmount mapping should be 0");
        //assertEq(upliftOnlyRouter.bptAmount(nftTokenId), 0, "bptAmount mapping should be 0");
        //assertEq(upliftOnlyRouter.startTime(nftTokenId), 0, "startTime mapping should be 0");

        assertEq(upliftOnlyRouter.nftPool(nftTokenId), address(0), "pool mapping should be 0");

        assertEq(
            BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)),
            0,
            "upliftOnlyRouter should hold no BPT"
        );
        assertEq(balancesAfter.bobBpt, 0, "bob should not hold any BPT");
    }

    function testRemoveLiquidityDoublePositivePriceChange() public {
        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        vm.prank(owner);
        UpliftOnlyExample(payable(poolHooksContract)).transferOwnership(poolHooksContract);
        vm.stopPrank();

        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 1, "bptAmount mapping should be 1");
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].amount, bptAmount, "bptAmount mapping should be 0");
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].blockTimestampDeposit,
            block.timestamp,
            "bptAmount mapping should be 0"
        );
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].lpTokenDepositValue,
            500000000000000000,
            "should match sum(amount * price)"
        );
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].upliftFeeBps, 200e14, "fee");

        int256[] memory prices = new int256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            prices[i] = int256(i) * 2e18;
        }
        updateWeightRunner.setMockPrices(pool, prices);

        uint256 nftTokenId = 0;
        uint256[] memory minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        BaseVaultTest.Balances memory balancesBefore = getBalances(bob);

        vm.startPrank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, minAmountsOut, false, pool);
        vm.stopPrank();
        BaseVaultTest.Balances memory balancesAfter = getBalances(bob);

        uint256 valueAtDeposit = 0.5e18; // ← whatever you used when bob deposited
        uint256 valueNow = 1e18; // ← current LP value you set with the oracle

        uint256 upliftRatio = ((valueNow - valueAtDeposit) * 1e18) / valueNow; // 18 dp

        uint256 feePercentage = (upliftRatio.mulDown(uint256(upliftOnlyRouter.upliftFeeBps())));
        // feePercentage is 18 dp; e.g. with double price ⇒ 1e16  (1 %)

        uint256 amountOut = bptAmount / 2;
        uint256 hookFee = amountOut.mulDown(feePercentage);

        // Bob gets original liquidity with no fee applied because of full decay.
        assertEq(
            balancesAfter.bobTokens[daiIdx] - balancesBefore.bobTokens[daiIdx],
            amountOut - hookFee,
            "bob's DAI amount is wrong"
        );
        assertEq(
            balancesAfter.bobTokens[usdcIdx] - balancesBefore.bobTokens[usdcIdx],
            amountOut - hookFee,
            "bob's USDC amount is wrong"
        );

        // Pool balances decrease by amountOut.
        assertEq(
            balancesBefore.poolTokens[daiIdx] - balancesAfter.poolTokens[daiIdx],
            amountOut - hookFee,
            "Pool's DAI amount is wrong"
        );
        assertEq(
            balancesBefore.poolTokens[usdcIdx] - balancesAfter.poolTokens[usdcIdx],
            amountOut - hookFee,
            "Pool's USDC amount is wrong"
        );

        //As the bpt value taken in fees is readded to the pool under the router address, the pool supply should remain the same
        assertEq(
            balancesBefore.poolSupply - balancesAfter.poolSupply,
            bptAmount - hookFee,
            "BPT supply amount is wrong"
        );

        // Same happens with Vault balances: decrease by amountOut.
        assertEq(
            balancesBefore.vaultTokens[daiIdx] - balancesAfter.vaultTokens[daiIdx],
            amountOut - hookFee,
            "Vault's DAI amount is wrong"
        );
        assertEq(
            balancesBefore.vaultTokens[usdcIdx] - balancesAfter.vaultTokens[usdcIdx],
            amountOut - hookFee,
            "Vault's USDC amount is wrong"
        );

        // Hook balances remain unchanged.
        assertEq(balancesBefore.hookTokens[daiIdx], balancesAfter.hookTokens[daiIdx], "Hook's DAI amount is wrong");
        assertEq(balancesBefore.hookTokens[usdcIdx], balancesAfter.hookTokens[usdcIdx], "Hook's USDC amount is wrong");

        // Router should set all lp data to 0.
        //User has extracted deposit, now deposit was deleted and popped from the mapping
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 0, "bptAmount mapping should be 0");
        //assertEq(upliftOnlyRouter.bptAmount(nftTokenId), 0, "bptAmount mapping should be 0");
        //assertEq(upliftOnlyRouter.startTime(nftTokenId), 0, "startTime mapping should be 0");

        assertEq(upliftOnlyRouter.nftPool(nftTokenId), address(0), "pool mapping should be 0");

        assertEq(
            BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)),
            0,
            "upliftOnlyRouter should hold no BPT"
        );
        assertEq(balancesAfter.bobBpt, 0, "bob should not hold any BPT");
    }

    function testRemoveWithNonOwner() public {
        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        uint256[] memory minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        // Remove fails because lp isn't the owner of the NFT.
        vm.expectRevert(abi.encodeWithSelector(UpliftOnlyExample.WithdrawalByNonOwner.selector, lp, pool, bptAmount));
        vm.prank(lp);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, minAmountsOut, false, pool);
    }

    function testAddFromExternalRouter() public {
        // Add fails because it must be done via NftLiquidityPositionExample.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.expectRevert(abi.encodeWithSelector(UpliftOnlyExample.CannotUseExternalRouter.selector, router));
        vm.prank(bob);
        router.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
    }

    function testRemoveFromExternalRouter() public {
        uint256 amountOut = poolInitAmount / 2;
        uint256[] memory minAmountsOut = [amountOut, amountOut].toMemoryArray();

        vm.expectRevert(
            abi.encodeWithSelector(UpliftOnlyExample.WithdrawalByNonOwner.selector, lp, pool, amountOut * 2)
        );
        vm.startPrank(lp);
        upliftOnlyRouter.removeLiquidityProportional(amountOut * 2, minAmountsOut, false, pool);
        vm.stopPrank();
    }

    function testOnAfterRemoveLiquidityFromExternalRouterWithRealDepositor() public {
        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();
        uint256[] memory minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, bob));
        vm.startPrank(bob);
        upliftOnlyRouter.onAfterRemoveLiquidity(
            address(router),
            pool,
            RemoveLiquidityKind.PROPORTIONAL,
            bptAmount,
            minAmountsOut,
            minAmountsOut,
            minAmountsOut,
            bytes("")
        );
        vm.stopPrank();
    }

    function testOnAfterRemoveLiquidityFromExternalRouterWithRandomExternal() public {
        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();
        uint256[] memory minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.SenderIsNotVault.selector, lp));
        vm.startPrank(lp);
        upliftOnlyRouter.onAfterRemoveLiquidity(
            address(router),
            pool,
            RemoveLiquidityKind.PROPORTIONAL,
            bptAmount,
            minAmountsOut,
            minAmountsOut,
            minAmountsOut,
            bytes("")
        );
        vm.stopPrank();
    }

    function testOnBeforeAddLiquidityFromExternalRouterWithRealDepositor() public {
        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();
        uint256[] memory minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        vm.expectRevert(abi.encodeWithSelector(UpliftOnlyExample.CannotUseExternalRouter.selector, router));
        vm.startPrank(bob);
        upliftOnlyRouter.onBeforeAddLiquidity(
            address(router),
            pool,
            AddLiquidityKind.PROPORTIONAL,
            minAmountsOut,
            bptAmount,
            minAmountsOut,
            bytes("")
        );
        vm.stopPrank();
    }

    function testOnBeforeAddLiquidityFromExternalRouterWithRandomExternal() public {
        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();
        uint256[] memory minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        vm.expectRevert(abi.encodeWithSelector(UpliftOnlyExample.CannotUseExternalRouter.selector, router));
        vm.startPrank(lp);
        upliftOnlyRouter.onBeforeAddLiquidity(
            address(router),
            pool,
            AddLiquidityKind.PROPORTIONAL,
            minAmountsOut,
            bptAmount,
            minAmountsOut,
            bytes("")
        );
        vm.stopPrank();
    }

    function testAfterUpdateFromExternalRouterWithRealDepositor() public {
        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(UpliftOnlyExample.TransferUpdateNonNft.selector, lp, bob, bob, 1));
        vm.startPrank(bob);
        upliftOnlyRouter.afterUpdate(lp, bob, 1);
        vm.stopPrank();
    }

    function testAfterUpdateFromExternalRouterWithRandomExternal() public {
        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(UpliftOnlyExample.TransferUpdateNonNft.selector, bob, lp, lp, 1));
        vm.startPrank(lp);
        upliftOnlyRouter.afterUpdate(bob, lp, 1);
        vm.stopPrank();
    }

    function testAfterUpdateFromExternalRouterWithRouter() public {
        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(UpliftOnlyExample.TransferUpdateNonNft.selector, bob, lp, router, 1));
        vm.startPrank(address(router));
        upliftOnlyRouter.afterUpdate(bob, lp, 1);
        vm.stopPrank();
    }

    function testAfterUpdateFromNFTInvalidTokenID() public {
        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        vm.startPrank(address(upliftOnlyRouter.lpNFT()));
        vm.expectRevert(abi.encodeWithSelector(UpliftOnlyExample.TransferUpdateTokenIDInvalid.selector, bob, lp, 2));
        upliftOnlyRouter.afterUpdate(bob, lp, 2);
        vm.stopPrank();
    }

    function testSetHookFeeNonOwnerFail() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.startPrank(bob);
        upliftOnlyRouter.setHookSwapFeePercentage(1);
        vm.stopPrank();
    }

    function testSetHookFeeOwnerPass(uint64 poolHookAmount) public {
        uint64 boundFeeAmount = uint64(bound(poolHookAmount, _MIN_SWAP_FEE_PERCENTAGE, _MAX_SWAP_FEE_PERCENTAGE));
        vm.expectEmit();
        emit UpliftOnlyExample.HookSwapFeePercentageChanged(poolHooksContract, boundFeeAmount);
        vm.startPrank(owner);
        upliftOnlyRouter.setHookSwapFeePercentage(boundFeeAmount);
        vm.stopPrank();
    }

    function testSetHookPassSmallerThanMinimumFail(uint64 poolHookAmount) public {
        uint64 boundFeeAmount = uint64(bound(poolHookAmount, 0, _MIN_SWAP_FEE_PERCENTAGE - 1));

        vm.startPrank(owner);
        vm.expectRevert("Below _MIN_SWAP_FEE_PERCENTAGE");
        upliftOnlyRouter.setHookSwapFeePercentage(boundFeeAmount);
        vm.stopPrank();
    }

    function testSetHookPassGreaterThanMaxFail(uint64 poolHookAmount) public {
        uint64 boundFeeAmount = uint64(
            bound(poolHookAmount, uint64(_MAX_SWAP_FEE_PERCENTAGE) + 1, uint64(type(uint64).max))
        );

        vm.startPrank(owner);
        vm.expectRevert("Above _MAX_SWAP_FEE_PERCENTAGE");
        upliftOnlyRouter.setHookSwapFeePercentage(boundFeeAmount);
        vm.stopPrank();
    }

    function testFeeCalculationCausesRevert() public {
        vm.startPrank(address(vaultAdmin));
        updateWeightRunner.setQuantAMMSwapFeeTake(5e14); //set admin fee to 5 basis points (same as min withdrawal fee)
        vm.stopPrank();
        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 1, "bptAmount mapping should be 1");
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].amount, bptAmount, "bptAmount mapping should be 0");
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].blockTimestampDeposit,
            block.timestamp,
            "bptAmount mapping should be 0"
        );
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].lpTokenDepositValue,
            500000000000000000,
            "should match sum(amount * price)"
        );
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].upliftFeeBps, 200e14, "fee");

        int256[] memory prices = new int256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            prices[i] = int256(i + 1) * 1.5e1; // Make the price 1.5 times higher
        }
        updateWeightRunner.setMockPrices(pool, prices);

        uint256[] memory minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        vm.startPrank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultErrors.AmountInAboveMax.selector,
                address(dai),
                83333333333333334,
                83333333333333167
            )
        );
        upliftOnlyRouter.removeLiquidityProportional(bptAmount / 3, minAmountsOut, false, pool);
        vm.stopPrank();
    }

    function testRemoveLiquidityWithProtocolTakeNoPriceChange() public {
        vm.prank(address(vaultAdmin));
        updateWeightRunner.setQuantAMMUpliftFeeTake(0.5e18);
        vm.stopPrank();

        vm.prank(owner);
        UpliftOnlyExample(payable(poolHooksContract)).transferOwnership(poolHooksContract);

        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();

        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 1, "bptAmount mapping should be 1");
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].amount, bptAmount, "bptAmount mapping should be 0");
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].blockTimestampDeposit,
            block.timestamp,
            "bptAmount mapping should be 0"
        );
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].lpTokenDepositValue,
            500000000000000000,
            "should match sum(amount * price)"
        );
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].upliftFeeBps, 200e14, "fee");

        uint256 nftTokenId = 0;
        uint256[] memory minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        BaseVaultTest.Balances memory balancesBefore = getBalances(updateWeightRunner.getQuantAMMAdmin());

        vm.startPrank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, minAmountsOut, false, pool);
        vm.stopPrank();
        BaseVaultTest.Balances memory balancesAfter = getBalances(updateWeightRunner.getQuantAMMAdmin());

        uint256 feeAmountAmountPercent = (
            (((bptAmount / 2) * ((uint256(upliftOnlyRouter.minWithdrawalFeeBps())))) / ((bptAmount / 2)))
        );
        uint256 amountOut = (bptAmount / 2).mulDown((1e18 - feeAmountAmountPercent));

        // Bob gets original liquidity with no fee applied because of full decay.
        assertEq(
            balancesAfter.bobTokens[daiIdx] - balancesBefore.bobTokens[daiIdx],
            amountOut,
            "bob's DAI amount is wrong"
        );
        assertEq(
            balancesAfter.bobTokens[usdcIdx] - balancesBefore.bobTokens[usdcIdx],
            amountOut,
            "bob's USDC amount is wrong"
        );

        // Pool balances decrease by amountOut.
        assertEq(
            balancesBefore.poolTokens[daiIdx] - balancesAfter.poolTokens[daiIdx],
            amountOut,
            "Pool's DAI amount is wrong"
        );
        assertEq(
            balancesBefore.poolTokens[usdcIdx] - balancesAfter.poolTokens[usdcIdx],
            amountOut,
            "Pool's USDC amount is wrong"
        );

        //As the bpt value taken in fees is readded to the pool under the router address, the pool supply should remain the same
        assertEq(
            balancesBefore.poolSupply - balancesAfter.poolSupply,
            bptAmount - balancesAfter.userBpt,
            "BPT supply amount is wrong"
        );

        // Same happens with Vault balances: decrease by amountOut.
        assertEq(
            balancesBefore.vaultTokens[daiIdx] - balancesAfter.vaultTokens[daiIdx],
            amountOut,
            "Vault's DAI amount is wrong"
        );
        assertEq(
            balancesBefore.vaultTokens[usdcIdx] - balancesAfter.vaultTokens[usdcIdx],
            amountOut,
            "Vault's USDC amount is wrong"
        );

        // Hook balances remain unchanged.
        assertEq(balancesBefore.hookTokens[daiIdx], balancesAfter.hookTokens[daiIdx], "Hook's DAI amount is wrong");
        assertEq(balancesBefore.hookTokens[usdcIdx], balancesAfter.hookTokens[usdcIdx], "Hook's USDC amount is wrong");

        // Router should set all lp data to 0.
        //User has extracted deposit, now deposit was deleted and popped from the mapping
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 0, "bptAmount mapping should be 0");
        //assertEq(upliftOnlyRouter.bptAmount(nftTokenId), 0, "bptAmount mapping should be 0");
        //assertEq(upliftOnlyRouter.startTime(nftTokenId), 0, "startTime mapping should be 0");

        assertEq(upliftOnlyRouter.nftPool(nftTokenId), address(0), "pool mapping should be 0");

        assertEq(
            BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)),
            0,
            "upliftOnlyRouter should hold no BPT"
        );
        assertEq(balancesAfter.bobBpt, 0, "bob should not hold any BPT");

        // was originall 1000000000000000000, doubled in value to 2000000000000000000,
        //total fee was 50% of uplift which is 1000000000000000000, of that fee the protocol take 50% which is 500000000000000000
        assertEq(balancesAfter.userBpt, 500000000000000000, "quantamm should not hold any BPT");
    }

    function testRemoveLiquidityWithProtocolTakeNegativePriceChange() public {
        vm.prank(address(vaultAdmin));
        updateWeightRunner.setQuantAMMUpliftFeeTake(0.5e18);
        vm.stopPrank();

        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 1, "bptAmount mapping should be 1");
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].amount, bptAmount, "bptAmount mapping should be 0");
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].blockTimestampDeposit,
            block.timestamp,
            "bptAmount mapping should be 0"
        );
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].lpTokenDepositValue,
            500000000000000000,
            "should match sum(amount * price)"
        );
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].upliftFeeBps, 200e14, "fee");

        int256[] memory prices = new int256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            prices[i] = (int256(i) * 1e18) / 2;
        }
        updateWeightRunner.setMockPrices(pool, prices);

        uint256 nftTokenId = 0;
        uint256[] memory minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        BaseVaultTest.Balances memory balancesBefore = getBalances(updateWeightRunner.getQuantAMMAdmin());

        vm.startPrank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, minAmountsOut, false, pool);
        vm.stopPrank();
        BaseVaultTest.Balances memory balancesAfter = getBalances(updateWeightRunner.getQuantAMMAdmin());
        // pool share without FixedPoint helpers (avoids double 1e18 division)

        uint64 exitFeePercentage = upliftOnlyRouter.minWithdrawalFeeBps();
        uint256 amountOut = bptAmount / 2;
        uint256 hookFee = amountOut.mulDown(exitFeePercentage);

        // Bob gets original liquidity with no fee applied because of full decay.
        assertEq(
            balancesAfter.bobTokens[daiIdx] - balancesBefore.bobTokens[daiIdx],
            amountOut - hookFee,
            "bob's DAI amount is wrong"
        );
        assertEq(
            balancesAfter.bobTokens[usdcIdx] - balancesBefore.bobTokens[usdcIdx],
            amountOut - hookFee,
            "bob's USDC amount is wrong"
        );

        // Pool balances decrease by amountOut.
        assertEq(
            balancesBefore.poolTokens[daiIdx] - balancesAfter.poolTokens[daiIdx],
            amountOut - hookFee,
            "Pool's DAI amount is wrong"
        );
        assertEq(
            balancesBefore.poolTokens[usdcIdx] - balancesAfter.poolTokens[usdcIdx],
            amountOut - hookFee,
            "Pool's USDC amount is wrong"
        );

        //As the bpt value taken in fees is readded to the pool under the router address, the pool supply should remain the same
        assertEq(
            balancesBefore.poolSupply - balancesAfter.poolSupply,
            bptAmount - balancesAfter.userBpt,
            "BPT supply amount is wrong"
        );

        // Same happens with Vault balances: decrease by amountOut.
        assertEq(
            balancesBefore.vaultTokens[daiIdx] - balancesAfter.vaultTokens[daiIdx],
            amountOut - hookFee,
            "Vault's DAI amount is wrong"
        );
        assertEq(
            balancesBefore.vaultTokens[usdcIdx] - balancesAfter.vaultTokens[usdcIdx],
            amountOut - hookFee,
            "Vault's USDC amount is wrong"
        );

        // Hook balances remain unchanged.
        assertEq(balancesBefore.hookTokens[daiIdx], balancesAfter.hookTokens[daiIdx], "Hook's DAI amount is wrong");
        assertEq(balancesBefore.hookTokens[usdcIdx], balancesAfter.hookTokens[usdcIdx], "Hook's USDC amount is wrong");

        // Router should set all lp data to 0.
        //User has extracted deposit, now deposit was deleted and popped from the mapping
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 0, "bptAmount mapping should be 0");
        //assertEq(upliftOnlyRouter.bptAmount(nftTokenId), 0, "bptAmount mapping should be 0");
        //assertEq(upliftOnlyRouter.startTime(nftTokenId), 0, "startTime mapping should be 0");

        assertEq(upliftOnlyRouter.nftPool(nftTokenId), address(0), "pool mapping should be 0");

        assertEq(
            BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)),
            0,
            "upliftOnlyRouter should hold no BPT"
        );
        assertEq(balancesAfter.bobBpt, 0, "bob should not hold any BPT");
    }

    function testRemoveLiquidityWithProtocolTakeDoublePositivePriceChange() public {
        vm.prank(address(vaultAdmin));
        updateWeightRunner.setQuantAMMUpliftFeeTake(0.05e18);
        vm.stopPrank();
        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 1, "bptAmount mapping should be 1");
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].amount, bptAmount, "bptAmount mapping should be 0");
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].blockTimestampDeposit,
            block.timestamp,
            "bptAmount mapping should be 0"
        );
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].lpTokenDepositValue,
            500000000000000000,
            "should match sum(amount * price)"
        );
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].upliftFeeBps, 200e14, "fee");

        int256[] memory prices = new int256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            prices[i] = int256(i) * 2e18;
        }
        updateWeightRunner.setMockPrices(pool, prices);

        uint256 nftTokenId = 0;
        uint256[] memory minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        BaseVaultTest.Balances memory balancesBefore = getBalances(updateWeightRunner.getQuantAMMAdmin());

        vm.startPrank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, minAmountsOut, false, pool);
        vm.stopPrank();
        BaseVaultTest.Balances memory balancesAfter = getBalances(updateWeightRunner.getQuantAMMAdmin());

        uint256 valueAtDeposit = 0.5e18; // ← whatever you used when bob deposited
        uint256 valueNow = 1e18; // ← current LP value you set with the oracle

        uint256 upliftRatio = ((valueNow - valueAtDeposit) * 1e18) / valueNow; // 18 dp

        uint256 feePercentage = upliftRatio.mulDown(uint256(upliftOnlyRouter.upliftFeeBps()));
        // feePercentage is 18 dp; e.g. with double price ⇒ 1e16  (1 %)

        uint256 amountOut = bptAmount / 2;
        uint256 hookFee = amountOut.mulDown(feePercentage);

        // Bob gets original liquidity with no fee applied because of full decay.
        assertEq(
            balancesAfter.bobTokens[daiIdx] - balancesBefore.bobTokens[daiIdx],
            amountOut - hookFee,
            "bob's DAI amount is wrong"
        );
        assertEq(
            balancesAfter.bobTokens[usdcIdx] - balancesBefore.bobTokens[usdcIdx],
            amountOut - hookFee,
            "bob's USDC amount is wrong"
        );

        // Pool balances decrease by amountOut.
        assertEq(
            balancesBefore.poolTokens[daiIdx] - balancesAfter.poolTokens[daiIdx],
            amountOut - hookFee,
            "Pool's DAI amount is wrong"
        );
        assertEq(
            balancesBefore.poolTokens[usdcIdx] - balancesAfter.poolTokens[usdcIdx],
            amountOut - hookFee,
            "Pool's USDC amount is wrong"
        );

        //As the bpt value taken in fees is readded to the pool under the router address, the pool supply should remain the same
        assertEq(
            balancesBefore.poolSupply - balancesAfter.poolSupply,
            bptAmount - balancesAfter.userBpt,
            "BPT supply amount is wrong"
        );

        // Same happens with Vault balances: decrease by amountOut.
        assertEq(
            balancesBefore.vaultTokens[daiIdx] - balancesAfter.vaultTokens[daiIdx],
            amountOut - hookFee,
            "Vault's DAI amount is wrong"
        );
        assertEq(
            balancesBefore.vaultTokens[usdcIdx] - balancesAfter.vaultTokens[usdcIdx],
            amountOut - hookFee,
            "Vault's USDC amount is wrong"
        );

        // Hook balances remain unchanged.
        assertEq(balancesBefore.hookTokens[daiIdx], balancesAfter.hookTokens[daiIdx], "Hook's DAI amount is wrong");
        assertEq(balancesBefore.hookTokens[usdcIdx], balancesAfter.hookTokens[usdcIdx], "Hook's USDC amount is wrong");

        // Router should set all lp data to 0.
        //User has extracted deposit, now deposit was deleted and popped from the mapping
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 0, "bptAmount mapping should be 0");
        //assertEq(upliftOnlyRouter.bptAmount(nftTokenId), 0, "bptAmount mapping should be 0");
        //assertEq(upliftOnlyRouter.startTime(nftTokenId), 0, "startTime mapping should be 0");

        assertEq(upliftOnlyRouter.nftPool(nftTokenId), address(0), "pool mapping should be 0");

        assertEq(
            BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)),
            0,
            "upliftOnlyRouter should hold no BPT"
        );
        assertEq(balancesAfter.bobBpt, 0, "bob should not hold any BPT");
    }
}
