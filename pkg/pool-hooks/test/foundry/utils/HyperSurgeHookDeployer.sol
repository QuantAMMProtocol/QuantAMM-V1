// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { HyperSurgeHookMock } from "../../../contracts/test/HyperSurgeHookMock.sol";
import { OracleWrapper } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/OracleWrapper.sol";

/// @notice Deployer that instantiates the HyperSurgeHookMock and (optionally) wires up oracle wrappers.
/// @dev Mirrors your StableSurgeHookDeployer pattern so tests can share setup code.
abstract contract HyperSurgeHookDeployer {
    /// -----------------------------------------------------------------------
    /// Deploy
    /// -----------------------------------------------------------------------
    function deployHook(
        IVault vault,
        uint256 defaultMaxSurgeFeePercentage,
        uint256 defaultThresholdPercentage,
        uint256 defaultCapDeviation,
        string memory version
    ) internal returns (HyperSurgeHookMock hook) {
        hook = new HyperSurgeHookMock(
            vault,
            defaultMaxSurgeFeePercentage,
            defaultThresholdPercentage,
            defaultCapDeviation,
            version
        );
    }

    /// -----------------------------------------------------------------------
    /// Optional helper: batch-configure oracle wrappers per token index
    /// -----------------------------------------------------------------------
    /// @notice Convenience for tests/fixtures to set oracle wrappers for `pool` tokens.
    /// @dev Access control is enforced in the hook (swap fee manager or governance).
    ///      This helper simply builds the typed array and forwards the call.
    function configureOracleWrappers(
        HyperSurgeHookMock hook,
        address pool,
        uint8[] memory tokenIndices,
        address[] memory oracleWrapperAddresses
    ) internal {
        require(tokenIndices.length == oracleWrapperAddresses.length, "HyperSurge: length mismatch");

        // Build the typed OracleWrapper[] in memory from addresses so callers
        // don't need to import the type in every test.
        OracleWrapper[] memory typed = new OracleWrapper[](oracleWrapperAddresses.length);
        for (uint256 i = 0; i < oracleWrapperAddresses.length; ++i) {
            typed[i] = OracleWrapper(oracleWrapperAddresses[i]);
        }

        hook.setTokenOraclesBatch(pool, tokenIndices, typed);
    }

    uint256[] internal weights;

    function setWeights(uint256[] memory newWeights) external {
        weights = newWeights;
    }
}
