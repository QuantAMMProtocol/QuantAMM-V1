//SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "@prb/math/contracts/PRBMathSD59x18.sol";
import "./base/QuantammGradientBasedRule.sol";
import "./base/QuantammMathGuard.sol";
import "./base/QuantammMathMovingAverage.sol";
import "./UpdateRule.sol";

/// @title MeanReversionChannelUpdateRule contract for QuantAMM mean reversion channel weight updates
/// @notice Contains the logic for calculating the new weights of a QuantAMM pool using the mean reversion channel strategy
contract ChannelFollowingUpdateRule is QuantAMMGradientBasedRule, UpdateRule {
    constructor(address _updateWeightRunner) UpdateRule(_updateWeightRunner) {
        name = "MeanReversionChannel";
        
        parameterDescriptions = new string[](6);
        parameterDescriptions[0] = "Kappa: Kappa dictates the aggressiveness of response to a signal change";
        parameterDescriptions[1] = "Width: Width parameter for the mean reversion channel";
        parameterDescriptions[2] = "Amplitude: Amplitude of the mean reversion effect";
        parameterDescriptions[3] = "Exponents: Exponents for the trend following portion";
        parameterDescriptions[4] = "Inverse Scaling: Scaling factor for channel portion (default 0.5415)";
        parameterDescriptions[5] = "Pre-exp Scaling: Scaling factor before exponentiation (default 0.5)";
    }

    using PRBMathSD59x18 for int256;

    int256 private constant ONE = 1e18;
    int256 private constant PI = 3141592653589793238 * 1e18 / 1e18; // π scaled to 18 decimals
    int256 private constant DEFAULT_INVERSE_SCALING = 5415e14; // 0.5415 in 18 decimals
    int256 private constant DEFAULT_PRE_EXP_SCALING = 5e17; // 0.5 in 18 decimals
    uint16 private constant REQUIRES_PREV_MAVG = 0;

    struct MeanReversionChannelLocals {
        int256[] kappa;
        int256[] width;
        int256[] amplitude;
        int256[] exponents;
        int256 inverseScaling;
        int256 preExpScaling;
        int256[] newWeights;
        int256[] signal;
        int256 normalizationFactor;
        uint256 prevWeightLength;
        uint i;
        int256 sumKappa;
    }

    function _getWeights(
        int256[] calldata _prevWeights,
        int256[] calldata _data,
        int256[][] calldata _parameters,
        QuantAMMPoolParameters memory _poolParameters
    ) internal override returns (int256[] memory newWeightsConverted) {
        MeanReversionChannelLocals memory locals;
        
        locals.kappa = _parameters[0];
        locals.width = _parameters[1];
        locals.amplitude = _parameters[2];
        locals.exponents = _parameters[3];
        
        // Set default values if not provided
        locals.inverseScaling = _parameters.length > 4 ? _parameters[4][0] : DEFAULT_INVERSE_SCALING;
        locals.preExpScaling = _parameters.length > 5 ? _parameters[5][0] : DEFAULT_PRE_EXP_SCALING;

        locals.prevWeightLength = _prevWeights.length;
        _poolParameters.numberOfAssets = locals.prevWeightLength;

        // Calculate price gradients
        locals.newWeights = _calculateQuantAMMGradient(_data, _poolParameters);
        locals.signal = new int256[](locals.prevWeightLength);

        // Calculate signal for each asset
        for (locals.i = 0; locals.i < locals.prevWeightLength;) {
            // Calculate envelope: exp(-(price_gradient^2) / (2 * width^2))
            int256 gradientSquared = locals.newWeights[locals.i].mul(locals.newWeights[locals.i]);
            int256 widthSquared = locals.width[0].mul(locals.width[0]);
            int256 envelope = (-gradientSquared.div(widthSquared.mul(2))).exp();

            // Calculate scaled price gradient: π * price_gradient / (3 * width)
            int256 scaledGradient = PI.mul(locals.newWeights[locals.i]).div(locals.width[0].mul(3));
            
            // Calculate channel portion
            int256 channelPortion = locals.amplitude[0].mul(envelope).mul(
                scaledGradient.sub(scaledGradient.pow(3).div(6))
            ).div(locals.inverseScaling);
            channelPortion = -channelPortion; // Negative amplitude effect

            // Calculate trend portion
            int256 trendPortion;
            {
                int256 absGradient = locals.newWeights[locals.i] >= 0 ? 
                    locals.newWeights[locals.i] : -locals.newWeights[locals.i];
                
                int256 scaledAbsGradient = absGradient.div(locals.preExpScaling.mul(2));
                trendPortion = _pow(scaledAbsGradient, locals.exponents[0]);
                
                if (locals.newWeights[locals.i] < 0) {
                    trendPortion = -trendPortion;
                }
                
                trendPortion = trendPortion.mul(ONE - envelope);
            }

            locals.signal[locals.i] = channelPortion + trendPortion;
            
            if (locals.kappa.length == 1) {
                locals.normalizationFactor += locals.signal[locals.i];
            } else {
                locals.normalizationFactor += locals.signal[locals.i].mul(locals.kappa[locals.i]);
            }

            unchecked {
                ++locals.i;
            }
        }

        newWeightsConverted = new int256[](locals.prevWeightLength);

        // Calculate final weights
        if (locals.kappa.length == 1) {
            locals.normalizationFactor = locals.normalizationFactor.div(int256(locals.prevWeightLength));
            
            for (locals.i = 0; locals.i < locals.prevWeightLength;) {
                newWeightsConverted[locals.i] = _prevWeights[locals.i] + 
                    locals.kappa[0].mul(locals.signal[locals.i] - locals.normalizationFactor);
                
                unchecked {
                    ++locals.i;
                }
            }
        } else {
            for (locals.i = 0; locals.i < locals.kappa.length;) {
                locals.sumKappa += locals.kappa[locals.i];
                unchecked {
                    ++locals.i;
                }
            }

            locals.normalizationFactor = locals.normalizationFactor.div(locals.sumKappa);

            for (locals.i = 0; locals.i < locals.prevWeightLength;) {
                int256 weightUpdate = locals.kappa[locals.i].mul(
                    locals.signal[locals.i] - locals.normalizationFactor
                );
                newWeightsConverted[locals.i] = _prevWeights[locals.i] + weightUpdate;
                require(newWeightsConverted[locals.i] >= 0, "Invalid weight");
                
                unchecked {
                    ++locals.i;
                }
            }
        }

        return newWeightsConverted;
    }

    function _requiresPrevMovingAverage() internal pure override returns (uint16) {
        return REQUIRES_PREV_MAVG;
    }

    function _setInitialIntermediateValues(
        address _poolAddress,
        int256[] memory _initialValues,
        uint _numberOfAssets
    ) internal override {
        _setGradient(_poolAddress, _initialValues, _numberOfAssets);
    }

    function validParameters(int256[][] calldata _parameters) external pure override returns (bool) {
        // Must have at least kappa, width, amplitude and exponents
        if (_parameters.length < 4) return false;

        // All parameter arrays must have same length or be length 1 (scalar)
        uint baseLength = _parameters[0].length;
        if (baseLength == 0) return false;

        for (uint i = 1; i < 4; i++) {
            if (_parameters[i].length != baseLength && _parameters[i].length != 1) {
                return false;
            }
        }

        // Optional parameters must be scalar if provided
        if (_parameters.length > 4 && _parameters[4].length != 1) return false;
        if (_parameters.length > 5 && _parameters[5].length != 1) return false;

        // Validate parameter values
        for (uint i = 0; i < _parameters[0].length; i++) {
            if (_parameters[0][i] <= 0) return false; // kappa must be positive
            if (_parameters[1][i] <= 0) return false; // width must be positive
            if (_parameters[2][i] <= 0) return false; // amplitude must be positive
            if (_parameters[3][i] <= ONE) return false; // exponents must be > 1
        }

        return true;
    }
}