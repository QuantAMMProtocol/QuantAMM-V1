// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ITypeAndVersion } from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IUpdateWeightRunner } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IUpdateWeightRunner.sol";

contract TruflationCreAuthWrapper is ITypeAndVersion, Ownable {
    constructor(
        address updateWeightRunnerAddress,
        int256[] memory fullInflationRegimeWeight,
        int256[] memory mixedInflationRegimeWeight,
        int256[] memory noInflationRegimeWeight
    ) Ownable(msg.sender) {
        updateWeightRunner = IUpdateWeightRunner(updateWeightRunnerAddress);

        require(fullInflationRegimeWeight.length == 2, "Invalid Full inflation regime weight");
        require(mixedInflationRegimeWeight.length == 2, "Invalid Mixed inflation regime weight");
        require(noInflationRegimeWeight.length == 2, "Invalid No inflation regime weight");

        BTC_FULL_INFLATION_REGIME_WEIGHT = fullInflationRegimeWeight[0];
        USDC_FULL_INFLATION_REGIME_WEIGHT = fullInflationRegimeWeight[1];
        BTC_MIXED_INFLATION_REGIME_WEIGHT = mixedInflationRegimeWeight[0];
        USDC_MIXED_INFLATION_REGIME_WEIGHT = mixedInflationRegimeWeight[1];
        BTC_NO_INFLATION_REGIME_WEIGHT = noInflationRegimeWeight[0];
        USDC_NO_INFLATION_REGIME_WEIGHT = noInflationRegimeWeight[1];
    }

    IUpdateWeightRunner public updateWeightRunner;

    uint40 public lastInterpolationTimePossible;

    string public constant override typeAndVersion = "CreAuthWrapper 1.0.0";

    int256 public immutable BTC_FULL_INFLATION_REGIME_WEIGHT;
    int256 public immutable USDC_FULL_INFLATION_REGIME_WEIGHT;
    int256 public immutable BTC_MIXED_INFLATION_REGIME_WEIGHT;
    int256 public immutable USDC_MIXED_INFLATION_REGIME_WEIGHT;
    int256 public immutable BTC_NO_INFLATION_REGIME_WEIGHT;
    int256 public immutable USDC_NO_INFLATION_REGIME_WEIGHT;

    struct WorkflowMetadata {
        address allowedSender;
        address allowedWorkflowOwner;
        bytes10 allowedWorkflowName;
    }

    bytes32 public s_writePermission;

    event WritePermissionRemoved(bytes32 indexed pool);
    event TargetWeightsForwarded(
        uint indexed regime,
        address indexed pool,
        address sender,
        address workflowOwner,
        bytes10 workflowName
    );
    event WriteAdminSet(address indexed feedAdmin, bool indexed isAdmin);
    event InvalidUpdatePermission(address indexed pool, address sender, address workflowOwner, bytes10 workflowName);

    error EmptyConfig();
    error InvalidAddress(address addr);
    error InvalidWorkflowName(bytes10 workflowName);
    error UnauthorizedCaller(address caller);

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

        return s_writePermission == permission;
    }

    /// @notice Sets the UpdateWeightRunner contract address. Admin breakglass feature available to owner only.
    /// @param updateWeightRunnerAddress The address of the UpdateWeightRunner contract
    function setUpdateWeightRunner(address updateWeightRunnerAddress) external onlyOwner {
        require(updateWeightRunnerAddress != address(0), "INVADDR");
        updateWeightRunner = IUpdateWeightRunner(updateWeightRunnerAddress);
    }

    /// @notice Initializes the config for a pool feed
    /// @param pool The address of the pool for the feed
    /// @param workflowMetadata List of workflow metadata (owners, senders, and names) for every feed
    function setWriteConfig(address pool, WorkflowMetadata calldata workflowMetadata) external onlyOwner {
        if (workflowMetadata.allowedSender == address(0)) {
            revert InvalidAddress(workflowMetadata.allowedSender);
        }
        if (workflowMetadata.allowedWorkflowOwner == address(0)) {
            revert InvalidAddress(workflowMetadata.allowedWorkflowOwner);
        }
        if (workflowMetadata.allowedWorkflowName == bytes10(0)) {
            revert InvalidWorkflowName(workflowMetadata.allowedWorkflowName);
        }

        bytes32 poolHash = _createPoolHash(
            pool,
            workflowMetadata.allowedSender,
            workflowMetadata.allowedWorkflowOwner,
            workflowMetadata.allowedWorkflowName
        );

        s_writePermission = poolHash;

        emit WriteAdminSet(workflowMetadata.allowedSender, true);
    }

    /// @notice Removes the write permission config for a pool feed
    function removeWritePermissionConfig() external onlyOwner {
        if (s_writePermission == bytes32(0)) {
            revert EmptyConfig();
        }

        emit WritePermissionRemoved(s_writePermission);

        s_writePermission = bytes32(0);
    }

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
        address poolId,
        address sender,
        address workflowOwner,
        bytes10 workflowName
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, sender, workflowOwner, workflowName));
    }

    enum InflationRegime {
        BTC_INFLATION,
        MIXED_INFLATION,
        NO_INFLATION
    }

    function setTargetWeightsByRegimeWithMeta(
        uint newRegime,
        address _poolAddress,
        int256[] calldata _weights,
        bytes calldata _meta
    ) external {
        require(
            newRegime == uint(InflationRegime.BTC_INFLATION) ||
                newRegime == uint(InflationRegime.MIXED_INFLATION) ||
                newRegime == uint(InflationRegime.NO_INFLATION),
            "INVALID_REGIME"
        );

        (address workflowOwner, bytes10 workflowName) = _getWorkflowMetaData(_meta);

        bytes32 permission = _createPoolHash(_poolAddress, msg.sender, workflowOwner, workflowName);

        if (s_writePermission != permission) {
            emit InvalidUpdatePermission(_poolAddress, msg.sender, workflowOwner, workflowName);
            revert UnauthorizedCaller(msg.sender);
        }

        if (newRegime == uint40(InflationRegime.BTC_INFLATION)) {
            require(_weights.length == 2, "ARRAY_LENGTH_MISMATCH");
            require(_weights[0] == BTC_FULL_INFLATION_REGIME_WEIGHT, "INVALID_WEIGHT");
            require(_weights[1] == USDC_FULL_INFLATION_REGIME_WEIGHT, "INVALID_WEIGHT");
        } else if (newRegime == uint40(InflationRegime.MIXED_INFLATION)) {
            require(_weights.length == 2, "ARRAY_LENGTH_MISMATCH");
            require(_weights[0] == BTC_MIXED_INFLATION_REGIME_WEIGHT, "INVALID_WEIGHT");
            require(_weights[1] == USDC_MIXED_INFLATION_REGIME_WEIGHT, "INVALID_WEIGHT");
        } else {
            require(_weights.length == 2, "ARRAY_LENGTH_MISMATCH");
            require(_weights[0] == BTC_NO_INFLATION_REGIME_WEIGHT, "INVALID_WEIGHT");
            require(_weights[1] == USDC_NO_INFLATION_REGIME_WEIGHT, "INVALID_WEIGHT");
        }

        updateWeightRunner.setTargetWeightsManually(_weights, _poolAddress, lastInterpolationTimePossible, uint(2));

        emit TargetWeightsForwarded(newRegime, _poolAddress, msg.sender, workflowOwner, workflowName);
    }
}
