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
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import {WeightedMath} from "@balancer-labs/v3-solidity-utils/contracts/math/WeightedMath.sol";

import "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IQuantAMMWeightedPool.sol";

contract QuantAMMWeightedPoolAllTokenVariationsTest is QuantAMMWeightedPoolContractsDeployer, BaseVaultTest {


    using CastingHelpers for address[];
    using ArrayHelpers for *;
    using FixedPoint for uint256;

    // Maximum swap fee of 10%
    uint64 public constant MAX_SWAP_FEE_PERCENTAGE = 10e16;

    QuantAMMWeightedPoolFactory internal quantAMMWeightedPoolFactory;

    //@audit previous fuzz test was only testing a 20% change (0.125 goes to 0.15 for one asset, and 0.1 for another asset)
    // by shifting weights between min and max, we try to cover the edge cases with maximum/minimum weights
    int256 private constant _NUM_TOKENS = 8; // num tokens
    uint256 private constant _INTERPOLATION_TIME = 5; // 5 seconds - guard rail can be hit
    uint256 private constant _ORACLE_STALENESS_THRESHOLD = 3600; // 1 hour
    uint64 private constant _ABSOLUTE_WEIGHT_GUARD_RAIL = 0.01e18; // 1% guard rail
    uint64 private constant _EPSILON_MAX = 0.01e18; // 1% epsilon max   
    uint64 private constant _MAX_TRADE_SIZE_RATIO = 0.01e18; // 1% max trade size ratio
    int256 private constant _MIN_WEIGHT = int256(uint256(_ABSOLUTE_WEIGHT_GUARD_RAIL)); // 0.01e18
    int256 private constant _MAX_WEIGHT = 1e18 - (int256(_NUM_TOKENS) - 1) * int256(uint256(_ABSOLUTE_WEIGHT_GUARD_RAIL)); // 1e18- (8-1) * 0.01e18 = 0.93e18


    uint64 private constant _LAMBDA = 0.2e18; // 20% lambda
    int256 private constant _KAPPA = 0.2e18; // 20% kappa

    int256 private constant _DEFAULT_WEIGHT = 0.125e18; // 12.5% default weight
    int256 private constant _DEFAULT_MULTIPLIER = 0.001e18; // 0.1% default multiplier

    //@audit taken from WeightedMath.sol
    uint256 private constant _MAX_INVARIANT_RATIO = 300e16; // 300%
    uint256 private constant _MIN_INVARIANT_RATIO = 70e16; // 70%

    //@audit taken from WeightedMath.sol for Swap limits
    uint256 internal constant _MAX_IN_RATIO = 30e16; // 30%
    uint256 internal constant _MAX_OUT_RATIO = 30e16; // 30%

    struct TestParam { //@audit convention for struct is camel case starting with capital letter
        uint index;
        int256 weight;
        int256 multiplier;
    }

    struct FuzzParams {
        int256 firstWeight;
        int256 secondWeight;
        int256 firstMultiplier;
        int256 secondMultiplier; 
        int256 otherMultiplier; // multiplier for all other weights
        uint256 delay;
    }

    struct BalanceFuzzParams {
        uint256 tokenIndex;
        uint256 invariantRatio;
    }

    struct SwapFuzzParams {
        uint256 exactIn;
        uint256 exactOut;
    }


    struct VariationTestVariables {
        int256[] newWeights;
        uint256[] testUint256;
        uint256[] balances;
        TestParam firstWeight;
        TestParam secondWeight;
        TestParam otherWeights;
        QuantAMMWeightedPoolFactory.NewPoolParams params;
        PoolSwapParams swapParams;
        IQuantAMMWeightedPool.QuantAMMWeightedPoolDynamicData dynamicData;
        IQuantAMMWeightedPool.QuantAMMWeightedPoolImmutableData immutableData;
    }    

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
        updateWeightRunner = new MockUpdateWeightRunner(owner, addr2); //@note owner = vault admin, addr2 = eth oracle

        chainlinkOracle = _deployOracle(fixedValue, delay);

        updateWeightRunner.addOracle(OracleWrapper(chainlinkOracle));

        vm.stopPrank();

        quantAMMWeightedPoolFactory = deployQuantAMMWeightedPoolFactory(
            IVault(address(vault)),
            365 days, //@note pause window is setup at 365 days
            "Factory v1",
            "Pool v1"
        );
        vm.label(address(quantAMMWeightedPoolFactory), "quantamm weighted pool factory");
    }

    function _createPoolParams(int256 weight, uint delay) internal 
             returns (QuantAMMWeightedPoolFactory.NewPoolParams memory retParams) {
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
        //@note This is hardcoded to 8 right now - if NUM_TOKENS is changed, this array needs to change
        MockMomentumRule momentumRule = new MockMomentumRule(owner); 
        //@note using momentum rule- maybe also test with other rules

        uint32[] memory weights = new uint32[](uint256(_NUM_TOKENS));
        int256[] memory initialWeights = new int256[](uint256(_NUM_TOKENS));
        uint256[] memory initialWeightsUint = new uint256[](8);

        for(uint i; i< uint256(_NUM_TOKENS); i++){
            weights[i] = uint32(uint256(weight));
            initialWeights[i] = weight;
            initialWeightsUint[i] = uint256(weight);                        
        }

        uint64[] memory lambdas = new uint64[](1);
        lambdas[0] = _LAMBDA; 

        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](1);
        parameters[0][0] = _KAPPA; 

        address[][] memory oracles = new address[][](1);
        oracles[0] = new address[](1);
        oracles[0][0] = address(chainlinkOracle); //@note single oracle - set to price 1000

        return QuantAMMWeightedPoolFactory.NewPoolParams(
            "Pool With Donation",
            "PwD",
            vault.buildTokenConfig(tokens), //@note creates a sorted array of TokenConfig
            initialWeightsUint, //@note initial set of weights - common for all 
            roleAccounts,
            MAX_SWAP_FEE_PERCENTAGE,
            address(0), //@note no hook contract
            true, //@note enable donation - true
            false, // Do not disable unbalanced add/remove liquidity //@note disable unbalanced liquidity -> false
            keccak256(abi.encodePacked(delay)), //@follow-up why is this salt? how is delay connected here?
            initialWeights, 
            IQuantAMMWeightedPool.PoolSettings(
                new IERC20[](uint256(_NUM_TOKENS)),
                IUpdateRule(momentumRule),
                oracles,
                60, //@note update interval = 60 secs
                lambdas, //@note scalar lambda
                _EPSILON_MAX, 
                _ABSOLUTE_WEIGHT_GUARD_RAIL, 
                _MAX_TRADE_SIZE_RATIO, 
                parameters, //@notre rul parameters
                address(0) //@note no pool manager
            ),
            initialWeights, //@note initial moving averages
            initialWeights, //@note initial intermediate values
            3600, //@note oracle staleness threshold - 1 hour
            0, //@note no pool registry
            new string[][](0) //@note no pool detaiols
        );
    }

    function _setupVariables(VariationTestVariables memory variables, uint i, 
                             uint j, FuzzParams memory params) internal pure {
        variables.firstWeight.index = i;
        variables.secondWeight.index = j;                    
        variables.params.salt = keccak256(abi.encodePacked(params.delay, "i", i,"_","j_", j));

      // Add bounds for first weight
        variables.firstWeight.weight = truncateTo32Bit(bound(
            params.firstWeight,
            _MIN_WEIGHT,
            _MAX_WEIGHT
        ));

      int256 maxSecondWeight = 1e18 - variables.firstWeight.weight - (_MIN_WEIGHT * int256(_NUM_TOKENS - 2));
      if(maxSecondWeight > _MAX_WEIGHT) maxSecondWeight = _MAX_WEIGHT;
        // Add bound for second weight
        variables.secondWeight.weight = truncateTo32Bit(bound(
            params.secondWeight,  
            _MIN_WEIGHT,
            maxSecondWeight
        ));

        // Bound multiplier to safe range over interpolation time 
        // default multiplier is designed to traverse min-> max -> this is causing an underflow in calculateBlockNormalisedWeight
        // @audit to prevent this, we are  restricting multiplier to a safe range
        //@audit truncating to 32 bit to make it consistent with the unpacking logic in the contract
        variables.firstWeight.multiplier = truncateTo32Bit(bound(params.firstMultiplier, (_MIN_WEIGHT - variables.firstWeight.weight)/ int256(_INTERPOLATION_TIME), (_MAX_WEIGHT - variables.firstWeight.weight)/ int256(_INTERPOLATION_TIME)));

         // Same for second weight
        variables.secondWeight.multiplier = truncateTo32Bit(bound(params.secondMultiplier, (_MIN_WEIGHT - variables.secondWeight.weight)/ int256(_INTERPOLATION_TIME), (_MAX_WEIGHT - variables.secondWeight.weight)/ int256(_INTERPOLATION_TIME)));
  

        // @audit for other tokens, calculate safe range by using the residual weight
        int256 otherWeight = truncateTo32Bit((1e18 - variables.firstWeight.weight - variables.secondWeight.weight) / int256(_NUM_TOKENS - 2));        
        int256 otherMultiplier = variables.firstWeight.multiplier >  variables.secondWeight.multiplier ?  variables.secondWeight.multiplier: variables.firstWeight.multiplier;

        otherMultiplier = truncateTo32Bit(bound(otherMultiplier, (_MIN_WEIGHT - otherWeight) / int256(_INTERPOLATION_TIME), (_MAX_WEIGHT - otherWeight) / int256(_INTERPOLATION_TIME)));
        
        // store them in other weights as we need to use them later
        variables.otherWeights.weight = otherWeight;
        variables.otherWeights.multiplier = otherMultiplier;

        variables.newWeights = _getDefaultWeightAndMultiplierForRemainingTokens(variables.firstWeight, 
                                                                                   variables.secondWeight,
                                                                                   variables.otherWeights);
                
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

    function _getDefaultWeightAndMultiplierForRemainingTokens(
        TestParam memory firstWeightParam,
        TestParam memory secondWeightParam,
        TestParam memory otherWeightParams
    ) internal pure returns (int256[] memory weights) {
        weights = new int256[](uint256(_NUM_TOKENS * 2));
                
        // Set weights
        for(uint i = 0; i < uint256(_NUM_TOKENS); i++) {
            if(i == firstWeightParam.index) {
                weights[i] = firstWeightParam.weight;
            } else if(i == secondWeightParam.index) {
                weights[i] = secondWeightParam.weight;
            } else {
                weights[i] = otherWeightParams.weight;
            }
            // Set multipliers
            weights[i + uint256(_NUM_TOKENS)] = i == firstWeightParam.index ?  firstWeightParam.multiplier  : (i == secondWeightParam.index ?  
                secondWeightParam.multiplier : otherWeightParams.multiplier);
        }
    }

    function _calculateInterpolatedWeight(TestParam memory param, uint256 delay) internal pure returns (uint256) {
        if(param.multiplier > 0) {
            return uint256(param.weight) + FixedPoint.mulDown(uint256(param.multiplier), delay); 
        } else {
            return uint256(param.weight) - FixedPoint.mulUp(uint256(-param.multiplier), delay);
        }
    }    

    function truncateTo32Bit(int256 value) internal pure returns (int256) {
        return (value / 1e9) * 1e9;
    }    

    function _logFuzzParams(FuzzParams memory params) internal view {
        console.logString( string.concat("First Weight: ", vm.toString(params.firstWeight)));
        console.logString( string.concat("Second Weight: ", vm.toString(params.secondWeight)));        
        console.logString( string.concat("First Multiplier: ", vm.toString(params.firstMultiplier)));                
        console.logString( string.concat("Second Multiplier: ", vm.toString(params.secondMultiplier)));
        console.logString( string.concat("Other Multiplier: ", vm.toString(params.otherMultiplier)));                                                        
        console.log("Delay: ", params.delay);
    }

    //@audit except for delay, other fuzzing param bounds are configured in setVariables
    function testGetNormalizedWeightsInitial_Fuzz(FuzzParams memory params) public {
        params.delay =0; // forcing it to zero for this test       
        _testGetNormalizedWeights(params);
    }

    function testGetNormalizedWeightsNBlocksAfter_Fuzz(FuzzParams memory params) public {
        params.delay = bound(params.delay, 1, _INTERPOLATION_TIME);
        _logFuzzParams(params);                
        _testGetNormalizedWeights(params);
    }

    function testGetNormalizedWeightsAfterLimit_Fuzz(FuzzParams memory params) public {        
        params.delay = bound(params.delay, _INTERPOLATION_TIME + 1, type(uint40).max);
        _testGetNormalizedWeights(params);
    }

    function testGetDynamicDataWeightsInitial_Fuzz(FuzzParams memory params) public {
        params.delay = bound(params.delay, 0, 0); // forcing it to zero for this test        
        _testGetDynamicData(params);
    }

    function testGetDynamicDataWeightsNBlocksAfter_Fuzz(FuzzParams memory params) public {
       params.delay = bound(params.delay, 1, _INTERPOLATION_TIME);
       _testGetDynamicData(params);
    }

    function testGetDynamicDataWeightsAfterLimit_Fuzz(FuzzParams memory params) public {
        params.delay = bound(params.delay, _INTERPOLATION_TIME + 1, type(uint40).max);
        _testGetDynamicData(params);
    }
    //the other tests go through individual use cases, this makes sure no combo of weight in and out makes a difference
    function testBalancesInitial_Fuzz(FuzzParams memory params, BalanceFuzzParams memory balanceParams) public {
         params.delay = bound(params.delay, 0, 0); // forcing it to zero for this test      
        _testBalances(params, balanceParams);        
    }

    function testBalancesNBlocksAfter_Fuzz(FuzzParams memory params, BalanceFuzzParams memory balanceParams) public {
       params.delay = bound(params.delay, 1, _INTERPOLATION_TIME);
        _testBalances(params, balanceParams);        
    }

    function testBalancesAfterLimit_Fuzz(FuzzParams memory params, BalanceFuzzParams memory balanceParams) public {
        params.delay = bound(params.delay, _INTERPOLATION_TIME + 1, type(uint40).max);
        _testBalances(params, balanceParams);        
    }

    //the other tests go through individual use cases, this makes sure no combo of weight in and out makes a difference
    function testSwapExactInInitial_Fuzz(FuzzParams memory params, SwapFuzzParams memory swapParams) public {
       params.delay = bound(params.delay, 0, 0); // forcing it to zero for this test           
        _testSwapExactIn(params, swapParams);        
    }

    function testSwapExactInNBlocksAfter_Fuzz(FuzzParams memory params, SwapFuzzParams memory swapParams) public {
        params.delay = bound(params.delay, 1, _INTERPOLATION_TIME);        
        _testSwapExactIn(params, swapParams);
    }

    function testSwapExactInAfterLimit_Fuzz(FuzzParams memory params, SwapFuzzParams memory swapParams) public {
        params.delay = bound(params.delay, _INTERPOLATION_TIME + 1, type(uint40).max);
        _testSwapExactIn(params, swapParams);
    }

    //the other tests go through individual use cases, this makes sure no combo of weight in and out makes a difference
    function testSwapExactOutInitial_Fuzz(FuzzParams memory params, SwapFuzzParams memory swapParams) public {
        params.delay = bound(params.delay, 0, 0); // forcing it to zero for this test   
        _testSwapExactOut(params, swapParams);     
    }

    function testSwapExactOutNBlocksAfter_Fuzz(FuzzParams memory params, SwapFuzzParams memory swapParams) public {
        params.delay = bound(params.delay, 1, _INTERPOLATION_TIME);        
        _testSwapExactOut(params, swapParams);   
    }

    function testSwapExactOutAfterLimit_Fuzz(FuzzParams memory params, SwapFuzzParams memory swapParams) public {
        params.delay = bound(params.delay, _INTERPOLATION_TIME + 1, type(uint40).max);
        _testSwapExactOut(params, swapParams);   
    }


    function _testGetNormalizedWeights(FuzzParams memory params) internal {
        uint40 timestamp = uint40(block.timestamp);
        VariationTestVariables memory variables;
        variables.firstWeight = TestParam(0, _DEFAULT_WEIGHT, _DEFAULT_MULTIPLIER); 
        variables.secondWeight = TestParam(0, _DEFAULT_WEIGHT, _DEFAULT_MULTIPLIER); 
        variables.otherWeights = TestParam(0, _DEFAULT_WEIGHT, _DEFAULT_MULTIPLIER);

        // create pool params
        variables.params = _createPoolParams(_DEFAULT_WEIGHT, params.delay);

        address quantAMMWeightedPool = quantAMMWeightedPoolFactory.create(variables.params); //@note new pool params
        
        uint expectedDelay = params.delay;
        if(params.delay > _INTERPOLATION_TIME){
            expectedDelay = _INTERPOLATION_TIME;
        }
        for(uint i = 0 ; i < uint256(_NUM_TOKENS); i++){
            for(uint j = 0; j < uint256(_NUM_TOKENS); j++){
                if(i != j){
                    vm.warp(timestamp);
                    _setupVariables(variables, i, j, params);

                    vm.prank(address(updateWeightRunner));                    
                    QuantAMMWeightedPool(quantAMMWeightedPool).setWeights(
                        variables.newWeights,
                        quantAMMWeightedPool,
                        uint40(timestamp + _INTERPOLATION_TIME)
                    );
                    
                    if(params.delay > 0){
                        vm.warp(timestamp + params.delay);
                    }
                    
                    variables.testUint256 = QuantAMMWeightedPool(quantAMMWeightedPool).getNormalizedWeights();
                    
                    for(uint k = 0; k < uint256(_NUM_TOKENS); k++){
                        if(k == variables.firstWeight.index){
                            if(variables.firstWeight.multiplier > 0){
                                assertEq(variables.testUint256[k], uint256(variables.firstWeight.weight) + uint256(variables.firstWeight.multiplier)  * expectedDelay);
                            }
                            else{
                                assertEq(variables.testUint256[k], uint256(variables.firstWeight.weight) - uint256(-variables.firstWeight.multiplier)  * expectedDelay);
                            }
                        }
                        else if(k == variables.secondWeight.index){
                            if(variables.secondWeight.multiplier > 0){
                                assertEq(variables.testUint256[k], uint256(variables.secondWeight.weight) + uint256(variables.secondWeight.multiplier)* expectedDelay);
                            }
                            else{
                                assertEq(variables.testUint256[k], uint256(variables.secondWeight.weight) - uint256(-variables.secondWeight.multiplier) *  expectedDelay);
                            }
                        }
                        else{                        
                                if(variables.otherWeights.multiplier > 0){
                                    assertEq(variables.testUint256[k], uint256(variables.otherWeights.weight) + uint256(variables.otherWeights.multiplier)* expectedDelay);
                                }
                                else{
                                    assertEq(variables.testUint256[k], uint256(variables.otherWeights.weight) - uint256(-variables.otherWeights.multiplier)* expectedDelay);
                                }
                        }

 
                    }
                }
            }
        }
    }

    function _testGetDynamicData(FuzzParams memory params) internal {
        uint40 timestamp = uint40(block.timestamp);
        VariationTestVariables memory variables;
        variables.firstWeight = TestParam(0, _DEFAULT_WEIGHT, _DEFAULT_MULTIPLIER); 
        variables.secondWeight = TestParam(0, _DEFAULT_WEIGHT, _DEFAULT_MULTIPLIER); 
        variables.otherWeights = TestParam(0, _DEFAULT_WEIGHT, _DEFAULT_MULTIPLIER);

        variables.params = _createPoolParams(_DEFAULT_WEIGHT, params.delay);
        address quantAMMWeightedPool = quantAMMWeightedPoolFactory.create(variables.params);

        uint expectedDelay = params.delay;
        if(params.delay > _INTERPOLATION_TIME){
            expectedDelay = _INTERPOLATION_TIME;
        }
        for(uint i = 0 ; i < uint256(_NUM_TOKENS); i++){
            for(uint j = 0; j < uint256(_NUM_TOKENS); j++){
                if(i != j){
                    vm.warp(timestamp);
                    _setupVariables(variables, i, j, params);

                    vm.prank(address(updateWeightRunner));                    
                    QuantAMMWeightedPool(quantAMMWeightedPool).setWeights(
                        variables.newWeights,
                        quantAMMWeightedPool,
                        uint40(timestamp + _INTERPOLATION_TIME)
                    );

                    if(params.delay > 0){
                        vm.warp(timestamp + params.delay);
                    }
                    
                    variables.dynamicData = QuantAMMWeightedPool(quantAMMWeightedPool).getQuantAMMWeightedPoolDynamicData();

                    for(uint k = 0; k < uint256(_NUM_TOKENS); k++){
                        if(k == variables.firstWeight.index){
                            assertEq(variables.dynamicData.weightsAtLastUpdateInterval[variables.firstWeight.index], variables.firstWeight.weight);
                            assertEq(variables.dynamicData.weightBlockMultipliers[variables.firstWeight.index], variables.firstWeight.multiplier);
                        }
                        else if(k == variables.secondWeight.index){
                            assertEq(variables.dynamicData.weightsAtLastUpdateInterval[variables.secondWeight.index], variables.secondWeight.weight);
                            assertEq(variables.dynamicData.weightBlockMultipliers[variables.secondWeight.index], variables.secondWeight.multiplier);
                        }
                        else{
                            assertEq(variables.dynamicData.weightsAtLastUpdateInterval[k], variables.otherWeights.weight);
                            assertEq(variables.dynamicData.weightBlockMultipliers[k], variables.otherWeights.multiplier);
                        }

                    }

                    assertEq(variables.dynamicData.lastUpdateIntervalTime, uint40(timestamp));
                    assertEq(variables.dynamicData.lastInterpolationTimePossible, uint40(timestamp + _INTERPOLATION_TIME));
                }
            }
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    //@audit this test overflows - showing the problem with heavily imbalanced pools
    // fuzzer throws an overflow with following combo
    // console::log("Token Index:", 5)
    // console::log("Invariant Ratio:", 3000000000000000000 [3e18])
    // console::log("normalized weight:", 11666699000000000 [1.166e16])

    function _testBalances(FuzzParams memory params, BalanceFuzzParams memory balanceParams) internal {
        uint40 timestamp = uint40(block.timestamp);
        VariationTestVariables memory variables;
        variables.firstWeight = TestParam(0, _DEFAULT_WEIGHT, _DEFAULT_MULTIPLIER); 
        variables.secondWeight = TestParam(0, _DEFAULT_WEIGHT, _DEFAULT_MULTIPLIER); 
        variables.otherWeights = TestParam(0, _DEFAULT_WEIGHT, _DEFAULT_MULTIPLIER);


        balanceParams.tokenIndex = bound(balanceParams.tokenIndex, 0, uint256(_NUM_TOKENS) - 1);
        balanceParams.invariantRatio = bound(balanceParams.invariantRatio, _MIN_INVARIANT_RATIO, _MAX_INVARIANT_RATIO);
        
        variables.params = _createPoolParams(_DEFAULT_WEIGHT,  params.delay);
        address quantAMMWeightedPool = quantAMMWeightedPoolFactory.create(variables.params);

        uint expectedDelay = params.delay;
        if(params.delay > _INTERPOLATION_TIME){
            expectedDelay = _INTERPOLATION_TIME;
        }
        for(uint i = 0 ; i < uint256(_NUM_TOKENS); i++){
            for(uint j = 0; j < uint256(_NUM_TOKENS); j++){
                if(i != j){
                    vm.warp(timestamp);
                    _setupVariables(variables, i, j, params);
                    
                    vm.prank(address(updateWeightRunner));
                    QuantAMMWeightedPool(quantAMMWeightedPool).setWeights(
                        variables.newWeights,
                        quantAMMWeightedPool,
                        uint40(timestamp + _INTERPOLATION_TIME)
                    );

                    if(params.delay > 0){
                        vm.warp(timestamp + params.delay);
                    }

                    // @audit Calculate this instead of passing it as input
                    uint256 normalizedWeight = _calculateInterpolatedWeight(
                        balanceParams.tokenIndex == variables.firstWeight.index ? variables.firstWeight :
                        balanceParams.tokenIndex == variables.secondWeight.index ? variables.secondWeight :
                        variables.otherWeights,
                        expectedDelay
                    );                    

                    //Calculate expected balance using WeightedMath formula
                        uint256 expectedBalance = WeightedMath.computeBalanceOutGivenInvariant(
                            variables.balances[balanceParams.tokenIndex],
                            normalizedWeight,
                            balanceParams.invariantRatio
                        );

                        console.log("Token Index:", balanceParams.tokenIndex);
                        console.log("Invariant Ratio:", balanceParams.invariantRatio);
                        console.log("Balance:", variables.balances[balanceParams.tokenIndex]);

                    uint256 actualBalance = QuantAMMWeightedPool(quantAMMWeightedPool).computeBalance(
                        variables.balances,
                        balanceParams.tokenIndex,
                        balanceParams.invariantRatio
                    ); 
                    assertApproxEqRel(actualBalance, expectedBalance, 1e12); // Allow small relative error
                }
            }
        }
    }


    function _testSwapExactIn(FuzzParams memory params, SwapFuzzParams memory swapParams) internal {
        uint40 timestamp = uint40(block.timestamp);
        VariationTestVariables memory variables;
        variables.firstWeight = TestParam(0, _DEFAULT_WEIGHT, _DEFAULT_MULTIPLIER); 
        variables.secondWeight = TestParam(0, _DEFAULT_WEIGHT, _DEFAULT_MULTIPLIER); 
        variables.otherWeights = TestParam(0, _DEFAULT_WEIGHT, _DEFAULT_MULTIPLIER);

        variables.params = _createPoolParams(_DEFAULT_WEIGHT, params.delay);
        address quantAMMWeightedPool = quantAMMWeightedPoolFactory.create(variables.params);

        swapParams.exactOut = 0; // this is an exact in swap

        uint expectedDelay = params.delay;
        if(params.delay > _INTERPOLATION_TIME){
            expectedDelay = _INTERPOLATION_TIME;
        }
        for(uint i = 0 ; i < uint256(_NUM_TOKENS); i++){
            for(uint j = 0; j < uint256(_NUM_TOKENS); j++){
                if(i != j){
                    vm.warp(timestamp);
                    _setupVariables(variables, i, j, params);

                    vm.prank(address(updateWeightRunner));
                    QuantAMMWeightedPool(quantAMMWeightedPool).setWeights(
                        variables.newWeights,
                        quantAMMWeightedPool,
                        uint40(timestamp + _INTERPOLATION_TIME)
                    );
                    uint256 maxTradeSize = variables.balances[variables.firstWeight.index].mulDown(_min(_MAX_IN_RATIO, uint256(_MAX_TRADE_SIZE_RATIO)));
                    swapParams.exactIn = bound(swapParams.exactIn, 1, maxTradeSize); //@audit respecting WeightedMath constraint and max trade size constraint

                    if(params.delay > 0){
                        vm.warp(timestamp + params.delay);
                    }
                    
                    variables.swapParams = PoolSwapParams({
                        kind: SwapKind.EXACT_IN,
                        amountGivenScaled18: swapParams.exactIn,
                        balancesScaled18: variables.balances,
                        indexIn: variables.firstWeight.index,
                        indexOut: variables.secondWeight.index,
                        router: address(router),
                        userData: abi.encode(0)
                    });

                    vm.prank(address(vault));
                    uint256 amountOut = QuantAMMWeightedPool(quantAMMWeightedPool).onSwap(variables.swapParams);
                    
                    // get the pool weights
                     uint256[] memory poolWeights = QuantAMMWeightedPool(quantAMMWeightedPool).getNormalizedWeights();
                    
                    // For ExactIn:
                    uint256 expectedAmountOut = WeightedMath.computeOutGivenExactIn(
                        variables.balances[variables.firstWeight.index],
                        poolWeights[variables.firstWeight.index],
                        variables.balances[variables.secondWeight.index], 
                        poolWeights[variables.secondWeight.index],
                        swapParams.exactIn
                    );


                    assertApproxEqRel(amountOut, expectedAmountOut, 1e12); // Allow very small relative error 
                }
            }
        }
    }

    function _testSwapExactOut(FuzzParams memory params, SwapFuzzParams memory swapParams) internal {
        uint40 timestamp = uint40(block.timestamp);
        VariationTestVariables memory variables;
        variables.firstWeight = TestParam(0, _DEFAULT_WEIGHT, _DEFAULT_MULTIPLIER); 
        variables.secondWeight = TestParam(0, _DEFAULT_WEIGHT, _DEFAULT_MULTIPLIER); 
        variables.otherWeights = TestParam(0, _DEFAULT_WEIGHT, _DEFAULT_MULTIPLIER);


        variables.params = _createPoolParams(_DEFAULT_WEIGHT, params.delay);
        address quantAMMWeightedPool = quantAMMWeightedPoolFactory.create(variables.params);

        swapParams.exactIn = 0; // this is an exact out swap

        uint expectedDelay = params.delay;
        if(params.delay > _INTERPOLATION_TIME){
            expectedDelay = _INTERPOLATION_TIME;
        }

        for(uint i = 0 ; i < uint256(_NUM_TOKENS); i++){
            for(uint j = 0; j < uint256(_NUM_TOKENS); j++){
                if(i != j){
                    vm.warp(timestamp);
                    _setupVariables(variables, i, j, params);

                    vm.prank(address(updateWeightRunner));
                    QuantAMMWeightedPool(quantAMMWeightedPool).setWeights(
                        variables.newWeights,
                        quantAMMWeightedPool,
                        uint40(timestamp + _INTERPOLATION_TIME)
                    );

                    if(params.delay > 0){
                        vm.warp(timestamp + params.delay);
                    }
                    uint256 maxTradeSize = variables.balances[variables.secondWeight.index].mulDown(_min(_MAX_OUT_RATIO, uint256(_MAX_TRADE_SIZE_RATIO)));
                    swapParams.exactOut = bound(swapParams.exactOut, 1, maxTradeSize);

                    variables.swapParams = PoolSwapParams({
                        kind: SwapKind.EXACT_OUT,
                        amountGivenScaled18: swapParams.exactOut,
                        balancesScaled18: variables.balances,
                        indexIn: variables.firstWeight.index,
                        indexOut: variables.secondWeight.index,
                        router: address(router),
                        userData: abi.encode(0)
                    });
                    vm.prank(address(vault));
                    uint256 amountIn = QuantAMMWeightedPool(quantAMMWeightedPool).onSwap(variables.swapParams);

                     uint256[] memory poolWeights = QuantAMMWeightedPool(quantAMMWeightedPool).getNormalizedWeights();

                    // For ExactOut: 
                    uint256 expectedAmountIn = WeightedMath.computeInGivenExactOut(
                        variables.balances[variables.firstWeight.index],
                        poolWeights[variables.firstWeight.index],
                        variables.balances[variables.secondWeight.index],  
                        poolWeights[variables.secondWeight.index],
                        swapParams.exactOut);

                     assertApproxEqRel(amountIn, expectedAmountIn, 1e12);
                }
            }
        }
    }


}