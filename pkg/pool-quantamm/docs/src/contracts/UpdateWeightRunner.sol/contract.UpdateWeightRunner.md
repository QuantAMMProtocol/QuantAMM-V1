# UpdateWeightRunner
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/UpdateWeightRunner.sol)

**Inherits:**
IUpdateWeightRunner


## State Variables
### ethOracle
main eth oracle that could be used to determine value of pools and assets.

*this could be used for things like uplift only withdrawal fee hooks*


```solidity
OracleWrapper public ethOracle;
```


### MASK_POOL_PERFORM_UPDATE
Mask to check if a pool is allowed to perform an update, some might only want to get data


```solidity
uint256 private constant MASK_POOL_PERFORM_UPDATE = 1;
```


### MASK_POOL_GET_DATA
Mask to check if a pool is allowed to get data


```solidity
uint256 private constant MASK_POOL_GET_DATA = 2;
```


### MASK_POOL_OWNER_UPDATES
Mask to check if a pool owner can update weights


```solidity
uint256 private constant MASK_POOL_OWNER_UPDATES = 8;
```


### MASK_POOL_QUANTAMM_ADMIN_UPDATES
Mask to check if a pool is allowed to perform admin updates


```solidity
uint256 private constant MASK_POOL_QUANTAMM_ADMIN_UPDATES = 16;
```


### MASK_POOL_RULE_DIRECT_SET_WEIGHT
Mask to check if a pool is allowed to perform direct weight update from a rule


```solidity
uint256 private constant MASK_POOL_RULE_DIRECT_SET_WEIGHT = 32;
```


### quantammAdmin

```solidity
address public immutable quantammAdmin;
```


### poolRuleSettings
key is pool address, value is rule settings for running the pool


```solidity
mapping(address => PoolRuleSettings) public poolRuleSettings;
```


### poolOracles
Mapping of pool primary oracles keyed by pool address. Happy path oracles in the same order as the constituent assets


```solidity
mapping(address => address[]) public poolOracles;
```


### poolBackupOracles
Mapping of pool backup oracles keyed by pool address for each asset in the pool (in order of priority)


```solidity
mapping(address => address[][]) public poolBackupOracles;
```


### quantAMMSwapFeeTake
The % of the total swap fee that is allocated to the protocol for running costs.


```solidity
uint256 public quantAMMSwapFeeTake = 0.5e18;
```


### approvedOracles
List of approved oracles that can be used for updating weights.


```solidity
mapping(address => bool) public approvedOracles;
```


### approvedPoolActions
Mapping of actions approved for a pool by the QuantAMM protocol team.


```solidity
mapping(address => uint256) public approvedPoolActions;
```


### ruleOracleStalenessThreshold
mapping keyed of oracle address to staleness threshold in seconds. Created for gas efficincy.


```solidity
mapping(address => uint256) public ruleOracleStalenessThreshold;
```


### rules
Mapping of pools to rules


```solidity
mapping(address => IUpdateRule) public rules;
```


## Functions
### constructor


```solidity
constructor(address _quantammAdmin, address _ethOracle);
```

### setQuantAMMSwapFeeTake


```solidity
function setQuantAMMSwapFeeTake(uint256 _quantAMMSwapFeeTake) external override;
```

### getQuantAMMSwapFeeTake


```solidity
function getQuantAMMSwapFeeTake() external view override returns (uint256);
```

### setQuantAMMUpliftFeeTake

Set the quantAMM uplift fee % amount allocated to the protocol for running costs


```solidity
function setQuantAMMUpliftFeeTake(uint256 _quantAMMUpliftFeeTake) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_quantAMMUpliftFeeTake`|`uint256`|The new uplift fee % amount allocated to the protocol for running costs|


### getQuantAMMUpliftFeeTake

Get the quantAMM uplift fee % amount allocated to the protocol for running costs


```solidity
function getQuantAMMUpliftFeeTake() external view returns (uint256);
```

### getQuantAMMAdmin


```solidity
function getQuantAMMAdmin() external view override returns (address);
```

### getOptimisedPoolOracle

Get the happy path primary oracles for the constituents of a pool


```solidity
function getOptimisedPoolOracle(address _poolAddress) public view returns (address[] memory oracles);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|Address of the pool|


### getPoolOracleAndBackups

Get the backup oracles for the constituents of a pool


```solidity
function getPoolOracleAndBackups(address _poolAddress) public view returns (address[][] memory oracles);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|Address of the pool|


### getPoolRuleSettings

Get the rule settings for a pool


```solidity
function getPoolRuleSettings(address _poolAddress) public view returns (PoolRuleSettings memory oracles);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|Address of the pool|


### getPoolApprovedActions

Get the actions a pool has been approved for


```solidity
function getPoolApprovedActions(address _poolAddress) public view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|Address of the pool|


### getPoolRule

Get the rule for a pool


```solidity
function getPoolRule(address _poolAddress) public view returns (IUpdateRule rule);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|Address of the pool|


### addOracle

Add a new oracle to the available oracles


```solidity
function addOracle(OracleWrapper _oracle) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_oracle`|`OracleWrapper`|Oracle to add|


### removeOracle

Removes an existing oracle from the approved oracles


```solidity
function removeOracle(OracleWrapper _oracleToRemove) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_oracleToRemove`|`OracleWrapper`|The oracle to remove|


### setApprovedActionsForPool

Set the actions a pool is approved for


```solidity
function setApprovedActionsForPool(address _pool, uint256 _actions) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_pool`|`address`|Pool to set actions for|
|`_actions`|`uint256`||


### setRuleForPoolAdminInitialise

Set the rule for a pool, called by the pool creator

*CODEHAWKS M-02*


```solidity
function setRuleForPoolAdminInitialise(IQuantAMMWeightedPool.PoolSettings memory _poolSettings, address _pool)
    external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolSettings`|`IQuantAMMWeightedPool.PoolSettings`|Settings for the pool|
|`_pool`|`address`|Pool to set the rule for|


### setRuleForPool

Set a rule for a pool, called by the pool


```solidity
function setRuleForPool(IQuantAMMWeightedPool.PoolSettings memory _poolSettings) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolSettings`|`IQuantAMMWeightedPool.PoolSettings`|Settings for the pool|


### _setRuleForPool


```solidity
function _setRuleForPool(IQuantAMMWeightedPool.PoolSettings memory _poolSettings, address pool) internal;
```

### performUpdate

Run the update for the provided rule. Last update must be performed more than or equal (CODEHAWKS INFO /2/228) to updateInterval seconds ago.


```solidity
function performUpdate(address _pool) public;
```

### setETHUSDOracle

Change the ETH/USD oracle


```solidity
function setETHUSDOracle(address _ethUsdOracle) public;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_ethUsdOracle`|`address`|The new oracle address to use for ETH/USD|


### InitialisePoolLastRunTime

Sets the timestamp of when an update was last run for a pool. Can by used as a breakgrass measure to retrigger an update.


```solidity
function InitialisePoolLastRunTime(address _poolAddress, uint40 _time) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|the target pool address|
|`_time`|`uint40`|the time to initialise the last update run to|


### getData

Wrapper for if someone wants to get the oracle data the rule is using from an external source


```solidity
function getData(address _pool) public view virtual returns (int256[] memory outputData);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_pool`|`address`|Pool to get data for|


### _getData

Get the data for a pool from the oracles and return it in the same order as the assets in the pool


```solidity
function _getData(address _pool, bool internalCall) private view returns (int256[] memory outputData);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_pool`|`address`|Pool to get data for|
|`internalCall`|`bool`|Internal call flag to detect if the function was called internally for emission and permissions|


### _getUpdatedWeightsAndOracleData


```solidity
function _getUpdatedWeightsAndOracleData(
    address _pool,
    int256[] memory _currentWeights,
    PoolRuleSettings memory _ruleSettings
) private returns (int256[] memory updatedWeights, int256[] memory data);
```

### _performUpdateAndGetData

Perform the update for a pool and get the new data


```solidity
function _performUpdateAndGetData(address _poolAddress, PoolRuleSettings memory _ruleSettings) private;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|Pool to update|
|`_ruleSettings`|`PoolRuleSettings`|Settings for the rule to use for the update (lambda, epsilonMax, absolute guard rails, ruleParameters)|


### flattenDynamicDataWeightAndMutlipliers

Flatten the weights and multipliers into a single array


```solidity
function flattenDynamicDataWeightAndMutlipliers(
    int256[] memory firstFourWeightsAndMultipliers,
    int256[] memory secondFourWeightsAndMultipliers
) internal pure returns (int256[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`firstFourWeightsAndMultipliers`|`int256[]`|The first four weights and multipliers w,w,w,w,m,m,m,m|
|`secondFourWeightsAndMultipliers`|`int256[]`|The second four weights and multipliers w,w,w,w,m,m,m,m|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`int256[]`|The flattened weights and multipliers w,w,w,w,w,w,w,w,m,m,m,m,m,m,m,m|


### _calculateMultiplerAndSetWeights

Calculate the multiplier and set the weights for a pool.

*The multipler is the amount per block to add/remove from the last successful weight update.*


```solidity
function _calculateMultiplerAndSetWeights(CalculateMuliplierAndSetWeightsLocal memory local) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`local`|`CalculateMuliplierAndSetWeightsLocal`|Local data for the function|


### calculateMultiplierAndSetWeightsFromRule

Ability to set weights from a rule without calculating new weights being triggered for approved configured pools

*requested for use in zk rules where weights are calculated with circuit and this is only called post verifier call*


```solidity
function calculateMultiplierAndSetWeightsFromRule(CalculateMuliplierAndSetWeightsLocal memory params) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`params`|`CalculateMuliplierAndSetWeightsLocal`|Local data for the function|


### setTargetWeightsManually

Breakglass function to allow the admin or the pool manager to set the quantammAdmins weights manually

*this function is different to setWeightsManually as it is more timelock friendly*


```solidity
function setTargetWeightsManually(
    int256[] calldata _weights,
    address _poolAddress,
    uint40 _interpolationTime,
    uint256 _numberOfAssets
) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_weights`|`int256[]`|the new weights|
|`_poolAddress`|`address`|the target pool|
|`_interpolationTime`|`uint40`|the time required to calcluate the multiplier|
|`_numberOfAssets`|`uint256`|the number of assets in the pool|


### setWeightsManually

Breakglass function to allow the admin or the pool manager to set the quantammAdmins weights manually


```solidity
function setWeightsManually(
    int256[] calldata _weights,
    address _poolAddress,
    uint40 _lastInterpolationTimePossible,
    uint256 _numberOfAssets
) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_weights`|`int256[]`|the new weights|
|`_poolAddress`|`address`|the target pool|
|`_lastInterpolationTimePossible`|`uint40`|the last time that the interpolation will work|
|`_numberOfAssets`|`uint256`|the number of assets in the pool|


### setIntermediateValuesManually

Breakglass function to allow the admin or the pool manager to set the intermediate values of the rule manually


```solidity
function setIntermediateValuesManually(
    address _poolAddress,
    int256[] memory _newMovingAverages,
    int256[] memory _newParameters,
    uint256 _numberOfAssets
) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|the target pool|
|`_newMovingAverages`|`int256[]`|manual new moving averages|
|`_newParameters`|`int256[]`|manual new parameters|
|`_numberOfAssets`|`uint256`|number of assets in the pool|


## Events
### OracleAdded

```solidity
event OracleAdded(address indexed oracleAddress);
```

### OracleRemved

```solidity
event OracleRemved(address indexed oracleAddress);
```

### SetWeightManual

```solidity
event SetWeightManual(
    address indexed caller,
    address indexed pool,
    int256[] weights,
    uint40 lastInterpolationTimePossible,
    uint40 lastUpdateTime
);
```

### SetIntermediateValuesManually

```solidity
event SetIntermediateValuesManually(
    address indexed caller,
    address indexed pool,
    int256[] newMovingAverages,
    int256[] newParameters,
    uint256 numberOfAssets
);
```

### SwapFeeTakeSet

```solidity
event SwapFeeTakeSet(uint256 oldSwapFee, uint256 newSwapFee);
```

### UpliftFeeTakeSet

```solidity
event UpliftFeeTakeSet(uint256 oldSwapFee, uint256 newSwapFee);
```

### UpdatePerformed

```solidity
event UpdatePerformed(address indexed caller, address indexed pool);
```

### UpdatePerformedQuantAMM

```solidity
event UpdatePerformedQuantAMM(address indexed caller, address indexed pool);
```

### SetApprovedActionsForPool

```solidity
event SetApprovedActionsForPool(address indexed caller, address indexed pool, uint256 actions);
```

### ETHUSDOracleSet

```solidity
event ETHUSDOracleSet(address ethUsdOracle);
```

### PoolLastRunSet

```solidity
event PoolLastRunSet(address poolAddress, uint40 time);
```

### PoolRuleSetAdminOverride

```solidity
event PoolRuleSetAdminOverride(address admin, address poolAddress, address ruleAddress);
```

### CalculateWeightsRequest

```solidity
event CalculateWeightsRequest(
    int256[] currentWeights,
    int256[] data,
    address pool,
    int256[][] ruleParameters,
    uint64[] lambda,
    uint64 epsilonMax,
    uint64 absoluteWeightGuardRail
);
```

### CalculateWeightsResponse

```solidity
event CalculateWeightsResponse(int256[] updatedWeights);
```

### WeightsUpdated
*Emitted when the weights of the pool are updated*


```solidity
event WeightsUpdated(
    address indexed poolAddress,
    address updateOwner,
    int256[] weights,
    uint40 lastInterpolationTimePossible,
    uint40 lastUpdateTime
);
```

## Structs
### CalculateMuliplierAndSetWeightsLocal

```solidity
struct CalculateMuliplierAndSetWeightsLocal {
    int256[] currentWeights;
    int256[] updatedWeights;
    int256 updateInterval;
    int256 absoluteWeightGuardRail18;
    address poolAddress;
}
```

