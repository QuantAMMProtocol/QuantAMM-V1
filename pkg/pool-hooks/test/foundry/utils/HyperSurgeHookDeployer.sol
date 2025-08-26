// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { HyperSurgeHookMock } from "../../../contracts/test/HyperSurgeHookMock.sol";

/// @notice Deployer that instantiates the HyperSurgeHookMock.
/// @dev Mirrors your StableSurgeHookDeployer pattern so tests can share setup code.
abstract contract HyperSurgeHookDeployer {
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

    uint256[] internal weights;

    function setWeights(uint256[] memory newWeights) external {
        weights = newWeights;
    }
}
