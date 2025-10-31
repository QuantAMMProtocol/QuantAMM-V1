// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IReceiver } from "@chainlink/contracts/src/v0.8/keystone/interfaces/IReceiver.sol";
import { OwnerIsCreator } from "@chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import { ITypeAndVersion } from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";

import { IERC165 } from "@openzeppelin/contracts@5.0.2/interfaces/IERC165.sol";
import { IERC20 } from "@openzeppelin/contracts@5.0.2/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts@5.0.2/token/ERC20/utils/SafeERC20.sol";

import { IUpdateWeightRunner } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IUpdateWeightRunner.sol";

contract CreAuthWrapper is IReceiver, ITypeAndVersion, OwnerIsCreator {
    using SafeERC20 for IERC20;

    constructor(address updateWeightRunnerAddress) OwnerIsCreator() {
        updateWeightRunner = IUpdateWeightRunner(updateWeightRunnerAddress);
    }

    IUpdateWeightRunner public immutable updateWeightRunner;

    string public constant override typeAndVersion = "CreAuthWrapper 1.0.0";

    // solhint-disable-next-line
    uint256 public constant override version = 1;

    /// Cache State

    struct WorkflowMetadata {
        address allowedSender; // ─╮ Address of the allowed sender
        address allowedWorkflowOwner; // ─╮ Address of the workflow owner
        bytes10 allowedWorkflowName; // ──╯ Name of the workflow
    }

    struct FeedConfig {
        // DataId.
        string description; // Description of the BTF that is used
        WorkflowMetadata[] workflowMetadata; // Metadata for the feed
    }

    /// Addresses that are permitted to configure all feeds
    mapping(address feedAdmin => bool isFeedAdmin) private s_feedAdmins;

    mapping(address poolId => FeedConfig) private s_feedConfigs;

    mapping(bytes32 poolHash => bool) private s_writePermissions;

    event FeedConfigRemoved(address indexed pool);
    event TargetWeightsForwarded(address indexed pool, address sender, address workflowOwner, bytes10 workflowName);
    event FeedAdminSet(address indexed feedAdmin, bool indexed isAdmin);
    event InvalidUpdatePermission(address indexed pool, address sender, address workflowOwner, bytes10 workflowName);
    error ArrayLengthMismatch();
    error EmptyConfig();
    error FeedNotConfigured(address pool);
    error InvalidAddress(address addr);
    error InvalidWorkflowName(bytes10 workflowName);
    error UnauthorizedCaller(address caller);
    error NoMappingForSender(address proxy);

    modifier onlyFeedAdmin() {
        if (!s_feedAdmins[msg.sender]) revert UnauthorizedCaller(msg.sender);
        _;
    }

    /// ================================================================
    /// @notice Get the workflow metadata of a feed
    /// @param pool The address of the pool for the feed
    /// @param startIndex The cursor to start fetching the metadata from
    /// @param maxCount The number of metadata to fetch
    /// @return workflowMetadata The metadata of the feed
    function getFeedMetadata(
        address pool,
        uint256 startIndex,
        uint256 maxCount
    ) external view returns (WorkflowMetadata[] memory workflowMetadata) {
        FeedConfig storage feedConfig = s_feedConfigs[pool];

        uint256 workflowMetadataLength = feedConfig.workflowMetadata.length;

        if (workflowMetadataLength == 0) {
            revert FeedNotConfigured(pool);
        }

        if (startIndex >= workflowMetadataLength) return new WorkflowMetadata[](0);
        uint256 endIndex = startIndex + maxCount;
        endIndex = endIndex > workflowMetadataLength || maxCount == 0 ? workflowMetadataLength : endIndex;

        workflowMetadata = new WorkflowMetadata[](endIndex - startIndex);
        for (uint256 idx; idx < workflowMetadata.length; idx++) {
            workflowMetadata[idx] = feedConfig.workflowMetadata[idx + startIndex];
        }

        return workflowMetadata;
    }

    /// @notice Checks to see if this data ID, msg.sender, workflow owner, and workflow name are permissioned
    /// @param pool The address of the pool for the feed
    /// @param workflowMetadata workflow metadata
    function checkFeedPermission(
        address pool,
        WorkflowMetadata memory workflowMetadata
    ) external view returns (bool hasPermission) {
        bytes32 permission = _createPoolHash(
            pool,
            workflowMetadata.allowedSender,
            workflowMetadata.allowedWorkflowOwner,
            workflowMetadata.allowedWorkflowName
        );
        return s_writePermissions[permission];
    }

    // ================================================================
    // │                  Contract Config Interface                   │
    // ================================================================

    /// @notice Initializes the config for a pool feed
    /// @param pools The addresses of the pools to configure
    /// @param descriptions The descriptions of the feeds
    /// @param workflowMetadata List of workflow metadata (owners, senders, and names) for every feed
    function setPoolFeedConfigs(
        address[] calldata pools,
        string[] calldata descriptions,
        WorkflowMetadata[] calldata workflowMetadata
    ) external onlyFeedAdmin {
        if (workflowMetadata.length == 0 || pools.length == 0) {
            revert EmptyConfig();
        }

        if (pools.length != descriptions.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i; i < pools.length; ++i) {
            address pool = pools[i];
            if (pool == address(0)) revert InvalidAddress(pool);
            FeedConfig storage feedConfig = s_feedConfigs[pool];

            if (feedConfig.workflowMetadata.length > 0) {
                // Feed is already configured, remove the previous config
                for (uint256 j; j < feedConfig.workflowMetadata.length; ++j) {
                    WorkflowMetadata memory feedCurrentWorkflowMetadata = feedConfig.workflowMetadata[j];
                    bytes32 poolHash = _createPoolHash(
                        pool,
                        feedCurrentWorkflowMetadata.allowedSender,
                        feedCurrentWorkflowMetadata.allowedWorkflowOwner,
                        feedCurrentWorkflowMetadata.allowedWorkflowName
                    );
                    delete s_writePermissions[poolHash];
                }

                delete s_feedConfigs[pool];

                emit FeedConfigRemoved(pool);
            }

            for (uint256 j; j < workflowMetadata.length; ++j) {
                WorkflowMetadata memory feedWorkflowMetadata = workflowMetadata[j];
                // Do those checks only once for the first data id
                if (i == 0) {
                    if (feedWorkflowMetadata.allowedSender == address(0)) {
                        revert InvalidAddress(feedWorkflowMetadata.allowedSender);
                    }
                    if (feedWorkflowMetadata.allowedWorkflowOwner == address(0)) {
                        revert InvalidAddress(feedWorkflowMetadata.allowedWorkflowOwner);
                    }
                    if (feedWorkflowMetadata.allowedWorkflowName == bytes10(0)) {
                        revert InvalidWorkflowName(feedWorkflowMetadata.allowedWorkflowName);
                    }
                }

                bytes32 poolHash = _createPoolHash(
                    pool,
                    feedWorkflowMetadata.allowedSender,
                    feedWorkflowMetadata.allowedWorkflowOwner,
                    feedWorkflowMetadata.allowedWorkflowName
                );
                s_writePermissions[poolHash] = true;
                feedConfig.workflowMetadata.push(feedWorkflowMetadata);
            }

            feedConfig.description = descriptions[i];
        }
    }

    /// @notice Removes feeds and all associated data, for a set of feeds
    /// @param pools And array of data IDs to delete the data and configs of
    function removeFeedConfigs(address[] calldata pools) external onlyFeedAdmin {
        for (uint256 i; i < pools.length; ++i) {
            address pool = pools[i];
            if (s_feedConfigs[pool].workflowMetadata.length == 0) revert FeedNotConfigured(pool);

            for (uint256 j; j < s_feedConfigs[pool].workflowMetadata.length; ++j) {
                WorkflowMetadata memory feedWorkflowMetadata = s_feedConfigs[pool].workflowMetadata[j];
                bytes32 poolHash = _createPoolHash(
                    pool,
                    feedWorkflowMetadata.allowedSender,
                    feedWorkflowMetadata.allowedWorkflowOwner,
                    feedWorkflowMetadata.allowedWorkflowName
                );
                delete s_writePermissions[poolHash];
            }

            delete s_feedConfigs[pool];

            emit FeedConfigRemoved(pool);
        }
    }

    /// @notice Sets a feed admin for all feeds, only callable by the Owner
    /// @param feedAdmin The feed admin
    function setFeedAdmin(address feedAdmin, bool isAdmin) external onlyOwner {
        if (feedAdmin == address(0)) revert InvalidAddress(feedAdmin);

        s_feedAdmins[feedAdmin] = isAdmin;
        emit FeedAdminSet(feedAdmin, isAdmin);
    }

    /// @notice Returns a bool is an address has feed admin permission for all feeds
    /// @param feedAdmin The feed admin
    /// @return isFeedAdmin bool if the address is the feed admin for all feeds
    function isFeedAdmin(address feedAdmin) external view returns (bool) {
        return s_feedAdmins[feedAdmin];
    }

    // ================================================================
    // │                        Helper Methods                        │
    // ================================================================

    /// @notice Extracts the workflow name and the workflow owner from the metadata parameter of onReport
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

    /// @notice Creates a pool hash used to permission write access
    /// @param poolId The pool ID for the feed
    /// @param sender The msg.sender of the transaction calling into onpool
    /// @param workflowOwner The owner of the workflow
    /// @param workflowName The name of the workflow
    /// @return poolHash The keccak256 hash of the abi.encoded inputs
    function _createPoolHash(
        address pool,
        address sender,
        address workflowOwner,
        bytes10 workflowName
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(pool, sender, workflowOwner, workflowName));
    }

    /// @notice Wrapper that verifies metadata and write permissions, then forwards to UpdateWeightRunner.setTargetWeightManually.
    function setTargetWeightManuallyWithMeta(
        int256[] calldata _weights, // 1e18-scaled, non-negative
        address _poolAddress,
        uint40 _lastInterpolationTimePossible,
        uint256 _numberOfAssets,
        WeightUpdateMeta calldata _meta
    ) external {
        (address workflowOwner, bytes10 workflowName) = _getWorkflowMetaData(_meta);

        bytes32 permission = _createPoolHash(
            _poolAddress,
            msg.sender,
            workflowOwner,
            workflowName
        );

        if (!s_writePermissions[permission]) {
            emit InvalidUpdatePermission(_poolAddress, msg.sender, workflowOwner, workflowName);
            revert UnauthorizedCaller(msg.sender);
        }

        // 6) Forward the call to the UpdateWeightRunner
        _updateWeightRunner.setTargetWeightManually(_weights, _poolAddress, _lastInterpolationTimePossible, _numberOfAssets);

        emit TargetWeightsForwarded(
            _poolAddress,
            msg.sender,
            workflowOwner,
            workflowName
        );
    }
}
