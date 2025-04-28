# MockCalculationRule
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/mock/MockCalculationRule.sol)

**Inherits:**
IUpdateRule, [QuantAMMCovarianceBasedRule](/contracts/rules/base/QuantammCovarianceBasedRule.sol/abstract.QuantAMMCovarianceBasedRule.md), [QuantAMMGradientBasedRule](/contracts/rules/base/QuantammGradientBasedRule.sol/abstract.QuantAMMGradientBasedRule.md), [QuantAMMVarianceBasedRule](/contracts/rules/base/QuantammVarianceBasedRule.sol/contract.QuantAMMVarianceBasedRule.md)


## State Variables
### prevMovingAverage

```solidity
int256[] prevMovingAverage;
```


### results

```solidity
int256[] results;
```


### matrixResults

```solidity
int256[][] matrixResults;
```


## Functions
### setPrevMovingAverage


```solidity
function setPrevMovingAverage(int256[] memory _prevMovingAverage) external;
```

### getResults


```solidity
function getResults() external view returns (int256[] memory);
```

### getMatrixResults


```solidity
function getMatrixResults() external view returns (int256[][] memory);
```

### convert256Array


```solidity
function convert256Array(int256[] memory originalArray) internal pure returns (int128[] memory);
```

### externalCalculateQuantAMMVariance


```solidity
function externalCalculateQuantAMMVariance(
    int256[] calldata _newData,
    int256[] memory _movingAverage,
    address pool,
    int128[] memory _lambda,
    uint256 numAssets
) external;
```

### externalCalculateQuantAMMGradient


```solidity
function externalCalculateQuantAMMGradient(
    int256[] calldata _newData,
    int256[] memory _movingAverage,
    address pool,
    int128[] memory lambda,
    uint256 numAssets
) external;
```

### externalCalculateQuantAMMCovariance


```solidity
function externalCalculateQuantAMMCovariance(
    int256[] calldata _newData,
    int256[] memory _movingAverage,
    address pool,
    int128[] memory _lambda,
    uint256 numAssets
) external;
```

### setInitialGradient


```solidity
function setInitialGradient(address poolAddress, int256[] memory _initialValues, uint256 _numberOfAssets) external;
```

### getInitialGradient


```solidity
function getInitialGradient(address poolAddress, uint256 numAssets) external view returns (int256[] memory);
```

### setInitialVariance


```solidity
function setInitialVariance(address poolAddress, int256[] memory _initialValues, uint256 _numberOfAssets) external;
```

### getIntermediateVariance


```solidity
function getIntermediateVariance(address poolAddress, uint256 _numberOfAssets)
    external
    view
    returns (int256[] memory);
```

### setInitialCovariance


```solidity
function setInitialCovariance(address poolAddress, int256[][] memory _initialValues, uint256 _numberOfAssets)
    external;
```

### getIntermediateCovariance


```solidity
function getIntermediateCovariance(address poolAddress, uint256 _numberOfAssets)
    external
    view
    returns (int256[][] memory);
```

### CalculateNewWeights


```solidity
function CalculateNewWeights(
    int256[] calldata prevWeights,
    int256[] calldata data,
    address pool,
    int256[][] calldata _parameters,
    uint64[] calldata lambdaStore,
    uint64 epsilonMax,
    uint64 absoluteWeightGuardRail
) external override returns (int256[] memory updatedWeights);
```

### initialisePoolRuleIntermediateValues


```solidity
function initialisePoolRuleIntermediateValues(
    address poolAddress,
    int256[] memory _newMovingAverages,
    int256[] memory _newParameters,
    uint256 _numberOfAssets
) external override;
```

### validParameters

Check if the given parameters are valid for the rule


```solidity
function validParameters(int256[][] calldata parameters) external pure override returns (bool);
```

