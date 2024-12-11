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

        parameterDescriptions = new string ;
        parameterDescriptions[0] = "K: Scaling factor for weight updates";
        parameterDescriptions[1] = "Width: Width parameter for the mean reversion channel";
        parameterDescriptions[2] = "Amplitude: Amplitude of the mean reversion effect";
        parameterDescriptions[3] = "Exponents: Exponent for the trend following portion";
        parameterDescriptions[4] = "Inverse scaling factor for the channel portion";
        parameterDescriptions[5] = "Pre-exp scaling factor applied before exponentiation";
    }

    using PRBMathSD59x18 for int256;

    int256 private constant ONE = 1 * 1e18; // Fixed-point representation of 1

    /// @dev Struct to avoid stack too deep issues
    /// @notice Struct to store local variables for the mean reversion calculation
    struct QuantAMMReversionLocals {
        int256[] kStore;
        int256[] newWeights;
        int256 normalizationFactor;
        uint256 assetCount;
        int256[] signal;
        int256 envelope;
        int256 scaledGradient;
        int256 channelPortion;
        int256 trendPortion;
        uint256 i;
    }

    /// @notice Calculates the new weights using the mean reversion channel strategy
    /// @param _prevWeights The previous weights retrieved from the vault
    /// @param _data The latest data from the signal, usually price gradients
    /// @param _parameters The parameters of the rule
    function _getWeights(
        int256[] calldata _prevWeights,
        int256[] calldata _data,
        int256[][] calldata _parameters, // [0]=k, [1]=width, [2]=amplitude, [3]=exponents, [4]=inverseScaling, [5]=preExpScaling
        QuantAMMPoolParameters memory _poolParameters
    ) internal override returns (int256[] memory newWeightsConverted) {
        QuantAMMReversionLocals memory locals;

        locals.kStore = _parameters[0];
        int256 width = _parameters[1][0];
        int256 amplitude = _parameters[2][0];
        int256 exponents = _parameters[3][0];
        int256 inverseScaling = _parameters[4][0];
        int256 preExpScaling = _parameters[5][0];

        locals.assetCount = _prevWeights.length;
        locals.newWeights = new int256[](locals.assetCount);
        locals.signal = new int256[](locals.assetCount);

        for (locals.i = 0; locals.i < locals.assetCount; ) {
            // Envelope: exp(-(price_gradient^2) / (2 * width^2))
            locals.envelope = int256(
                PRBMathSD59x18.exp(
                    -(_data[locals.i].mul(_data[locals.i])).div(width.mul(width).mul(2))
                )
            );

            // Scaled gradient: π * price_gradient / (3 * width)
            locals.scaledGradient = _data[locals.i].mul(3141592653589793238).div(width.mul(3)); // π as 3.141592653589793238e18

            // Channel portion: -amplitude * envelope * (scaledGradient - (scaledGradient^3) / 6) / inverseScaling
            int256 scaledGradientCubed = locals.scaledGradient.mul(locals.scaledGradient).mul(locals.scaledGradient).div(6);
            locals.channelPortion = amplitude
                .mul(locals.envelope)
                .mul(locals.scaledGradient - scaledGradientCubed)
                .div(inverseScaling);

            // Trend portion: (1 - envelope) * sign(price_gradient) * abs(price_gradient / (2.0 * preExpScaling))^exponents
            int256 absGradient = _data[locals.i].abs();
            int256 trendFactor = absGradient.div(preExpScaling.mul(2)).pow(uint256(exponents));
            locals.trendPortion = (ONE - locals.envelope)
                .mul(_data[locals.i] > 0 ? ONE : -ONE) // Sign of price gradient
                .mul(trendFactor);

            // Signal: channelPortion + trendPortion
            locals.signal[locals.i] = locals.channelPortion + locals.trendPortion;

            // Normalization factor for offset calculation
            locals.normalizationFactor += locals.kStore[locals.i].mul(locals.signal[locals.i]);

            unchecked {
                ++locals.i;
            }
        }

        locals.normalizationFactor = locals.normalizationFactor.div(int256(locals.assetCount));

        newWeightsConverted = new int256[](locals.assetCount);
        for (locals.i = 0; locals.i < locals.assetCount; ) {
            // Final weight updates: k * (signal + offset)
            int256 offset = locals.signal[locals.i] - locals.normalizationFactor;
            newWeightsConverted[locals.i] = _prevWeights[locals.i] + locals.kStore[locals.i].mul(offset);

            require(newWeightsConverted[locals.i] >= 0, "Invalid weight");

            unchecked {
                ++locals.i;
            }
        }

        return newWeightsConverted;
    }
}
