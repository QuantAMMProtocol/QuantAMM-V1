// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IReceiver } from "@chainlink/contracts/src/v0.8/keystone/interfaces/IReceiver.sol";
import { ITypeAndVersion } from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { CreReceiver } from "./CreReceiver.sol";
import { IUpdateRule } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IUpdateRule.sol"; // Ensure this path is correct
import { UpdateWeightRunner } from "../UpdateWeightRunner.sol";
import { QuantAMMMathGuard } from "./base/QuantammMathGuard.sol";
import { IQuantAMMWeightedPool } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IQuantAMMWeightedPool.sol";

/// @title The Wrapper needed to bridge between CRE auth and update weighr runner
/// @dev CRE has a single address per chain that can execute functions.
///      While this means that msg.sender can be constant it also means anyone can setup
///      a CRE workflow and it will trigger from the same msg.sender.
///      The metadata is set by the workflow sender and cannot be manipulated.
///      Checking the metadata as well as the msg.sender means that the auth is complete
contract CreUpdateRule is QuantAMMMathGuard, CreReceiver, ITypeAndVersion, IUpdateRule {
    constructor(address updateWeightRunnerAddress) CreReceiver() {
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
    event UpdateWeightRunnerChanged(address indexed newAddress, address indexed oldAddress, address indexed changer);

    error InvalidAddress(address addr);
    error NotImplemented(address sender);

    /// @notice Sets the UpdateWeightRunner contract address. Admin breakglass feature available to owner only.
    /// @param updateWeightRunnerAddress The address of the UpdateWeightRunner contract
    function setUpdateWeightRunner(address updateWeightRunnerAddress) external onlyOwner {
        if (updateWeightRunnerAddress == address(0)) {
            revert InvalidAddress(updateWeightRunnerAddress);
        }
        address oldAddress = address(updateWeightRunner);

        updateWeightRunner = UpdateWeightRunner(updateWeightRunnerAddress);
        emit UpdateWeightRunnerChanged(updateWeightRunnerAddress, oldAddress, msg.sender);
    }

    function _processReport(bytes calldata report) internal virtual override {
        //Cannot change the process report structure however for testing we need to have a internal memory wrapper
        _processReportMemory(report);
    }

    function _processReportMemory(bytes memory report) internal virtual {
        UpdateWeightRunner.CalculateMuliplierAndSetWeightsLocal memory local;

        WorkflowMetadata memory meta = abi.decode(report, (WorkflowMetadata));

        //as the pool address is part of the report, make sure that the rule doesnt call another pool
        if (meta.poolAddress == address(0) || address(updateWeightRunner.rules(meta.poolAddress)) != address(this)) {
            revert InvalidAddress(meta.poolAddress);
        }

        uint256[] memory currentWeights = IQuantAMMWeightedPool(meta.poolAddress).getNormalizedWeights();
        local.currentWeights = new int256[](currentWeights.length);

        require(currentWeights.length == meta.weights.length, "WRONGLENGTH");
        UpdateWeightRunner.PoolRuleSettings memory poolSettings = updateWeightRunner.getPoolRuleSettings(
            meta.poolAddress
        );

        local.poolAddress = meta.poolAddress;
        local.updateInterval = int256(uint256(poolSettings.timingSettings.updateInterval));

        int256[] memory updated = new int256[](meta.weights.length);

        for (uint256 i = 0; i < meta.weights.length; ++i) {
            local.currentWeights[i] = int256(currentWeights[i]);
            updated[i] = int256(meta.weights[i]);
        }

        //Guard weights is done in the base contract so regardless of the rule the logic will always be executed
        int256[] memory guardedWeights = _guardQuantAMMWeights(
            updated,
            local.currentWeights,
            int128(uint128(poolSettings.epsilonMax)),
            int128(uint128(poolSettings.absoluteWeightGuardRail))
        );

        //current weights always the block weights
        //updated weights are used to determine what the multipliers should be
        local.updatedWeights = guardedWeights;

        updateWeightRunner.calculateMultiplierAndSetWeightsFromRule(local);

        emit TargetWeightsForwarded(local.poolAddress, msg.sender);
    }

    function CalculateNewWeights(
        int256[] calldata,
        int256[] memory,
        address,
        int256[][] calldata,
        uint64[] calldata,
        uint64,
        uint64
    ) external override view returns (int256[] memory) {
        //throw not silently pass as this is for the standard perform update call. CRE takes over this function
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
        //all parametisation should be within CRE workflow
    }

    function validParameters(int256[][] calldata) external pure override returns (bool) {
        // No parameters to validate in this wrapper. Again called during initialisation so dont want it to throw.
        return true;
    }
}
