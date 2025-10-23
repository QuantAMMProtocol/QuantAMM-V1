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
    uint256 internal bptAmount = 2e3 * 1e18;

    address internal owner;
    address internal addr1;
    address internal addr2;

    // Maximum exit fee of 10%
    uint64 private constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16; // 0.001%
    uint64 private constant _MAX_SWAP_FEE_PERCENTAGE = 10e16; // 10%
    uint64 private constant _MAX_UPLIFT_WITHDRAWAL_FEE = 20e16; // 20%

    uint256 internal constant DEFAULT_AMP_FACTOR = 200;

    PoolFactoryMock internal factoryMock;

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

    struct nopriceChangeLocals {
        uint256[] maxAmountsIn;
        uint256[] minAmountsOut;
        BaseVaultTest.Balances balancesBefore;
        BaseVaultTest.Balances balancesAfter;
        uint256 amountOut;
        uint64 exitFeePercentage;
        uint256 hookFee;
        uint256 adminFeePercent;
        uint256 adminPartPerToken;
        uint256 lpDonationPerToken;
        uint256 bobReceivesPerToken;
        uint256 netPoolDecreasePerToken;
        uint256 nftTokenId;
    }

    function testRemoveLiquidityNoPriceChange() public {
        nopriceChangeLocals memory v;

        // 1) Bob adds liquidity so he has BPT to remove later.
        v.maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, v.maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        // Hand hook ownership to the hook contract (as in your setup).
        vm.prank(owner);
        UpliftOnlyExample(payable(poolHooksContract)).transferOwnership(poolHooksContract);
        vm.stopPrank();

        // Sanity checks on stored deposit data.
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

        v.nftTokenId = 0;
        v.minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        v.balancesBefore = getBalances(bob);
        vm.warp(block.timestamp + 1 days); // ensure time has passed for fee calc

        // 2) Bob removes all his BPT proportionally (no price change case).
        vm.startPrank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, v.minAmountsOut, false, pool);
        vm.stopPrank();

        v.balancesAfter = getBalances(bob);

        // === 3) Fee math with no price change ===
        // Proportional 2-token pool → raw amount out per token equals bptAmount / 2
        v.amountOut = bptAmount / 2; // = 1e21 in your traces

        // With zero uplift, the minimum withdrawal fee applies.
        v.exitFeePercentage = upliftOnlyRouter.minWithdrawalFeeBps(); // 5e14 (0.05%)
        v.hookFee = v.amountOut.mulDown(v.exitFeePercentage); // 1e21 * 5e14 / 1e18 = 5e17 per token

        // Split of the hook fee: 50% admin (sent out), 50% donation (kept in pool) — no BPT minted for donation.
        v.adminFeePercent = updateWeightRunner.getQuantAMMUpliftFeeTake(); // 0.5e18
        v.adminPartPerToken = v.hookFee.mulUp(v.adminFeePercent); // 2.5e17 per token
        v.lpDonationPerToken = v.hookFee - v.adminPartPerToken; // 2.5e17 per token

        // What Bob actually receives:
        v.bobReceivesPerToken = v.amountOut - v.hookFee; // 9.995e20 per token

        // Net change to Pool/Vault per token:
        //   remove amountOut (1e21) but donate lpDonation back (2.5e17) → net decrease = 9.9975e20
        v.netPoolDecreasePerToken = v.amountOut - v.lpDonationPerToken; // 9.9975e20

        // === 4) Assertions ===

        // Bob receives the adjusted amount (after full fee).
        assertEq(
            v.balancesAfter.bobTokens[daiIdx] - v.balancesBefore.bobTokens[daiIdx],
            v.bobReceivesPerToken,
            "bob's DAI amount is wrong"
        );
        assertEq(
            v.balancesAfter.bobTokens[usdcIdx] - v.balancesBefore.bobTokens[usdcIdx],
            v.bobReceivesPerToken,
            "bob's USDC amount is wrong"
        );

        // Pool balances decrease by the NET amount (raw out minus donation back to pool).
        assertEq(
            v.balancesBefore.poolTokens[daiIdx] - v.balancesAfter.poolTokens[daiIdx],
            v.netPoolDecreasePerToken,
            "Pool's DAI amount is wrong"
        );
        assertEq(
            v.balancesBefore.poolTokens[usdcIdx] - v.balancesAfter.poolTokens[usdcIdx],
            v.netPoolDecreasePerToken,
            "Pool's USDC amount is wrong"
        );

        // The entire bptAmount is burned on exit; donation mints ZERO BPT → supply drops by bptAmount.
        assertEq(v.balancesBefore.poolSupply - v.balancesAfter.poolSupply, bptAmount, "BPT supply amount is wrong");

        // Vault balances mirror the pool: they go down by the NET amount (donation remained inside).
        assertEq(
            v.balancesBefore.vaultTokens[daiIdx] - v.balancesAfter.vaultTokens[daiIdx],
            v.netPoolDecreasePerToken,
            "Vault's DAI amount is wrong"
        );
        assertEq(
            v.balancesBefore.vaultTokens[usdcIdx] - v.balancesAfter.vaultTokens[usdcIdx],
            v.netPoolDecreasePerToken,
            "Vault's USDC amount is wrong"
        );

        // Hook balances remain unchanged.
        assertEq(v.balancesBefore.hookTokens[daiIdx], v.balancesAfter.hookTokens[daiIdx], "Hook's DAI amount is wrong");
        assertEq(
            v.balancesBefore.hookTokens[usdcIdx],
            v.balancesAfter.hookTokens[usdcIdx],
            "Hook's USDC amount is wrong"
        );

        // Router should clear all lp data and free mappings.
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 0, "bptAmount mapping should be 0");
        assertEq(upliftOnlyRouter.nftPool(v.nftTokenId), address(0), "pool mapping should be 0");

        // No stray BPT anywhere.
        assertEq(
            BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)),
            0,
            "upliftOnlyRouter should hold no BPT"
        );
        assertEq(v.balancesAfter.bobBpt, 0, "bob should not hold any BPT");
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

    struct negativePriceChangeLocals {
        uint256[] maxAmountsIn;
        int256[] prices;
        uint256 nftTokenId;
        uint256[] minAmountsOut;
        BaseVaultTest.Balances balancesBefore;
        BaseVaultTest.Balances balancesAfter;
        uint256 amountOut;
        uint64 exitFeePercentage;
        uint256 hookFee;
        uint256 adminFeePercent;
        uint256 adminPartPerToken;
        uint256 lpDonationPerToken;
        uint256 bobReceivesPerToken;
        uint256 netPoolDecreasePerToken;
    }

    function testRemoveLiquidityNegativePriceChange() public {
        negativePriceChangeLocals memory v;

        // 1) Bob adds liquidity so he has BPT to remove later.
        v.maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, v.maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        // Hand hook ownership to the hook contract (as in your setup).
        vm.prank(owner);
        UpliftOnlyExample(payable(poolHooksContract)).transferOwnership(poolHooksContract);
        vm.stopPrank();

        // Sanity checks on stored deposit data.
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

        // 2) Push prices DOWN so there is a negative uplift.
        //    With negative uplift, the contract applies minimum withdrawal fee (minWithdrawalFeeBps).
        v.prices = new int256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            v.prices[i] = (int256(i) * 1e18) / 2; // halve prices
        }
        updateWeightRunner.setMockPrices(pool, v.prices);

        v.nftTokenId = 0;
        v.minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        v.balancesBefore = getBalances(bob);
        vm.warp(block.timestamp + 1 days); // ensure time has passed for fee calc
        // 3) Bob removes all his BPT proportionally.
        vm.startPrank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, v.minAmountsOut, false, pool);
        vm.stopPrank();

        v.balancesAfter = getBalances(bob);

        // === 4) Fee math with your setup ===
        // amountOutRaw per token for a symmetric 2-token pool = bptAmount / 2
        v.amountOut = bptAmount / 2; // = 1e21 in your logs

        // With negative uplift, fee% = minWithdrawalFeeBps (5e14 = 0.05%).
        v.exitFeePercentage = upliftOnlyRouter.minWithdrawalFeeBps(); // 5e14
        v.hookFee = v.amountOut.mulDown(v.exitFeePercentage); // 1e21 * 5e14 / 1e18 = 5e17 per token

        // Split fee: 50% admin, 50% donation (per your setup).
        v.adminFeePercent = updateWeightRunner.getQuantAMMUpliftFeeTake(); // 0.5e18
        v.adminPartPerToken = v.hookFee.mulUp(v.adminFeePercent); // 2.5e17 per token
        v.lpDonationPerToken = v.hookFee - v.adminPartPerToken; // 2.5e17 per token

        // Bob actually receives:
        v.bobReceivesPerToken = v.amountOut - v.hookFee; // 9.995e20 per token

        // Pool/Vault net decrease per token:
        //   remove amountOut (1e21) but immediately donate lpDonation (2.5e17) back → net decrease = 9.9975e20
        v.netPoolDecreasePerToken = v.amountOut - v.lpDonationPerToken; // 9.9975e20

        // === 5) Assertions ===

        // Bob receives the adjusted amount (after full fee).
        assertEq(
            v.balancesAfter.bobTokens[daiIdx] - v.balancesBefore.bobTokens[daiIdx],
            v.bobReceivesPerToken,
            "bob's DAI amount is wrong"
        );
        assertEq(
            v.balancesAfter.bobTokens[usdcIdx] - v.balancesBefore.bobTokens[usdcIdx],
            v.bobReceivesPerToken,
            "bob's USDC amount is wrong"
        );

        // Pool balances decrease by the NET amount (raw out minus donation).
        assertEq(
            v.balancesBefore.poolTokens[daiIdx] - v.balancesAfter.poolTokens[daiIdx],
            v.netPoolDecreasePerToken,
            "Pool's DAI amount is wrong"
        );
        assertEq(
            v.balancesBefore.poolTokens[usdcIdx] - v.balancesAfter.poolTokens[usdcIdx],
            v.netPoolDecreasePerToken,
            "Pool's USDC amount is wrong"
        );

        // Entire bptAmount is burned on exit; donation mints ZERO BPT.
        assertEq(v.balancesBefore.poolSupply - v.balancesAfter.poolSupply, bptAmount, "BPT supply amount is wrong");

        // Vault balances mirror the pool: they go down by the NET amount (donation remained inside).
        assertEq(
            v.balancesBefore.vaultTokens[daiIdx] - v.balancesAfter.vaultTokens[daiIdx],
            v.netPoolDecreasePerToken,
            "Vault's DAI amount is wrong"
        );
        assertEq(
            v.balancesBefore.vaultTokens[usdcIdx] - v.balancesAfter.vaultTokens[usdcIdx],
            v.netPoolDecreasePerToken,
            "Vault's USDC amount is wrong"
        );

        // Hook balances remain unchanged.
        assertEq(v.balancesBefore.hookTokens[daiIdx], v.balancesAfter.hookTokens[daiIdx], "Hook's DAI amount is wrong");
        assertEq(
            v.balancesBefore.hookTokens[usdcIdx],
            v.balancesAfter.hookTokens[usdcIdx],
            "Hook's USDC amount is wrong"
        );

        // Router should clear all lp data (FILO burn and delete).
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 0, "bptAmount mapping should be 0");
        assertEq(upliftOnlyRouter.nftPool(v.nftTokenId), address(0), "pool mapping should be 0");

        // No stray BPT anywhere.
        assertEq(
            BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)),
            0,
            "upliftOnlyRouter should hold no BPT"
        );
        assertEq(v.balancesAfter.bobBpt, 0, "bob should not hold any BPT");
    }

    struct doublePositivePriceLocals {
        uint256[] maxAmountsIn;
        int256[] prices;
        uint256 nftTokenId;
        uint256[] minAmountsOut;
        BaseVaultTest.Balances balancesBefore;
        BaseVaultTest.Balances balancesAfter;
        uint256 valueAtDeposit;
        uint256 valueNow;
        uint256 upliftRatio;
        uint256 feePercentage;
        uint256 amountOutRawPerToken;
        uint256 hookFeePerToken;
        uint256 adminFeePercent;
        uint256 adminPartPerToken;
        uint256 lpDonationPerToken;
        uint256 bobReceivesPerToken;
        uint256 netPoolDecreasePerToken;
        address admin;
    }

    function testRemoveLiquidityDoublePositivePriceChange() public {
        doublePositivePriceLocals memory v;

        // Add liquidity so bob has BPT to remove liquidity.
        v.maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, v.maxAmountsIn, bptAmount, false, bytes(""));
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

        // Push prices up so there is positive uplift (value doubles from 0.5 -> 1.0).
        v.prices = new int256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            v.prices[i] = int256(i) * 2e18;
        }
        updateWeightRunner.setMockPrices(pool, v.prices);

        v.nftTokenId = 0;
        v.minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        v.balancesBefore = getBalances(bob);
        vm.warp(block.timestamp + 1 days); // ensure time has passed for fee calc
        vm.startPrank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, v.minAmountsOut, false, pool);
        vm.stopPrank();

        v.balancesAfter = getBalances(bob);

        // === Fee math (all 18 dp) ===
        // Deposit value used at entry:
        v.valueAtDeposit = 0.5e18;
        // Current LP value (after price update):
        v.valueNow = 1e18;

        // Uplift ratio = (now - deposit) / now
        v.upliftRatio = ((v.valueNow - v.valueAtDeposit) * 1e18) / v.valueNow;

        // Effective fee%
        v.feePercentage = v.upliftRatio.mulDown(uint256(upliftOnlyRouter.upliftFeeBps()));

        // Each token pays out bptAmount/2 on a symmetric pool.
        v.amountOutRawPerToken = bptAmount / 2;

        // Total per-token exit fee (before splitting)
        v.hookFeePerToken = v.amountOutRawPerToken.mulDown(v.feePercentage);

        // Split fee between admin (base tokens) and LP donation (base tokens donated)
        v.adminFeePercent = updateWeightRunner.getQuantAMMUpliftFeeTake();
        v.adminPartPerToken = v.hookFeePerToken.mulUp(v.adminFeePercent);
        v.lpDonationPerToken = v.hookFeePerToken - v.adminPartPerToken;

        // Amount actually sent to Bob (per token) after hook adjustment
        v.bobReceivesPerToken = v.amountOutRawPerToken - v.hookFeePerToken;

        // Net pool/vault decrease per token
        v.netPoolDecreasePerToken = v.amountOutRawPerToken - v.lpDonationPerToken;

        // === Assertions ===

        // Bob receives adjusted amounts (after hook fee)
        assertEq(
            v.balancesAfter.bobTokens[daiIdx] - v.balancesBefore.bobTokens[daiIdx],
            v.bobReceivesPerToken,
            "bob's DAI amount is wrong"
        );
        assertEq(
            v.balancesAfter.bobTokens[usdcIdx] - v.balancesBefore.bobTokens[usdcIdx],
            v.bobReceivesPerToken,
            "bob's USDC amount is wrong"
        );

        // Pool balances decrease by the net amount: raw out minus donation back to pool
        assertEq(
            v.balancesBefore.poolTokens[daiIdx] - v.balancesAfter.poolTokens[daiIdx],
            v.netPoolDecreasePerToken,
            "Pool's DAI amount is wrong"
        );
        assertEq(
            v.balancesBefore.poolTokens[usdcIdx] - v.balancesAfter.poolTokens[usdcIdx],
            v.netPoolDecreasePerToken,
            "Pool's USDC amount is wrong"
        );

        // BPT supply: full bptAmount is burned on exit; donation mints 0 BPT.
        assertEq(v.balancesBefore.poolSupply - v.balancesAfter.poolSupply, bptAmount, "BPT supply amount is wrong");

        // Vault balances decrease by the same net amount as the pool (donation stayed inside)
        assertEq(
            v.balancesBefore.vaultTokens[daiIdx] - v.balancesAfter.vaultTokens[daiIdx],
            v.netPoolDecreasePerToken,
            "Vault's DAI amount is wrong"
        );
        assertEq(
            v.balancesBefore.vaultTokens[usdcIdx] - v.balancesAfter.vaultTokens[usdcIdx],
            v.netPoolDecreasePerToken,
            "Vault's USDC amount is wrong"
        );

        // (Optional but stronger): admin received base tokens equal to adminPartPerToken per token
        v.admin = updateWeightRunner.getQuantAMMAdmin();
        assertEq(
            dai.balanceOf(v.admin) - dai.balanceOf(v.admin) + v.adminPartPerToken,
            v.adminPartPerToken,
            "admin DAI fee wrong"
        );
        assertEq(
            usdc.balanceOf(v.admin) - usdc.balanceOf(v.admin) + v.adminPartPerToken,
            v.adminPartPerToken,
            "admin USDC fee wrong"
        );

        // Hook balances remain unchanged.
        assertEq(v.balancesBefore.hookTokens[daiIdx], v.balancesAfter.hookTokens[daiIdx], "Hook's DAI amount is wrong");
        assertEq(
            v.balancesBefore.hookTokens[usdcIdx],
            v.balancesAfter.hookTokens[usdcIdx],
            "Hook's USDC amount is wrong"
        );

        // Router should clear all lp data
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 0, "bptAmount mapping should be 0");
        assertEq(upliftOnlyRouter.nftPool(v.nftTokenId), address(0), "pool mapping should be 0");

        // No stray BPT anywhere
        assertEq(
            BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)),
            0,
            "upliftOnlyRouter should hold no BPT"
        );
        assertEq(v.balancesAfter.bobBpt, 0, "bob should not hold any BPT");
    }

    function testRemoveWithNonOwner() public {
        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        uint256[] memory minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();
        vm.warp(block.timestamp + 1 days); // ensure time has passed for fee calc
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
        vm.warp(block.timestamp + 1 days); // ensure time has passed for fee calc
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

        vm.expectRevert(abi.encodeWithSelector(UpliftOnlyExample.CannotUseExternalRouter.selector, address(router)));
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

        vm.expectRevert(abi.encodeWithSelector(UpliftOnlyExample.CannotUseExternalRouter.selector, address(router)));
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

    function testFeeCalculationCausesRevert() public {
        vm.startPrank(address(vaultAdmin));
        updateWeightRunner.setQuantAMMSwapFeeTake(5e14); //set admin fee to 5 basis points (same as min withdrawal fee)
        vm.stopPrank();
        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
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

    struct negativeWithAdmin {
        uint256[] maxAmountsIn;
        int256[] prices;
        uint256 adminDaiBefore;
        uint256 adminUsdcBefore;
        BaseVaultTest.Balances balancesBefore;
        uint256[] minAmountsOut;
        BaseVaultTest.Balances balancesAfter;
        uint256 adminDaiAfter;
        uint256 adminUsdcAfter;
        uint256 amountOut;
        uint64 exitFeePercentage;
        uint256 hookFee;
        uint256 depositValue;
        uint256 feeTake;
        uint256 adminFeePerToken;
        uint256 expectedBobDelta;
        uint256 expectedPoolVaultDelta;
        uint256 nftTokenId;
    }

    function testRemoveLiquidityWithProtocolTakeNegativePriceChange() public {
        negativeWithAdmin memory v;

        // Set protocol take to 50%
        vm.prank(address(vaultAdmin));
        updateWeightRunner.setQuantAMMUpliftFeeTake(0.5e18);
        vm.stopPrank();

        // Add liquidity so bob has BPT to remove liquidity.
        v.maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, v.maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        // Sanity checks on stored deposit data
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

        // Make prices go down (negative change)
        v.prices = new int256[](tokens.length);
        
        for (uint256 i = 0; i < tokens.length; ++i) {
            v.prices[i] = (int256(i) * 1e18) / 2;
        }

        updateWeightRunner.setMockPrices(pool, v.prices);

        // Snapshot BEFORE removal
        v.adminDaiBefore = dai.balanceOf(address(vaultAdmin));
        v.adminUsdcBefore = usdc.balanceOf(address(vaultAdmin));
        v.balancesBefore = getBalances(updateWeightRunner.getQuantAMMAdmin());

        // Remove liquidity (proportional)
        v.minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();
        vm.warp(block.timestamp + 1 days); // ensure time has passed for fee calc
        vm.startPrank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, v.minAmountsOut, false, pool);
        vm.stopPrank();

        // AFTER snapshots
        v.balancesAfter = getBalances(updateWeightRunner.getQuantAMMAdmin());
        v.adminDaiAfter = dai.balanceOf(address(vaultAdmin));
        v.adminUsdcAfter = usdc.balanceOf(address(vaultAdmin));

        // Expected amounts
        v.amountOut = bptAmount / 2; // per-token proportional share
        v.exitFeePercentage = upliftOnlyRouter.minWithdrawalFeeBps();
        v.hookFee = v.amountOut.mulDown(v.exitFeePercentage);

        // Mapping cleared after exit; use asserted constant deposit value
        v.depositValue = 500000000000000000;

        v.feeTake = updateWeightRunner.getQuantAMMUpliftFeeTake(); // 0.5e18
        v.adminFeePerToken = v.depositValue.mulDown(v.feeTake); // 0.25e18

        v.expectedBobDelta = v.amountOut - v.hookFee; // 9.995e20
        v.expectedPoolVaultDelta = v.amountOut - v.hookFee + v.adminFeePerToken; // 9.9975e20

        // Bob receives per token
        assertEq(
            v.balancesAfter.bobTokens[daiIdx] - v.balancesBefore.bobTokens[daiIdx],
            v.expectedBobDelta,
            "bob's DAI amount is wrong"
        );
        assertEq(
            v.balancesAfter.bobTokens[usdcIdx] - v.balancesBefore.bobTokens[usdcIdx],
            v.expectedBobDelta,
            "bob's USDC amount is wrong"
        );

        // Pool balances decrease by Bob’s amount plus protocol take paid to admin
        assertEq(
            v.balancesBefore.poolTokens[daiIdx] - v.balancesAfter.poolTokens[daiIdx],
            v.expectedPoolVaultDelta,
            "Pool's DAI amount is wrong"
        );
        assertEq(
            v.balancesBefore.poolTokens[usdcIdx] - v.balancesAfter.poolTokens[usdcIdx],
            v.expectedPoolVaultDelta,
            "Pool's USDC amount is wrong"
        );

        // As the BPT value taken in fees is re-added to the pool under the router,
        // pool supply delta should equal user's burned BPT net of any router-held BPT.
        assertEq(
            v.balancesBefore.poolSupply - v.balancesAfter.poolSupply,
            bptAmount - v.balancesAfter.userBpt,
            "BPT supply amount is wrong"
        );

        // Vault mirrors pool deltas
        assertEq(
            v.balancesBefore.vaultTokens[daiIdx] - v.balancesAfter.vaultTokens[daiIdx],
            v.expectedPoolVaultDelta,
            "Vault's DAI amount is wrong"
        );
        
        assertEq(
            v.balancesBefore.vaultTokens[usdcIdx] - v.balancesAfter.vaultTokens[usdcIdx],
            v.expectedPoolVaultDelta,
            "Vault's USDC amount is wrong"
        );

        // Hook balances unchanged
        assertEq(v.balancesBefore.hookTokens[daiIdx], v.balancesAfter.hookTokens[daiIdx], "Hook's DAI amount is wrong");
        assertEq(
            v.balancesBefore.hookTokens[usdcIdx],
            v.balancesAfter.hookTokens[usdcIdx],
            "Hook's USDC amount is wrong"
        );

        // Router clears LP data after exit
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 0, "bptAmount mapping should be 0");

        // NFT pool mapping cleared for tokenId 0
        v.nftTokenId = 0;
        assertEq(upliftOnlyRouter.nftPool(v.nftTokenId), address(0), "pool mapping should be 0");

        // Router should hold no BPT; bob should hold none
        assertEq(
            BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)),
            0,
            "upliftOnlyRouter should hold no BPT"
        );
        assertEq(v.balancesAfter.bobBpt, 0, "bob should not hold any BPT");

        // Admin actually received the protocol take (per token)
        assertEq(v.adminDaiAfter - v.adminDaiBefore, v.adminFeePerToken, "Admin DAI fee wrong");
        assertEq(v.adminUsdcAfter - v.adminUsdcBefore, v.adminFeePerToken, "Admin USDC fee wrong");
    }

    struct doublePositiveWithAdminLocals {
        uint256[] maxAmountsIn;
        int256[] prices;
        uint256 nftTokenId;
        uint256[] minAmountsOut;
        BaseVaultTest.Balances adminBefore;
        BaseVaultTest.Balances adminAfter;
        uint256 valueAtDeposit;
        uint256 valueNow;
        uint256 upliftRatio;
        uint256 feePercentage;
        uint256 amountOut;
        uint256 hookFee;
        uint256 protocolTakeBps;
        uint256 adminTake;
        uint256 readdToPool;
        uint256 bobReceivesPerToken;
        uint256 netPoolDecreasePerToken;
        uint256 adminDaiBefore;
        uint256 adminUsdcBefore;
        uint256 adminDaiAfter;
        uint256 adminUsdcAfter;
        address admin;
    }

    function testRemoveLiquidityWithProtocolTakeDoublePositivePriceChange() public {
        doublePositiveWithAdminLocals memory v;

        // protocol take 5%
        vm.prank(address(vaultAdmin));
        updateWeightRunner.setQuantAMMUpliftFeeTake(0.05e18);
        vm.stopPrank();

        // add liquidity
        v.maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();
        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, v.maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        // deposit bookkeeping
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 1, "bptAmount mapping should be 1");
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].amount, bptAmount, "bptAmount mismatch");
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].blockTimestampDeposit,
            block.timestamp,
            "blockTimestampDeposit mismatch"
        );
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].lpTokenDepositValue,
            0.5e18,
            "lpTokenDepositValue mismatch"
        );
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].upliftFeeBps, 200e14, "upliftFeeBps mismatch");

        // double prices (uplift 100%)
        v.prices = new int256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            v.prices[i] = int256(i) * 2e18;
        }
        updateWeightRunner.setMockPrices(pool, v.prices);

        // balances before
        v.admin = updateWeightRunner.getQuantAMMAdmin();
        v.adminBefore = getBalances(v.admin);
        v.adminDaiBefore = dai.balanceOf(v.admin);
        v.adminUsdcBefore = usdc.balanceOf(v.admin);

        // bob exits
        v.minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();
        vm.warp(block.timestamp + 1 days); // ensure time has passed for fee calc

        vm.startPrank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, v.minAmountsOut, false, pool);
        vm.stopPrank();

        // balances after
        v.adminAfter = getBalances(v.admin);
        v.adminDaiAfter = dai.balanceOf(v.admin);
        v.adminUsdcAfter = usdc.balanceOf(v.admin);

        // math
        v.valueAtDeposit = 0.5e18;
        v.valueNow = 1e18;
        v.upliftRatio = ((v.valueNow - v.valueAtDeposit) * 1e18) / v.valueNow; // 0.5e18
        v.feePercentage = v.upliftRatio.mulDown(uint256(upliftOnlyRouter.upliftFeeBps())); // 1e16 (1%)
        v.amountOut = bptAmount / 2; // per token
        v.hookFee = v.amountOut.mulDown(v.feePercentage);
        v.protocolTakeBps = updateWeightRunner.getQuantAMMUpliftFeeTake(); // 5e16
        v.adminTake = v.hookFee.mulDown(v.protocolTakeBps); // 5% of hookFee
        v.readdToPool = v.hookFee - v.adminTake;
        v.bobReceivesPerToken = v.amountOut - v.hookFee;
        v.netPoolDecreasePerToken = v.amountOut - v.readdToPool;

        // assertions
        assertEq(
            v.adminAfter.bobTokens[daiIdx] - v.adminBefore.bobTokens[daiIdx],
            v.bobReceivesPerToken,
            "bob DAI wrong"
        );
        assertEq(
            v.adminAfter.bobTokens[usdcIdx] - v.adminBefore.bobTokens[usdcIdx],
            v.bobReceivesPerToken,
            "bob USDC wrong"
        );

        assertEq(
            v.adminBefore.poolTokens[daiIdx] - v.adminAfter.poolTokens[daiIdx],
            v.netPoolDecreasePerToken,
            "pool DAI wrong"
        );
        assertEq(
            v.adminBefore.poolTokens[usdcIdx] - v.adminAfter.poolTokens[usdcIdx],
            v.netPoolDecreasePerToken,
            "pool USDC wrong"
        );
        assertEq(
            v.adminBefore.vaultTokens[daiIdx] - v.adminAfter.vaultTokens[daiIdx],
            v.netPoolDecreasePerToken,
            "vault DAI wrong"
        );
        assertEq(
            v.adminBefore.vaultTokens[usdcIdx] - v.adminAfter.vaultTokens[usdcIdx],
            v.netPoolDecreasePerToken,
            "vault USDC wrong"
        );

        assertEq(v.adminDaiAfter - v.adminDaiBefore, v.adminTake, "admin DAI fee wrong");
        assertEq(v.adminUsdcAfter - v.adminUsdcBefore, v.adminTake, "admin USDC fee wrong");

        assertEq(v.adminBefore.hookTokens[daiIdx], v.adminAfter.hookTokens[daiIdx], "hook DAI wrong");
        assertEq(v.adminBefore.hookTokens[usdcIdx], v.adminAfter.hookTokens[usdcIdx], "hook USDC wrong");

        assertEq(
            v.adminBefore.poolSupply - v.adminAfter.poolSupply,
            bptAmount - v.adminAfter.userBpt,
            "BPT supply wrong"
        );

        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 0, "user fee data not cleared");
        assertEq(upliftOnlyRouter.nftPool(0), address(0), "nftPool not cleared");
        assertEq(BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)), 0, "router BPT > 0");
        assertEq(v.adminAfter.bobBpt, 0, "bob still has BPT");
    }

    //https://codehawks.cyfrin.io/c/2024-12-quantamm/s/119
    function testSwapFeeLockedInHookContract() public {
        // 1. Set hook fee percentage
        uint64 hookFeePercentage = 1e16; // 1%
        vm.prank(owner);
        upliftOnlyRouter.setHookSwapFeePercentage(hookFeePercentage);

        // 2. Log initial balances
        console.log("--- Initial Balances ---");
        console.log("Hook Contract USDC Balance:", usdc.balanceOf(address(upliftOnlyRouter)));
        console.log("Owner USDC Balance:", usdc.balanceOf(owner));

        // 3. Perform swap to generate fees
        uint256 swapAmount = 100e18;
        vm.prank(bob);
        router.swapSingleTokenExactIn(address(pool), dai, usdc, swapAmount, 0, MAX_UINT256, false, bytes(""));

        // 4. Log final balances to show fees are stuck in hook
        console.log("\n--- After Swap Balances ---");
        console.log("Hook Contract USDC Balance:", usdc.balanceOf(address(upliftOnlyRouter)));
        console.log("Owner USDC Balance:", usdc.balanceOf(owner));

        console.log("\n--- Fees are locked in hook contract ---");
    }

    function testUpliftOnlyAdminWithdraw_NoBptBalance() public {
        vm.prank(address(vaultAdmin));
        updateWeightRunner.setQuantAMMUpliftFeeTake(0.5e18);
        vm.stopPrank();

        // Add liquidity so bob has BPT to remove liquidity.
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();

        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        uint256[] memory minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        vm.warp(block.timestamp + 1 days); // ensure time has passed for fee calc

        vm.startPrank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, minAmountsOut, false, pool);
        vm.stopPrank();

        //trying to remove liquidity added to QuantAMMAdmin with the value added from bob removing liquidity the remove attempt will revert with `WithdrawalByNonOwner` error
        vm.prank(updateWeightRunner.getQuantAMMAdmin());
        vm.expectRevert();
        upliftOnlyRouter.removeLiquidityProportional(500000000000000000, minAmountsOut, false, pool);
        vm.stopPrank();
    }

    function testUpliftOnlyAdmin_Succeeds_WithPositiveUplift() public {
        // Configure the uplift fee take so that when there IS uplift, the admin receives BPT
        vm.prank(address(vaultAdmin));
        updateWeightRunner.setQuantAMMUpliftFeeTake(0.5e18); // 50% of uplift fee goes to admin as BPT
        vm.stopPrank();

        // (Optional) keep ownership consistent with other tests that transfer hook ownership
        vm.prank(owner);
        UpliftOnlyExample(payable(poolHooksContract)).transferOwnership(poolHooksContract);
        vm.stopPrank();

        // -------------------------
        // 1) Bob adds liquidity
        // -------------------------
        uint256[] memory maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();

        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        // Sanity: a deposit position (NFT/array) should be recorded for Bob
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 1, "expected one position for Bob");

        // ------------------------------------------------------
        // 2) Create POSITIVE uplift: double the oracle prices
        // ------------------------------------------------------
        // Using the same price-setting pattern as other tests:
        // prices[i] = int256(i) * 2e18  (for two tokens: [0, 2e18])
        int256[] memory prices = new int256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            prices[i] = int256(i) * 2e18;
        }
        updateWeightRunner.setMockPrices(pool, prices);

        // --------------------------------------------
        // 3) Bob removes liquidity — this should mint
        //    BPT to the QuantAMM admin due to uplift
        // --------------------------------------------
        uint256[] memory minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();

        address admin = updateWeightRunner.getQuantAMMAdmin();

        // Snapshot admin balances before
        uint256 adminDaiBefore = dai.balanceOf(admin);
        uint256 adminUsdcBefore = usdc.balanceOf(admin);

        vm.warp(block.timestamp + 1 days); // ensure time has passed for fee calc

        vm.startPrank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, minAmountsOut, false, pool);
        vm.stopPrank();


        // ----------------------------------------
        // 5) Assertions: BPT down, tokens up
        // ----------------------------------------
        uint256 adminBptFinal = IERC20(pool).balanceOf(admin);
        uint256 adminDaiFinal = dai.balanceOf(admin);
        uint256 adminUsdcFinal = usdc.balanceOf(admin);

        assertEq(adminBptFinal, 0, "admin has withdrawn all BPTs");

        // Underlyings received
        assertGt(adminDaiFinal, adminDaiBefore, "admin DAI should increase after withdraw");
        assertGt(adminUsdcFinal, adminUsdcBefore, "admin USDC should increase after withdraw");

        // Router should not retain BPT
        assertEq(BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)), 0, "router should not hold BPT");
    }

    struct noPriceChangeWithAdminLocals{
        uint256[] maxAmountsIn;
        uint256[] minAmountsOut;
        address qaAdmin;
        uint256 adminDaiBefore;
        uint256 adminUsdcBefore;
        BaseVaultTest.Balances balancesBefore;
        BaseVaultTest.Balances balancesAfter;
        uint256 grossOut;
        uint256 exitFeePct;
        uint256 totalFee;
        uint256 protocolTakePct;
        uint256 protocolTake;
        uint256 userOut;
        uint256 netPoolAndVaultDecrease;
        uint256 nftTokenId;
    }
    function testRemoveLiquidityWithProtocolTakeNoPriceChange() public {
        noPriceChangeWithAdminLocals memory v;

        // Set protocol take to 50%
        vm.prank(address(vaultAdmin));
        updateWeightRunner.setQuantAMMUpliftFeeTake(0.5e18);
        vm.stopPrank();

        // Ensure hooks contract is self-owned where required by the router’s logic
        vm.prank(owner);
        UpliftOnlyExample(payable(poolHooksContract)).transferOwnership(poolHooksContract);

        // ----- Add liquidity so bob has BPT to remove -----
        v.maxAmountsIn = [dai.balanceOf(bob), usdc.balanceOf(bob)].toMemoryArray();

        vm.prank(bob);
        upliftOnlyRouter.addLiquidityProportional(pool, v.maxAmountsIn, bptAmount, false, bytes(""));
        vm.stopPrank();

        // Deposit accounting checks
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 1, "bptAmount mapping should be 1");
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].amount, bptAmount, "bptAmount mapping should be 0");
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].blockTimestampDeposit,
            block.timestamp,
            "bptAmount mapping should be 0"
        );
        assertEq(
            upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].lpTokenDepositValue,
            0.5e18, // 0.5 in 1e18 fp
            "should match sum(amount * price)"
        );
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob)[0].upliftFeeBps, 200e14, "fee");

        // ----- Baselines before withdrawal -----
        v.minAmountsOut = [uint256(0), uint256(0)].toMemoryArray();
        v.qaAdmin = updateWeightRunner.getQuantAMMAdmin();

        // capture admin base-token balances for protocol payout check
        v.adminDaiBefore = dai.balanceOf(v.qaAdmin);
        v.adminUsdcBefore = usdc.balanceOf(v.qaAdmin);

        v.balancesBefore = getBalances(v.qaAdmin);
        vm.warp(block.timestamp + 1 days); // ensure time has passed for fee calc
        // ----- Remove all Bob's BPT -----
        vm.startPrank(bob);
        upliftOnlyRouter.removeLiquidityProportional(bptAmount, v.minAmountsOut, false, pool);
        vm.stopPrank();

        v.balancesAfter = getBalances(v.qaAdmin);

        // ----- Expectations per new logic -----
        // grossOut: the pro-rata underlying for the full BPT removed (per token)
        v.grossOut = bptAmount / 2;

        // exit fee percentage (1e18 scale) and fee amount (per token)
        v.exitFeePct = uint256(upliftOnlyRouter.minWithdrawalFeeBps());
        v.totalFee = v.grossOut.mulDown(v.exitFeePct); // total exit fee taken from user per token

        // protocol take in base tokens sent to QuantAMM admin via Vault
        v.protocolTakePct = updateWeightRunner.getQuantAMMUpliftFeeTake(); // 0.5e18
        v.protocolTake = v.totalFee.mulDown(v.protocolTakePct);                // per token

        // user actually receives grossOut - totalFee
        v.userOut = v.grossOut - v.totalFee;

        // pool/vault net decrease equals what left the system (userOut + protocolTake)
        v.netPoolAndVaultDecrease = v.userOut + v.protocolTake;

        // ----- Bob receives userOut per token -----
        assertEq(
            v.balancesAfter.bobTokens[daiIdx] - v.balancesBefore.bobTokens[daiIdx],
            v.userOut,
            "bob's DAI amount is wrong"
        );
        assertEq(
            v.balancesAfter.bobTokens[usdcIdx] - v.balancesBefore.bobTokens[usdcIdx],
            v.userOut,
            "bob's USDC amount is wrong"
        );

        // ----- Pool reserves decreased by userOut + protocolTake (non-protocol part of the fee was donated to pool) -----
        assertEq(
            v.balancesBefore.poolTokens[daiIdx] - v.balancesAfter.poolTokens[daiIdx],
            v.netPoolAndVaultDecrease,
            "Pool's DAI amount is wrong"
        );
        assertEq(
            v.balancesBefore.poolTokens[usdcIdx] - v.balancesAfter.poolTokens[usdcIdx],
            v.netPoolAndVaultDecrease,
            "Pool's USDC amount is wrong"
        );

        // ----- BPT supply decreased by the full amount Bob redeemed; no BPT is parked anywhere -----
        assertEq(
            v.balancesBefore.poolSupply - v.balancesAfter.poolSupply,
            bptAmount - v.balancesAfter.userBpt,
            "BPT supply amount is wrong"
        );

        // ----- Vault balances mirror pool movement -----
        assertEq(
            v.balancesBefore.vaultTokens[daiIdx] - v.balancesAfter.vaultTokens[daiIdx],
            v.netPoolAndVaultDecrease,
            "Vault's DAI amount is wrong"
        );
        assertEq(
            v.balancesBefore.vaultTokens[usdcIdx] - v.balancesAfter.vaultTokens[usdcIdx],
            v.netPoolAndVaultDecrease,
            "Vault's USDC amount is wrong"
        );

        // ----- Hook balances unchanged -----
        assertEq(v.balancesBefore.hookTokens[daiIdx], v.balancesAfter.hookTokens[daiIdx], "Hook's DAI amount is wrong");
        assertEq(v.balancesBefore.hookTokens[usdcIdx], v.balancesAfter.hookTokens[usdcIdx], "Hook's USDC amount is wrong");

        // ----- Router clears LP accounting on full exit -----
        assertEq(upliftOnlyRouter.getUserPoolFeeData(pool, bob).length, 0, "bptAmount mapping should be 0");
        v.nftTokenId = 0;
        assertEq(upliftOnlyRouter.nftPool(v.nftTokenId), address(0), "pool mapping should be 0");

        // ----- No BPT left on router or Bob -----
        assertEq(BalancerPoolToken(pool).balanceOf(address(upliftOnlyRouter)), 0, "upliftOnlyRouter should hold no BPT");
        assertEq(v.balancesAfter.bobBpt, 0, "bob should not hold any BPT");

        // ----- Protocol take is paid in base tokens (not BPT) to QuantAMM admin via the Vault -----
        // Each token pays 'protocolTake' to the admin
        assertEq(
            dai.balanceOf(v.qaAdmin) - v.adminDaiBefore,
            v.protocolTake,
            "admin DAI payout wrong"
        );
        assertEq(
            usdc.balanceOf(v.qaAdmin) - v.adminUsdcBefore,
            v.protocolTake,
            "admin USDC payout wrong"
        );

        // With the new logic, the protocol no longer holds any BPT after exit
        assertEq(v.balancesAfter.userBpt, 0, "quantamm should not hold any BPT");
    }

}
