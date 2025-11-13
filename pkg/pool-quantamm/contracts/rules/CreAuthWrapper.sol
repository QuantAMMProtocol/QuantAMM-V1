// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IReceiver} from "@chainlink/contracts/src/v0.8/keystone/interfaces/IReceiver.sol";
import { ITypeAndVersion } from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ICreReceiver } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/ICreReceiver.sol";
import { IUpdateRule } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IUpdateRule.sol"; // Ensure this path is correct
import { UpdateWeightRunner } from "../UpdateWeightRunner.sol";
import "./base/QuantammMathGuard.sol";

/// @title The Wrapper needed to bridge between CRE auth and update weighr runner
/// @dev CRE has a single address per chain that can execute functions.
///      While this means that msg.sender can be constant it also means anyone can setup
///      a CRE workflow and it will trigger from the same msg.sender.
///      The metadata is set by the workflow sender and cannot be manipulated.
///      Checking the metadata as well as the msg.sender means that the auth is complete
contract CREUpdateRule is QuantAMMMathGuard, ICreReceiver, ITypeAndVersion, IUpdateRule {
    constructor(address updateWeightRunnerAddress) ICreReceiver() {
        updateWeightRunner = UpdateWeightRunner(updateWeightRunnerAddress);
    }

    UpdateWeightRunner public updateWeightRunner;

    string public constant override typeAndVersion = "CreAuthWrapper 1.0.0";

    struct WorkflowMetadata {
        address poolAddress;
        uint256[] weights;
        uint40 lastInterpolationTimePossible;
    }

    event TargetWeightsForwarded(address indexed pool, address sender);

    error InvalidAddress(address addr);
    error NotImplemented(address sender);

    /// @notice Sets the UpdateWeightRunner contract address. Admin breakglass feature available to owner only.
    /// @param updateWeightRunnerAddress The address of the UpdateWeightRunner contract
    function setUpdateWeightRunner(address updateWeightRunnerAddress) external onlyOwner {
        require(updateWeightRunnerAddress != address(0), "INVADDR");
        updateWeightRunner = UpdateWeightRunner(updateWeightRunnerAddress);
    }

    /// @notice The main function that checks the CRE permissions and then passes through the weights
    /// @param _poolAddress target pool address
    /// @param _weights the new target weights
    /// @param _lastInterpolationTimePossible the update interval
    /// @dev this wrapper assumes complete trust in the correct workflow in terms of weights and last interpolation time
    function setTargetWeightsByRegimeWithMeta(
        address _poolAddress,
        int256[] memory _weights,
        uint40 _lastInterpolationTimePossible
    ) internal {
        updateWeightRunner.setTargetWeightsManually(
            _weights,
            _poolAddress,
            _lastInterpolationTimePossible,
            _weights.length
        );
        emit TargetWeightsForwarded(_poolAddress, msg.sender);
    }

    function _processReport(bytes calldata report) internal virtual override {
        WorkflowMetadata memory meta = abi.decode(report, (WorkflowMetadata));
        if (meta.poolAddress == address(0) 
            //as the pool address is part of the report, make sure that the rule doesnt call another pool
            && address(updateWeightRunner.rules(meta.poolAddress)) == address(this)) {
            revert InvalidAddress(meta.poolAddress);
        }
        
        UpdateWeightRunner.CalculateMuliplierAndSetWeightsLocal memory local;
        local.poolAddress = meta.poolAddress;
        local.updateInterval = int256(uint256(meta.lastInterpolationTimePossible));
        local.absoluteWeightGuardRail18 = 0;

        int256[] memory updated = new int256[](meta.weights.length);
        for (uint256 i = 0; i < meta.weights.length; ++i) {
            updated[i] = int256(meta.weights[i]);
        }
         //Guard weights is done in the base contract so regardless of the rule the logic will always be executed
        int256[] memory updatedWeights = _guardQuantAMMWeights(
            updated,
            _prevWeights,
            int128(uint128(_epsilonMax)),
            int128(uint128(_absoluteWeightGuardRail))
        );

        local.updatedWeights = updated;
        local.currentWeights = new int256[](updated.length);

        updateWeightRunner.calculateMultiplierAndSetWeightsFromRule(local);
    }

    function CalculateNewWeights(
        int256[] calldata ,
        int256[] memory ,
        address ,
        int256[][] calldata,
        uint64[] calldata,
        uint64,
        uint64
    ) external override returns (int256[] memory) {
        //throw not silently pass as this if for the standard perform update call. CRE takes over this function
        //this is as intended and why calculateMultiplierAndSetWeightsFromRule exists
        revert NotImplemented(msg.sender);
    }

    function initialisePoolRuleIntermediateValues(
        address _poolAddress,
        int256[] memory _newMovingAverages,
        int256[] memory _newInitialValues,
        uint _numberOfAssets
    ) external override {
        //this is fine to be empty, it will be called during pool creation, the pool and rule will initialise without throwing
    }

    function validParameters(int256[][] calldata ) external view override returns (bool) {
        // No parameters to validate in this wrapper
        return true;
    }
}
