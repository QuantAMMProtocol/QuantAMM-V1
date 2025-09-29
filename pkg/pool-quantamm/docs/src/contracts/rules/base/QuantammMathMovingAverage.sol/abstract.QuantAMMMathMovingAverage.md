# QuantAMMMathMovingAverage
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/rules/base/QuantammMathMovingAverage.sol)

**Inherits:**
[ScalarRuleQuantAMMStorage](/contracts/QuantAMMStorage.sol/abstract.ScalarRuleQuantAMMStorage.md)

Contains the logic for calculating the moving average of the pool price and storing the moving averages


## State Variables
### ONE

```solidity
int256 private constant ONE = 1 * 1e18;
```


### movingAverages

```solidity
mapping(address => int256[]) public movingAverages;
```


## Functions
### getMovingAverages

View function to get the moving averages for a given pool


```solidity
function getMovingAverages(address poolAddress, uint256 numberOfAssets) external view returns (int256[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolAddress`|`address`|The address of the pool|
|`numberOfAssets`|`uint256`|The number of assets in the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`int256[]`|The unpacked moving averages as an array of int256|


### _calculateQuantAMMMovingAverage

Calculates the new moving average value, i.e. p̅(t) = p̅(t - 1) + (1 - λ)(p(t) - p̅(t - 1))


```solidity
function _calculateQuantAMMMovingAverage(
    int256[] memory _prevMovingAverage,
    int256[] memory _newData,
    int128[] memory _lambda,
    uint256 _numberOfAssets
) internal pure returns (int256[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_prevMovingAverage`|`int256[]`|p̅(t - 1)|
|`_newData`|`int256[]`|p(t)|
|`_lambda`|`int128[]`|λ|
|`_numberOfAssets`|`uint256`|number of assets in the pool|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`int256[]`|p̅(t) avertage price of the pool|


### _setInitialMovingAverages


```solidity
function _setInitialMovingAverages(
    address _poolAddress,
    int256[] memory _initialMovingAverages,
    uint256 _numberOfAssets
) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|address of pool being initialised|
|`_initialMovingAverages`|`int256[]`|array of initial moving averages|
|`_numberOfAssets`|`uint256`|number of assets in the pool|


