//SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

/// @title DaoOperations contract for QuantAMM DAO operations 
/// @notice Contains the logic for only allowing the DAO to call certain functions 
abstract contract DaoOperations {
    address public immutable daoRunner;

    constructor(address _daoRunner) {
        daoRunner = _daoRunner;
    }

    /// @notice Modifier for only allowing the DAO to call certain functions
    modifier onlyDAO() {
        require(msg.sender == daoRunner, "ONLYDAO"); //Only callable by the DAO
        _;
    }
}
