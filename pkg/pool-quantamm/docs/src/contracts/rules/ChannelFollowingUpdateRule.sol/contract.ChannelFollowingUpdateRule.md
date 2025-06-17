# ChannelFollowingUpdateRule
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/rules/ChannelFollowingUpdateRule.sol)

**Inherits:**
[QuantAMMGradientBasedRule](/contracts/rules/base/QuantammGradientBasedRule.sol/abstract.QuantAMMGradientBasedRule.md), [UpdateRule](/contracts/rules/UpdateRule.sol/abstract.UpdateRule.md)

Contains the logic for calculating the new weights of a QuantAMM pool using the channel following strategy


## State Variables
### ONE

```solidity
int256 private constant ONE = 1e18;
```


### TWO

```solidity
int256 private constant TWO = 2e18;
```


### THREE

```solidity
int256 private constant THREE = 3e18;
```


### SIX

```solidity
int256 private constant SIX = 6e18;
```


### PI

```solidity
int256 private constant PI = 3.141592653589793238e18;
```


### REQUIRES_PREV_MAVG

```solidity
uint16 private constant REQUIRES_PREV_MAVG = 0;
```


## Functions
### constructor


```solidity
constructor(address _updateWeightRunner) UpdateRule(_updateWeightRunner);
```

### _getWeights

Calculates the new weights for a QuantAMM pool using the channel following strategy.

The channel following strategy combines trend following with a channel component:
w(t) = w(t-1) + κ[channel + trend - normalizationFactor]
where:
- g = normalized price gradient = (1/p)·(dp/dt)
- envelope = exp(-g²/(2W²))
- s = pi * g / (3W)
- channel = -(A/h)·envelope · (s - 1/6 s^3)
- trend = (1-envelope) * sign(g) * |g/(2S)|^(exponent)
- normalizationFactor = 1/N * ∑(κ[channel + trend])_i
Parameters:
- κ: Kappa controls overall update magnitude
- W: Width controls the channel and envelope width
- A: Amplitude controls channel height
- exponents: Exponent for the trend following portion
- h: Inverse scaling within the channel
- S: Pre-exp scaling for trend component
The strategy aims to:
1. Mean-revert within the channel (channel component, for small changes in g)
2. Follow trends (nonlinearly, if exponents are not 1) outside the channel (trend component, for large changes in g)
3. Smoothly transition between the two regimes (via the envelope function)


```solidity
function _getWeights(
    int256[] calldata _prevWeights,
    int256[] memory _data,
    int256[][] calldata _parameters,
    QuantAMMPoolParameters memory _poolParameters
) internal override returns (int256[] memory newWeightsConverted);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_prevWeights`|`int256[]`|the previous weights retrieved from the vault|
|`_data`|`int256[]`|the latest data, usually price|
|`_parameters`|`int256[][]`|the parameters of the rule that are not lambda. Parameters [0] through [5] are arrays/vectors, [6] is a scalar. [0]=kappa [1]=width [2]=amplitude [3]=exponents [4]=inverseScaling [5]=preExpScaling [6]=useRawPrice|
|`_poolParameters`|`QuantAMMPoolParameters`||


### _requiresPrevMovingAverage

Check if the rule requires the previous moving average


```solidity
function _requiresPrevMovingAverage() internal pure override returns (uint16);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint16`|0 if it does not require the previous moving average, 1 if it does|


### _setInitialIntermediateValues

Set the initial intermediate values for the pool, in this case the gradient


```solidity
function _setInitialIntermediateValues(address _poolAddress, int256[] memory _initialValues, uint256 _numberOfAssets)
    internal
    override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|the target pool address|
|`_initialValues`|`int256[]`|the initial values of the pool|
|`_numberOfAssets`|`uint256`|the number of assets in the pool|


### validParameters


```solidity
function validParameters(int256[][] calldata _parameters) external pure override returns (bool);
```

## Structs
### ChannelFollowingLocals
Struct to store local variables for the channel following calculation

*struct to avoid stack too deep issues*


```solidity
struct ChannelFollowingLocals {
    int256[] kappa;
    int256[] width;
    int256[] amplitude;
    int256[] exponents;
    int256[] inverseScaling;
    int256[] preExpScaling;
    int256[] newWeights;
    int256[] signal;
    int256 normalizationFactor;
    uint256 prevWeightLength;
    bool useRawPrice;
    uint256 i;
    int256 denominator;
    int256 sumKappa;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`kappa`|`int256[]`|array of kappa value parameters|
|`width`|`int256[]`|array of width value parameters|
|`amplitude`|`int256[]`|array of amplitude value parameters|
|`exponents`|`int256[]`|array of exponent value parameters|
|`inverseScaling`|`int256[]`|array of inverse scaling value parameters|
|`preExpScaling`|`int256[]`|array of pre-exp scaling value parameters|
|`newWeights`|`int256[]`|array of new weights|
|`signal`|`int256[]`|array of signal values|
|`normalizationFactor`|`int256`|normalization factor for the weights|
|`prevWeightLength`|`uint256`|length of the previous weights|
|`useRawPrice`|`bool`|boolean to determine if raw price should be used or average|
|`i`|`uint256`|index for looping|
|`denominator`|`int256`|denominator for the weights|
|`sumKappa`|`int256`|sum of all kappa values|

