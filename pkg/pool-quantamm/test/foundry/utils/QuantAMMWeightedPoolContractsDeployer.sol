// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { BaseContractsDeployer } from "@balancer-labs/v3-solidity-utils/test/foundry/utils/BaseContractsDeployer.sol";

import { MockQuantAMMWeightedPool } from "../../../contracts/mock/QuantAMMWeightedPoolMock.sol";
import { QuantAMMWeightedMathMock } from "../../../contracts/mock/QuantAMMWeightedMathMock.sol";
import { QuantAMMWeightedPool } from "../../../contracts/QuantAMMWeightedPool.sol";
import { QuantAMMWeightedPoolFactory } from "../../../contracts/QuantAMMWeightedPoolFactory.sol";

/**
 * @dev This contract contains functions for deploying mocks and contracts related to the "WeightedPool". These functions should have support for reusing artifacts from the hardhat compilation.
 */
contract QuantAMMWeightedPoolContractsDeployer is BaseContractsDeployer {
    string private artifactsRootDir = "artifacts/";

    constructor() {
        // if this external artifact path exists, it means we are running outside of this repo
        if (vm.exists("artifacts/@balancer-labs/v3-pool-quantamm/")) {
            artifactsRootDir = "artifacts/@balancer-labs/v3-pool-quantamm/";
        }
    }

    function deployQuantAMMWeightedPoolFactory(
        IVault vault,
        uint32 pauseWindowDuration,
        string memory factoryVersion,
        string memory poolVersion,
        address updateWeightRunner
    ) internal returns (QuantAMMWeightedPoolFactory) {
        if (reusingArtifacts) {
            return
                QuantAMMWeightedPoolFactory(
                    deployCode(
                        _computeWeightedPath(type(QuantAMMWeightedPoolFactory).name),
                        abi.encode(vault, pauseWindowDuration, factoryVersion, poolVersion, updateWeightRunner)
                    )
                );
        } else {
            return new QuantAMMWeightedPoolFactory(vault, pauseWindowDuration, factoryVersion, poolVersion, updateWeightRunner);
        }
    }

    function deployQuantAMMWeightedMathMock() internal returns (QuantAMMWeightedMathMock) {
        if (reusingArtifacts) {
            return QuantAMMWeightedMathMock(deployCode(_computeWeightedPathTest(type(QuantAMMWeightedMathMock).name), ""));
        } else {
            return new QuantAMMWeightedMathMock();
        }
    }

    function deployQuantAMMWeightedPoolMock(
        QuantAMMWeightedPool.NewPoolParams memory params,
        IVault vault
    ) internal returns (MockQuantAMMWeightedPool) {
        if (reusingArtifacts) {
            return
                MockQuantAMMWeightedPool(
                    deployCode(_computeWeightedPathTest(type(MockQuantAMMWeightedPool).name), abi.encode(params, vault))
                );
        } else {
            return new MockQuantAMMWeightedPool(params, vault);
        }
    }

    function _computeWeightedPath(string memory name) private view returns (string memory) {
        return string(abi.encodePacked(artifactsRootDir, "contracts/", name, ".sol/", name, ".json"));
    }

    function _computeWeightedPathTest(string memory name) private view returns (string memory) {
        return string(abi.encodePacked(artifactsRootDir, "contracts/test/", name, ".sol/", name, ".json"));
    }
}
