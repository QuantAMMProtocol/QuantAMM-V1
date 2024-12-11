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
        parameterDescriptions[0] = "Kappa: Scaling factor for weight updates";
        parameterDescriptions[1] = "Width: Width parameter for the mean reversion channel";
        parameterDescriptions[2] = "Amplitude: Amplitude of the mean reversion effect";
        parameterDescriptions[3] = "Exponents: Exponents for the trend following portion";
        parameterDescriptions[4] = "Use raw price: 0 = use moving average, 1 = use raw price";
        parameterDescriptions[5] = "Lambda: Lambda dictates the estimator weighting and price smoothing";
    }

    using PRBMathSD59x18 for int256;

    int256 private constant ONE = 1e18;
    int256 private constant PI = 3141592653589793238 * 1e18 / 1e18; // π scaled to 18 decimals
    int256 private constant INV_SCALING = 5415e14; // 0.5415 in fixed point
    int256 private constant PRE_EXP_SCALING = 5e17; // 0.5 in fixed point
    uint16 private constant REQUIRES_PREV_MAVG = 0;

    struct QuantAMMMeanReversionLocals {
        int256[] kappaStore;
        int256[] newWeights;
        int256[] signals;
        int256 normalizationFactor;
        uint256 prevWeightLength;
        bool useRawPrice;
        uint i;
        int256 denominator;
        int256 sumKappa;
        int256 res;
        int256 width;
        int256 amplitude;
        int256 exponent;
    }

    function _getWeights(
        int256[] calldata _prevWeights,
        int256[] calldata _data,
        int256[][] calldata _parameters,
        QuantAMMPoolParameters memory _poolParameters
    ) internal override returns (int256[] memory newWeightsConverted) {
        QuantAMMMeanReversionLocals memory locals;

        locals.kappaStore = _parameters[0];
        locals.width = _parameters[1][0];
        locals.amplitude = _parameters[2][0];
        locals.exponent = _parameters[3][0];
        
        locals.useRawPrice = false;
        if (_parameters.length > 4) {
            locals.useRawPrice = _parameters[4][0] == ONE;
        }

        _poolParameters.numberOfAssets = _prevWeights.length;
        locals.prevWeightLength = _prevWeights.length;
        
        // Calculate gradients
        locals.newWeights = _calculateQuantAMMGradient(_data, _poolParameters);
        locals.signals = new int256[](locals.prevWeightLength);

        // Calculate signals for each asset
        for (locals.i = 0; locals.i < locals.prevWeightLength;) {
            locals.denominator = _poolParameters.movingAverage[locals.i];
            if (locals.useRawPrice) {
                locals.denominator = _data[locals.i];
            }

            int256 priceGradient = ONE.div(locals.denominator).mul(locals.newWeights[locals.i]);
            
            // Calculate envelope: exp(-(price_gradient^2)/(2 * width^2))
            int256 gradientSquared = priceGradient.mul(priceGradient);
            int256 widthSquared = locals.width.mul(locals.width);
            int256 envelope = PRBMathSD59x18.exp(-(gradientSquared.div(widthSquared.mul(2 * ONE))));
            
            // Calculate scaled price gradient: π * price_gradient / (3 * width)
            int256 scaledGradient = PI.mul(priceGradient).div(locals.width.mul(3 * ONE));
            
            // Channel portion calculation
            int256 cubicTerm = scaledGradient.mul(scaledGradient).mul(scaledGradient).div(6 * ONE);
            int256 channelPortion = locals.amplitude.mul(envelope).mul(
                scaledGradient - cubicTerm
            ).div(INV_SCALING);
            channelPortion = -channelPortion; // Negative for mean reversion
            
            // Trend portion calculation
            int256 trendPortion;
            {
                int256 sign = priceGradient >= 0 ? ONE : -ONE;
                int256 scaledAbs = priceGradient.abs().mul(ONE).div(2 * PRE_EXP_SCALING);
                int256 powered = PRBMathSD59x18.pow(scaledAbs, locals.exponent);
                trendPortion = (ONE - envelope).mul(sign).mul(powered).div(ONE);
            }
            
            // Combine portions
            locals.signals[locals.i] = channelPortion + trendPortion;
            
            // Calculate normalization factor
            if (locals.kappaStore.length == 1) {
                locals.normalizationFactor += locals.signals[locals.i];
            } else {
                locals.normalizationFactor += locals.signals[locals.i].mul(locals.kappaStore[locals.i]);
            }

            unchecked {
                ++locals.i;
            }
        }

        newWeightsConverted = new int256[](locals.prevWeightLength);

        // Apply kappa and normalize
        if (locals.kappaStore.length == 1) {
            locals.normalizationFactor /= int256(locals.prevWeightLength);
            
            for (locals.i = 0; locals.i < locals.prevWeightLength;) {
                int256 res = int256(_prevWeights[locals.i]) +
                    locals.kappaStore[0].mul(locals.signals[locals.i] - locals.normalizationFactor);
                newWeightsConverted[locals.i] = res;
                
                unchecked {
                    ++locals.i;
                }
            }
        } else {
            int256 sumKappa;
            for (locals.i = 0; locals.i < locals.kappaStore.length;) {
                sumKappa += locals.kappaStore[locals.i];
                unchecked {
                    ++locals.i;
                }
            }

            locals.normalizationFactor = locals.normalizationFactor.div(sumKappa);

            for (locals.i = 0; locals.i < _prevWeights.length;) {
                locals.res = int256(_prevWeights[locals.i]) +
                    locals.kappaStore[locals.i].mul(locals.signals[locals.i] - locals.normalizationFactor);
                require(locals.res >= 0, "Invalid weight");
                newWeightsConverted[locals.i] = locals.res;
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
}