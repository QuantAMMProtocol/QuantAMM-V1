// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    IERC165
} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v5.0.2/contracts/utils/introspection/IERC165.sol";
import { IReceiver } from "@chainlink/contracts/src/v0.8/keystone/interfaces/IReceiver.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title IReceiverTemplate - Abstract receiver with optional permission controls
/// @notice Provides flexible, updatable security checks for receiving workflow reports
/// @dev All permission fields default to zero (disabled). Use setter functions to enable checks.
/// https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts#3-using-ireceivertemplate
abstract contract CreReceiver is IReceiver, Ownable {
    // Optional permission fields (all default to zero = disabled)
    address public forwarderAddress; // If set, only this address can call onReport
    address public expectedAuthor; // If set, only reports from this workflow owner are accepted
    bytes10 public expectedWorkflowName; // If set, only reports with this workflow name are accepted
    bytes32 public expectedWorkflowId; // If set, only reports from this specific workflow ID are accepted

    // Custom errors
    error InvalidSender(address sender, address expected);
    error InvalidAuthor(address received, address expected);
    error InvalidWorkflowName(bytes10 received, bytes10 expected);
    error InvalidWorkflowId(bytes32 received, bytes32 expected);

    event ExpectedAuthorChanged(address indexed newAuthor, address indexed oldAuthor, address indexed changer);
    event ExpectedWorkflowNameChanged(bytes10 indexed newName, bytes10 indexed oldName, address indexed changer);
    event ExpectedWorkflowIdChanged(bytes32 indexed newId, bytes32 indexed oldId, address indexed changer);
    event ForwarderAddressChanged(address indexed newForwarder, address indexed oldForwarder, address indexed changer);

    /// @notice Constructor sets msg.sender as the owner
    /// @dev All permission fields are initialized to zero (disabled by default)
    constructor() Ownable(msg.sender) {}

    /// @inheritdoc IReceiver
    /// @dev Performs optional validation checks based on which permission fields are set
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        // Security Check 1: Verify caller is the trusted Chainlink Forwarder (if configured)
        if (forwarderAddress != address(0) && msg.sender != forwarderAddress) {
            revert InvalidSender(msg.sender, forwarderAddress);
        }

        // Security Checks 2-4: Verify workflow identity - ID, owner, and/or name (if any are configured)
        if (expectedWorkflowId != bytes32(0) || expectedAuthor != address(0) || expectedWorkflowName != bytes10(0)) {
            (bytes32 workflowId, bytes10 workflowName, address workflowOwner) = _decodeMetadata(metadata);

            if (expectedWorkflowId != bytes32(0) && workflowId != expectedWorkflowId) {
                revert InvalidWorkflowId(workflowId, expectedWorkflowId);
            }
            if (expectedAuthor != address(0) && workflowOwner != expectedAuthor) {
                revert InvalidAuthor(workflowOwner, expectedAuthor);
            }
            if (expectedWorkflowName != bytes10(0) && workflowName != expectedWorkflowName) {
                revert InvalidWorkflowName(workflowName, expectedWorkflowName);
            }
        }

        _processReport(report);
    }

    /// @notice Updates the forwarder address that is allowed to call onReport
    /// @param _forwarder The new forwarder address (use address(0) to disable this check)
    function setForwarderAddress(address _forwarder) external onlyOwner {
        address oldForwarder = forwarderAddress;
        forwarderAddress = _forwarder;
        emit ForwarderAddressChanged(_forwarder, oldForwarder, msg.sender);
    }

    /// @notice Updates the expected workflow owner address
    /// @param _author The new expected author address (use address(0) to disable this check)
    function setExpectedAuthor(address _author) external onlyOwner {
        address oldAuthor = expectedAuthor;
        expectedAuthor = _author;
        emit ExpectedAuthorChanged(_author, oldAuthor, msg.sender);
    }

    /// @notice Updates the expected workflow name
    /// @param _name The new expected workflow name (use bytes10(0) to disable this check)
    function setExpectedWorkflowName(bytes10 _name) external onlyOwner {
        bytes10 oldName = expectedWorkflowName;
        expectedWorkflowName = _name;
        emit ExpectedWorkflowNameChanged(_name, oldName, msg.sender);
    }

    /// @notice Updates the expected workflow ID
    /// @param _id The new expected workflow ID (use bytes32(0) to disable this check)
    function setExpectedWorkflowId(bytes32 _id) external onlyOwner {
        bytes32 oldId = expectedWorkflowId;
        expectedWorkflowId = _id;
        emit ExpectedWorkflowIdChanged(_id, oldId, msg.sender);
    }

    /// @notice Extracts all metadata fields from the onReport metadata parameter
    /// @param metadata The metadata in bytes format
    /// @return workflowId The unique identifier of the workflow (bytes32)
    /// @return workflowName The name of the workflow (bytes10)
    /// @return workflowOwner The owner address of the workflow
    function _decodeMetadata(
        bytes memory metadata
    ) internal pure returns (bytes32 workflowId, bytes10 workflowName, address workflowOwner) {
        // Metadata structure:
        // - First 32 bytes: length of the byte array (standard for dynamic bytes)
        // - Offset 32, size 32: workflow_id (bytes32)
        // - Offset 64, size 10: workflow_name (bytes10)
        // - Offset 74, size 20: workflow_owner (address)
        assembly {
            workflowId := mload(add(metadata, 32))
            workflowName := mload(add(metadata, 64))
            workflowOwner := shr(mul(12, 8), mload(add(metadata, 74)))
        }
    }

    /// @notice Abstract function to process the report data
    /// @param report The report calldata containing your workflow's encoded data
    /// @dev Implement this function with your contract's business logic
    function _processReport(bytes calldata report) internal virtual;

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
