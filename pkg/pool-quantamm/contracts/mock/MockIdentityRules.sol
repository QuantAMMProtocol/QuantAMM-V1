//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IUpdateRule.sol";
import "../rules/UpdateRule.sol";
import "../UpdateWeightRunner.sol";

/// @notice Rule that simply returns the previous weights for testing
contract MockIdentityRule is IUpdateRule {
    /// @notice Flags to control in tests which data should be pulled
    bool queryGradient;

    bool queryCovariances;

    bool queryPrecision;

    bool queryVariances;

    bool public CalculateNewWeightsCalled;

    bytes public gradient;

    bytes public variances;

    bytes public covariances;

    bytes public precision;

    uint16 private constant REQUIRES_PREV_MAVG = 0;

    function CalculateNewWeights(
        int256[] calldata prevWeights,
        int256[] calldata /*data*/,
        address /*pool*/,
        int256[][] calldata /*_parameters*/,
        uint64[] calldata /*lambdaStore*/,
        uint64 /*epsilonMax*/,
        uint64 /* absoluteWeightGuardRail*/
    ) external override returns (int256[] memory /*updatedWeights*/) {
        CalculateNewWeightsCalled = true;
        return new int256[](prevWeights.length);
    }

    function initialisePoolRuleIntermediateValues(
        address poolAddress,
        int256[] memory _newMovingAverages,
        int256[] memory _newParameters,
        uint _numberOfAssets
    ) external override {}

    /// @notice Check if the given parameters are valid for the rule
    function validParameters(
        int256[][] calldata /*parameters*/
    ) external pure override returns (bool) {
        return true;
    }

    function SetCalculateNewWeightsCalled(bool newVal) external {
        CalculateNewWeightsCalled = newVal;
    }

    function setQueryGradient(bool _queryGradient) public {
        queryGradient = _queryGradient;
    }

    function setQueryCovariances(bool _queryCovariances) public {
        queryCovariances = _queryCovariances;
    }

    function setQueryPrecision(bool _queryPrecision) public {
        queryPrecision = _queryPrecision;
    }

    function setQueryVariances(bool _queryVariances) public {
        queryVariances = _queryVariances;
    }
}
