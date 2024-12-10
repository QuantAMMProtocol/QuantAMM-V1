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

Most of this functionality could be in the QuantAMM Base contract but it would push the contract size over the limit.

setUpdateWeightRunnerAddress
Used during initialisation. There is a little bit of a chicken and egg question here. Obviously this
could lead to deployment attacks in which case we would just scap that deployment and try
again.

setWeightsManually
It could be that a given weight update or a large enough pause requires an update to the weight
and multipliers. This means computation of what the weights and multipliers should be is to be
done offchain.
This is quite extreme and puts the calculation intermediate values that rely on a last weight and
the pool weights off balance. However such a break glass function could be needed if a
calculation has created a multiplier or last block multiplier that is buggy.

setIntermediateValuesManually
This is a less nuclear manual intervention. If a calculation has not been done at the update
interval or a bad calculation has been done at the update interval, and you are expecting the
next update to work as expected then you can set the intermediate values of the calculation and
wait for the next update. As the intermediate value is supposed to incorporate all historical
updates in a weighted way (see estimator wp sections) this means that any change such as a
calculation being down for a while or bad oracle values can be mediated by just updated the
intermediate values.

setPoolUpdateWeightRunnerManually
While interaction between pools and update weight runner is strictly controlled. Given the logic
in the updateweightrunner is not insignificant, an update could be done via this admin function
to patch any potential issue with the updateweight runner itself.

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

    /// @notice set the intermediate values manually as a break glass function
    /// @param _movingAverages the moving averages to set, this should include prev averages if the pool is configured with the prev flag.
    /// @param _intermediateValues the intermediate values to set for the rules
    /// @param _poolAddress the address of the pool to set the intermediate values for
    /// @param numberOfAssets the number of assets in the pool, used for packing and unpacking
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
    /// @param _poolAddress the address of the pool to set the update weight runner for
    /// @param _newUpdateWeightRunner the address of the new update weight runner
    function setPoolUpdateWeightRunnerManually(address _poolAddress, address _newUpdateWeightRunner) public onlyExecutor(){
        IQuantAMMWeightedPool(_poolAddress).setUpdateWeightRunnerAddress(_newUpdateWeightRunner);
        updateWeightRunner = _newUpdateWeightRunner;
        emit UpdateWeightRunnerUpdated(_poolAddress, _newUpdateWeightRunner, msg.sender);
    }

    /// @notice add an oracle to the update weight runner
    /// @param _oracle the address of the oracle to add
    function addOracle(address _oracle) public onlyExecutor {
        UpdateWeightRunner(updateWeightRunner).addOracle(OracleWrapper(_oracle));
        //event emitted in the update weight runner
    }

    /// @notice remove an oracle from the update weight runner
    /// @param _oracle the address of the oracle to remove
    function removeOracle(address _oracle) public onlyExecutor {
        UpdateWeightRunner(updateWeightRunner).removeOracle(OracleWrapper(_oracle));
        //event emitted in the update weight runner
    }

    /// @notice set approved actions for a specific pool in the update weight runner
    /// @param _poolAddress the address of the pool to set the approved actions for
    /// @param _actions the actions to approve
    function setApprovedActionsForPool(address _poolAddress, uint256 _actions) public onlyExecutor {
        UpdateWeightRunner(updateWeightRunner).setApprovedActionsForPool(_poolAddress, _actions);
        //event emitted in the update weight runner
    }

    /// @notice set the ETH/USD oracle in the update weight runner
    /// @param _ethUsdOracle the address of the ETH/USD oracle to set
    function setETHUSDOracle(address _ethUsdOracle) public onlyExecutor {
        UpdateWeightRunner(updateWeightRunner).setETHUSDOracle(_ethUsdOracle);
        //event emitted in the update weight runner
    }
}
