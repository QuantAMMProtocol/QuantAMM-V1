# MockPool
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/mock/MockPool.sol)


## State Variables
### updateInterval

```solidity
uint40 public immutable updateInterval;
```


### lambda

```solidity
int256 public lambda;
```


### epsilonMax

```solidity
int256 public epsilonMax;
```


### absoluteWeightGuardRail

```solidity
int256 public absoluteWeightGuardRail;
```


### invariantValue

```solidity
uint256 private invariantValue;
```


### numberOfAssets

```solidity
uint256 private numberOfAssets;
```


### oracleStalenessThreshold

```solidity
uint256 immutable oracleStalenessThreshold;
```


### updateWeightRunner

```solidity
address immutable updateWeightRunner;
```


### poolLpTokenValue

```solidity
uint256 poolLpTokenValue;
```


### afterTokenTransferID

```solidity
uint256 public afterTokenTransferID;
```


## Functions
### constructor


```solidity
constructor(uint40 _updateInterval, int256 _lambda, address _updateWeightRunner);
```

### numAssets


```solidity
function numAssets() external view returns (uint256);
```

### getBaseAssets


```solidity
function getBaseAssets() external view returns (IERC20[] memory);
```

### getAssets


```solidity
function getAssets() external view returns (address[] memory);
```

### getEpsilonMax


```solidity
function getEpsilonMax() external view returns (int256);
```

### getAbsoluteGuardRails


```solidity
function getAbsoluteGuardRails() external view returns (int256);
```

### setRuleForPool


```solidity
function setRuleForPool(
    IUpdateRule _rule,
    address[][] calldata _poolOracles,
    uint64[] calldata _lambda,
    int256[][] calldata _ruleParameters,
    uint64 _epsilonMax,
    uint64 _absoluteWeightGuardRail,
    uint40 _updateInterval,
    address _poolManager
) external;
```

### setNumberOfAssets


```solidity
function setNumberOfAssets(uint256 _numberOfAssets) external;
```

### performRuleUpdate


```solidity
function performRuleUpdate() external;
```

### callSetRuleForPool


```solidity
function callSetRuleForPool(
    UpdateWeightRunner _updateWeightRunner,
    IUpdateRule _rule,
    address[][] calldata _poolOracles,
    uint64[] calldata _lambda,
    int256[][] calldata _ruleParameters,
    uint64 _epsilonMax,
    uint64 _absoluteWeightGuardRail
) public;
```

### setLambda


```solidity
function setLambda(int256 _lambda) public;
```

### setEpsilonMax


```solidity
function setEpsilonMax(int256 _epsilonMax) public;
```

### setAbsoluteWeightGuardRail


```solidity
function setAbsoluteWeightGuardRail(int256 _absoluteWeightGuardRail) public;
```

### setInvariant


```solidity
function setInvariant(uint256 _invariant) public;
```

### getTokenAddress


```solidity
function getTokenAddress() public pure returns (address tokenAddress);
```

### getOracleStalenessThreshold


```solidity
function getOracleStalenessThreshold() external view returns (uint256);
```

### setPoolLPTokenValue


```solidity
function setPoolLPTokenValue(uint256 _poolLPTokenValue) public;
```

### getPoolLPTokenValue


```solidity
function getPoolLPTokenValue(int256[] memory) public view returns (uint256);
```

### afterTokenTransfer


```solidity
function afterTokenTransfer(address, address, uint256 firstTokenId) public;
```

