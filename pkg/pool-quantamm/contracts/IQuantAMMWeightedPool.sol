// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@prb/math/contracts/PRBMathSD59x18.sol";
import "./rules/IUpdateRule.sol";

/// @title the main central quantammBase containing records and balances of all pools. Contains all user-pool interaction functions.
interface IQuantAMMWeightedPool {

    struct QuantAMMBaseInterpolationVariables {
        uint40 lastUpdateIntervalTime;
        uint40 lastPossibleInterpolationTime;
    }

    struct QuantAMMBaseGetWeightData {
        QuantAMMBaseInterpolationVariables quantAMMBaseInterpolationDetails;
        address[] assets;
        int256 tradeCap; //in bps
        int256 poolOptions;
        address getWeightsMethod;
    }


    /// @notice Settings that identify a pool
    struct PoolSettings {
        IERC20[] assets;
        IUpdateRule rule;
        address[][] oracles;
        uint16 updateInterval;
        uint64[] lambda;
        uint64 epsilonMax;
        uint64 absoluteWeightGuardRail;
        uint64 maxTradeSizeRatio;
        int256[][] ruleParameters;
        address[] complianceCheckersTrade;
        address[] complianceCheckersDeposit;
        address poolManager;
    }
    
    /// @notice function called to set weights and weight block multipliers
    /// @param _weights the weights to set that sum to 1
    /// @param _poolAddress the address of the pool to set the weights for
    /// @param _lastInterpolationTimePossible the last time that the weights can be updated given the block multiplier before one weight hits the guardrail
    function setWeights(
        int256[] calldata _weights,
        address _poolAddress,
        uint40 _lastInterpolationTimePossible
    ) external;

    /// @notice used to view the pool address for a given pool settings hash if the pool is registered with the quantammBase
    /// @param _poolAddress the address of the pool to get the settings hash for
    function poolRegistry(address _poolAddress) external view returns (uint256);
    
    /// @notice the acceptable number of blocks behind the current that an oracle value can be
    function getOracleStalenessThreshold() external view returns (uint);
}
