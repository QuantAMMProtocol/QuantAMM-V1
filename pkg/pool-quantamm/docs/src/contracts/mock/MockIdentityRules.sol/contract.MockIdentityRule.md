# MockIdentityRule
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/mock/MockIdentityRules.sol)

**Inherits:**
IUpdateRule

Rule that simply returns the previous weights for testing


## State Variables
### queryGradient
Flags to control in tests which data should be pulled


```solidity
bool queryGradient;
```


### queryCovariances

```solidity
bool queryCovariances;
```


### queryPrecision

```solidity
bool queryPrecision;
```


### queryVariances

```solidity
bool queryVariances;
```


### expectedDataValue

```solidity
int256[] expectedDataValue;
```


### CalculateNewWeightsCalled

```solidity
bool public CalculateNewWeightsCalled;
```


### movingAverages

```solidity
int256[] public movingAverages;
```


### intermediateValues

```solidity
int256[] public intermediateValues;
```


### numberOfAssets

```solidity
uint256 public numberOfAssets;
```


### weights

```solidity
int256[] weights;
```


## Functions
### getWeights


```solidity
function getWeights() external view returns (int256[] memory);
```

### getMovingAverages


```solidity
function getMovingAverages() external view returns (int256[] memory);
```

### getIntermediateValues


```solidity
function getIntermediateValues() external view returns (int256[] memory);
```

### CalculateNewWeights


```solidity
function CalculateNewWeights(
    int256[] calldata prevWeights,
    int256[] calldata data,
    address,
    int256[][] calldata,
    uint64[] calldata,
    uint64,
    uint64
) external override returns (int256[] memory);
```

### initialisePoolRuleIntermediateValues


```solidity
function initialisePoolRuleIntermediateValues(
    address,
    int256[] memory _newMovingAverages,
    int256[] memory _newParameters,
    uint256 _numberOfAssets
) external override;
```

### validParameters

Check if the given parameters are valid for the rule


```solidity
function validParameters(int256[][] calldata) external pure override returns (bool);
```

### SetCalculateNewWeightsCalled


```solidity
function SetCalculateNewWeightsCalled(bool newVal) external;
```

### setQueryGradient


```solidity
function setQueryGradient(bool _queryGradient) public;
```

### setQueryCovariances


```solidity
function setQueryCovariances(bool _queryCovariances) public;
```

### setQueryPrecision


```solidity
function setQueryPrecision(bool _queryPrecision) public;
```

### setQueryVariances


```solidity
function setQueryVariances(bool _queryVariances) public;
```

### setWeights


```solidity
function setWeights(int256[] memory newCalculatedWeights) public;
```

### setExpectedDataValue


```solidity
function setExpectedDataValue(int256[] memory _expectedDataValue) public;
```

