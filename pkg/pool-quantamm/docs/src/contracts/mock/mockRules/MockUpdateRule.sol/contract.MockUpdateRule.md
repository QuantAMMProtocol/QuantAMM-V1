# MockUpdateRule
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/mock/mockRules/MockUpdateRule.sol)

**Inherits:**
[UpdateRule](/contracts/rules/UpdateRule.sol/abstract.UpdateRule.md)


## State Variables
### weights

```solidity
int256[] weights;
```


### intermediateValues

```solidity
int256[] intermediateValues;
```


### validParametersResults

```solidity
bool validParametersResults;
```


### requiresPrevMovingAverage

```solidity
uint16 requiresPrevMovingAverage;
```


## Functions
### constructor


```solidity
constructor(address _updateWeightRunner) UpdateRule(_updateWeightRunner);
```

### setWeights


```solidity
function setWeights(int256[] memory _weights) external;
```

### GetResultWeights


```solidity
function GetResultWeights() external view returns (int256[] memory results);
```

### GetMovingAverages


```solidity
function GetMovingAverages(address poolAddress, uint256 numAssets) external view returns (int256[] memory results);
```

### validParameters


```solidity
function validParameters(int256[][] calldata) external view override returns (bool);
```

### _getWeights


```solidity
function _getWeights(int256[] calldata, int256[] memory, int256[][] calldata, QuantAMMPoolParameters memory)
    internal
    virtual
    override
    returns (int256[] memory newWeights);
```

### _requiresPrevMovingAverage


```solidity
function _requiresPrevMovingAverage() internal pure virtual override returns (uint16);
```

### _setInitialIntermediateValues


```solidity
function _setInitialIntermediateValues(address, int256[] memory _initialValues, uint256) internal virtual override;
```

