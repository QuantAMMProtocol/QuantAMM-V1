//SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "../UpdateWeightRunner.sol";
import "../rules/UpdateRule.sol";

/// @dev Additionally exposes private fields for testing, otherwise normal update weight runner

contract MockUpdateWeightRunner is UpdateWeightRunner {
    constructor(address _vaultAdmin, address ethOracle) UpdateWeightRunner(_vaultAdmin, ethOracle) {}

    // To allow differentiation in the gas reporter plugin
    function performFirstUpdate(address _pool) external {
        performUpdate(_pool);
    }

    function calculateMultiplierAndSetWeights(int256[] memory oldWeights,
                                              int256[] memory newWeights,
                                              uint40 updateInterval,
                                              uint64 absWeightGuardRail,
                                              address pool) public {
        _calculateMultiplerAndSetWeights(CalculateMuliplierAndSetWeightsLocal({
                    currentWeights: oldWeights, 
                    updatedWeights: newWeights, 
                    updateInterval: int256(int40(updateInterval)), 
                    absoluteWeightGuardRail18: int256(int64(absWeightGuardRail)),
                    poolAddress: pool
                    }));
    }
}
