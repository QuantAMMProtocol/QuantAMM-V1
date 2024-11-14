// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@prb/math/contracts/PRBMathSD59x18.sol";
import "./QuantAMMStorage.sol";
import "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IUpdateRule.sol";
import "./DaoOperations.sol";
import "./UpdateWeightRunner.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
/*
ARCHITECTURE DESIGN NOTES

Most of this functionality could be in the vault contract but it would push the contract size over the limit.

The vault administration contract is responsible for the following:
- setting the protocol trading fee
- setting the protocol trading fee receiving address
- setting the protocol fixed withdrawal fee
- setting the protocol fixed withdrawal fee receiving address
- setting the min and max trading fees for the protocol
- setting the min and max fixed withdrawal fees for the protocol
- setting the non protocol fees being charged by a pool
- diluting a pool

Only fixed addresses of the base and update weight runner are allowed to call these functions.
While there is a small race condition possible during deployment, if someone does come in with a different address all that is required is a redeployment. 


*/
/// @title QuantAMM base administration contract for low frequency, high impact admin calls to the base
/// @notice Responsible for considerable critical setting management. Separated from the base contract due to contract size limits.
contract QuantAMMBaseAdministration is DaoOperations, ScalarQuantAMMBaseStorage, Ownable2Step {
    event UpdateWeightRunnerUpdated(address indexed pool, address indexed newUpdateWeightRunner, address indexed caller);
    event UpdateWeightRunnerAddressUpdated(address indexed oldAddress, address indexed newAddress);

    /// @notice Address of the contract that will be allowed to update weights
    address public updateWeightRunner;

    TimelockController private timelock;
    
    constructor(
        address _daoRunner,
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors
    ) DaoOperations(_daoRunner) Ownable(msg.sender) {
        timelock = new TimelockController(minDelay, proposers, executors, msg.sender);

        // Grant ownership to the timelock
        transferOwnership(address(timelock));

        for (uint256 i = 0; i < proposers.length; i++) {
            timelock.grantRole(timelock.PROPOSER_ROLE(), proposers[i]);
        }

        for (uint256 i = 0; i < executors.length; i++) {
            timelock.grantRole(timelock.EXECUTOR_ROLE(), executors[i]);
        }
    }

    // Modifier to check for EXECUTOR_ROLE using `timelock`
    modifier onlyExecutor() {
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), msg.sender), "Not an executor");
        _;
    }

    /// @notice one time only call during deployment to set the update weight runner address
    /// @param _updateWeightRunner the address of the update weight runner
    function setUpdateWeightRunnerAddress(address _updateWeightRunner) public onlyExecutor() {
        require(updateWeightRunner == address(0), "Update weight runner already set");
        require(_updateWeightRunner != address(0), "address cannot be default");
        updateWeightRunner = _updateWeightRunner;
        emit UpdateWeightRunnerAddressUpdated(address(0), _updateWeightRunner);
    }

    /// @notice set the pool weights manually as a break glass function
    /// @param _weights the weights to set that sum to 1 and interpolation values
    /// @param _poolAddress the address of the pool to set the weights for
    /// @param _lastInterpolationTimePossible the last time that the weights can be updated given the block multiplier before one weight hits the guardrail
    function setWeightsManually(
        int256[] calldata _weights,
        address _poolAddress,
        uint40 _lastInterpolationTimePossible
    ) public onlyExecutor() {
        UpdateWeightRunner(updateWeightRunner).setWeightsManually(
            _weights,
            _poolAddress,
            _lastInterpolationTimePossible
        );
        //event emitted in the update weight runner
    }

    function setIntermediateValuesManually(
        int256[] calldata _movingAverages,
        int256[] calldata _intermediateValues,
        address _poolAddress,
        uint numberOfAssets
    ) public onlyExecutor() {
        UpdateWeightRunner(updateWeightRunner).setIntermediateValuesManually(
            _poolAddress,
            _movingAverages,
            _intermediateValues,
            numberOfAssets
        );
        //event emitted in the update weight runner
    }

    /// @notice set the updateweight runner manually as a break glass function
    function setPoolUpdateWeightRunnerManually(address _poolAddress, address _newUpdateWeightRunner) public onlyExecutor(){
        IQuantAMMWeightedPool(_poolAddress).setUpdateWeightRunnerAddress(_newUpdateWeightRunner);
        updateWeightRunner = _newUpdateWeightRunner;
        emit UpdateWeightRunnerUpdated(_poolAddress, _newUpdateWeightRunner, msg.sender);
        //event emitted in the update weight runner
    }
}
