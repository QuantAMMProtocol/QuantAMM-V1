# MinimumVarianceUpdateRule
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/rules/MinimumVarianceUpdateRule.sol)

**Inherits:**
[QuantAMMVarianceBasedRule](/contracts/rules/base/QuantammVarianceBasedRule.sol/contract.QuantAMMVarianceBasedRule.md), [UpdateRule](/contracts/rules/UpdateRule.sol/abstract.UpdateRule.md)

Contains the logic for calculating the new weights of a QuantAMM pool using the minimum variance update rule and updating the weights of the QuantAMM pool


## State Variables
### ONE

```solidity
int256 private constant ONE = 1 * 1e18;
```


### REQUIRES_PREV_MAVG

```solidity
uint16 private constant REQUIRES_PREV_MAVG = 1;
```


## Functions
### constructor


```solidity
constructor(address _updateWeightRunner) UpdateRule(_updateWeightRunner);
```

### _getWeights

w(t) = (Λ * w(t − 1)) + ((1 − Λ)*Σ^−1(t)) / N,j=1∑ Σ^−1 j(t) - see whitepaper


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
|`_poolParameters`|`QuantAMMPoolParameters`|pool parameters [0]=Λ|


### _setInitialIntermediateValues

Set the initial intermediate values for the rule


```solidity
function _setInitialIntermediateValues(address _poolAddress, int256[] memory _initialValues, uint256 _numberOfAssets)
    internal
    override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_poolAddress`|`address`|target pool address|
|`_initialValues`|`int256[]`|initial values of intermediate state|
|`_numberOfAssets`|`uint256`|number of assets in the pool|


### _requiresPrevMovingAverage

Wether the rule requires the previous moving average


```solidity
function _requiresPrevMovingAverage() internal pure override returns (uint16);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint16`|1 if the rule requires the previous moving average, 0 otherwise|


### validParameters

Check if the given parameters are valid for the rule

*If parameters are not valid, either reverts or returns false*


```solidity
function validParameters(int256[][] calldata _parameters) external pure override returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_parameters`|`int256[][]`|the parameters of the rule, in this case the mixing variance|


