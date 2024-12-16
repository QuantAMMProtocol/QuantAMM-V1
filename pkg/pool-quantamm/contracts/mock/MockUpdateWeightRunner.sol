//SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "../UpdateWeightRunner.sol";
import "../rules/UpdateRule.sol";

/// @dev Additionally exposes private fields for testing, otherwise normal update weight runner

contract MockUpdateWeightRunner is UpdateWeightRunner {
    constructor(address _vaultAdmin, address ethOracle, bool overrideGetData) UpdateWeightRunner(_vaultAdmin, ethOracle) {
        _overrideGetData = overrideGetData;
    }

    bool private _overrideGetData;
    mapping(address => int256[]) public mockPrices;

    // To allow differentiation in the gas reporter plugin
    function performFirstUpdate(address _pool) external {
        performUpdate(_pool);
    }

    function setMockPrices(address _pool, int256[] memory prices) external {
        mockPrices[_pool] = prices;
    }

    function getData(address _pool) public view override returns (int256[] memory outputData) {
        if(_overrideGetData){
            return mockPrices[_pool];
        }
        else{
            return super.getData(_pool);
        }
    }
}
