# PowerChannelUpdateRule
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/rules/PowerChannelUpdateRule.sol)

**Inherits:**
[QuantAMMGradientBasedRule](/contracts/rules/base/QuantammGradientBasedRule.sol/abstract.QuantAMMGradientBasedRule.md), [UpdateRule](/contracts/rules/UpdateRule.sol/abstract.UpdateRule.md)

Contains the logic for calculating the new weights of a QuantAMM pool using the power channel update rule


## State Variables
### ONE

```solidity
int256 private constant ONE = 1 * 1e18;
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

w(t) = w(t − 1) + κ · ( sign(1/p(t)*∂p(t)/∂t) * |1/p(t)*∂p(t)/∂t|^q − ℓp(t) ) where ℓp(t) = 1/N * ∑(sign(1/p(t)*∂p(t)/∂t) * |1/p(t)*∂p(t)/∂t|^q)


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
|`_data`|`int256[]`|the latest data from the signal, usually price|
|`_parameters`|`int256[][]`|the parameters of the rule that are not lambda|
|`_poolParameters`|`QuantAMMPoolParameters`|pool parameters [0]=k, [1]=q, can be per token (vector) or single for all tokens (scalar), [2]=useRawPrice|


### _requiresPrevMovingAverage

Get the number of assets required for the rule


```solidity
function _requiresPrevMovingAverage() internal pure override returns (uint16);
```

### _setInitialIntermediateValues

Set the initial intermediate values for the rule, in this case the gradient


```solidity
function _setInitialIntermediateValues(address _poolAddress, int256[] memory _initialValues, uint256 _numberOfAssets)
    internal
    override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|address of pool being initialised|
|`_initialValues`|`int256[]`|the initial intermediate values provided|
|`_numberOfAssets`|`uint256`|number of assets in the pool|


### validParameters

Check if the given parameters are valid for the rule

*If parameters are not valid, either reverts or returns false*


```solidity
function validParameters(int256[][] calldata parameters) external pure override returns (bool valid);
```

## Structs
### QuantAMMPowerChannelLocals
Struct to store local variables for the power channel calculation

*struct to avoid stack too deep issues*


```solidity
struct QuantAMMPowerChannelLocals {
    int256[] kappa;
    int256[] newWeights;
    int256 normalizationFactor;
    uint256 prevWeightsLength;
    bool useRawPrice;
    uint256 i;
    int256 q;
    int256[] vectorQ;
    int256 denominator;
    int256 sumKappa;
    int256 res;
    int256 sign;
    int256 intermediateRes;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`kappa`|`int256[]`|array of kappa value parameters|
|`newWeights`|`int256[]`|array of new weights|
|`normalizationFactor`|`int256`|normalization factor for the weights|
|`prevWeightsLength`|`uint256`|length of the previous weights|
|`useRawPrice`|`bool`|boolean to determine if raw price should be used or average|
|`i`|`uint256`|index for looping|
|`q`|`int256`|Q value|
|`vectorQ`|`int256[]`||
|`denominator`|`int256`|denominator for the weights|
|`sumKappa`|`int256`|sum of all kappa values|
|`res`|`int256`|result of the calculation|
|`sign`|`int256`|sign of the calculation|
|`intermediateRes`|`int256`|intermediate result of the calculation|

