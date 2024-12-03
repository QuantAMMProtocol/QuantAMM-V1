pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "forge-std/console.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { PoolRoleAccounts } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
import { BalancerPoolToken } from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { QuantAMMWeightedPool } from "../../contracts/QuantAMMWeightedPool.sol";
import { QuantAMMWeightedPoolFactory } from "../../contracts/QuantAMMWeightedPoolFactory.sol";
import { QuantAMMWeightedPoolContractsDeployer } from "./utils/QuantAMMWeightedPoolContractsDeployer.sol";
import { PoolSwapParams, SwapKind } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { OracleWrapper } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/OracleWrapper.sol";
import { MockUpdateWeightRunner } from "../../contracts/mock/MockUpdateWeightRunner.sol";
import { MockMomentumRule } from "../../contracts/mock/mockRules/MockMomentumRule.sol";
import { MockChainlinkOracle } from "../../contracts/mock/MockChainlinkOracles.sol";

import "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IQuantAMMWeightedPool.sol";

contract QuantAMMWeightedPoolAllTokenVariationsTest is QuantAMMWeightedPoolContractsDeployer, BaseVaultTest {
    struct testParam {
        uint index;
        int256 weight;
        int256 multiplier;
    }

    struct VariationTestVariables {
        int256[] newWeights;
        uint256[] testUint256;
        uint256[] balances;
        testParam firstWeight;
        testParam secondWeight;
        QuantAMMWeightedPoolFactory.NewPoolParams params;
        PoolSwapParams swapParams;
        IQuantAMMWeightedPool.QuantAMMWeightedPoolDynamicData dynamicData;
        IQuantAMMWeightedPool.QuantAMMWeightedPoolImmutableData immutableData;
    }
    using CastingHelpers for address[];
    using ArrayHelpers for *;

    // Maximum swap fee of 10%
    uint64 public constant MAX_SWAP_FEE_PERCENTAGE = 10e16;

    QuantAMMWeightedPoolFactory internal quantAMMWeightedPoolFactory;

    function setUp() public override {
        int216 fixedValue = 1000;
        uint delay = 3600;

        super.setUp();
        (address ownerLocal, address addr1Local, address addr2Local) = (vm.addr(1), vm.addr(2), vm.addr(3));
        owner = ownerLocal;
        addr1 = addr1Local;
        addr2 = addr2Local;
        // Deploy UpdateWeightRunner contract
        vm.startPrank(owner);
        updateWeightRunner = new MockUpdateWeightRunner(owner, addr2);

        chainlinkOracle = _deployOracle(fixedValue, delay);

        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));

        vm.stopPrank();

        quantAMMWeightedPoolFactory = deployQuantAMMWeightedPoolFactory(
            IVault(address(vault)),
            365 days,
            "Factory v1",
            "Pool v1"
        );
        vm.label(address(quantAMMWeightedPoolFactory), "quantamm weighted pool factory");
    }

    function testGetNormalizedWeightsInitial_Fuzz(int256 defaultMultiplier) public {
        int256 min = -(int256(type(uint256).min)) / int256(5e18);
        int256 max = int256(type(uint256).max) / int256(5e18);
        int256 boundMultiplier = bound(defaultMultiplier, min, max);
        _testGetNormalizedWeights(0, 0.125e18, boundMultiplier);
    }

    function testGetNormalizedWeightsNBlocksAfter_Fuzz(uint delay, int256 defaultMultiplier) public {
        uint boundDelay = bound(delay, 1, 5);
        int256 min = -(int256(type(uint256).min)) / int256(5e18);
        int256 max = int256(type(uint256).max)  / int256(5e18);
        int256 boundMultiplier = bound(defaultMultiplier, min, max);
        _testGetNormalizedWeights(boundDelay, 0.125e18, boundMultiplier);
    }

    function testGetNormalizedWeightsAfterLimit_Fuzz(uint delay, int256 defaultMultiplier) public {
        uint boundDelay = bound(delay, 6, type(uint40).max);
        int256 min = -(int256(type(uint256).min)) / int256(5e18);
        int256 max = int256(type(uint256).max)  / int256(5e18);
        int256 boundMultiplier = bound(defaultMultiplier, min, max);
        _testGetNormalizedWeights(boundDelay, 0.125e18, boundMultiplier);
    }

    function testGetDynamicDataWeightsInitial_Fuzz(int256 defaultMultiplier) public {
        int256 min = -(int256(type(uint256).min)) / int256(5e18);
        int256 max = int256(type(uint256).max) / int256(5e18);
        int256 boundMultiplier = bound(defaultMultiplier, min, max);
        _testGetNormalizedWeights(0, 0.125e18, boundMultiplier);
    }

    function testGetDynamicDataWeightsNBlocksAfter_Fuzz(uint delay, int256 defaultMultiplier) public {
        uint boundDelay = bound(delay, 1, 5);
        int256 min = -(int256(type(uint256).min)) / int256(5e18);
        int256 max = int256(type(uint256).max)  / int256(5e18);
        int256 boundMultiplier = bound(defaultMultiplier, min, max);
        _testGetNormalizedWeights(boundDelay, 0.125e18, boundMultiplier);
    }

    function testGetDynamicDataWeightsAfterLimit_Fuzz(uint delay, int256 defaultMultiplier) public {
        uint boundDelay = bound(delay, 6, type(uint40).max);
        int256 min = -(int256(type(uint256).min)) / int256(5e18);
        int256 max = int256(type(uint256).max)  / int256(5e18);
        int256 boundMultiplier = bound(defaultMultiplier, min, max);
        _testGetNormalizedWeights(boundDelay, 0.125e18, boundMultiplier);
    }
    //the other tests go through individual use cases, this makes sure no combo of weight in and out makes a difference
    function testBalancesInitial() public {
        uint256 initialBalanceExpected = 34364.13714432034357275e18;
        _testBalances(0, initialBalanceExpected);        
    }

    function testBalancesNBlocksAfter() public {
        uint256 afterNBlocksBalanceExpected = 33157.342019808691780500e18;
        _testBalances(2, afterNBlocksBalanceExpected);        
    }

    function testBalancesAfterLimit() public {
        uint256 afterLimitBalanceExpected = 31506.494738337110886450e18;
        _testBalances(7, afterLimitBalanceExpected);        
    }

    //the other tests go through individual use cases, this makes sure no combo of weight in and out makes a difference
    function testSwapExactInInitial() public {
        uint256 initialExactInExpected = 0.933193215556651560e18;
        _testSwapExactIn(0, initialExactInExpected);        
    }

    function testSwapExactInNBlocksAfter() public {
        uint256 afterNBlocksExactInExpected = 0.939332273487470940e18;
        _testSwapExactIn(2, afterNBlocksExactInExpected);
    }

    function testSwapExactInAfterLimit() public {
        uint256 afterLimitExactInExpected = 0.948243800561591520e18;
        _testSwapExactIn(7, afterLimitExactInExpected);
    }

    //the other tests go through individual use cases, this makes sure no combo of weight in and out makes a difference
    function testSwapExactOutInitial() public {
        uint256 initialExactOutExpected = 1.071600963612444750e18;
        _testSwapExactOut(0, initialExactOutExpected);     
    }

    function testSwapExactOutNBlocksAfter() public {
        uint256 afterNBlocksExactOutExpected = 1.064596364045350800e18;
        _testSwapExactOut(2, afterNBlocksExactOutExpected);   
    }

    function testSwapExactOutAfterLimit() public {
        uint256 afterLimitExactOutExpected = 1.054589808567700500e18;
        _testSwapExactOut(7, afterLimitExactOutExpected);   
    }


    function _testGetNormalizedWeights(uint delay, int256 defaultWeight, int256 defaultMultiplier) internal {
        uint40 timestamp = uint40(block.timestamp);
        VariationTestVariables memory variables;
        variables.firstWeight = testParam(0, 0.1e18, 0.001e18);
        variables.secondWeight = testParam(0, 0.15e18, 0.001e18);
        variables.params = _createPoolParams(defaultWeight, delay);
        address quantAMMWeightedPool = quantAMMWeightedPoolFactory.create(variables.params);
        
        uint expectedDelay = delay;
        if(delay > 5){
            expectedDelay = 5;
        }
        for(uint i = 0 ; i < 8; i++){
            for(uint j = 0; j < 8; j++){
                if(i != j){
                    vm.warp(timestamp);
                    _setupVariables(variables, i, j, delay, defaultMultiplier);

                    vm.prank(address(updateWeightRunner));
                    
                    QuantAMMWeightedPool(quantAMMWeightedPool).setWeights(
                        variables.newWeights,
                        quantAMMWeightedPool,
                        uint40(timestamp + 5)
                    );

                    variables.testUint256 = QuantAMMWeightedPool(quantAMMWeightedPool).getNormalizedWeights();
                    
                    if(delay > 0){
                        vm.warp(timestamp + delay);
                    }
                    
                    variables.testUint256 = QuantAMMWeightedPool(quantAMMWeightedPool).getNormalizedWeights();
                    
                    for(uint k = 0; k < 8; k++){
                        if(k == variables.firstWeight.index){
                            if(variables.firstWeight.multiplier > 0){
                                assertEq(variables.testUint256[k], uint256(variables.firstWeight.weight) + (uint256(variables.firstWeight.multiplier) * expectedDelay));
                            }
                            else{
                                assertEq(variables.testUint256[k], uint256(variables.firstWeight.weight) - (uint256(-variables.firstWeight.multiplier) * uint256(expectedDelay)));
                            }
                        }
                        else if(k == variables.secondWeight.index){
                            if(variables.secondWeight.multiplier > 0){
                                assertEq(variables.testUint256[k], uint256(variables.secondWeight.weight) + (uint256(variables.secondWeight.multiplier) * expectedDelay));
                            }
                            else{
                                assertEq(variables.testUint256[k], uint256(variables.secondWeight.weight) - (uint256(-variables.secondWeight.multiplier) * uint256(expectedDelay)));
                            }
                        }
                        else{
                            if(defaultMultiplier > 0){
                                assertEq(variables.testUint256[k], uint256(defaultWeight) + (uint256(defaultMultiplier) * expectedDelay));
                            }
                            else{
                                assertEq(variables.testUint256[k], uint256(defaultWeight) - (uint256(-defaultMultiplier) * uint256(expectedDelay)));
                            }
                        }
                    }
                }
            }
        }
    }

    function _testGetDynamicData(uint delay, int256 multiplier) internal {
        uint40 timestamp = uint40(block.timestamp);
        VariationTestVariables memory variables;
        variables.firstWeight = testParam(0, 0.1e18, 0.001e18);
        variables.secondWeight = testParam(0, 0.15e18, 0.001e18);
        variables.params = _createPoolParams(0.125e18, delay);
        address quantAMMWeightedPool = quantAMMWeightedPoolFactory.create(variables.params);
        uint expectedDelay = delay;
        if(delay > 5){
            expectedDelay = 5;
        }
        for(uint i = 0 ; i < 8; i++){
            for(uint j = 0; j < 8; j++){
                if(i != j){
                    vm.warp(timestamp);
                    _setupVariables(variables, i, j, delay, multiplier);

                    vm.prank(address(updateWeightRunner));
                    
                    QuantAMMWeightedPool(quantAMMWeightedPool).setWeights(
                        variables.newWeights,
                        quantAMMWeightedPool,
                        uint40(timestamp + 5)
                    );

                    if(delay > 0){
                        vm.warp(timestamp + delay);
                    }
                    
                    variables.dynamicData = QuantAMMWeightedPool(quantAMMWeightedPool).getQuantAMMWeightedPoolDynamicData();

                    for(uint k = 0; k < 8; k++){
                        if(k == variables.firstWeight.index){
                            assertEq(variables.dynamicData.weightsAtLastUpdateInterval[variables.firstWeight.index], variables.firstWeight.weight);
                            assertEq(variables.dynamicData.weightBlockMultipliers[variables.firstWeight.index], variables.firstWeight.multiplier);
                        }
                        else if(k == variables.secondWeight.index){
                            assertEq(variables.dynamicData.weightsAtLastUpdateInterval[variables.secondWeight.index], variables.secondWeight.weight);
                            assertEq(variables.dynamicData.weightBlockMultipliers[variables.secondWeight.index], variables.secondWeight.multiplier);
                        }
                        else{
                            assertEq(variables.dynamicData.weightsAtLastUpdateInterval[k], 0.125e18);
                            assertEq(variables.dynamicData.weightBlockMultipliers[k], multiplier);
                        }
                    }

                    assertEq(variables.dynamicData.lastUpdateIntervalTime, uint40(timestamp));
                    assertEq(variables.dynamicData.lastInterpolationTimePossible, uint40(timestamp + 5));
                }
            }
        }
    }

    function _testBalances(uint delay, uint256 balanceExpected) internal {
        uint40 timestamp = uint40(block.timestamp);
        VariationTestVariables memory variables;
        variables.firstWeight = testParam(0, 0.1e18, 0.001e18);
        variables.secondWeight = testParam(0, 0.15e18, 0.001e18);
        variables.params = _createPoolParams(0.125e18, delay);
        address quantAMMWeightedPool = quantAMMWeightedPoolFactory.create(variables.params);
        uint expectedDelay = delay;
        if(delay > 5){
            expectedDelay = 5;
        }
        for(uint i = 0 ; i < 8; i++){
            for(uint j = 0; j < 8; j++){
                if(i != j){
                    vm.warp(timestamp);
                    _setupVariables(variables, i, j, delay, 0.025e18);
                    
                    vm.prank(address(updateWeightRunner));

                    QuantAMMWeightedPool(quantAMMWeightedPool).setWeights(
                        variables.newWeights,
                        quantAMMWeightedPool,
                        uint40(timestamp + 5)
                    );

                    if(delay > 0){
                        vm.warp(timestamp + delay);
                    }

                    uint256 testUnint = QuantAMMWeightedPool(quantAMMWeightedPool).computeBalance(
                        variables.balances,
                        variables.firstWeight.index,
                        uint256(1.2e18)
                    );

                    assertEq(testUnint, balanceExpected);
                }
            }
        }
    }


    function _testSwapExactIn(uint delay, uint256 exactInExpected) internal {
        uint40 timestamp = uint40(block.timestamp);
        VariationTestVariables memory variables;
        variables.firstWeight = testParam(0, 0.1e18, 0.001e18);
        variables.secondWeight = testParam(0, 0.15e18, 0.001e18);
        variables.params = _createPoolParams(0.125e18, delay);
        address quantAMMWeightedPool = quantAMMWeightedPoolFactory.create(variables.params);

        uint expectedDelay = delay;
        if(delay > 5){
            expectedDelay = 5;
        }
        for(uint i = 0 ; i < 8; i++){
            for(uint j = 0; j < 8; j++){
                if(i != j){
                    vm.warp(timestamp);
                    _setupVariables(variables, i, j, delay, 0.025e18);

                    vm.prank(address(updateWeightRunner));

                    QuantAMMWeightedPool(quantAMMWeightedPool).setWeights(
                        variables.newWeights,
                        quantAMMWeightedPool,
                        uint40(timestamp + 5)
                    );

                    if(delay > 0){
                        vm.warp(timestamp + delay);
                    }
                    
                    variables.swapParams = PoolSwapParams({
                        kind: SwapKind.EXACT_IN,
                        amountGivenScaled18: 1e18,
                        balancesScaled18: variables.balances,
                        indexIn: variables.firstWeight.index,
                        indexOut: variables.secondWeight.index,
                        router: address(router),
                        userData: abi.encode(0)
                    });
                    vm.prank(address(vault));
                    uint256 testUnint = QuantAMMWeightedPool(quantAMMWeightedPool).onSwap(variables.swapParams);

                    assertEq(testUnint, exactInExpected);
                }
            }
        }
    }

    function _testSwapExactOut(uint delay, uint256 exactOutExpected) internal {
        uint40 timestamp = uint40(block.timestamp);
        VariationTestVariables memory variables;
        variables.firstWeight = testParam(0, 0.1e18, 0.001e18);
        variables.secondWeight = testParam(0, 0.15e18, 0.001e18);
        variables.params = _createPoolParams(0.125e18, delay);
        address quantAMMWeightedPool = quantAMMWeightedPoolFactory.create(variables.params);
        uint expectedDelay = delay;
        if(delay > 5){
            expectedDelay = 5;
        }
        for(uint i = 0 ; i < 8; i++){
            for(uint j = 0; j < 8; j++){
                if(i != j){
                    vm.warp(timestamp);
                    _setupVariables(variables, i, j, delay, 0.025e18);

                    vm.prank(address(updateWeightRunner));

                    QuantAMMWeightedPool(quantAMMWeightedPool).setWeights(
                        variables.newWeights,
                        quantAMMWeightedPool,
                        uint40(timestamp + 5)
                    );

                    if(delay > 0){
                        vm.warp(timestamp + delay);
                    }


                    variables.swapParams = PoolSwapParams({
                        kind: SwapKind.EXACT_OUT,
                        amountGivenScaled18: 1e18,
                        balancesScaled18: variables.balances,
                        indexIn: variables.firstWeight.index,
                        indexOut: variables.secondWeight.index,
                        router: address(router),
                        userData: abi.encode(0)
                    });
                    vm.prank(address(vault));
                    uint256 testUnint = QuantAMMWeightedPool(quantAMMWeightedPool).onSwap(variables.swapParams);

                    assertEq(testUnint, exactOutExpected);
                }
            }
        }
    }

    function _setupVariables(VariationTestVariables memory variables, uint i, uint j, uint delay, int256 defaultMultiplier) internal pure {
        variables.firstWeight.index = i;
        variables.secondWeight.index = j;                    
        variables.params.salt = keccak256(abi.encodePacked(delay, "i", i,"_","j_", j));
        variables.newWeights = _getDefaultWeightAndMultiplier(defaultMultiplier);
        
        variables.newWeights[variables.firstWeight.index] = variables.firstWeight.weight;
        variables.newWeights[variables.secondWeight.index] = variables.secondWeight.weight;

        variables.newWeights[variables.firstWeight.index + 8] = variables.firstWeight.multiplier;
        variables.newWeights[variables.secondWeight.index + 8] = variables.secondWeight.multiplier;
        
        variables.balances = _getDefaultBalances();
        variables.balances[variables.firstWeight.index] = 5550e18;
        variables.balances[variables.secondWeight.index] = 7770e18;                    
    }

    function _getDefaultBalances() internal pure returns (uint256[] memory balances) {
        balances = new uint256[](8);
        balances[0] = 1000e18;
        balances[1] = 2000e18;
        balances[2] = 500e18;
        balances[3] = 350e18;
        balances[4] = 750e18;
        balances[5] = 7500e18;
        balances[6] = 8000e18;
        balances[7] = 5000e18;
    }

    function _getDefaultWeightAndMultiplier(int256 multipliers) internal pure returns (int256[] memory weights) {
        weights = new int256[](16);
        weights[0] = 0.125e18;
        weights[1] = 0.125e18;
        weights[2] = 0.125e18;
        weights[3] = 0.125e18;
        weights[4] = 0.125e18;
        weights[5] = 0.125e18;
        weights[6] = 0.125e18;
        weights[7] = 0.125e18;
        weights[8] = multipliers;
        weights[9] = multipliers;
        weights[10] = multipliers;
        weights[11] = multipliers;
        weights[12] = multipliers;
        weights[13] = multipliers;
        weights[14] = multipliers;
        weights[15] = multipliers;
    }

    function _createPoolParams(int256 weight, uint delay) internal returns (QuantAMMWeightedPoolFactory.NewPoolParams memory retParams) {
        PoolRoleAccounts memory roleAccounts;
        IERC20[] memory tokens = [
            address(dai),
            address(usdc),
            address(weth),
            address(wsteth),
            address(veBAL),
            address(waDAI),
            address(usdt),
            address(waUSDC)
        ].toMemoryArray().asIERC20();
        MockMomentumRule momentumRule = new MockMomentumRule(owner);

        uint32[] memory weights = new uint32[](8);
        weights[0] = uint32(uint256(weight));
        weights[1] = uint32(uint256(weight));
        weights[2] = uint32(uint256(weight));
        weights[3] = uint32(uint256(weight));
        weights[4] = uint32(uint256(weight));
        weights[5] = uint32(uint256(weight));
        weights[6] = uint32(uint256(weight));
        weights[7] = uint32(uint256(weight));

        int256[] memory initialWeights = new int256[](8);
        initialWeights[0] = weight;
        initialWeights[1] = weight;
        initialWeights[2] = weight;
        initialWeights[3] = weight;
        initialWeights[4] = weight;
        initialWeights[5] = weight;
        initialWeights[6] = weight;
        initialWeights[7] = weight;

        uint256[] memory initialWeightsUint = new uint256[](8);
        initialWeightsUint[0] = uint256(weight);
        initialWeightsUint[1] = uint256(weight);
        initialWeightsUint[2] = uint256(weight);
        initialWeightsUint[3] = uint256(weight);
        initialWeightsUint[4] = uint256(weight);
        initialWeightsUint[5] = uint256(weight);
        initialWeightsUint[6] = uint256(weight);
        initialWeightsUint[7] = uint256(weight);

        uint64[] memory lambdas = new uint64[](1);
        lambdas[0] = 0.2e18;

        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](1);
        parameters[0][0] = 0.2e18;

        address[][] memory oracles = new address[][](1);
        oracles[0] = new address[](1);
        oracles[0][0] = address(chainlinkOracle);

        return QuantAMMWeightedPoolFactory.NewPoolParams(
            "Pool With Donation",
            "PwD",
            vault.buildTokenConfig(tokens),
            initialWeightsUint,
            roleAccounts,
            MAX_SWAP_FEE_PERCENTAGE,
            address(0),
            true,
            false, // Do not disable unbalanced add/remove liquidity
            keccak256(abi.encodePacked(delay)),
            initialWeights,
            IQuantAMMWeightedPool.PoolSettings(
                new IERC20[](8),
                IUpdateRule(momentumRule),
                oracles,
                60,
                lambdas,
                0.01e18,
                0.01e18,
                0.01e18,
                parameters,
                address(0)
            ),
            initialWeights,
            initialWeights,
            3600,
            0,
            new string[][](0)
        );
    }
}