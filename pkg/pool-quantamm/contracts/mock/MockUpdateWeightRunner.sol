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
}
