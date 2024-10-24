// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import "../../../contracts/mock/MockRuleInvoker.sol";
import "../../../contracts/mock/mockRules/MockAntiMomentumRule.sol";
import "../../../contracts/mock/MockPool.sol";
import "../utils.t.sol";

contract AntiMomentumRuleTest is Test, QuantAMMTestUtils {
    MockAntiMomentumRule public rule;
    MockPool public mockPool;

    function setUp() public {
        // Deploying MockMomentumRule contract
        rule = new MockAntiMomentumRule(address(this));

        // Deploy MockPool contract with some mock parameters
        mockPool = new MockPool(3600, 1 ether, address(rule));
    }

    function runInitialUpdate(
        uint256 numAssets,
        int256[][] memory parameters,
        int256[] memory previousAlphas,
        int256[] memory prevMovingAverages,
        int256[] memory movingAverages,
        int128[] memory lambdas,
        int256[] memory prevWeights,
        int256[] memory data,
        int256[] memory results
    ) internal {
        // Simulate setting number of assets and calculating intermediate values
        mockPool.setNumberOfAssets(numAssets);
        rule.initialisePoolRuleIntermediateValues(
            address(mockPool),
            prevMovingAverages,
            previousAlphas,
            numAssets
        );

        // Run calculation for unguarded weights
        rule.CalculateUnguardedWeights(
            prevWeights,
            data,
            address(mockPool),
            parameters,
            lambdas,
            movingAverages
        );

        // Check results against expected weights
        int256[] memory res = rule.GetResultWeights();
        checkResult(res, results);
    }

    function testAntiMomentumRuleNoninitialisedParametersShouldNotBeAccepted() public view {
        int256[][] memory parameters;
        bool result = rule.validParameters(parameters); 
        assertFalse(result);
    }

    function testAntiMomentumRuleEmptyParametersShouldNotBeAccepted() public view {
        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](1);
        bool result = rule.validParameters(parameters);
        assertFalse(result);
    }

    function testAntiMomentumRuleTestEmpty1DParametersShouldNotBeAccepted() public view {
        int256[][] memory parameters = new int256[][](1);
        bool result = rule.validParameters(parameters);
        assertFalse(result);
    }

    function testAntiMomentumRuleTestZeroShouldBeAccepted() public view {
        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(0);
        bool result = rule.validParameters(parameters);
        assertFalse(result);
    }

    function testAntiMomentumRuleTestPositiveNumberShouldBeAccepted() public view {
        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(42);
        bool result = rule.validParameters(parameters);
        assertTrue(result);
    }

    function testAntiMomentumRuleTestNegativeNumberShouldNotBeAccepted() public view {
        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](1);
        parameters[0][0] = -PRBMathSD59x18.fromInt(1);
        bool result = rule.validParameters(parameters);
        assertFalse(result);
    }
    
    function testAntiMomentumRuleVectorParamTestZeroShouldBeAccepted() public view {
        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](2);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);
        parameters[0][1] = PRBMathSD59x18.fromInt(0);
        bool result = rule.validParameters(parameters);
        assertFalse(result);
    }

    function testAntiMomentumRuleVectorParamTestPositiveNumberShouldBeAccepted() public view {
        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](2);
        parameters[0][0] = PRBMathSD59x18.fromInt(42);
        parameters[0][1] = PRBMathSD59x18.fromInt(42);
        bool result = rule.validParameters(parameters);
        assertTrue(result);
    }

    function testAntiMomentumRuleVectorParamTestNegativeNumberShouldNotBeAccepted() public view {
        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](2);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);
        parameters[0][1] = -PRBMathSD59x18.fromInt(1);
        bool result = rule.validParameters(parameters);
        assertFalse(result);
    }

    function testAntiMomentumRuleTestCorrectUpdateWithHigherPrices() public {
        /*
            ℓp(t)	0.10125	
            moving average	[0.9, 1.2]
            alpha	[7.7, 10.73333333]
            beta	[0.297,	0.414]
            new weight	[0.49775, 0.4925]
        */

        // Define local variables for the parameters
        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);

        int256[] memory previousAlphas = new int256[](2);
        previousAlphas[0] = PRBMathSD59x18.fromInt(1);
        previousAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(0);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(0);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = 0.9e18;
        movingAverages[1] = PRBMathSD59x18.fromInt(1) + 0.2e18;

        int128[] memory lambdas = new int128[](1);
        lambdas[0] = int128(0.7e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(3);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.507499999999999999e18;
        expectedResults[1] = 0.4925e18;

        // Now pass the variables into the runInitialUpdate function
        runInitialUpdate(
            2,                // numAssets
            parameters,
            previousAlphas,
            prevMovingAverages,
            movingAverages,
            lambdas,
            prevWeights,
            data,
            expectedResults
        );
    }

    function testAntiMomentumRuleTestCorrectUpdateWithLowerPrices() public {
        /*
            moving average	2.7	4
            alpha	-1.633333333	1.4
            beta	-0.063	0.054
            new weight	0.4775	0.5225
        */

        // Define local variables for the parameters
        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);

        int256[] memory previousAlphas = new int256[](2);
        previousAlphas[0] = PRBMathSD59x18.fromInt(1);
        previousAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(3);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = PRBMathSD59x18.fromInt(2) + 0.7e18;
        movingAverages[1] = PRBMathSD59x18.fromInt(4);

        int128[] memory lambdas = new int128[](1);
        lambdas[0] = int128(0.7e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(2);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 518416666666666667;
        expectedResults[1] = 0.481583333333333334e18;
        
        // Now pass the variables into the runInitialUpdate function
        runInitialUpdate(
            2,                // numAssets
            parameters,
            previousAlphas,
            prevMovingAverages,
            movingAverages,
            lambdas,
            prevWeights,
            data,
            expectedResults
        );
    }

    function testAntiMomentumRuleTestCorrectUpdateWithHigherPrices_VectorParams() public {
    // Define local variables for the parameters
        int256[][] memory parameters  = new int256[][](2);
        parameters[0] = new int256[](2);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);
        parameters[0][1] = PRBMathSD59x18.fromInt(1) + 0.5e18;
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(1);

        int256[] memory previousAlphas = new int256[](2);
        previousAlphas[0] = PRBMathSD59x18.fromInt(1);
        previousAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(3);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = PRBMathSD59x18.fromInt(3);
        movingAverages[1] = PRBMathSD59x18.fromInt(4);

        int128[] memory lambdas = new int128[](2);
        lambdas[0] = int128(0.7e18);
        lambdas[1] = int128(0.7e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(3);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.491e18;
        expectedResults[1] = 0.47975e18;

        // Now pass the variables into the runInitialUpdate function
        runInitialUpdate(
            2,                // numAssets
            parameters,
            previousAlphas,
            prevMovingAverages,
            movingAverages,
            lambdas,
            prevWeights,
            data,
            expectedResults
        );
    }

function testAntiMomentumRuleTestCorrectUpdateWithLowerPrices_VectorParams() public {
    // Define local variables for the parameters
        
        int256[][] memory parameters  = new int256[][](2);
        parameters[0] = new int256[](2);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);
        parameters[0][1] = PRBMathSD59x18.fromInt(1) + 0.5e18;
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(1);

        int256[] memory previousAlphas = new int256[](2);
        previousAlphas[0] = PRBMathSD59x18.fromInt(1);
        previousAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(3);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = PRBMathSD59x18.fromInt(2) + 0.7e18;
        movingAverages[1] = PRBMathSD59x18.fromInt(4);

        int128[] memory lambdas = new int128[](2);
        lambdas[0] = int128(0.7e18);
        lambdas[1] = int128(0.7e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(2);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.5315e18;
        expectedResults[1] = 0.47975e18;

        // Now pass the variables into the runInitialUpdate function
        runInitialUpdate(
            2,                // numAssets
            parameters,
            previousAlphas,
            prevMovingAverages,
            movingAverages,
            lambdas,
            prevWeights,
            data,
            expectedResults
        );
    }


    function testAntiMomentumRuleTestCorrectUpdateWithHigherPricesAverageDenominator() public {
        /*
            ℓp(t)	0.10125	
            moving average	[0.9, 1.2]
            alpha	[7.7, 10.73333333]
            beta	[0.297,	0.414]
            new weight	[0.49775, 0.4925]
        */

        // Define local variables for the parameters
        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);

        int256[] memory previousAlphas = new int256[](2);
        previousAlphas[0] = PRBMathSD59x18.fromInt(1);
        previousAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(0);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(0);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = 0.9e18;
        movingAverages[1] = PRBMathSD59x18.fromInt(1) + 0.2e18;

        int128[] memory lambdas = new int128[](1);
        lambdas[0] = int128(0.7e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(3);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.507499999999999999e18;
        expectedResults[1] = 0.4925e18;

        // Now pass the variables into the runInitialUpdate function
        runInitialUpdate(
            2,                // numAssets
            parameters,
            previousAlphas,
            prevMovingAverages,
            movingAverages,
            lambdas,
            prevWeights,
            data,
            expectedResults
        );
    }

    function testAntiMomentumRuleTestCorrectUpdateWithLowerPricesAverageDenominator() public {
        /*
            moving average	2.7	4
            alpha	-1.633333333	1.4
            beta	-0.063	0.054
            new weight	0.4775	0.5225
        */

        // Define local variables for the parameters
        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);

        int256[] memory previousAlphas = new int256[](2);
        previousAlphas[0] = PRBMathSD59x18.fromInt(1);
        previousAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(3);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = PRBMathSD59x18.fromInt(2) + 0.7e18;
        movingAverages[1] = PRBMathSD59x18.fromInt(4);

        int128[] memory lambdas = new int128[](1);
        lambdas[0] = int128(0.7e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(2);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.518416666666666667e18;
        expectedResults[1] = 0.481583333333333334e18;
        
        // Now pass the variables into the runInitialUpdate function
        runInitialUpdate(
            2,                // numAssets
            parameters,
            previousAlphas,
            prevMovingAverages,
            movingAverages,
            lambdas,
            prevWeights,
            data,
            expectedResults
        );
    }

    function testAntiMomentumRuleTestCorrectUpdateWithHigherPricesAverageDenominator_VectorParams() public {
    // Define local variables for the parameters
        int256[][] memory parameters  = new int256[][](1);
        parameters[0] = new int256[](2);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);
        parameters[0][1] = PRBMathSD59x18.fromInt(1) + 0.5e18;

        int256[] memory previousAlphas = new int256[](2);
        previousAlphas[0] = PRBMathSD59x18.fromInt(1);
        previousAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(3);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = PRBMathSD59x18.fromInt(3);
        movingAverages[1] = PRBMathSD59x18.fromInt(4);

        int128[] memory lambdas = new int128[](2);
        lambdas[0] = int128(0.7e18);
        lambdas[1] = int128(0.7e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(3);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.491e18;
        expectedResults[1] = 0.47975e18;

        // Now pass the variables into the runInitialUpdate function
        runInitialUpdate(
            2,                // numAssets
            parameters,
            previousAlphas,
            prevMovingAverages,
            movingAverages,
            lambdas,
            prevWeights,
            data,
            expectedResults
        );
    }

function testAntiMomentumRuleTestCorrectUpdateWithLowerPricesAverageDenominator_VectorParams() public {
    // Define local variables for the parameters
        
        int256[][] memory parameters  = new int256[][](1);
        parameters[0] = new int256[](2);
        parameters[0][0] = PRBMathSD59x18.fromInt(1);
        parameters[0][1] = PRBMathSD59x18.fromInt(1) + 0.5e18;

        int256[] memory previousAlphas = new int256[](2);
        previousAlphas[0] = PRBMathSD59x18.fromInt(1);
        previousAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(3);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = PRBMathSD59x18.fromInt(2) + 0.7e18;
        movingAverages[1] = PRBMathSD59x18.fromInt(4);

        int128[] memory lambdas = new int128[](2);
        lambdas[0] = int128(0.7e18);
        lambdas[1] = int128(0.7e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18;
        prevWeights[1] = 0.5e18;

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(2);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.523333333333333333e18;
        expectedResults[1] = 0.47975e18;

        // Now pass the variables into the runInitialUpdate function
        runInitialUpdate(
            2,                // numAssets
            parameters,
            previousAlphas,
            prevMovingAverages,
            movingAverages,
            lambdas,
            prevWeights,
            data,
            expectedResults
        );
    }
}