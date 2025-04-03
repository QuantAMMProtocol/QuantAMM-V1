// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@prb/math/contracts/PRBMathSD59x18.sol";

import { MockCalculationRule } from "../../../../contracts/mock/MockCalculationRule.sol";
import { MockPool } from "../../../../contracts/mock/MockPool.sol";
import { MockQuantAMMMathGuard } from "../../../../contracts/mock/MockQuantAMMMathGuard.sol";

import { QuantAMMTestUtils } from "../../utils.t.sol";

contract QuantAMMCoVarianceRuleTest is Test, QuantAMMTestUtils {
    using PRBMathSD59x18 for int256;

    MockCalculationRule mockCalculationRule;
    MockPool mockPool;
    MockQuantAMMMathGuard mockQuantAMMMathGuard;

    int256 constant UPDATE_INTERVAL = 1800e18; // 1800 seconds in fixed-point format
    int128 constant LAMBDA = 5e17; // Lambda is 0.5 in fixed-point format

    function setUp() public {
        mockCalculationRule = new MockCalculationRule();
        mockPool = new MockPool(3600, 1e18, address(mockCalculationRule)); // 3600 sec update interval
        mockQuantAMMMathGuard = new MockQuantAMMMathGuard();
    }

    function testInitialSettingOfCovariance(uint256 unboundedNumberOfAssets) public {
        uint256 numberOfAssets = bound(unboundedNumberOfAssets, 2, 8);

        mockPool.setNumberOfAssets(numberOfAssets);

        int256[][] memory initialCovariances = new int256[][](numberOfAssets);
        for (uint256 i = 0; i < numberOfAssets; i++) {
            initialCovariances[i] = new int256[](numberOfAssets);

            for (uint256 j = 0; j < numberOfAssets; j++) {
                initialCovariances[i][j] = PRBMathSD59x18.fromInt(int256(j + 1));
            }
        }

        mockCalculationRule.setInitialCovariance(address(mockPool), initialCovariances, numberOfAssets);

        int256[][] memory results = mockCalculationRule.getIntermediateCovariance(address(mockPool), numberOfAssets);
        int256[] memory flattenedResults = mockCalculationRule.getIntermediateCovarianceState(
            address(mockPool),
            numberOfAssets
        );

        for (uint256 i = 0; i < numberOfAssets; i++) {
            for (uint256 j = 0; j < numberOfAssets; j++) {
                assertEq(results[i][j], initialCovariances[i][j]);
                assertEq(flattenedResults[i * numberOfAssets + j], initialCovariances[i][j]);
            }
        }
    }

    function testBreakGlassSettingOfCovariances(uint256 unboundedNumberOfAssets) public {
        uint256 numberOfAssets = bound(unboundedNumberOfAssets, 2, 8);

        mockPool.setNumberOfAssets(numberOfAssets);

        int256[][] memory initialCovariances = new int256[][](numberOfAssets);
        for (uint256 i = 0; i < numberOfAssets; i++) {
            initialCovariances[i] = new int256[](numberOfAssets);

            for (uint256 j = 0; j < numberOfAssets; j++) {
                initialCovariances[i][j] = PRBMathSD59x18.fromInt(int256(j + 1));
            }
        }

        mockCalculationRule.setInitialCovariance(address(mockPool), initialCovariances, numberOfAssets);

        int256[][] memory results = mockCalculationRule.getIntermediateCovariance(address(mockPool), numberOfAssets);
        int256[] memory flattenedResults = mockCalculationRule.getIntermediateCovarianceState(
            address(mockPool),
            numberOfAssets
        );

        for (uint256 i = 0; i < numberOfAssets; i++) {
            for (uint256 j = 0; j < numberOfAssets; j++) {
                assertEq(results[i][j], initialCovariances[i][j]);
                assertEq(flattenedResults[i * numberOfAssets + j], initialCovariances[i][j]);
            }
        }
        for (uint256 i = 0; i < numberOfAssets; i++) {
            for (uint256 j = 0; j < numberOfAssets; j++) {
                initialCovariances[i][j] = PRBMathSD59x18.fromInt(int256(i + 3));
            }
        }

        mockCalculationRule.setInitialCovariance(address(mockPool), initialCovariances, numberOfAssets);

        results = mockCalculationRule.getIntermediateCovariance(address(mockPool), numberOfAssets);
        flattenedResults = mockCalculationRule.getIntermediateCovarianceState(address(mockPool), numberOfAssets);

        for (uint256 i = 0; i < numberOfAssets; i++) {
            for (uint256 j = 0; j < numberOfAssets; j++) {
                assertEq(results[i][j], initialCovariances[i][j]);
                assertEq(flattenedResults[i * numberOfAssets + j], initialCovariances[i][j]);
            }
        }
    }

    function testCovariance(
        int256[][] memory priceData,
        int256[][] memory priceDataBn,
        int256[][] memory movingAverages,
        int256[][] memory initialCovariance,
        bool vectorLambda
    ) internal returns (int256[][][] memory results) {
        mockCalculationRule.setInitialCovariance(address(mockPool), initialCovariance, priceData[0].length);
        mockCalculationRule.setPrevMovingAverage(movingAverages[0]);

        results = new int256[][][](movingAverages.length);

        int128[] memory lambda = new int128[](vectorLambda ? priceData[0].length : 1);
        for (uint256 i = 0; i < lambda.length; i++) {
            lambda[i] = int128(uint128(0.5e18));
        }
        console.log("lambda", lambda.length);

        for (uint256 i = 0; i < movingAverages.length; ++i) {
            if (i > 0) {
                mockCalculationRule.setPrevMovingAverage(movingAverages[i - 1]);
            }
            mockCalculationRule.externalCalculateQuantAMMCovariance(
                priceDataBn[i],
                movingAverages[i],
                address(mockPool),
                lambda,
                initialCovariance[0].length
            );
            results[i] = mockCalculationRule.getMatrixResults();
        }
    }

    // Function to test covariance calculation
    function testAndValidateCovariance(
        int256[][] memory priceData,
        int256[][] memory priceDataBn,
        int256[][] memory movingAverages,
        int256[][] memory initialCovariance,
        int256[][][] memory expectedRes,
        bool vectorLambda
    ) internal {
        int256[][][] memory results = testCovariance(
            priceData,
            priceDataBn,
            movingAverages,
            initialCovariance,
            vectorLambda
        );

        checkCovarianceResult(priceData, results, expectedRes);
    }

    function checkCovarianceResult(
        int256[][] memory priceData,
        int256[][][] memory res,
        int256[][][] memory expectedRes
    ) internal pure {
        uint256 n = priceData[0].length;
        for (uint256 i = 0; i < res.length; i++) {
            for (uint256 j = 0; j < n; j++) {
                for (uint256 k = 0; k < n; k++) {
                    assertEq(res[i][j][k], expectedRes[i][j][k], "Values are not the same");
                }
            }
        }
    }

    // Covariance Matrix Calculation
    // 2 tokens
    function testCovarianceCalculation2Tokens(bool vectorLambda) public {
        mockPool.setNumberOfAssets(2);
        int256[][] memory priceData = convert2DArrayToDynamic(
            [
                [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
                [PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100)],
                [PRBMathSD59x18.fromInt(1109), PRBMathSD59x18.fromInt(1106)],
                [PRBMathSD59x18.fromInt(1095), PRBMathSD59x18.fromInt(1098)]
            ]
        );

        int256[][] memory priceDataBn = convert2DArrayToDynamic(
            [
                [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
                [PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100)],
                [PRBMathSD59x18.fromInt(1109), PRBMathSD59x18.fromInt(1106)],
                [PRBMathSD59x18.fromInt(1095), PRBMathSD59x18.fromInt(1098)]
            ]
        );

        int256[][] memory movingAverages = convert2DArrayToDynamic(
            [
                [
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000)
                ],
                [
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000)
                ],
                [
                    PRBMathSD59x18.fromInt(1079) + 5e17,
                    PRBMathSD59x18.fromInt(1078),
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1050)
                ],
                [
                    PRBMathSD59x18.fromInt(1087) + 25e16,
                    PRBMathSD59x18.fromInt(1088),
                    PRBMathSD59x18.fromInt(1079) + 5e17,
                    PRBMathSD59x18.fromInt(1078)
                ]
            ]
        );

        int256[][] memory initialCovariance = new int256[][](2);
        initialCovariance[0] = new int256[](2);
        initialCovariance[0][0] = 0;
        initialCovariance[0][1] = 0;
        initialCovariance[1] = new int256[](2);
        initialCovariance[1][0] = 0;
        initialCovariance[1][1] = 0;

        int256[][][] memory expectedRes = covert3DArrayToDynamic(
            [
                [
                    [PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0)],
                    [PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0)]
                ],
                [
                    [PRBMathSD59x18.fromInt(2500), PRBMathSD59x18.fromInt(2500)],
                    [PRBMathSD59x18.fromInt(2500), PRBMathSD59x18.fromInt(2500)]
                ],
                [
                    [PRBMathSD59x18.fromInt(2120) + 25e16, PRBMathSD59x18.fromInt(2076)],
                    [PRBMathSD59x18.fromInt(2076), PRBMathSD59x18.fromInt(2034)]
                ],
                [
                    [PRBMathSD59x18.fromInt(1120) + 1875e14, PRBMathSD59x18.fromInt(1115) + 5e17],
                    [PRBMathSD59x18.fromInt(1115) + 5e17, PRBMathSD59x18.fromInt(1117)]
                ]
            ]
        );

        testAndValidateCovariance(priceData, priceDataBn, movingAverages, initialCovariance, expectedRes, vectorLambda);
    }

    // Covariance Matrix Calculation
    // 2 tokens
    function testCovarianceCalculation3Tokens(bool vectorLambda) public {
        mockPool.setNumberOfAssets(3);
        int256[][] memory priceData = convert2DArrayToDynamic(
            [
                [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
                [PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100)],
                [PRBMathSD59x18.fromInt(1109), PRBMathSD59x18.fromInt(1106), PRBMathSD59x18.fromInt(1106)],
                [PRBMathSD59x18.fromInt(1095), PRBMathSD59x18.fromInt(1098), PRBMathSD59x18.fromInt(1098)]
            ]
        );

        int256[][] memory priceDataBn = convert2DArrayToDynamic(
            [
                [PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000), PRBMathSD59x18.fromInt(1000)],
                [PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100), PRBMathSD59x18.fromInt(1100)],
                [PRBMathSD59x18.fromInt(1109), PRBMathSD59x18.fromInt(1106), PRBMathSD59x18.fromInt(1106)],
                [PRBMathSD59x18.fromInt(1095), PRBMathSD59x18.fromInt(1098), PRBMathSD59x18.fromInt(1098)]
            ]
        );

        int256[][] memory movingAverages = convert2DArrayToDynamic(
            [
                [
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000)
                ],
                [
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000),
                    PRBMathSD59x18.fromInt(1000)
                ],
                [
                    PRBMathSD59x18.fromInt(1079) + 5e17,
                    PRBMathSD59x18.fromInt(1078),
                    PRBMathSD59x18.fromInt(1078),
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1050),
                    PRBMathSD59x18.fromInt(1050)
                ],
                [
                    PRBMathSD59x18.fromInt(1087) + 25e16,
                    PRBMathSD59x18.fromInt(1088),
                    PRBMathSD59x18.fromInt(1088),
                    PRBMathSD59x18.fromInt(1079) + 5e17,
                    PRBMathSD59x18.fromInt(1078),
                    PRBMathSD59x18.fromInt(1078)
                ]
            ]
        );

        int256[][] memory initialCovariance = new int256[][](3);
        initialCovariance[0] = new int256[](3);
        initialCovariance[0][0] = 0;
        initialCovariance[0][1] = 0;
        initialCovariance[0][2] = 0;
        initialCovariance[1] = new int256[](3);
        initialCovariance[1][0] = 0;
        initialCovariance[1][1] = 0;
        initialCovariance[1][2] = 0;
        initialCovariance[2] = new int256[](3);
        initialCovariance[2][0] = 0;
        initialCovariance[2][1] = 0;
        initialCovariance[2][2] = 0;

        int256[][][] memory expectedRes = covert3DArrayToDynamic(
            [
                [
                    [PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0)],
                    [PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0)],
                    [PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0), PRBMathSD59x18.fromInt(0)]
                ],
                [
                    [PRBMathSD59x18.fromInt(2500), PRBMathSD59x18.fromInt(2500), PRBMathSD59x18.fromInt(2500)],
                    [PRBMathSD59x18.fromInt(2500), PRBMathSD59x18.fromInt(2500), PRBMathSD59x18.fromInt(2500)],
                    [PRBMathSD59x18.fromInt(2500), PRBMathSD59x18.fromInt(2500), PRBMathSD59x18.fromInt(2500)]
                ],
                [
                    [PRBMathSD59x18.fromInt(2120) + 25e16, PRBMathSD59x18.fromInt(2076), PRBMathSD59x18.fromInt(2076)],
                    [PRBMathSD59x18.fromInt(2076), PRBMathSD59x18.fromInt(2034), PRBMathSD59x18.fromInt(2034)],
                    [PRBMathSD59x18.fromInt(2076), PRBMathSD59x18.fromInt(2034), PRBMathSD59x18.fromInt(2034)]
                ],
                [
                    [
                        PRBMathSD59x18.fromInt(1120) + 1875e14,
                        PRBMathSD59x18.fromInt(1115) + 5e17,
                        PRBMathSD59x18.fromInt(1115) + 5e17
                    ],
                    [PRBMathSD59x18.fromInt(1115) + 5e17, PRBMathSD59x18.fromInt(1117), PRBMathSD59x18.fromInt(1117)],
                    [PRBMathSD59x18.fromInt(1115) + 5e17, PRBMathSD59x18.fromInt(1117), PRBMathSD59x18.fromInt(1117)]
                ]
            ]
        );

        testAndValidateCovariance(priceData, priceDataBn, movingAverages, initialCovariance, expectedRes, vectorLambda);
    }

    // Fuzz test for covariance calculation with random number of assets
    function testFuzz_CovarianceCalculationAccess(
        uint256 unboundNumAssets,
        uint256 unboundNumberOfCalculations,
        bool vectorLambda
    ) public {
        uint256 numAssets = bound(unboundNumAssets, 2, 8);
        uint256 numberOfCalculations = bound(unboundNumberOfCalculations, 1, 20);

        mockPool.setNumberOfAssets(numAssets);
        int256[][] memory priceData = new int256[][](numberOfCalculations);
        int256[][] memory priceDataBn = new int256[][](numberOfCalculations);
        int256[][] memory movingAverages = new int256[][](numberOfCalculations);

        for (uint256 i = 0; i < numberOfCalculations; i++) {
            priceData[i] = new int256[](numAssets);
            priceDataBn[i] = new int256[](numAssets);
            movingAverages[i] = new int256[](numAssets * 2);
            for (uint256 j = 0; j < numAssets; j++) {
                priceData[i][j] = PRBMathSD59x18.fromInt(1000 + int256(i * 100 + j * 10));
                priceDataBn[i][j] = PRBMathSD59x18.fromInt(1000 + int256(i * 100 + j * 10));
                movingAverages[i][j] = PRBMathSD59x18.fromInt(1000 + int256(i * 50 + j * 5));
                movingAverages[i][j + numAssets] = PRBMathSD59x18.fromInt(1000 + int256(i * 50 + j * 5));
            }
        }

        int256[][] memory initialCovariance = new int256[][](numAssets);
        for (uint256 i = 0; i < numAssets; i++) {
            initialCovariance[i] = new int256[](numAssets);
            for (uint256 j = 0; j < numAssets; j++) {
                initialCovariance[i][j] = 0;
            }
        }

        testCovariance(priceData, priceDataBn, movingAverages, initialCovariance, vectorLambda);
    }
}
