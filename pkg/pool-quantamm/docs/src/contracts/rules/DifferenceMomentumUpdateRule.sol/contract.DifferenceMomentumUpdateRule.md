# DifferenceMomentumUpdateRule
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/rules/DifferenceMomentumUpdateRule.sol)

**Inherits:**
[QuantAMMGradientBasedRule](/contracts/rules/base/QuantammGradientBasedRule.sol/abstract.QuantAMMGradientBasedRule.md), [UpdateRule](/contracts/rules/UpdateRule.sol/abstract.UpdateRule.md)

Contains the logic for calculating the new weights of a QuantAMM pool using the difference momentum update rule


## State Variables
### ONE

```solidity
int256 private constant ONE = 1 * 1e18;
```


### REQUIRES_PREV_MAVG

```solidity
uint16 private constant REQUIRES_PREV_MAVG = 0;
```


### shortMovingAverages

```solidity
mapping(address => int256[]) public shortMovingAverages;
```


## Functions
### constructor


```solidity
constructor(address _updateWeightRunner) UpdateRule(_updateWeightRunner);
```

### _getWeights

w(t) = w(t − 1) + κ · (  (EWMA_short - EWMA_long) / EWMA_long − ℓp(t)) where ℓp(t) = 1/N * ∑((EWMA_short - EWMA_long) / EWMA_long)_i


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
|`_parameters`|`int256[][]`|The parameters of the rule that are not lambda_long: [0] = kappa: Can be per token (vector) or single for all tokens (scalar) [1] = lambda short: Can be per token (vector) or single for all tokens (scalar)|
|`_poolParameters`|`QuantAMMPoolParameters`||


### _setInitialIntermediateValues

Set the initial intermediate values for the pool, in this case the moving averages


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


### _requiresPrevMovingAverage

Check if the rule requires the previous moving average


```solidity
function _requiresPrevMovingAverage() internal pure override returns (uint16);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint16`|0 if it does not require the previous moving average, 1 if it does|


### validParameters

Check if the given parameters are valid for the rule

*If parameters are not valid, either reverts or returns false*


```solidity
function validParameters(int256[][] calldata _parameters) external pure override returns (bool);
```

## Structs
### QuantAMMDifferenceMomentumLocals
Struct to store local variables for the momentum calculation

*struct to avoid stack too deep issues*


```solidity
struct QuantAMMDifferenceMomentumLocals {
    int256[] kappaStore;
    int256[] newWeights;
    int256 normalizationFactor;
    uint256 prevWeightLength;
    uint256 i;
    int256 denominator;
    int256 sumKappa;
    int256 res;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`kappaStore`|`int256[]`|array of kappa value parameters|
|`newWeights`|`int256[]`|array of new weights|
|`normalizationFactor`|`int256`|normalization factor for the weights|
|`prevWeightLength`|`uint256`|length of the previous weights|
|`i`|`uint256`|index for looping|
|`denominator`|`int256`|denominator for the weights|
|`sumKappa`|`int256`|sum of all kappa values|
|`res`|`int256`|result of the calculation|

