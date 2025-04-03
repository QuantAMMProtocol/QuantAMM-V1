// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.24;

import "@prb/math/contracts/PRBMathSD59x18.sol";
import "../../QuantAMMStorage.sol";

/// @title QuantAMMMathMovingAverage contract for QuantAMM moving average calculations and storage of moving averages for QuantAMM pools
/// @notice Contains the logic for calculating the moving average of the pool price and storing the moving averages
abstract contract QuantAMMMathMovingAverage is ScalarRuleQuantAMMStorage {
    using PRBMathSD59x18 for int256;

    int256 private constant ONE = 1 * 1e18; // Result of PRBMathSD59x18.fromInt(1), store as constant to avoid recalculation every time

    // this can be just the moving averages per token, or if prev moving average is true then it is [...moving averages, ...prev moving averages]
    mapping(address => int256[]) public movingAverages;

    /// @notice View function to get the moving averages for a given pool
    /// @param poolAddress The address of the pool
    /// @param numberOfAssets The number of assets in the pool
    /// @return The unpacked moving averages as an array of int256
    function getMovingAverages(address poolAddress, uint numberOfAssets) external view returns (int256[] memory) {
        return _quantAMMUnpack128Array(movingAverages[poolAddress], numberOfAssets);
    }

    /// @notice Calculates the new moving average value, i.e. p̅(t) = p̅(t - 1) + (1 - λ)(p(t) - p̅(t - 1))
    /// @param _prevMovingAverage p̅(t - 1)
    /// @param _newData p(t)
    /// @param _lambda λ
    /// @param _numberOfAssets number of assets in the pool
    /// @return p̅(t) avertage price of the pool
    function _calculateQuantAMMMovingAverage(
        int256[] memory _prevMovingAverage,
        int256[] memory _newData,
        int128[] memory _lambda,
        uint _numberOfAssets
    ) internal pure returns (int256[] memory) {
        int256[] memory newMovingAverage = new int256[](_numberOfAssets);
        int256 convertedLambda = int256(_lambda[0]);
        int256 oneMinusLambda = ONE - convertedLambda;
        if (_lambda.length == 1) {
            for (uint i; i < _numberOfAssets; ) {
                // p̅(t) = p̅(t - 1) + (1 - λ)(p(t) - p̅(t - 1)) - see whitepaper
                int256 movingAverageI = _prevMovingAverage[i];
                //CODEHAWKS INFO /s/200 reordering to avoid precision loss
                newMovingAverage[i] = (movingAverageI.mul(convertedLambda) + _newData[i].mul(oneMinusLambda)).div(ONE);
                unchecked {
                    ++i;
                }
            }
        } else {
            for (uint i; i < _numberOfAssets; ) {
                unchecked {
                    convertedLambda = int256(_lambda[i]);
                    oneMinusLambda = ONE - convertedLambda;
                }
                int256 movingAverageI = _prevMovingAverage[i];
                // p̅(t) = p̅(t - 1) + (1 - λ)(p(t) - p̅(t - 1))
                //CODEHAWKS INFO /s/200 reordering to avoid precision loss
                newMovingAverage[i] = (movingAverageI.mul(convertedLambda) + _newData[i].mul(oneMinusLambda)).div(ONE);
                unchecked {
                    ++i;
                }
            }
        }

        return newMovingAverage;
    }

    /// @param _poolAddress address of pool being initialised
    /// @param _initialMovingAverages array of initial moving averages
    /// @param _numberOfAssets number of assets in the pool
    function _setInitialMovingAverages(
        address _poolAddress,
        int256[] memory _initialMovingAverages,
        uint _numberOfAssets
    ) internal {
        //CODEHAWKS H-04 no longer storing prev, also /s/767
        if (_initialMovingAverages.length == _numberOfAssets) {
            //should be during create pool
            movingAverages[_poolAddress] = _quantAMMPack128Array(_initialMovingAverages);
        } else {
            revert("Invalid set moving avg");
        }
    }
}
