// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { QuantAMMWeightedPool } from "../QuantAMMWeightedPool.sol";

contract MockQuantAMMWeightedPool is QuantAMMWeightedPool {
    // Local storage of weights, so that they can be changed for tests.
    uint256[] private _normalizedWeights;

    //Some tests that use this mock pool want to use the base getters for weights, so they can test the base functionality.
    //This is useful for testing the base functionality of the QuantAMMWeightedPool, without having to deploy a real QuantAMMWeightedPool.
    bool public useBaseGets;

    constructor(NewPoolParams memory params, IVault vault) QuantAMMWeightedPool(params, vault) {
        _normalizedWeights = new uint256[](params.numTokens);
    }

    function setUseBaseGets(bool _useBaseGets) external {
        useBaseGets = _useBaseGets;
    }

    function setNormalizedWeight(uint256 tokenIndex, uint256 newWeight) external {
        if (tokenIndex < _normalizedWeights.length) {
            _normalizedWeights[tokenIndex] = newWeight;
        }
    }

    // Helper for most common case of setting weights - for two token pools.
    function setNormalizedWeights(uint256[2] memory newWeights) external {
        require(newWeights[0] + newWeights[1] == FixedPoint.ONE, "Weights don't total 1");

        _normalizedWeights[0] = newWeights[0];
        _normalizedWeights[1] = newWeights[1];
    }

    // Helper for most common case of setting weights - for two token pools.
    function setNormalizedWeights(uint256[] memory newWeights) external {
        _normalizedWeights = newWeights;
    }

    function _getNormalizedWeight(uint256 tokenIndex, uint256 x, uint256 y) internal view override returns (uint256) {
        if (useBaseGets) {
            return super._getNormalizedWeight(tokenIndex, x, y);
        }
        if (tokenIndex < _normalizedWeights.length) {
            return _normalizedWeights[tokenIndex];
        } else {
            revert IVaultErrors.InvalidToken();
        }
    }

    function _getNormalizedWeights() internal view override returns (uint256[] memory) {
        if (useBaseGets) {
            return super._getNormalizedWeights();
        }
        return _normalizedWeights;
    }

    /// @notice Get the normalised weights for a pair of tokens
    /// @param tokenIndexOne The index of the first token
    /// @param tokenIndexTwo The index of the second token
    function _getNormalisedWeightPair(
        uint256 tokenIndexOne,
        uint256 tokenIndexTwo,
        uint256 x,
        uint256 y
    ) internal view override returns (QuantAMMNormalisedTokenPair memory) {
        if (useBaseGets) {
            return super._getNormalisedWeightPair(tokenIndexOne, tokenIndexTwo, x, y);
        }

        if (tokenIndexOne < _normalizedWeights.length && tokenIndexTwo < _normalizedWeights.length) {
            return QuantAMMNormalisedTokenPair(_normalizedWeights[tokenIndexOne], _normalizedWeights[tokenIndexTwo]);
        } else {
            revert IVaultErrors.InvalidToken();
        }
    }
}
