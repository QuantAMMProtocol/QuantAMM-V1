// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";
import { QuantAMMWeightedPool, IQuantAMMWeightedPool } from "pool-quantamm/contracts/QuantAMMWeightedPool.sol";
import {QuantAMMWeightedPoolFactory} from "pool-quantamm/contracts/QuantAMMWeightedPoolFactory.sol";
import { UpdateWeightRunner, IUpdateRule } from "pool-quantamm/contracts/UpdateWeightRunner.sol";
import { MockChainlinkOracle } from "./utils/MockChainlinkOracles.sol";
import "@balancer-labs/v3-interfaces/contracts/pool-quantamm/OracleWrapper.sol";
import { IUpdateRule } from "pool-quantamm/contracts/rules/UpdateRule.sol";
import { MockMomentumRule } from "pool-quantamm/contracts/mock/mockRules/MockMomentumRule.sol";
import { UpliftOnlyExample } from "../../contracts/hooks-quantamm/UpliftOnlyExample.sol";
import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IVaultAdmin } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultAdmin.sol";
import { PoolRoleAccounts, TokenConfig, HooksConfig } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IWETH } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/misc/IWETH.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Router } from "@balancer-labs/v3-vault/contracts/Router.sol";
import {console} from "forge-std/console.sol";

contract UpliftExampleCode is BaseVaultTest {  // use default dai, usdc, weth and mock oracle
    //address daiOnETH = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    //address usdcOnETH = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    //address wethOnETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 internal daiIdx;
    uint256 internal usdcIdx;

    uint256 SWAP_FEE_PERCENTAGE = 10e16;

    address quantAdmin = makeAddr("quantAdmin");
    address owner = makeAddr("owner");
    address poolCreator = makeAddr("poolCreator");
    address liquidityProvider1 = makeAddr("liquidityProvider1");
    address liquidityProvider2 = makeAddr("liquidityProvider2");
    address attacker = makeAddr("attacker");
    //address usdcUsd = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    //address daiUsd = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    //address ethOracle = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    QuantAMMWeightedPool public weightedPool;
    QuantAMMWeightedPoolFactory public weightedPoolFactory;
    UpdateWeightRunner public updateWeightRunner;
    MockChainlinkOracle mockOracledai;
    MockChainlinkOracle mockOracleusdc;
    MockChainlinkOracle ethOracle;
    Router externalRouter;

    UpliftOnlyExample upLifthook;

    function setUp() public override {
        vm.warp(block.timestamp + 3600);
        mockOracledai = new MockChainlinkOracle(1e18, 0);
        mockOracleusdc = new MockChainlinkOracle(1e18, 0);
        ethOracle = new MockChainlinkOracle(2000e18, 0);
        updateWeightRunner = new UpdateWeightRunner(quantAdmin, address(ethOracle));

        vm.startPrank(quantAdmin);
        updateWeightRunner.addOracle(OracleWrapper(address(mockOracledai)));
        updateWeightRunner.addOracle(OracleWrapper(address(mockOracleusdc)));
        vm.stopPrank();

        super.setUp();

        (daiIdx, usdcIdx) = getSortedIndexes(address(dai), address(usdc));

        vm.prank(quantAdmin);
        updateWeightRunner.setApprovedActionsForPool(pool, 2);
    }

    function createHook() internal override returns (address) {
        // Create the factory here, because it needs to be deployed after the Vault, but before the hook contract.
        weightedPoolFactory = new QuantAMMWeightedPoolFactory(IVault(address(vault)), 365 days, "Factory v1", "Pool v1", address(updateWeightRunner));
        // lp will be the owner of the hook. Only LP is able to set hook fee percentages.
        vm.prank(quantAdmin);
        upLifthook = new UpliftOnlyExample(IVault(address(vault)), IWETH(weth), IPermit2(permit2), 100, 100, address(updateWeightRunner), "version 1", "lpnft", "LP-NFT");
        return address(upLifthook);
    }

    function _createPool(
        address[] memory tokens,
        string memory label
    ) internal override returns (address newPool, bytes memory poolArgs) {
        QuantAMMWeightedPoolFactory.CreationNewPoolParams memory poolParams = _createPoolParams(tokens);

        (newPool, poolArgs) = weightedPoolFactory.create(poolParams);
        vm.label(newPool, label);

        authorizer.grantRole(vault.getActionId(IVaultAdmin.setStaticSwapFeePercentage.selector), quantAdmin);
        vm.prank(quantAdmin);
        vault.setStaticSwapFeePercentage(newPool, SWAP_FEE_PERCENTAGE);
    }

    function _createPoolParams(address[] memory tokens) internal returns (QuantAMMWeightedPoolFactory.CreationNewPoolParams memory retParams) {
        PoolRoleAccounts memory roleAccounts;

        uint64[] memory lambdas = new uint64[](1);
        lambdas[0] = 0.2e18;

        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](1);
        parameters[0][0] = 0.2e18;

        address[][] memory oracles = new address[][](2);
        oracles[0] = new address[](1);
        oracles[0][0] = address(mockOracledai);
        oracles[1] = new address[](1);
        oracles[1][0] = address(mockOracleusdc);

        uint256[] memory normalizedWeights = new uint256[](2);
        normalizedWeights[0] = uint256(0.5e18);
        normalizedWeights[1] = uint256(0.5e18);

        IERC20[] memory ierctokens = new IERC20[](2);
        for (uint256 i = 0; i < tokens.length; i++) {
            ierctokens[i] = IERC20(tokens[i]);
        }

        int256[] memory initialWeights = new int256[](2);
        initialWeights[0] = 0.5e18;
        initialWeights[1] = 0.5e18;
        
        int256[] memory initialMovingAverages = new int256[](2);
        initialMovingAverages[0] = 0.5e18;
        initialMovingAverages[1] = 0.5e18;
        
        int256[] memory initialIntermediateValues = new int256[](2);
        initialIntermediateValues[0] = 0.5e18;
        initialIntermediateValues[1] = 0.5e18;
        
        TokenConfig[] memory tokenConfig = vault.buildTokenConfig(ierctokens);
        
        retParams = QuantAMMWeightedPoolFactory.CreationNewPoolParams(
            "Pool With Donation",
            "PwD",
            tokenConfig,
            normalizedWeights,
            roleAccounts,
            0.02e18,
            address(poolHooksContract),
            true,
            true, // Do not disable unbalanced add/remove liquidity
            0x0000000000000000000000000000000000000000000000000000000000000000,
            initialWeights,
            IQuantAMMWeightedPool.PoolSettings(
                ierctokens,
                IUpdateRule(new MockMomentumRule(owner)),
                oracles,
                60,
                lambdas,
                0.2e18,
                0.2e18,
                0.3e18,
                parameters,
                poolCreator
            ),
            initialMovingAverages,
            initialIntermediateValues,
            3600,
            16,//able to set weights
            new string[][](0)
        );
    }

    function testRemoveLiquidityUplift() public {
        addLiquidity();
        
        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[0] = 1;
        minAmountsOut[1] = 1;

        vm.prank(liquidityProvider1);
        vm.warp(block.timestamp + 1 days); // ensure time has passed for fee calc
        UpliftOnlyExample(payable(poolHooksContract)).removeLiquidityProportional(2e18, minAmountsOut, true, pool);
    }

    function addLiquidity() public {
        deal(address(dai), liquidityProvider1, 100e18);
        deal(address(usdc), liquidityProvider1, 100e18);

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = 2.1e18;
        maxAmountsIn[1] = 2.1e18;
        uint256 exactBptAmountOut = 2e18;

        vm.startPrank(liquidityProvider1);
        IERC20(address(dai)).approve(address(permit2), 100e18);
        IERC20(address(usdc)).approve(address(permit2), 100e18);
        permit2.approve(address(dai), address(poolHooksContract), 100e18, uint48(block.timestamp));
        permit2.approve(address(usdc), address(poolHooksContract), 100e18, uint48(block.timestamp));
        UpliftOnlyExample(payable(poolHooksContract)).addLiquidityProportional(pool, maxAmountsIn, exactBptAmountOut, false, abi.encodePacked(liquidityProvider1));
        vm.stopPrank();

        deal(address(dai), liquidityProvider2, 100e18);
        deal(address(usdc), liquidityProvider2, 100e18);

        vm.startPrank(liquidityProvider2);
        IERC20(address(dai)).approve(address(permit2), 100e18);
        IERC20(address(usdc)).approve(address(permit2), 100e18);
        permit2.approve(address(dai), address(poolHooksContract), 100e18, uint48(block.timestamp));
        permit2.approve(address(usdc), address(poolHooksContract), 100e18, uint48(block.timestamp));
        UpliftOnlyExample(payable(poolHooksContract)).addLiquidityProportional(pool, maxAmountsIn, exactBptAmountOut, false, abi.encodePacked(liquidityProvider2));
        vm.stopPrank();

        console.log("Liquidity added");
    }
}