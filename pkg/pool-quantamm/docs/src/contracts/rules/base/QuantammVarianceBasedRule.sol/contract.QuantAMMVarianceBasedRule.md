# QuantAMMVarianceBasedRule
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/rules/base/QuantammVarianceBasedRule.sol)

**Inherits:**
[ScalarRuleQuantAMMStorage](/contracts/QuantAMMStorage.sol/abstract.ScalarRuleQuantAMMStorage.md)

Contains the logic for calculating the variance of the pool price and storing the variance


## State Variables
### ONE

```solidity
int256 private constant ONE = 1 * 1e18;
```


### TENPOWEIGHTEEN

```solidity
int256 private constant TENPOWEIGHTEEN = (10 ** 18);
```


### _protectedAccess

```solidity
bool private immutable _protectedAccess;
```


### intermediateVarianceStates

```solidity
mapping(address => int256[]) internal intermediateVarianceStates;
```


## Functions
### getIntermediateVarianceState

View function to get the intermediate variance state for a given pool


```solidity
function getIntermediateVarianceState(address poolAddress, uint256 numberOfAssets)
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
|`<none>`|`int256[]`|The unpacked intermediate variance state as an array of int256|


### _calculateQuantAMMVariance

Calculates the new intermediate state for the variance update, i.e. the diagonal entries of A(t) = λA(t - 1) + (p(t) - p̅(t - 1))(p(t) - p̅(t))'

Calculates the new variances vector given the intermediate state, i.e. the diagonal entries of Σ(t) = (1 - λ)A(t)


```solidity
function _calculateQuantAMMVariance(int256[] memory _newData, QuantAMMPoolParameters memory _poolParameters)
    internal
    returns (int256[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_newData`|`int256[]`|p(t)|
|`_poolParameters`|`QuantAMMPoolParameters`|_movingAverage p̅(t), _lambda λ, _numberOfAssets number of assets in the pool, _pool the target pool address|


### _setIntermediateVariance


```solidity
function _setIntermediateVariance(address _poolAddress, int256[] memory _initialValues, uint256 _numberOfAssets)
    internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|the target pool address|
|`_initialValues`|`int256[]`|the initial variance values|
|`_numberOfAssets`|`uint256`|the number of assets in the pool|


## Structs
### QuantAMMVarianceLocals
Struct to store local variables for the variance calculation

*struct to avoind stack to deep issues*


```solidity
struct QuantAMMVarianceLocals {
    uint256 storageIndex;
    uint256 secondIndex;
    int256 intermediateState;
    uint256 n;
    uint256 nMinusOne;
    bool notDivisibleByTwo;
    int256 convertedLambda;
    int256 oneMinusLambda;
    int256[] intermediateVarianceState;
    int256[] finalState;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`storageIndex`|`uint256`|index of the storage array|
|`secondIndex`|`uint256`|index of the second intermediate value|
|`intermediateState`|`int256`|intermediate state during a variance calculation|
|`n`|`uint256`|number of assets in the pool|
|`nMinusOne`|`uint256`|n - 1|
|`notDivisibleByTwo`|`bool`|boolean to check if n is not divisible by 2|
|`convertedLambda`|`int256`|λ|
|`oneMinusLambda`|`int256`|1 - λ|
|`intermediateVarianceState`|`int256[]`|intermediate state of the variance|
|`finalState`|`int256[]`|final state of the variance|

