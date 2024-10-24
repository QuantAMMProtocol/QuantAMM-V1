//SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@prb/math/contracts/PRBMathSD59x18.sol";
import "./OracleWrapper.sol";
import "./IQuantAMMWeightedPool.sol";
import "./QuantAMMBaseAdministration.sol";
import "./rules/IUpdateRule.sol";
import "./rules/UpdateRule.sol";

import {
    IWeightedPool
} from "@balancer-labs/v3-interfaces/contracts/pool-weighted/IWeightedPool.sol";
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


contract UpdateWeightRunner is Ownable2Step {
    event OracleAdded(address indexed oracleAddress);
    event OracleRemved(address indexed oracleAddress);
    event UpdatePerformed(address indexed caller, address indexed pool);
    event UpdatePerformedQuantAMM(address indexed caller, address indexed pool);
    event QuantAMMWeightRunnerSet(address indexed weightRunner, bool allowed);
    event ETHUSDOracleSet(address ethUsdOracle);
    event PoolRuleSet(
        address rule,
        address[][] poolOracles,
        uint64[] lambda,
        int256[][] ruleParameters,
        uint64 epsilonMax,
        uint64 absoluteWeightGuardRail,
        uint40 updateInterval,
        address poolManager
    );
    event PoolLastRunSet(address poolAddress, uint40 time);

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
        uint64 absoluteWeightGuardRail;
        int256[][] ruleParameters;
        address poolManager;
    }

    /// @notice Struct for caching oracle replies
    /// @dev Data types chosen such that only one slot is used
    struct OracleData {
        int216 data;
        uint40 timestamp;
    }

    OracleWrapper private ethOracle;

    constructor(address _quantammAdmin, address _ethOracle) Ownable(msg.sender) {
        quantammAdmin = _quantammAdmin;
        ethOracle = OracleWrapper(_ethOracle);
    }

    address internal immutable quantammAdmin;

    /// @notice key is pool address, value is rule settings for running the pool
    mapping(address => PoolRuleSettings) public poolRuleSettings;

    /// @notice Mapping of pool primary oracles keyed by pool address. Happy path oracles in the same order as the constituent assets
    mapping(address => address[]) public poolOracles;

    /// @notice Mapping of pool backup oracles keyed by pool address for each asset in the pool (in order of priority)
    mapping(address => address[][]) public poolBackupOracles;

    /// @notice Mapping of external addresses that are owned by the protocol and can call performUpdateQuantAMM
    mapping(address => bool) public quantAMMWeightRunners;

    /// @notice Get the happy path primary oracles for the constituents of a pool
    /// @param _poolAddress Address of the pool
    function getOptimisedPoolOracle(
        address _poolAddress
    ) public view returns (address[] memory oracles) {
        return poolOracles[_poolAddress];
    }

    /// @notice Get the backup oracles for the constituents of a pool
    /// @param _poolAddress Address of the pool
    function getPoolOracleAndBackups(
        address _poolAddress
    ) public view returns (address[][] memory oracles) {
        return poolBackupOracles[_poolAddress];
    }

    /// @notice Get the rule settings for a pool
    /// @param _poolAddress Address of the pool
    function getPoolRuleSettings(
        address _poolAddress
    ) public view returns (PoolRuleSettings memory oracles) {
        return poolRuleSettings[_poolAddress];
    }

    /// @notice List of approved oracles that can be used for updating weights. 
    mapping(address => bool) public approvedOracles;

    /// @notice mapping keyed of oracle address to staleness threshold in seconds. Created for gas efficincy. 
    mapping(address => uint) public ruleOracleStalenessThreshold;

    /// @notice Mapping of pools to rules
    mapping(address => IUpdateRule) public rules;

    /// @notice Get the rule for a pool
    /// @param _poolAddress Address of the pool
    function getPoolRule(
        address _poolAddress
    ) public view returns (IUpdateRule rule) {
        return rules[_poolAddress];
    }

    /// @notice Add a new oracle to the available oracles
    /// @param _oracle Oracle to add
    function addOracle(OracleWrapper _oracle) external onlyOwner {
        address oracleAddress = address(_oracle);
        require(oracleAddress != address(0), "Invalid oracle address");
        if (!approvedOracles[oracleAddress]) {
            approvedOracles[oracleAddress] = true;
        } else {
            revert("Oracle already added");
        }
        emit OracleAdded(oracleAddress);
    }

    /// @notice Removes an existing oracle from the approved oracles
    /// @param _oracleToRemove The oracle to remove
    function removeOracle(OracleWrapper _oracleToRemove) external onlyOwner {
        approvedOracles[address(_oracleToRemove)] = false;
        emit OracleRemved(address(_oracleToRemove));
    }

    /// @notice Set a rule for a pool, called by the pool
    /// @param _poolSettings Settings for the pool
    function setRuleForPool(
        IQuantAMMWeightedPool.PoolSettings memory _poolSettings
    ) external {
        require(address(rules[msg.sender]) == address(0), "Rule already set");
        require(_poolSettings.oracles.length > 0, "Empty oracles array");
        require(poolOracles[msg.sender].length == 0, "pool rule already set");

        for (uint i; i < _poolSettings.oracles.length; ++i) {
            require(_poolSettings.oracles[i].length > 0, "Empty oracles array");
            for (uint j; j < _poolSettings.oracles[i].length; ++j) {
                if (!approvedOracles[_poolSettings.oracles[i][j]]) {
                    revert("Not approved oracled used");
                }
            }
        }

        address[] memory optimisedHappyPathOracles = new address[](
            _poolSettings.oracles.length
        );
        for (uint i; i < _poolSettings.oracles.length; ++i) {
            optimisedHappyPathOracles[i] = _poolSettings.oracles[i][0];
        }
        poolOracles[msg.sender] = optimisedHappyPathOracles;
        poolBackupOracles[msg.sender] = _poolSettings.oracles;
        rules[msg.sender] = _poolSettings.rule;
        poolRuleSettings[msg.sender] = PoolRuleSettings({
            lambda: _poolSettings.lambda,
            epsilonMax: _poolSettings.epsilonMax,
            absoluteWeightGuardRail: _poolSettings.absoluteWeightGuardRail,
            ruleParameters: _poolSettings.ruleParameters,
            timingSettings: PoolTimingSettings({
                updateInterval: _poolSettings.updateInterval,
                lastPoolUpdateRun: 0
            }),
            poolManager: _poolSettings.poolManager
        });

        // emit event for easier tracking of rule changes
        emit PoolRuleSet(
            address(_poolSettings.rule),
            _poolSettings.oracles,
            _poolSettings.lambda,
            _poolSettings.ruleParameters,
            _poolSettings.epsilonMax,
            _poolSettings.absoluteWeightGuardRail,
            _poolSettings.updateInterval,
            _poolSettings.poolManager
        );
    }

    /// @notice Run the update for the provided rule. Last update must be performed more than updateInterval seconds ago.
    function performUpdate(address _pool) public {
        //Main external access point to trigger an update
        address rule = address(rules[_pool]);
        require(rule != address(0), "Pool not registered");
        PoolRuleSettings memory settings = poolRuleSettings[_pool];
        
        require(
            block.timestamp - settings.timingSettings.lastPoolUpdateRun >=
                settings.timingSettings.updateInterval,
            "Update not allowed"
        );
        _performUpdateAndGetData(_pool, settings);

        // emit event for easier tracking of updates and to allow for easier querying of updates
        emit UpdatePerformed(msg.sender, _pool);
    }

    /// @notice Allow / disallow an address to call performUpdateQuantAMM
    /// @param _weightRunner the target runner address
    /// @param _allowed whether or not it is considered a quantamm owned address
    function setQuantAMMWeightRunner(
        address _weightRunner,
        bool _allowed
    ) public onlyOwner {
        require(quantAMMWeightRunners[_weightRunner] != _allowed, "Already set");
        quantAMMWeightRunners[_weightRunner] = _allowed;
        emit QuantAMMWeightRunnerSet(_weightRunner, _allowed);
    }

    /// @notice Change the ETH/USD oracle
    /// @param _ethUsdOracle The new oracle address to use for ETH/USD 
    function setETHUSDOracle(address _ethUsdOracle) public onlyOwner {
        ethOracle = OracleWrapper(_ethUsdOracle);
        emit ETHUSDOracleSet(_ethUsdOracle);
    }

    /// @notice Sets the timestamp of when an update was last run for a pool. Can by used as a breakgrass measure to retrigger an update.
    /// @param _poolAddress the target pool address
    /// @param _time the time to initialise the last update run to
    function InitialisePoolLastRunTime(
        address _poolAddress,
        uint40 _time
    ) external {
        uint256 MASK_POOL_DAO_WEIGHT_UPDATES = 32;
        uint256 poolRegistryEntry = IQuantAMMWeightedPool(_poolAddress).poolRegistry(_poolAddress);

        //current breakglass settings allow for dao or pool creator trigger. This is subject to review
        if (poolRegistryEntry & MASK_POOL_DAO_WEIGHT_UPDATES > 0) {
            address daoRunner = QuantAMMBaseAdministration(quantammAdmin).daoRunner();
            require(msg.sender == daoRunner, "ONLYDAO");
        } else {
            require(
                msg.sender == poolRuleSettings[_poolAddress].poolManager,
                "ONLYMANAGER"
            );
        }
        poolRuleSettings[_poolAddress].timingSettings.lastPoolUpdateRun = _time;
        emit PoolLastRunSet(_poolAddress, _time);
    }

    /// @notice Call oracle to retrieve new data
    /// @param _oracle the target oracle
    function _getOracleData(
        OracleWrapper _oracle
    ) private view returns (OracleData memory oracleResult) {
        if (!approvedOracles[address(_oracle)]) return oracleResult; // Return empty timestamp if oracle is no longer approved, result will be discarded
        (int216 data, uint40 timestamp) = _oracle.getData();
        oracleResult.data = data;
        oracleResult.timestamp = timestamp;
    }

    /// @notice Get the data for a pool from the oracles and return it in the same order as the assets in the pool
    /// @param _pool Pool to get data for
    function getData(
        address _pool
    ) public view returns (int256[] memory outputData) {
        //optimised == happy path, optimised into a different array to save gas
        address[] memory optimisedOracles = poolOracles[_pool];
        uint oracleLength = optimisedOracles.length;
        uint numAssetOracles;
        outputData = new int256[](oracleLength);
        uint oracleStalenessThreshold = IQuantAMMWeightedPool(_pool)
            .getOracleStalenessThreshold();

        for (uint i; i < oracleLength; ) {
            // Asset is base asset
            OracleData memory oracleResult;
            oracleResult = _getOracleData(OracleWrapper(optimisedOracles[i]));
            if (
                oracleResult.timestamp >
                block.timestamp - oracleStalenessThreshold
            ) {
                outputData[i] = oracleResult.data;
            } else {
                unchecked {
                    numAssetOracles = poolBackupOracles[_pool][i].length;
                }

                for (
                    uint j = 1 /*0 already done via optimised poolOracles*/;
                    j < numAssetOracles;

                ) {
                    oracleResult = _getOracleData(
                        // poolBackupOracles[_pool][asset][oracle]
                        OracleWrapper(poolBackupOracles[_pool][i][j])
                    );
                    if (
                        oracleResult.timestamp >
                        block.timestamp - oracleStalenessThreshold
                    ) {
                        // Oracle has fresh values
                        break;
                    } else if (j == numAssetOracles - 1) {
                        // All oracle results for this data point are stale. Should rarely happen in practice with proper backup oracles.

                        revert("No fresh oracle values available");
                    }
                    unchecked {
                        ++j;
                    }
                }
                outputData[i] = oracleResult.data;
            }

            unchecked {
                ++i;
            }
        }
    }

    function _getUpdatedWeightsAndOracleData(
        address _pool,
        int256[] memory _currentWeights,
        PoolRuleSettings memory _ruleSettings
    ) private returns (int256[] memory updatedWeights, int256[] memory data) {
        data = getData(_pool);
        
        updatedWeights = rules[_pool].CalculateNewWeights(
            _currentWeights,
            data,
            _pool,
            _ruleSettings.ruleParameters,
            _ruleSettings.lambda,
            _ruleSettings.epsilonMax,
            _ruleSettings.absoluteWeightGuardRail
        );
        poolRuleSettings[_pool].timingSettings.lastPoolUpdateRun = uint40(
            block.timestamp
        );
    }

    /// @notice Perform the update for a pool and get the new data
    /// @param _poolAddress Pool to update
    /// @param _ruleSettings Settings for the rule to use for the update (lambda, epsilonMax, absolute guard rails, ruleParameters)
    function _performUpdateAndGetData(
        address _poolAddress,
        PoolRuleSettings memory _ruleSettings
    ) private returns (int256[] memory) {
        uint256[] memory targetWeightsUnsigned = IWeightedPool(_poolAddress).getNormalizedWeights();
        
        int256[] memory targetWeights = new int256[](targetWeightsUnsigned.length);

        for(uint i; i < targetWeightsUnsigned.length;){
            targetWeights[i] = int256(targetWeightsUnsigned[i]);

            unchecked{
                i++;
            }
        }

        uint weightAndMultiplierLength = targetWeights.length * 2;
        (
            int256[] memory updatedWeights,
            int256[] memory data
        ) = _getUpdatedWeightsAndOracleData(_poolAddress, targetWeights, _ruleSettings);

        // the base pool needs both the target weights and the per block multipler per asset
        int256[] memory targetWeightsAndBlockMultiplier = new int256[](
            weightAndMultiplierLength
        );

        int256 currentLastInterpolationPossible = type(int256).max;
        int256 updateInterval = int256(
            int40(_ruleSettings.timingSettings.updateInterval)
        );

        for (uint i; i < targetWeights.length; ) {
            targetWeightsAndBlockMultiplier[i] = targetWeights[i];

            // this would be the simple scenario if we did not have to worry about guard rails
            int256 blockMultiplier = (updatedWeights[i] - targetWeights[i]) /
                updateInterval;

            targetWeightsAndBlockMultiplier[
                i + targetWeights.length
            ] = blockMultiplier;

            unchecked {
                //This is your worst case scenario, usually you expect (and have DR) that at your next interval you
                //get another update. However what if you don't. You can carry on interpolating until you hit a rail
                //This calculates the first blocktime which one of your constituents hits the rail and that is your max
                //interpolation weight
                //There are economic reasons for this detailed in the whitepaper design notes. 
                int256 weightBetweenTargetAndMax;
                int256 blockTimeUntilGuardRailHit;
                if (blockMultiplier > int256(0)) {
                    weightBetweenTargetAndMax =
                        int256(int64(_ruleSettings.absoluteWeightGuardRail)) -
                        targetWeights[i];
                    //not using .div so that the 18dp is removed
                    blockTimeUntilGuardRailHit =
                        weightBetweenTargetAndMax /
                        blockMultiplier;
                } else if (blockMultiplier == int256(0)) {
                    blockTimeUntilGuardRailHit = type(int256).max;
                } else {
                    weightBetweenTargetAndMax =
                        targetWeights[i] -
                        int256(int64(_ruleSettings.absoluteWeightGuardRail));
                    //not using .div so that the 18dp is removed
                    
                    blockTimeUntilGuardRailHit =
                        weightBetweenTargetAndMax /
                        blockMultiplier;
                }

                if (
                    blockTimeUntilGuardRailHit <
                    currentLastInterpolationPossible
                ) {
                    //-1 to avoid any round issues at boundry. Cheaper than seeing if there will be and then doing -1
                    currentLastInterpolationPossible = blockTimeUntilGuardRailHit;
                }

                ++i;
            }
        }

        uint40 lastTimestampThatInterpolationWorks = uint40(type(uint40).max);

        //next expected update + time beyond that
        currentLastInterpolationPossible +=
            int40(uint40(block.timestamp)) +
            int40(_ruleSettings.timingSettings.updateInterval);

        //needed to prevent silent overflows
        if (currentLastInterpolationPossible < int40(type(uint40).max)) {
            lastTimestampThatInterpolationWorks = uint40(
                int40(currentLastInterpolationPossible)
            );
        }

        //the main point of interaction between the update weight runner and the quantammAdmin is here
        IQuantAMMWeightedPool(_poolAddress).setWeights(
            targetWeightsAndBlockMultiplier,
            _poolAddress,
            lastTimestampThatInterpolationWorks
        );

        return data;
    }

    /// @notice Breakglass function to allow the DAO or the pool manager to set the quantammAdmins weights manually
    /// @param _weights the new weights
    /// @param _poolAddress the target pool
    /// @param _lastInterpolationTimePossible the last time that the interpolation will work
    function setWeightsManually(
        int256[] calldata _weights,
        address _poolAddress,
        uint40 _lastInterpolationTimePossible
    ) external {
        uint256 MASK_POOL_DAO_WEIGHT_UPDATES = 32;
        uint256 poolRegistryEntry = IQuantAMMWeightedPool(_poolAddress).poolRegistry(_poolAddress);
        if (poolRegistryEntry & MASK_POOL_DAO_WEIGHT_UPDATES > 0) {
            address daoRunner = QuantAMMBaseAdministration(quantammAdmin).daoRunner();
            require(msg.sender == daoRunner, "ONLYDAO");
        } else {
            require(
                msg.sender == poolRuleSettings[_poolAddress].poolManager,
                "ONLYMANAGER"
            );
        }

        IQuantAMMWeightedPool(_poolAddress).setWeights(_weights, _poolAddress, _lastInterpolationTimePossible);
    }

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
    ) external {
        uint256 MASK_POOL_DAO_WEIGHT_UPDATES = 32;
        uint256 poolRegistryEntry = IQuantAMMWeightedPool(_poolAddress).poolRegistry(_poolAddress);

        //Who can trigger these very powerful breakglass features is under review
        if (poolRegistryEntry & MASK_POOL_DAO_WEIGHT_UPDATES > 0) {
            address daoRunner = QuantAMMBaseAdministration(quantammAdmin).daoRunner();
            require(msg.sender == daoRunner, "ONLYDAO");
        } else {
            require(
                msg.sender == poolRuleSettings[_poolAddress].poolManager,
                "ONLYMANAGER"
            );
        }
        IUpdateRule rule = rules[_poolAddress];

        // utilises the base function so that manual updates go through the standard process
        rule.initialisePoolRuleIntermediateValues(
            _poolAddress,
            _newMovingAverages,
            _newParameters,
            _numberOfAssets
        );
    }
}
