// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "@prb/math/contracts/PRBMathSD59x18.sol";

abstract contract QuantAMMTestUtils is Test{

    function checkResult(int256[] memory res, int256[] memory expectedRes) internal pure {
        for (uint256 i = 0; i < expectedRes.length; i++) {
            assertEq(expectedRes[i], res[i]); 
        }
    }

    function checkMatrixResult(int256[][] memory redecoded, int256[][] memory targetMatrix) internal pure {
        for (uint256 i = 0; i < targetMatrix.length; i++) {
            for (uint256 j = 0; j < targetMatrix[i].length; j++) {
                assertEq(redecoded[i][j], targetMatrix[i][j]);
            }
        }
    }

    function convert2DArrayToDynamic(int256[4][4] memory arr) internal pure returns (int256[][] memory) {
        int256[][] memory res = new int256[][](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            res[i] = new int256[](arr[i].length);
            for (uint256 j = 0; j < arr[i].length; j++) {
                res[i][j] = arr[i][j];
            }
        }
        return res;
    }
    function convert2DArrayToDynamic(int256[2][4] memory arr) internal pure returns (int256[][] memory) {
        int256[][] memory res = new int256[][](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            res[i] = new int256[](arr[i].length);
            for (uint256 j = 0; j < arr[i].length; j++) {
                res[i][j] = arr[i][j];
            }
        }
        return res;
    }

    function convert2DArrayToDynamic(int256[3][5] memory arr) internal pure returns (int256[][] memory) {
        int256[][] memory res = new int256[][](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            res[i] = new int256[](arr[i].length);
            for (uint256 j = 0; j < arr[i].length; j++) {
                res[i][j] = arr[i][j];
            }
        }
        return res;
    }

    function covert3DArrayToDynamic(int256[2][2][4] memory arr) internal pure returns (int256[][][] memory) {
        int256[][][] memory res = new int256[][][](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            res[i] = new int256[][](arr[i].length);
            for (uint256 j = 0; j < arr[i].length; j++) {
                res[i][j] = new int256[](arr[i][j].length);
                for (uint256 k = 0; k < arr[i][j].length; k++) {
                    res[i][j][k] = arr[i][j][k];
                }
            }
        }
        return res;
    }

}

