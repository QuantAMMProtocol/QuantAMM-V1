//SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "forge-std/Test.sol";

import "@prb/math/contracts/PRBMathSD59x18.sol";
import "./UpdateRule.sol";
import "./base/QuantammGradientBasedRule.sol";

/// @title DifferenceMomentumUpdateRule contract for QuantAMM update rule based on Moving Average Convergence Divergence
/// @notice Contains the logic for calculating the new weights of a QuantAMM pool using the difference momentum update rule
contract DifferenceMomentumUpdateRule is QuantAMMGradientBasedRule, UpdateRule {
    constructor(address _updateWeightRunner) UpdateRule(_updateWeightRunner) {
        name = "DifferenceMomentum";

        parameterDescriptions = new string[](3);
        parameterDescriptions[
            0
        ] = "Kappa: Kappa dictates the aggressiveness of the rule's response to a signal change (here, price gradient)";
        parameterDescriptions[1] = "Lambda_short: This Lambda dictates price smoothing for the short-memory moving average";
        parameterDescriptions[
            2
        ] = "Lambda_long: This Lambda dictates price smoothing for the long-memory moving average";
    }

    using PRBMathSD59x18 for int256;

    int256 private constant ONE = 1 * 1e18; // Result of PRBMathSD59x18.fromInt(1), store as constant to avoid recalculation every time
    uint16 private constant REQUIRES_PREV_MAVG = 0;

    mapping(address => int256[]) public shortMovingAverages;

    /// @dev struct to avoid stack too deep issues
    /// @notice Struct to store local variables for the momentum calculation
    /// @param kappaStore array of kappa value parameters
    /// @param newWeights array of new weights
    /// @param normalizationFactor normalization factor for the weights
    /// @param prevWeightLength length of the previous weights
    /// @param useRawPrice boolean to determine if raw price should be used or average
    /// @param i index for looping
    /// @param denominator denominator for the weights
    /// @param sumKappa sum of all kappa values
    /// @param res result of the calculation
    struct QuantAMMMomentumLocals {
        int256[] kappaStore;
        int256[] newWeights;
        int256 normalizationFactor;
        uint256 prevWeightLength;
        bool useRawPrice;
        uint i;
        int256 denominator;
        int256 sumKappa;
        int256 res;
    }

    /// @notice w(t) = w(t − 1) + κ · ( (1 - EWMA_short / EWMA_long) − ℓp(t)) where ℓp(t) = 1/N * ∑( (1 - EWMA_short / EWMA_long)_i) - see whitepaper
    /// @param _prevWeights the previous weights retrieved from the vault
    /// @param _data the latest data from the signal, usually price
    /// @param _parameters the parameters of the rule that are not lambda_long [0]=kappa can be per token (vector) or single for all tokens (scalar), [1]=lambda_short
    function _getWeights(
        int256[] calldata _prevWeights,
        int256[]  memory _data,
        int256[][] calldata _parameters,
        QuantAMMPoolParameters memory _poolParameters
    ) internal override returns (int256[] memory newWeightsConverted) {
        QuantAMMMomentumLocals memory locals;
        console.log("1");
        locals.kappaStore = _parameters[0];
        locals.useRawPrice = false;
        _poolParameters.numberOfAssets = _prevWeights.length;

        console.log("2");
        console.log(shortMovingAverages[_poolParameters.pool].length);
        console.log(_poolParameters.numberOfAssets);

        int256[] memory currentShortMovingAverages = _quantAMMUnpack128Array(shortMovingAverages[_poolParameters.pool], _poolParameters.numberOfAssets);
        int256[] memory currentLongMovingAverages = _quantAMMUnpack128Array(movingAverages[_poolParameters.pool], _poolParameters.numberOfAssets);
        int256[] memory newShortMovingAverages = _calculateQuantAMMMovingAverage(
            currentShortMovingAverages,
            _data,
            _poolParameters.lambda,
            _poolParameters.numberOfAssets
        );
        int256[] memory newLongMovingAverages = _calculateQuantAMMMovingAverage(
            currentLongMovingAverages,
            _data,
            _poolParameters.lambda,
            _poolParameters.numberOfAssets
        );
        console.log("3");
        shortMovingAverages[_poolParameters.pool] = _quantAMMPack128Array(newShortMovingAverages);
        movingAverages[_poolParameters.pool] = _quantAMMPack128Array(newLongMovingAverages);

        for(uint i; i < newShortMovingAverages.length; ) {
            console.log("top of for loop");
            console.log("i", i);
            console.log("newShort");
            console.logInt(newShortMovingAverages[i]);
            console.log("newLong");
            console.logInt(newLongMovingAverages[i]);
            unchecked{++i;}
        }
        console.log("4");

        locals.prevWeightLength = _prevWeights.length;

        // newWeights is reused multiple times to save gas of multiple array initialisation
        locals.newWeights = new int256[](locals.prevWeightLength);
        console.log("5");
        console.log(movingAverages[_poolParameters.pool].length);
        for (locals.i = 0; locals.i < locals.prevWeightLength; ) {
            console.log("locals.i");
            console.log(locals.i);
            console.log("newShortMovingAverages[locals.i]");
            console.logInt(newShortMovingAverages[locals.i]);
            console.log("movingAverages[_poolParameters.pool][locals.i]");
            console.logInt(movingAverages[_poolParameters.pool][locals.i]);
        
            locals.newWeights[locals.i] = newShortMovingAverages[locals.i] - newLongMovingAverages[locals.i];

            console.log("6");

            locals.denominator = _poolParameters.movingAverage[locals.i];

            // 1/p(t) * ∂p(t)/∂t calculated and stored as used in multiple places
            locals.newWeights[locals.i] = ONE.div(locals.denominator).mul(locals.newWeights[locals.i]);
            if (locals.kappaStore.length == 1) {
                locals.normalizationFactor += locals.newWeights[locals.i];
            } else {
                locals.normalizationFactor += (locals.newWeights[locals.i].mul(locals.kappaStore[locals.i]));
            }

            unchecked {
                ++locals.i;
            }
        }
        console.log("7");
        newWeightsConverted = new int256[](locals.prevWeightLength);

        if (locals.kappaStore.length == 1) {
            //scalar logic separate to vector for efficiency
            locals.normalizationFactor /= int256(locals.prevWeightLength);
            // To avoid intermediate overflows (because of normalization), we only downcast in the end to an uint6
            // κ · ( 1/p(t) * ∂p(t)/∂t − ℓp(t))
            for (locals.i = 0; locals.i < locals.prevWeightLength; ) {
                int256 res = int256(_prevWeights[locals.i]) +
                    locals.kappaStore[0].mul(locals.newWeights[locals.i] - locals.normalizationFactor);
                newWeightsConverted[locals.i] = res;

                unchecked {
                    ++locals.i;
                }
            }
        } else {
            //vector logic separate to vector for efficiency
            int256 sumKappa;
            for (locals.i = 0; locals.i < locals.kappaStore.length; ) {
                sumKappa += locals.kappaStore[locals.i];
                unchecked {
                    ++locals.i;
                }
            }

            locals.normalizationFactor = locals.normalizationFactor.div(sumKappa);

            // To avoid intermediate overflows (because of normalization), we only downcast in the end to an uint6
            for (locals.i = 0; locals.i < _prevWeights.length; ) {
                locals.res =
                    int256(_prevWeights[locals.i]) +
                    locals.kappaStore[locals.i].mul(locals.newWeights[locals.i] - locals.normalizationFactor);
                require(locals.res >= 0, "Invalid weight");
                newWeightsConverted[locals.i] = locals.res;
                unchecked {
                    ++locals.i;
                }
            }
        }
        console.log("8");
        return newWeightsConverted;
    }

    /// @notice Set the initial intermediate values for the pool, in this case the gradient
    /// @param _poolAddress the target pool address
    /// @param _initialValues the initial values of the pool
    /// @param _numberOfAssets the number of assets in the pool
    function _setInitialIntermediateValues(
        address _poolAddress,
        int256[] memory _initialValues,
        uint _numberOfAssets
    ) internal override {
        require(_initialValues.length == _numberOfAssets * 2, "Invalid initial values");
        int256[] memory initialValues = new int256[](_numberOfAssets);
        int256[] memory initialAverageValues = new int256[](_numberOfAssets);
        for (uint i; i < _numberOfAssets; ) {
            initialValues[i] = _initialValues[i];
            initialAverageValues[i] = _initialValues[i + _numberOfAssets];
            unchecked {
                ++i;
            }
        }

        _setGradient(_poolAddress, initialValues, _numberOfAssets);

        //unfortunately to avoid incorrect access to base MathMovingAverage, we need to set the moving average here
        uint movingAverageLength = shortMovingAverages[_poolAddress].length;

        if (movingAverageLength == 0 || initialAverageValues.length == _numberOfAssets) {
            //should be during create pool
            shortMovingAverages[_poolAddress] = _quantAMMPack128Array(initialAverageValues);
        } else {
            revert("Invalid set moving avg");
        }
    }

    /// @notice Check if the rule requires the previous moving average
    /// @return 0 if it does not require the previous moving average, 1 if it does
    function _requiresPrevMovingAverage() internal pure override returns (uint16) {
        return REQUIRES_PREV_MAVG;
    }

    /// @notice Check if the given parameters are valid for the rule
    /// @dev If parameters are not valid, either reverts or returns false
    function validParameters(int256[][] calldata _parameters) external pure override returns (bool) {
        if (_parameters.length == 1 || (_parameters.length == 2 && _parameters[1].length == 1)) {
            int256[] memory kappa = _parameters[0];
            uint16 valid = uint16(kappa.length) > 0 ? 1 : 0;
            for (uint i; i < kappa.length; ) {
                if (!(kappa[i] > 0)) {
                    unchecked {
                        valid = 0;
                    }
                    break;
                }
                unchecked {
                    ++i;
                }
            }
            return valid == 1;
        }

        return false;
    }
}
