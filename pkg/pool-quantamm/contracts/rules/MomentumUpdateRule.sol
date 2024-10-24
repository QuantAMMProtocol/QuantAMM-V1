//SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "@prb/math/contracts/PRBMathSD59x18.sol";
import "./UpdateRule.sol";
import "./base/QuantammGradientBasedRule.sol";

/// @title MomentumUpdateRule contract for QuantAMM momentum update rule 
/// @notice Contains the logic for calculating the new weights of a QuantAMM pool using the momentum update rule
contract MomentumUpdateRule is QuantAMMGradientBasedRule, UpdateRule {
    constructor(address _updateWeightRunner) UpdateRule(_updateWeightRunner) {}

    using PRBMathSD59x18 for int256;

    int256 private constant ONE = 1 * 1e18; // Result of PRBMathSD59x18.fromInt(1), store as constant to avoid recalculation every time
    uint16 private constant REQUIRES_PREV_MAVG = 0;

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

    /// @param _prevWeights the previous weights retrieved from the vault
    /// @param _data the latest data from the signal, usually price
    /// @param _parameters the parameters of the rule that are not lambda
    /// @notice w(t) = w(t − 1) + κ · ( 1/p(t) * ∂p(t)/∂t − ℓp(t)) where ℓp(t) = 1/N * ∑( 1/p(t)i * ∂p(t)i/∂t) - see whitepaper
    function _getWeights(
        int256[] calldata _prevWeights,
        int256[] calldata _data,
        int256[][] calldata _parameters, //[0]=k
        QuantAMMPoolParameters memory _poolParameters
    ) internal override returns (int256[] memory newWeightsConverted) {
        QuantAMMMomentumLocals memory locals;

        locals.kappaStore = _parameters[0];
        locals.useRawPrice = false;
        // the second parameter determines if momentum should use the price or the average price as the denominator
        // using the average price has shown greater performance and resilience due to greater smoothing
        if (_parameters.length > 1) {
            locals.useRawPrice = _parameters[1][0] == ONE;
        }

        _poolParameters.numberOfAssets = _prevWeights.length;

        locals.prevWeightLength = _prevWeights.length;

        // newWeights is reused multiple times to save gas of multiple array initialisation
        locals.newWeights = _calculateQuantAMMGradient(
            _data,
            _poolParameters
        );

        
        for (locals.i = 0; locals.i < locals.prevWeightLength; ) {
            
            locals.denominator = _poolParameters.movingAverage[locals.i];
            if (locals.useRawPrice) {
                locals.denominator = _data[locals.i];
            }
            
            // 1/p(t) * ∂p(t)/∂t calculated and stored as used in multiple places
            locals.newWeights[locals.i] = ONE.div(locals.denominator).mul(locals.newWeights[locals.i]);
            
            if (locals.kappaStore.length == 1) {
                locals.normalizationFactor += locals.newWeights[locals.i];
            } else {
                locals.normalizationFactor += (locals.newWeights[locals.i] * locals.kappaStore[locals.i]);
            }

            unchecked {
                ++locals.i;
            }
        }

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

            locals.normalizationFactor /= sumKappa;

            // To avoid intermediate overflows (because of normalization), we only downcast in the end to an uint6
            for (locals.i = 0; locals.i < _prevWeights.length; ) {
                locals.res = int256(_prevWeights[locals.i]) +
                    locals.kappaStore[locals.i].mul(locals.newWeights[locals.i] - locals.normalizationFactor);
                require(locals.res >= 0, "Invalid weight");
                newWeightsConverted[locals.i] = locals.res;
                unchecked {
                    ++locals.i;
                }
            }
        }
        return newWeightsConverted;
    }

    /// @param _poolAddress the target pool address
    /// @param _initialValues the initial values of the pool
    /// @param _numberOfAssets the number of assets in the pool
    function _setInitialIntermediateValues(
        address _poolAddress,
        int256[] memory _initialValues,
        uint _numberOfAssets
    ) internal override {
        _setGradient(_poolAddress, _initialValues, _numberOfAssets);
    }

    function _requiresPrevMovingAverage()
        internal
        pure
        override
        returns (uint16)
    {
        return REQUIRES_PREV_MAVG;
    }

    /// @notice Check if the given parameters are valid for the rule
    /// @dev If parameters are not valid, either reverts or returns false
    function validParameters(
        int256[][] calldata _parameters
    ) external pure override returns (bool) {
        if (
            _parameters.length == 1 ||
            (_parameters.length == 2 && _parameters[1].length == 1)
        ) {
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
