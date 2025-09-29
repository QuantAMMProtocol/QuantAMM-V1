# UpdateRule
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/rules/UpdateRule.sol)

**Inherits:**
[QuantAMMMathGuard](/contracts/rules/base/QuantammMathGuard.sol/abstract.QuantAMMMathGuard.md), [QuantAMMMathMovingAverage](/contracts/rules/base/QuantammMathMovingAverage.sol/abstract.QuantAMMMathMovingAverage.md), IUpdateRule

Contains the logic for calculating the new weights of a QuantAMM pool and protections, must be implemented by all rules used in quantAMM


## State Variables
### REQ_PREV_MAVG_VAL

```solidity
uint16 private constant REQ_PREV_MAVG_VAL = 1;
```


### updateWeightRunner

```solidity
address private immutable updateWeightRunner;
```


### name

```solidity
string public name;
```


### parameterDescriptions

```solidity
string[] public parameterDescriptions;
```


## Functions
### constructor


```solidity
constructor(address _updateWeightRunner);
```

### CalculateNewWeights


```solidity
function CalculateNewWeights(
    int256[] calldata _prevWeights,
    int256[] calldata _data,
    address _pool,
    int256[][] calldata _parameters,
    uint64[] calldata _lambdaStore,
    uint64 _epsilonMax,
    uint64 _absoluteWeightGuardRail
) external returns (int256[] memory updatedWeights);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_prevWeights`|`int256[]`|the previous weights retrieved from the vault|
|`_data`|`int256[]`|the latest data from the signal, usually price|
|`_pool`|`address`|the target pool address|
|`_parameters`|`int256[][]`|the parameters of the rule that are not lambda|
|`_lambdaStore`|`uint64[]`|either vector or scalar lambda|
|`_epsilonMax`|`uint64`|the maximum weights can change in a given update interval|
|`_absoluteWeightGuardRail`|`uint64`|the minimum weight a token can have|


### _getWeights

Function that has to be implemented by update rules. Given previous weights, current data, and current gradient of the data, calculate the new weights.


```solidity
function _getWeights(
    int256[] calldata _prevWeights,
    int256[] memory _data,
    int256[][] calldata _parameters,
    QuantAMMPoolParameters memory _poolParameters
) internal virtual returns (int256[] memory newWeights);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_prevWeights`|`int256[]`|w(t - 1), the weights at the previous timestamp|
|`_data`|`int256[]`|p(t), the data at the current timestamp, usually referring to prices (but could also be other values that are returned by an oracle)|
|`_parameters`|`int256[][]`|Arbitrary values that parametrize the rule, interpretation depends on rule|
|`_poolParameters`|`QuantAMMPoolParameters`|PoolParameters|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`newWeights`|`int256[]`|w(t), the updated weights|


### _requiresPrevMovingAverage


```solidity
function _requiresPrevMovingAverage() internal pure virtual returns (uint16);
```

### _setInitialIntermediateValues


```solidity
function _setInitialIntermediateValues(address _poolAddress, int256[] memory _initialValues, uint256 _numberOfAssets)
    internal
    virtual;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|address of pool being initialised|
|`_initialValues`|`int256[]`|the initial intermediate values to be saved|
|`_numberOfAssets`|`uint256`|the number of assets in the pool|


### initialisePoolRuleIntermediateValues

top level initialisation function to be called during pool registration


```solidity
function initialisePoolRuleIntermediateValues(
    address _poolAddress,
    int256[] memory _newMovingAverages,
    int256[] memory _newInitialValues,
    uint256 _numberOfAssets
) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|address of pool being initialised|
|`_newMovingAverages`|`int256[]`|the initial moving averages to be saved|
|`_newInitialValues`|`int256[]`|the initial intermediate values to be saved|
|`_numberOfAssets`|`uint256`|the number of assets in the pool|


### validParameters

Check if the given parameters are valid for the rule


```solidity
function validParameters(int256[][] calldata parameters) external view virtual returns (bool);
```

## Structs
### QuantAMMUpdateRuleLocals
Struct to store local variables for the update rule

*struct to avoid stack too deep issues*


```solidity
struct QuantAMMUpdateRuleLocals {
    uint256 i;
    uint256 nMinusOne;
    uint256 numberOfAssets;
    bool requiresPrevAverage;
    uint256 intermediateMovingAverageStateLength;
    int256[] currMovingAverage;
    int256[] updatedMovingAverage;
    int256[] calculationMovingAverage;
    int256[] intermediateGradientState;
    int256[] unGuardedUpdatedWeights;
    int128[] lambda;
    uint256 secondIndex;
    uint256 storageIndex;
    uint256 lastAssetIndex;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`i`|`uint256`|index for looping|
|`nMinusOne`|`uint256`|number of assets minus one|
|`numberOfAssets`|`uint256`|number of assets in the pool|
|`requiresPrevAverage`|`bool`|boolean to determine if the rule requires the previous moving average|
|`intermediateMovingAverageStateLength`|`uint256`|length of the intermediate moving average state|
|`currMovingAverage`|`int256[]`|current moving average|
|`updatedMovingAverage`|`int256[]`|updated moving average|
|`calculationMovingAverage`|`int256[]`|moving average used in the calculation|
|`intermediateGradientState`|`int256[]`|intermediate gradient state|
|`unGuardedUpdatedWeights`|`int256[]`|unguarded updated weights|
|`lambda`|`int128[]`|lambda values|
|`secondIndex`|`uint256`|second index for looping|
|`storageIndex`|`uint256`|storage index for moving averages|
|`lastAssetIndex`|`uint256`|last asset index|

