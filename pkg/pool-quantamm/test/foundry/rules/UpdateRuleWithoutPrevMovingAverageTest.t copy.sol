// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import "../../../contracts/mock/mockRules/MockUpdateRule.sol";
import "../../../contracts/mock/mockRules/MockPrevAverageRule.sol";
import "../../../contracts/mock/MockPool.sol";
import "../utils.t.sol";

contract WithoutPrevMovingAverageUpdateRuleTest is Test, QuantAMMTestUtils {
    address internal owner;
    address internal addr1;
    address internal addr2;

    MockPool public mockPool;
    MockUpdateRule updateRule;
    MockPrevAverageUpdateRule prevAverageUpdateRule;

    function setUp() public {
        (address ownerLocal, address addr1Local, address addr2Local) = (vm.addr(1), vm.addr(2), vm.addr(3));
        owner = ownerLocal;
        addr1 = addr1Local;
        addr2 = addr2Local;
        updateRule = new MockUpdateRule(owner);      
        prevAverageUpdateRule = new MockPrevAverageUpdateRule(owner);  
    }

    function testUpdateRuleUnAuthCalc() public {
        vm.expectRevert("UNAUTH_CALC");
        updateRule.CalculateNewWeights(
        new int256[](0),
        new int256[](0),
        address(mockPool),
        new int256[][](0),
        new uint64[](0),
        uint64(1),
        uint64(1));
    }

    function testUpdateRuleAuthCalc() public {
        vm.startPrank(owner);
         // Define local variables for the parameters
        int256[][] memory parameters = new int256[][](2);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(1);

        int256[] memory previousAlphas = new int256[](2);
        previousAlphas[0] = PRBMathSD59x18.fromInt(1);
        previousAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(0);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(0);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = 0.9e18;
        movingAverages[1] = PRBMathSD59x18.fromInt(1) + 0.2e18;

        uint64[] memory lambdas = new uint64[](1);
        lambdas[0] = uint64(0.7e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(3);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256 epsilonMax = 0.1e18;

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.49775e18;
        expectedResults[1] = 0.50225e18;
        updateRule.setWeights(expectedResults);
        
        updateRule.initialisePoolRuleIntermediateValues(
            address(mockPool),
            prevMovingAverages,
            previousAlphas,
            2
        );

        //does not revert
        updateRule.CalculateNewWeights(
        prevWeights,
        data,
        address(mockPool),
        parameters,
        lambdas,
        uint64(uint256(epsilonMax)),
        uint64(0.2e18));

        vm.stopPrank();
    }

    function testUpdateRuleMovingAverageStorage() public {
        vm.startPrank(owner);
         // Define local variables for the parameters
        int256[][] memory parameters = new int256[][](2);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(1);

        int256[] memory previousAlphas = new int256[](2);
        previousAlphas[0] = PRBMathSD59x18.fromInt(1);
        previousAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(0);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(0);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = 0.9e18;
        movingAverages[1] = PRBMathSD59x18.fromInt(1) + 0.2e18;

        uint64[] memory lambdas = new uint64[](1);
        lambdas[0] = uint64(0.7e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(3);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256 epsilonMax = 0.1e18;

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.49775e18;
        expectedResults[1] = 0.50225e18;
        updateRule.setWeights(expectedResults);
        
        updateRule.initialisePoolRuleIntermediateValues(
            address(mockPool),
            prevMovingAverages,
            previousAlphas,
            2
        );

        //does not revert
        updateRule.CalculateNewWeights(
        prevWeights,
        data,
        address(mockPool),
        parameters,
        lambdas,
        uint64(uint256(epsilonMax)),
        uint64(0.2e18));

        int256[] memory savedMovAverages = updateRule.GetMovingAverages(address(mockPool), 2);

        checkResult(movingAverages, savedMovAverages);

        vm.stopPrank();
    }

    function testFuzz_UpdateRuleMovingAverageStorage(uint unboundNumAssets, bool requiresPrevMovingAverage) public {
        IUpdateRule targetRule = requiresPrevMovingAverage ? IUpdateRule(prevAverageUpdateRule) : IUpdateRule(updateRule);
        uint numAssets = bound(unboundNumAssets, 2, 8);
        vm.startPrank(owner);
        uint numMovingAverages = requiresPrevMovingAverage ? numAssets * 2 : numAssets;

        int256 one = PRBMathSD59x18.fromInt(1);

         // Define local variables for the parameters
        int256[][] memory parameters = new int256[][](2);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(1);

        int256[] memory previousAlphas = new int256[](numAssets);
        for(uint i = 0; i < numAssets; i++) {
            previousAlphas[i] = PRBMathSD59x18.fromInt(int256(i)) + one;
        }

        int256[] memory movingAverages = new int256[](numMovingAverages);
        for(uint i = 0; i < numMovingAverages; i++) {
            movingAverages[i] = PRBMathSD59x18.fromInt(int256(i)) + one;
        }

        uint64[] memory lambdas = new uint64[](1);
        lambdas[0] = uint64(0.7e18);

        int256[] memory prevWeights = new int256[](numAssets);
        for(uint i = 0; i < numAssets; i++) {
            prevWeights[i] = PRBMathSD59x18.fromInt(1) / int256(numAssets);
        }

        int256[] memory data = new int256[](numAssets);
        for(uint i = 0; i < numAssets; i++) {
            data[i] = PRBMathSD59x18.fromInt(int256(i)) + one;
        }

        if(requiresPrevMovingAverage) {
            MockPrevAverageUpdateRule(address(targetRule)).setWeights(prevWeights);
        }
        else{
            MockUpdateRule(address(targetRule)).setWeights(prevWeights);
        }
        
        targetRule.initialisePoolRuleIntermediateValues(
            address(mockPool),
            movingAverages,
            previousAlphas,
            numAssets
        );

        int256[] memory savedMovAverages;
        if(requiresPrevMovingAverage) {
            savedMovAverages = MockPrevAverageUpdateRule(address(targetRule)).GetMovingAverages(address(mockPool), numMovingAverages);
        }
        else{
            savedMovAverages = MockUpdateRule(address(targetRule)).GetMovingAverages(address(mockPool), numMovingAverages);
        }

        checkResult(movingAverages, savedMovAverages);
        
        for(uint i = 0; i < numMovingAverages; i++) {
            movingAverages[i] = movingAverages[i] + one;
        }

        //break glass set again after initialisation
        targetRule.initialisePoolRuleIntermediateValues(
            address(mockPool),
            movingAverages,
            previousAlphas,
            numAssets
        );

        if(requiresPrevMovingAverage) {
            savedMovAverages = MockPrevAverageUpdateRule(address(targetRule)).GetMovingAverages(address(mockPool), numMovingAverages);
        }
        else{
            savedMovAverages = MockUpdateRule(address(targetRule)).GetMovingAverages(address(mockPool), numMovingAverages);
        }

        checkResult(movingAverages, savedMovAverages);
        
        vm.stopPrank();
    }
    
    function testUpdateRuleGuardClampWeights() public {
        vm.startPrank(owner);
         // Define local variables for the parameters
        int256[][] memory parameters = new int256[][](2);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(1);

        int256[] memory previousAlphas = new int256[](2);
        previousAlphas[0] = PRBMathSD59x18.fromInt(1);
        previousAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(0);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(0);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = 0.9e18;
        movingAverages[1] = PRBMathSD59x18.fromInt(1) + 0.2e18;

        uint64[] memory lambdas = new uint64[](1);
        lambdas[0] = uint64(0.7e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(3);
        data[1] = PRBMathSD59x18.fromInt(4);


        int256[] memory calculatedWeights = new int256[](2);
        calculatedWeights[0] = 0.95e18;
        calculatedWeights[1] = 0.05e18;
        updateRule.setWeights(calculatedWeights);
        
        updateRule.initialisePoolRuleIntermediateValues(
            address(mockPool),
            prevMovingAverages,
            previousAlphas,
            2
        );

        //does not revert
        int256[] memory expectedClampWeights = updateRule.CalculateNewWeights(
        prevWeights,
        data,
        address(mockPool),
        parameters,
        lambdas,
        uint64(0.1e18),
        uint64(0.1e18));

        int256[] memory expectedWeights = new int256[](2);
        expectedWeights[0] = 0.6e18;
        expectedWeights[1] = 0.4e18;

        checkResult(expectedWeights, expectedClampWeights);

        vm.stopPrank();
    }

    function testUpdateRuleInitialisePoolPoolAuth() public {
        vm.startPrank(owner);
         // Define local variables for the parameters
        int256[][] memory parameters = new int256[][](2);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(1);

        int256[] memory previousAlphas = new int256[](2);
        previousAlphas[0] = PRBMathSD59x18.fromInt(1);
        previousAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(0);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(0);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = 0.9e18;
        movingAverages[1] = PRBMathSD59x18.fromInt(1) + 0.2e18;

        uint64[] memory lambdas = new uint64[](1);
        lambdas[0] = uint64(0.7e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(3);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.49775e18;
        expectedResults[1] = 0.50225e18;
        updateRule.setWeights(expectedResults);
        vm.stopPrank();

        vm.startPrank(address(mockPool));

        updateRule.initialisePoolRuleIntermediateValues(
            address(mockPool),
            prevMovingAverages,
            previousAlphas,
            2
        );

        vm.stopPrank();
    }

    function testUpdateRuleInitialisePoolUpdateWeightRunnerAuth() public {
        vm.startPrank(owner);
         // Define local variables for the parameters
        int256[][] memory parameters = new int256[][](2);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(1);

        int256[] memory previousAlphas = new int256[](2);
        previousAlphas[0] = PRBMathSD59x18.fromInt(1);
        previousAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(0);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(0);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = 0.9e18;
        movingAverages[1] = PRBMathSD59x18.fromInt(1) + 0.2e18;

        uint64[] memory lambdas = new uint64[](1);
        lambdas[0] = uint64(0.7e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(3);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.49775e18;
        expectedResults[1] = 0.50225e18;
        updateRule.setWeights(expectedResults);

        //does not revert
        updateRule.initialisePoolRuleIntermediateValues(
            address(mockPool),
            prevMovingAverages,
            previousAlphas,
            2
        );
        
        vm.stopPrank();
    }

    function testUpdateRuleInitialisePoolRandomNotAuth() public {
        vm.startPrank(owner);
         // Define local variables for the parameters
        int256[][] memory parameters = new int256[][](2);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(1);

        int256[] memory previousAlphas = new int256[](2);
        previousAlphas[0] = PRBMathSD59x18.fromInt(1);
        previousAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(0);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(0);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = 0.9e18;
        movingAverages[1] = PRBMathSD59x18.fromInt(1) + 0.2e18;

        uint64[] memory lambdas = new uint64[](1);
        lambdas[0] = uint64(0.7e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(3);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.49775e18;
        expectedResults[1] = 0.50225e18;
        updateRule.setWeights(expectedResults);

        vm.stopPrank();

        vm.startPrank(addr2);

        vm.expectRevert();
        updateRule.initialisePoolRuleIntermediateValues(
            address(mockPool),
            prevMovingAverages,
            previousAlphas,
            2
        );
        
        vm.stopPrank();
    }

    function testMultipleUpdateWithoutPrevMovingAverage() public {

        vm.startPrank(owner);
        // Define local variables for the parameters
        int256[][] memory parameters = new int256[][](2);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(1);

        int256[] memory previousAlphas = new int256[](2);
        previousAlphas[0] = PRBMathSD59x18.fromInt(1);
        previousAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(0);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(0);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = 0.9e18;
        movingAverages[1] = PRBMathSD59x18.fromInt(1) + 0.2e18;

        uint64[] memory lambdas = new uint64[](2);
        lambdas[0] = uint64(0.7e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(3);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256 epsilonMax = 0.1e18;

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.49775e18;
        expectedResults[1] = 0.50225e18;
        updateRule.setWeights(expectedResults);

        updateRule.initialisePoolRuleIntermediateValues(address(mockPool), prevMovingAverages, previousAlphas, 2);

        updateRule.CalculateNewWeights(
            prevWeights,
            data,
            address(mockPool),
            parameters,
            lambdas,
            uint64(uint256(epsilonMax)),
            uint64(0.2e18)
        );
        
        updateRule.CalculateNewWeights(
            prevWeights,
            data,
            address(mockPool),
            parameters,
            lambdas,
            uint64(uint256(epsilonMax)),
            uint64(0.2e18)
        );

        vm.stopPrank();
    }
}