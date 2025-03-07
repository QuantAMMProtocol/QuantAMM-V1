// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.24;

import {
    IWeightedPool,
    WeightedPoolDynamicData,
    WeightedPoolImmutableData
} from "@balancer-labs/v3-interfaces/contracts/pool-weighted/IWeightedPool.sol";
import { ISwapFeePercentageBounds } from "@balancer-labs/v3-interfaces/contracts/vault/ISwapFeePercentageBounds.sol";
import {
    IUnbalancedLiquidityInvariantRatioBounds
} from "@balancer-labs/v3-interfaces/contracts/vault/IUnbalancedLiquidityInvariantRatioBounds.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import {
    SwapKind,
    PoolSwapParams,
    PoolConfig,
    Rounding
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";

import { BalancerPoolToken } from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import { PoolInfo } from "@balancer-labs/v3-pool-utils/contracts/PoolInfo.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { WeightedMath } from "@balancer-labs/v3-solidity-utils/contracts/math/WeightedMath.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { Version } from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";
import { ScalarQuantAMMBaseStorage } from "../QuantAMMStorage.sol";
import { IQuantAMMWeightedPool } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IQuantAMMWeightedPool.sol";
import { ScalarQuantAMMBaseStorage } from "../QuantAMMStorage.sol";
import "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IUpdateRule.sol";
import "../UpdateWeightRunner.sol";

contract MockQuantAMMBasePool is IQuantAMMWeightedPool, IBasePool {
    constructor(uint16 _updateInterval, address _updateWeightRunner) {
        updateInterval = _updateInterval;
        lambda = new uint64[](0);
        epsilonMax = 1 * 1e18; // PRBMathSD69x18 1
        absoluteWeightGuardRail = 1 * 1e18; // PRBMathSD69x18 1
        oracleStalenessThreshold = 10;
        updateWeightRunner = UpdateWeightRunner(_updateWeightRunner);
    }

    int256[] public weights;
    
    
    uint40 public lastInterpolationTimePossible;

    int256[][] public ruleParameters; // Arbitrary parameters that are passed to the rule

    uint64[] public lambda; // Decay parameter for exponentially-weighted moving average (0 < λ < 1), stored as SD59x18 number

    uint64 public immutable epsilonMax; // Maximum allowed delta for a weight update, stored as SD59x18 number

    uint64 public immutable absoluteWeightGuardRail; // Maximum allowed weight for a token, stored as SD59x18 number

    uint64 public immutable updateInterval; // Minimum amount of seconds between two updates

    uint immutable oracleStalenessThreshold;

    address poolAddress;

    uint256 public poolRegistry;

    IERC20[] public assets; // The assets of the pool. If the pool is a composite pool, contains the LP tokens of those pools

    UpdateWeightRunner internal immutable updateWeightRunner;

    function getWeights() external view returns (int256[] memory){
        return weights;
    }
    
    function setWeights(
        int256[][] calldata _weights,
        uint40 _lastInterpolationTimePossible
    ) external override {
        //TODO
        int256[] memory _weightsTwo = new int256[](_weights.length * 2);
        weights = _weightsTwo;
        lastInterpolationTimePossible = _lastInterpolationTimePossible;
    }

    function getMinimumSwapFeePercentage() external view override returns (uint256) {}

    function getMaximumSwapFeePercentage() external view override returns (uint256) {}

    function getMinimumInvariantRatio() external view override returns (uint256) {}

    function getMaximumInvariantRatio() external view override returns (uint256) {}

    bool fixEnabled = true;
    function getWithinFixWindow() external view override returns (bool) {return fixEnabled;}

    function getPoolDetail(string memory category, string memory name) external view returns (string memory, string memory) {}
    
    function computeInvariant(
        uint256[] memory balancesLiveScaled18,
        Rounding rounding
    ) external view override returns (uint256 invariant) {}

    function computeBalance(
        uint256[] memory balancesLiveScaled18,
        uint256 tokenInIndex,
        uint256 invariantRatio
    ) external view override returns (uint256 newBalance) {}

    function onSwap(PoolSwapParams calldata params) external override returns (uint256 amountCalculatedScaled18) {}

    function getNormalizedWeights() external view override returns (uint256[] memory) {

        uint256[] memory normalizedWeights = new uint256[](weights.length / 2);
        for (uint256 i = 0; i < weights.length / 2; i++) {
            normalizedWeights[i] = uint256(weights[i]);
        }
        return normalizedWeights;
    }

    function setInitialWeights(int256[] calldata _initweights) external {
        int256[] memory firstFourWeights = new int256[](8);
        int256[] memory secondFourWeights = new int256[](8);
        uint initialOffset = _initweights.length < 4 ? _initweights.length : 4;
        uint secondOffset = _initweights.length < 4 ? 0 : initialOffset - 4;
        uint secondWeightOffset = 0;
        for (uint256 i = 0; i < _initweights.length; i++) {
            if (i < 4) {
                firstFourWeights[i] = _initweights[i];
                firstFourWeights[i + initialOffset] = 0; // Initial block multiplier is 0
            } else {
                secondFourWeights[secondWeightOffset] = _initweights[i];
                secondFourWeights[secondWeightOffset + secondOffset] = 0; // Initial block multiplier is 0
                secondWeightOffset++;
            }
        }
        
    }

    function setRuleForPool(PoolSettings calldata _settings) external {
        UpdateWeightRunner(updateWeightRunner).setRuleForPool(_settings);
    }

    function setPoolRegistry(uint256 _poolRegistry) external {
        poolRegistry = _poolRegistry;
    }

    function getOracleStalenessThreshold() external view override returns (uint) {
        return oracleStalenessThreshold;
    }

    function getQuantAMMWeightedPoolDynamicData()
        external
        view
        override
        returns (QuantAMMWeightedPoolDynamicData memory data)
    {}

    function getQuantAMMWeightedPoolImmutableData()
        external
        view
        override
        returns (QuantAMMWeightedPoolImmutableData memory data)
    {}

    function setUpdateWeightRunnerAddress(address _updateWeightRunner) external override {}
}
