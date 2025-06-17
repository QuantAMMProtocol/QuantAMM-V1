# QuantAMMMathGuard
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/rules/base/QuantammMathGuard.sol)

This contract implements the guard rails for QuantAMM weights updates as described in the QuantAMM whitepaper.


## State Variables
### ONE

```solidity
int256 private constant ONE = 1 * 1e18;
```


### TWO

```solidity
int256 private constant TWO = 2 * 1e18;
```


## Functions
### _guardQuantAMMWeights

Guards QuantAMM weights updates


```solidity
function _guardQuantAMMWeights(
    int256[] memory _weights,
    int256[] calldata _prevWeights,
    int256 _epsilonMax,
    int256 _absoluteWeightGuardRail
) internal pure returns (int256[] memory guardedNewWeights);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_weights`|`int256[]`|Raw weights to be guarded and normalized|
|`_prevWeights`|`int256[]`|Previous weights to be used for normalization|
|`_epsilonMax`|`int256`| Maximum allowed change in weights per update step (epsilon) in the QuantAMM whitepaper|
|`_absoluteWeightGuardRail`|`int256`|Minimum allowed weight in the QuantAMM whitepaper|


### _clampWeights

Applies guard rails (min value, max value) to weights and returns the normalized weights

*there are some edge cases where the clamping might result to break the guard rail. This is known and the last interpolation block logic in the update weight runner is an ultimate guard against this.*


```solidity
function _clampWeights(int256[] memory _weights, int256 _absoluteWeightGuardRail)
    internal
    pure
    returns (int256[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_weights`|`int256[]`|Raw weights|
|`_absoluteWeightGuardRail`|`int256`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`int256[]`|Clamped weights|


### _normalizeWeightUpdates

Normalizes the weights to ensure that the sum of the weights is equal to 1


```solidity
function _normalizeWeightUpdates(int256[] memory _prevWeights, int256[] memory _newWeights, int256 _epsilonMax)
    internal
    pure
    returns (int256[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_prevWeights`|`int256[]`|Previous weights|
|`_newWeights`|`int256[]`|New weights|
|`_epsilonMax`|`int256`|Maximum allowed change in weights per update step (epsilon) in the QuantAMM whitepaper|


### _pow

Raises SD59x18 number x to an arbitrary SD59x18 number y

*Calculates (2^(log2(x)))^y == x^y == 2^(log2(x) * y)*


```solidity
function _pow(int256 _x, int256 _y) internal pure returns (int256 result);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_x`|`int256`|Base|
|`_y`|`int256`|Exponent|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`result`|`int256`|x^y|


