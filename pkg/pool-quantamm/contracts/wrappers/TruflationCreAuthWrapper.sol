// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ITypeAndVersion } from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IUpdateWeightRunner } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IUpdateWeightRunner.sol";

/// @title The Wrapper needed to bridge between CRE auth and update weighr runner
/// @dev CRE has a single address per chain that can execute functions.
///      While this means that msg.sender can be constant it also means anyone can setup
///      a CRE workflow and it will trigger from the same msg.sender.
///      The metadata is set by the workflow sender and cannot be manipulated.
///      Checking the metadata as well as the msg.sender means that the auth is complete
contract CREAuthWrapper is ITypeAndVersion, Ownable {
    constructor(address updateWeightRunnerAddress) Ownable(msg.sender) {
        updateWeightRunner = IUpdateWeightRunner(updateWeightRunnerAddress);
    }

    IUpdateWeightRunner public updateWeightRunner;

    string public constant override typeAndVersion = "CreAuthWrapper 1.0.0";

    struct WorkflowMetadata {
        address poolAddress;
        address allowedSender;
        address allowedWorkflowOwner;
        bytes10 allowedWorkflowName;
    }

    WorkflowMetadata public s_writePermission;

    event WritePermissionRemoved(WorkflowMetadata indexed pool);
    event TargetWeightsForwarded(address indexed pool, address sender, address workflowOwner, bytes10 workflowName);
    event WriteAdminSet(address indexed poolAdmin, bool indexed isAdmin);
    event InvalidUpdatePermission(address indexed pool, address sender, address workflowOwner, bytes10 workflowName);

    error EmptyConfig();
    error InvalidAddress(address addr);
    error InvalidWorkflowName(bytes10 workflowName);
    error UnauthorizedCaller(address caller);

    /// @notice Checks to see if this data ID, msg.sender, workflow owner, and workflow name are permissioned
    /// @param workflowMetadata workflow metadata
    function checkCREAuthentication(
        WorkflowMetadata memory workflowMetadata
    ) external view returns (bool hasPermission) {
        return checkCREAuth(workflowMetadata, s_writePermission);
    }

    /// @notice Internal function to check CRE authentication
    /// @param workflowMetadata workflow metadata
    /// @param permissionWorkflowMetaData permissioned workflow metadata by the owner
    /// @return hasPermission boolean indicating if permission is granted
    function checkCREAuth(
        WorkflowMetadata memory workflowMetadata,
        WorkflowMetadata memory permissionWorkflowMetaData
    ) internal pure returns (bool hasPermission) {
        return
            workflowMetadata.allowedSender == permissionWorkflowMetaData.allowedSender &&
            workflowMetadata.allowedWorkflowOwner == permissionWorkflowMetaData.allowedWorkflowOwner &&
            workflowMetadata.allowedWorkflowName == permissionWorkflowMetaData.allowedWorkflowName &&
            workflowMetadata.poolAddress == permissionWorkflowMetaData.poolAddress;
    }

    /// @notice Sets the UpdateWeightRunner contract address. Admin breakglass feature available to owner only.
    /// @param updateWeightRunnerAddress The address of the UpdateWeightRunner contract
    function setUpdateWeightRunner(address updateWeightRunnerAddress) external onlyOwner {
        require(updateWeightRunnerAddress != address(0), "INVADDR");
        updateWeightRunner = IUpdateWeightRunner(updateWeightRunnerAddress);
    }

    /// @notice Initializes the config for a pool
    /// @param workflowMetadata List of workflow metadata (poolAddress, owners, senders, and names)
    function setWriteConfig(WorkflowMetadata calldata workflowMetadata) external onlyOwner {
        if (workflowMetadata.allowedSender == address(0)) {
            revert InvalidAddress(workflowMetadata.allowedSender);
        }
        if (workflowMetadata.allowedWorkflowOwner == address(0)) {
            revert InvalidAddress(workflowMetadata.allowedWorkflowOwner);
        }
        if (workflowMetadata.allowedWorkflowName == bytes10(0)) {
            revert InvalidWorkflowName(workflowMetadata.allowedWorkflowName);
        }

        if (workflowMetadata.poolAddress == address(0)) {
            revert InvalidAddress(workflowMetadata.poolAddress);
        }

        s_writePermission = workflowMetadata;

        emit WriteAdminSet(workflowMetadata.allowedSender, true);
    }

    /// @notice Removes the write permission config for a pool
    function removeWritePermissionConfig() external onlyOwner {
        if (s_writePermission.allowedSender == address(0)) {
            revert EmptyConfig();
        }

        emit WritePermissionRemoved(s_writePermission);

        s_writePermission = WorkflowMetadata({
            poolAddress: address(0),
            allowedSender: address(0),
            allowedWorkflowOwner: address(0),
            allowedWorkflowName: bytes10(0)
        });
    }

    /// @notice Extracts the workflow name and the workflow owner from the metadata parameter of setTargetWeightsByRegimeWithMeta
    /// @param metadata The metadata in bytes format
    /// @return workflowOwner The owner of the workflow
    /// @return workflowName  The name of the workflow
    function _getWorkflowMetaData(bytes memory metadata) internal pure returns (address, bytes10) {
        address workflowOwner;
        bytes10 workflowName;
        // (first 32 bytes contain length of the byte array)
        // workflow_cid             // offset 32, size 32
        // workflow_name            // offset 64, size 10
        // workflow_owner           // offset 74, size 20
        // pool_name              // offset 94, size  2
        assembly {
            // no shifting needed for bytes10 type
            workflowName := mload(add(metadata, 64))
            // shift right by 12 bytes to get the actual value
            workflowOwner := shr(mul(12, 8), mload(add(metadata, 74)))
        }

        return (workflowOwner, workflowName);
    }

    /// @notice The main function that checks the CRE permissions and then passes through the weights
    /// @param _poolAddress target pool address
    /// @param _weights the new target weights
    /// @param _lastInterpolationTimePossible the update interval
    /// @param _meta the CRE metadata required to authenticate
    /// @dev this wrapper assumes complete trust in the correct workflow in terms of weights and last interpolation time
    function setTargetWeightsByRegimeWithMeta(
        address _poolAddress,
        int256[] calldata _weights,
        uint40 _lastInterpolationTimePossible,
        bytes calldata _meta
    ) external {
        (address workflowOwner, bytes10 workflowName) = _getWorkflowMetaData(_meta);

        WorkflowMetadata memory workflowMetadata = WorkflowMetadata({
            poolAddress: _poolAddress,
            allowedSender: msg.sender, //main check against the singleton CRE address
            allowedWorkflowOwner: workflowOwner, //check against rogue workflows
            allowedWorkflowName: workflowName
        });

        if (checkCREAuth(workflowMetadata, s_writePermission)) {
            updateWeightRunner.setTargetWeightsManually(
                _weights,
                _poolAddress,
                _lastInterpolationTimePossible,
                _weights.length
            );
            emit TargetWeightsForwarded(_poolAddress, msg.sender, workflowOwner, workflowName);
        } else {
            emit InvalidUpdatePermission(_poolAddress, msg.sender, workflowOwner, workflowName);
            revert UnauthorizedCaller(msg.sender);
        }
    }
}
