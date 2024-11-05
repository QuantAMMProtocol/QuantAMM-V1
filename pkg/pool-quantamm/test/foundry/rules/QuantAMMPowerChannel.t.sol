// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import "../../../contracts/mock/MockRuleInvoker.sol";
import "../../../contracts/mock/mockRules/MockPowerChannelRule.sol";
import "../../../contracts/mock/MockPool.sol";
import "../utils.t.sol";

contract PowerChannelUpdateRuleTest is Test, QuantAMMTestUtils {
    MockPowerChannelRule rule;
    MockPool mockPool;

    function setUp() public {
        // Deploy Power Channel Rule contract
        rule = new MockPowerChannelRule(address(this));

        // Deploy Mock Pool contract
        mockPool = new MockPool(3600, PRBMathSD59x18.fromInt(1), address(rule));
    }

    function testPowerChannelEmptyParametersShouldNotBeAccepted() public view {
        int256[][] memory emptyParams;
        bool valid = rule.validParameters(emptyParams); // Passing empty parameters
        assertFalse(valid);
    }

    function testPowerChannelKappaZeroQGreaterThanOneShouldNotBeAccepted() public view {
        int256[][] memory parameters = new int256[][](2);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(0); // kappa = 1
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(2); // q > 1

        bool valid = rule.validParameters(parameters);
        assertFalse(valid);
    }

    function testFuzz_PowerChannelKappaZeroQGreaterThanOneShouldNotBeAccepted(int256 q) public view {
        int256[][] memory parameters = new int256[][](2);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(0); // kappa = 1
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(bound(q, 1, maxScaledFixedPoint18())); // q > 1

        bool valid = rule.validParameters(parameters);
        assertFalse(valid);
    }

    function testPowerChannelKappaGreaterThanZeroQGreaterThanOneShouldBeAccepted() public view {
        int256[][] memory parameters = new int256[][](2);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(1); // kappa > 0
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(2); // q > 1

        bool valid = rule.validParameters(parameters);
        assertTrue(valid);
    }

    function testPowerChannelKappaGreaterThanZeroQEqualToOneShouldNotBeAccepted() public view {
        int256[][] memory parameters = new int256[][](2);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(1); // kappa > 0
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(1); // q = 1

        bool valid = rule.validParameters(parameters);
        assertFalse(valid);
    }

    function testFuzz_PowerChannelKappaGreaterThanZeroQEqualToOneShouldNotBeAccepted(int256 kappa) public view {
        int256[][] memory parameters = new int256[][](2);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(bound(kappa, 1, maxScaledFixedPoint18())); // kappa > 0
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(1); // q = 1

        bool valid = rule.validParameters(parameters);
        assertFalse(valid);
    }

    function testPowerChannelKappaLessThanZeroQGreaterThanOneShouldNotBeAccepted() public view {
        int256[][] memory parameters = new int256[][](2);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(-1); // kappa < 0
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(2); // q > 1

        bool valid = rule.validParameters(parameters);
        assertFalse(valid);
    }

    function testFuzz_PowerChannelKappaLessThanZeroQGreaterThanOneShouldNotBeAccepted(
        int256 kappa,
        int256 q
    ) public view {
        int256[][] memory parameters = new int256[][](2);
        parameters[0] = new int256[](1);
        parameters[0][0] = -PRBMathSD59x18.fromInt(bound(kappa, 1, maxScaledFixedPoint18())); // kappa < 0
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(bound(q, 1, maxScaledFixedPoint18())); // q > 1

        bool valid = rule.validParameters(parameters);
        assertFalse(valid);
    }

    function testPowerChannelCorrectWeightsWithHigherPrices() public {
        int256[][] memory parameters = new int256[][](3);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(2048); // Parameter 1
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(3); // Parameter 2
        parameters[2] = new int256[](1);
        parameters[2][0] = PRBMathSD59x18.fromInt(1); // Parameter 3

        int256[] memory prevAlphas = new int256[](2);
        prevAlphas[0] = PRBMathSD59x18.fromInt(1);
        prevAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(3);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = PRBMathSD59x18.fromInt(3);
        movingAverages[1] = PRBMathSD59x18.fromInt(4);

        // Lambda initialization
        int128[] memory lambdas = new int128[](1);
        lambdas[0] = int128(0.9e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18; // Weight 1
        prevWeights[1] = 0.5e18; // Weight 2

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(3);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.499999909925926912e18;
        expectedResults[1] = 0.500000090074075136e18;

        mockPool.setNumberOfAssets(2);

        rule.initialisePoolRuleIntermediateValues(
            address(mockPool),
            prevMovingAverages,
            prevAlphas,
            mockPool.numAssets()
        );

        rule.CalculateUnguardedWeights(prevWeights, data, address(mockPool), parameters, lambdas, movingAverages);

        int256[] memory resultWeights = rule.GetResultWeights();

        checkResult(resultWeights, expectedResults);
    }
    // Function that tests correct weights with lower prices
    function testPowerChannelCorrectWeightsWithLowerPrices() public {
        int256[][] memory parameters = new int256[][](3);
        parameters[0] = new int256[](1);
        parameters[0][0] = PRBMathSD59x18.fromInt(2048); // Parameter 1
        parameters[1] = new int256[](1);
        parameters[1][0] = PRBMathSD59x18.fromInt(3); // Parameter 2
        parameters[2] = new int256[](1);
        parameters[2][0] = PRBMathSD59x18.fromInt(1); // Parameter 3

        // Alpha and moving averages initialization
        int256[] memory prevAlphas = new int256[](2);
        prevAlphas[0] = PRBMathSD59x18.fromInt(1);
        prevAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(3);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = PRBMathSD59x18.fromInt(3);
        movingAverages[1] = PRBMathSD59x18.fromInt(4);

        // Lambda initialization
        int128[] memory lambdas = new int128[](1);
        lambdas[0] = int128(0.9e18);

        // Weights initialization
        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18; // Weight 1
        prevWeights[1] = 0.5e18; // Weight 2

        // Data (new prices) initialization
        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(2); // New price 1
        data[1] = PRBMathSD59x18.fromInt(4); // New price 2

        // Expected result weights
        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.499867557750343680e18;
        expectedResults[1] = 0.500132442249656320e18;

        mockPool.setNumberOfAssets(2);

        // Call the rule function and get the result
        rule.initialisePoolRuleIntermediateValues(
            address(mockPool),
            prevMovingAverages,
            prevAlphas,
            mockPool.numAssets()
        );

        rule.CalculateUnguardedWeights(prevWeights, data, address(mockPool), parameters, lambdas, movingAverages);

        // Get the updated weights
        int256[] memory resultWeights = rule.GetResultWeights();

        checkResult(resultWeights, expectedResults);
    }

    function testPowerChannelCorrectWeightsWithVectorParamsHigherPrices() public {
        int256[][] memory parameters = new int256[][](3);
        parameters[0] = new int256[](2);
        parameters[0][0] = PRBMathSD59x18.fromInt(2048); // Parameter 1
        parameters[0][1] = PRBMathSD59x18.fromInt(32768); // Parameter 1
        parameters[1] = new int256[](2);
        parameters[1][0] = PRBMathSD59x18.fromInt(3); // Parameter 2
        parameters[1][1] = PRBMathSD59x18.fromInt(3); // Parameter 2
        parameters[2] = new int256[](2);
        parameters[2][0] = PRBMathSD59x18.fromInt(1); // Parameter 3
        parameters[2][1] = PRBMathSD59x18.fromInt(1); // Parameter 3

        int256[] memory prevAlphas = new int256[](2);
        prevAlphas[0] = PRBMathSD59x18.fromInt(1);
        prevAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(3);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = PRBMathSD59x18.fromInt(3);
        movingAverages[1] = PRBMathSD59x18.fromInt(4);

        // Lambda initialization
        int128[] memory lambdas = new int128[](1);
        lambdas[0] = int128(0.9e18);

        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18; // Weight 1
        prevWeights[1] = 0.5e18; // Weight 2

        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(3);
        data[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.500000075851851776e18;
        expectedResults[1] = 0.500004096000000000e18;

        mockPool.setNumberOfAssets(2);

        rule.initialisePoolRuleIntermediateValues(
            address(mockPool),
            prevMovingAverages,
            prevAlphas,
            mockPool.numAssets()
        );

        rule.CalculateUnguardedWeights(prevWeights, data, address(mockPool), parameters, lambdas, movingAverages);

        int256[] memory resultWeights = rule.GetResultWeights();

        checkResult(resultWeights, expectedResults);
    }
    // Function that tests correct weights with lower prices
    function testPowerChannelCorrectWeightsWithVectorParamsLowerPrices() public {
        int256[][] memory parameters = new int256[][](3);
        parameters[0] = new int256[](2);
        parameters[0][0] = PRBMathSD59x18.fromInt(2048); // Parameter 1
        parameters[0][1] = PRBMathSD59x18.fromInt(32768); // Parameter 1
        parameters[1] = new int256[](2);
        parameters[1][0] = PRBMathSD59x18.fromInt(3); // Parameter 2
        parameters[1][1] = PRBMathSD59x18.fromInt(3); // Parameter 2
        parameters[2] = new int256[](2);
        parameters[2][0] = PRBMathSD59x18.fromInt(1); // Parameter 3
        parameters[2][1] = PRBMathSD59x18.fromInt(1); // Parameter 3

        // Alpha and moving averages initialization
        int256[] memory prevAlphas = new int256[](2);
        prevAlphas[0] = PRBMathSD59x18.fromInt(1);
        prevAlphas[1] = PRBMathSD59x18.fromInt(2);

        int256[] memory prevMovingAverages = new int256[](2);
        prevMovingAverages[0] = PRBMathSD59x18.fromInt(3);
        prevMovingAverages[1] = PRBMathSD59x18.fromInt(4);

        int256[] memory movingAverages = new int256[](2);
        movingAverages[0] = PRBMathSD59x18.fromInt(3);
        movingAverages[1] = PRBMathSD59x18.fromInt(4);

        // Lambda initialization
        int128[] memory lambdas = new int128[](1);
        lambdas[0] = int128(0.9e18); // Lambda = 0.9

        // Weights initialization
        int256[] memory prevWeights = new int256[](2);
        prevWeights[0] = 0.5e18; // Weight 1
        prevWeights[1] = 0.5e18; // Weight 2

        // Data (new prices) initialization
        int256[] memory data = new int256[](2);
        data[0] = PRBMathSD59x18.fromInt(2); // New price 1
        data[1] = PRBMathSD59x18.fromInt(4); // New price 2

        // Expected result weights
        int256[] memory expectedResults = new int256[](2);
        expectedResults[0] = 0.499735371500687360e18;
        expectedResults[1] = 0.500004096000000000e18;

        mockPool.setNumberOfAssets(2);

        // Call the rule function and get the result
        rule.initialisePoolRuleIntermediateValues(
            address(mockPool),
            prevMovingAverages,
            prevAlphas,
            mockPool.numAssets()
        );

        rule.CalculateUnguardedWeights(prevWeights, data, address(mockPool), parameters, lambdas, movingAverages);

        // Get the updated weights
        int256[] memory resultWeights = rule.GetResultWeights();

        checkResult(resultWeights, expectedResults);
    }
}
