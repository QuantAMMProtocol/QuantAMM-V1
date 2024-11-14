//SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@prb/math/contracts/PRBMathSD59x18.sol";
import "./IQuantAMMWeightedPool.sol";
import "./IUpdateRule.sol";
import "./OracleWrapper.sol";

import {
    IWeightedPool
} from "../pool-weighted/IWeightedPool.sol";
/*
ARCHITECTURE DESIGN NOTES

The update weight runner is a singleton contract that is responsible for running all weight updates. It is a singleton contract as it is responsible for managing the update rule state of all pools.

The update weight runner is responsible for:
- Managing the state of all update rules
- Managing the state of all pools related to update rules
- Managing the state of all oracles related to update rules
- Managing the state of all quantAMM weight runners
- Managing the state of the ETH/USD oracle - important for exit fee calculations
- Managing the state of all approved oracles
- Managing the state of all oracle staleness thresholds
- Managing the state of all pool last run times
- Managing the state of all pool rule settings
- Managing the state of all pool primary oracles
- Managing the state of all pool backup oracles
- Managing the state of all pool rules

As all QuantAMM pools are based on the TFMM approach, core aspects of running a periodic strategy
update are shared. This allows for appropriate centralisation of the process in a single update weight
runner.
What benefits are achieved by such centralisation? Efficiency of external contract calls is a great benefit
however security should always come before efficiency. A single runner allows for a gated approach
where pool contracts can be built, however only when registered with the quantammAdmin and update weight
runner can they be considered to be ”approved” and running within the QuantAMM umbrella.
Centralised common logic also allows for ease of protecting the interaction between quantammAdmin and update
weight runner, while reducing the pool specific code that will require n number of audits per n pools
designs. Such logic includes a single heavily tested implementation for oracle fall backs, triggering of
updates and guard rails.


 */


/// @title UpdateWeightRunner singleton contract that is responsible for running all weight updates

interface IUpdateWeightRunner {
    // Store the current execution context for callbacks
    struct ExecutionData {
        address pool;
        uint96 subpoolIndex;
    }
    struct PoolTimingSettings {
        uint40 lastPoolUpdateRun;
        uint40 updateInterval;
    }

    struct PoolRuleSettings {
        uint64[] lambda;
        PoolTimingSettings timingSettings;
        uint64 epsilonMax;
        int256[][] ruleParameters;
        address poolManager;
    }

    /// @notice Struct for caching oracle replies
    /// @dev Data types chosen such that only one slot is used
    struct OracleData {
        int216 data;
        uint40 timestamp;
    }
    /// @notice Get the happy path primary oracles for the constituents of a pool
    /// @param _poolAddress Address of the pool
    function getOptimisedPoolOracle(
        address _poolAddress
    ) external view returns (address[] memory oracles);
    
    /// @notice Get the data for a pool from the oracles and return it in the same order as the assets in the pool
    /// @param _pool Pool to get data for
    function getData(
        address _pool
    ) external view returns (int256[] memory outputData);

    /// @notice Get the backup oracles for the constituents of a pool
    /// @param _poolAddress Address of the pool
    function getPoolOracleAndBackups(
        address _poolAddress
    ) external view returns (address[][] memory oracles);

    /// @notice Get the rule settings for a pool
    /// @param _poolAddress Address of the pool
    function getPoolRuleSettings(
        address _poolAddress
    ) external view returns (PoolRuleSettings memory oracles);

    /// @notice Get the rule for a pool
    /// @param _poolAddress Address of the pool
    function getPoolRule(
        address _poolAddress
    ) external view returns (IUpdateRule rule);

    /// @notice Add a new oracle to the available oracles
    /// @param _oracle Oracle to add
    function addOracle(OracleWrapper _oracle) external;

    /// @notice Removes an existing oracle from the approved oracles
    /// @param _oracleToRemove The oracle to remove
    function removeOracle(OracleWrapper _oracleToRemove) external;

    /// @notice Set a rule for a pool, called by the pool
    /// @param _rule Address of the rule
    /// @param _poolOracles Array of oracle indices (in order of priority)
    function setRuleForPool(
        IUpdateRule _rule,
        address[][] calldata _poolOracles,
        uint64[] calldata _lambda,
        int256[][] calldata _ruleParameters,
        uint64 _epsilonMax,
        uint40 _updateInterval,
        address _poolManager
    ) external ;

    /// @notice Run the update for the provided rule. Last update must be performed more than updateInterval seconds ago.
    function performUpdate(address _pool) external;

    /// @notice Allow / disallow an address to call performUpdateQuantAMM
    /// @param _weightRunner the target runner address
    /// @param _allowed whether or not it is considered a quantamm owned address
    function setQuantAMMWeightRunner(
        address _weightRunner,
        bool _allowed
    ) external;

    /// @notice Change the ETH/USD oracle
    /// @param _ethUsdOracle The new oracle address to use for ETH/USD 
    function setETHUSDOracle(address _ethUsdOracle) external;

    /// @notice Sets the timestamp of when an update was last run for a pool. Can by used as a breakgrass measure to retrigger an update.
    /// @param _poolAddress the target pool address
    /// @param _time the time to initialise the last update run to
    function InitialisePoolLastRunTime(
        address _poolAddress,
        uint40 _time
    ) external ;

    /// @notice Breakglass function to allow the DAO or the pool manager to set the quantammAdmins weights manually
    /// @param _weights the new weights
    /// @param _poolAddress the target pool
    /// @param _lastInterpolationTimePossible the last time that the interpolation will work
    function setWeightsManually(
        int256[] calldata _weights,
        address _poolAddress,
        uint40 _lastInterpolationTimePossible
    ) external ;

    /// @notice Breakglass function to allow the DAO or the pool manager to set the intermediate values of the rule manually
    /// @param _poolAddress the target pool
    /// @param _newMovingAverages manual new moving averages
    /// @param _newParameters manual new parameters
    /// @param _numberOfAssets number of assets in the pool
    function setIntermediateValuesManually(
        address _poolAddress,
        int256[] memory _newMovingAverages,
        int256[] memory _newParameters,
        uint _numberOfAssets
    ) external ;
}
