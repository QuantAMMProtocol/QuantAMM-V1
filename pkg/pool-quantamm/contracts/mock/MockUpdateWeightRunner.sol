//SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "../UpdateWeightRunner.sol";
import "../rules/UpdateRule.sol";

/// @dev Additionally exposes private fields for testing, otherwise normal update weight runner

contract MockUpdateWeightRunner is UpdateWeightRunner {
    constructor(address _vaultAdmin, address ethOracle) UpdateWeightRunner(_vaultAdmin, ethOracle) {}

    mapping(address => int256[]) public mockPrices;

    // To allow differentiation in the gas reporter plugin
    function performFirstUpdate(address _pool) external {
        performUpdate(_pool);
    }

    function setMockPrices(address _pool, int256[] memory prices) external {
        mockPrices[_pool] = prices;
    }

    function getData(address _pool) public view override returns (int256[] memory outputData) {
        return mockPrices[_pool];
    }
}
