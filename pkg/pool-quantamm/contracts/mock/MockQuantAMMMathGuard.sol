// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.24;

import "../rules/base/QuantammMathGuard.sol";

contract MockQuantAMMMathGuard is QuantAMMMathGuard {
    function mockGuardQuantAMMWeights(
        int256[] memory _weights,
        int256[] calldata _prevWeights,
        int256 _epsilonMax,
        int256 _absoluteWeightGuardRail
    ) external pure returns (int256[] memory guardedNewWeights) {
        guardedNewWeights = _guardQuantAMMWeights(_weights, _prevWeights, _epsilonMax, _absoluteWeightGuardRail);
    }

    function mockNormalizeWeightUpdates(
        int256[] memory _prevWeights,
        int256[] memory _newWeights,
        int256 _epsilonMax
    ) external pure returns (int256[] memory normalizedWeights) {
        normalizedWeights = _normalizeWeightUpdates(_prevWeights, _newWeights, _epsilonMax);
    }

    function mockClampWeights(int256[] memory _weights, int256 _absoluteWeightGuardRail)
        external
        pure
        returns (int256[] memory clampedWeights)
    {
        clampedWeights = _clampWeights(_weights, _absoluteWeightGuardRail);
    }
}
