# QuantAMMCovarianceBasedRule
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/rules/base/QuantammCovarianceBasedRule.sol)

**Inherits:**
[VectorRuleQuantAMMStorage](/contracts/QuantAMMStorage.sol/abstract.VectorRuleQuantAMMStorage.md)

This contract is abstract and needs to be inherited and implemented to be used. It also stores the intermediate values of all pools


## State Variables
### ONE

```solidity
int256 private constant ONE = 1 * 1e18;
```


### TENPOWEIGHTEEN

```solidity
int256 private constant TENPOWEIGHTEEN = (10 ** 18);
```


### intermediateCovarianceStates

```solidity
mapping(address => int256[]) internal intermediateCovarianceStates;
```


## Functions
### getIntermediateCovarianceState

View function to get the intermediate covariance state for a given pool


```solidity
function getIntermediateCovarianceState(address poolAddress, uint256 numberOfAssets)
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
|`<none>`|`int256[]`|The unpacked intermediate covariance state as a 1D flattened array of int256|


### _calculateQuantAMMCovariance

Calculates the new intermediate state for the covariance update, i.e. A(t) = λA(t - 1) + (p(t) - p̅(t - 1))(p(t) - p̅(t))'


```solidity
function _calculateQuantAMMCovariance(int256[] memory _newData, QuantAMMPoolParameters memory _poolParameters)
    internal
    returns (int256[][] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_newData`|`int256[]`|p(t)|
|`_poolParameters`|`QuantAMMPoolParameters`|pool parameters|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`int256[][]`|newState new state of the covariance matrix|


### _setIntermediateCovariance


```solidity
function _setIntermediateCovariance(address _poolAddress, int256[][] memory _initialValues, uint256 _numberOfAssets)
    internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|the pool address being initialised|
|`_initialValues`|`int256[][]`|the values passed in during the creation of the pool|
|`_numberOfAssets`|`uint256`| the number of assets in the pool being initialised|


## Structs
### QuantAMMCovariance
Struct to store local variables for the covariance calculation

*struct to avoind stack to deep issues*


```solidity
struct QuantAMMCovariance {
    uint256 n;
    int256[][] intermediateCovarianceState;
    int256[][] newState;
    int256[] u;
    int256[] v;
    int256 convertedLambda;
    int256 oneMinusLambda;
    int256 intermediateState;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`n`|`uint256`|Dimension of square matrix|
|`intermediateCovarianceState`|`int256[][]`|intermediate state of the covariance matrix|
|`newState`|`int256[][]`|new state of the covariance matrix|
|`u`|`int256[]`|(p(t) - p̅(t - 1))|
|`v`|`int256[]`|(p(t) - p̅(t))|
|`convertedLambda`|`int256`|λ|
|`oneMinusLambda`|`int256`|1 - λ|
|`intermediateState`|`int256`|intermediate state during a covariance matrix calculation|

