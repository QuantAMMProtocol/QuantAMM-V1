# QuantAMMGradientBasedRule
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/rules/base/QuantammGradientBasedRule.sol)

**Inherits:**
[ScalarRuleQuantAMMStorage](/contracts/QuantAMMStorage.sol/abstract.ScalarRuleQuantAMMStorage.md)

This contract is abstract and needs to be inherited and implemented to be used.


## State Variables
### ONE

```solidity
int256 private constant ONE = 1 * 1e18;
```


### THREE

```solidity
int256 private constant THREE = 3 * 1e18;
```


### intermediateGradientStates

```solidity
mapping(address => int256[]) internal intermediateGradientStates;
```


## Functions
### getIntermediateGradientState

View function to get the intermediate gradient state for a given pool


```solidity
function getIntermediateGradientState(address poolAddress, uint256 numberOfAssets)
    external
    view
    returns (int256[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolAddress`|`address`|The address of the pool|
|`numberOfAssets`|`uint256`|The number of assets in the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`int256[]`|The unpacked intermediate gradient state as an array of int256|


### _calculateQuantAMMGradient


```solidity
function _calculateQuantAMMGradient(int256[] memory _newData, QuantAMMPoolParameters memory _poolParameters)
    internal
    returns (int256[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_newData`|`int256[]`|p(t)|
|`_poolParameters`|`QuantAMMPoolParameters`|pool parameters|


### _setGradient


```solidity
function _setGradient(address poolAddress, int256[] memory _initialValues, uint256 _numberOfAssets) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolAddress`|`address`|the pool address being initialised|
|`_initialValues`|`int256[]`|the values passed in during the creation of the pool|
|`_numberOfAssets`|`uint256`|the number of assets in the pool being initialised|


## Structs
### QuantAMMGradientLocals
Struct to store local variables for the gradient calculation

*struct to avoind stack to deep issues*


```solidity
struct QuantAMMGradientLocals {
    int256 mulFactor;
    int256 intermediateValue;
    int256 secondIntermediateValue;
    uint256 secondIndex;
    uint256 storageArrayIndex;
    int256[] finalValues;
    int256[] intermediateGradientState;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`mulFactor`|`int256`|λ^3 / (1 - λ)|
|`intermediateValue`|`int256`|intermediate value during a gradient calculation|
|`secondIntermediateValue`|`int256`|second intermediate value during a gradient calculation|
|`secondIndex`|`uint256`|index of the second intermediate value|
|`storageArrayIndex`|`uint256`|index of the storage array|
|`finalValues`|`int256[]`|final values of the gradient|
|`intermediateGradientState`|`int256[]`|intermediate state during a gradient calculation|

