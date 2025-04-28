# MockQuantAMMBasePool
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/mock/MockQuantAMMBasePool.sol)

**Inherits:**
IQuantAMMWeightedPool, IBasePool


## State Variables
### weights

```solidity
int256[] public weights;
```


### lastInterpolationTimePossible

```solidity
uint40 public lastInterpolationTimePossible;
```


### ruleParameters

```solidity
int256[][] public ruleParameters;
```


### lambda

```solidity
uint64[] public lambda;
```


### epsilonMax

```solidity
uint64 public immutable epsilonMax;
```


### absoluteWeightGuardRail

```solidity
uint64 public immutable absoluteWeightGuardRail;
```


### updateInterval

```solidity
uint64 public immutable updateInterval;
```


### oracleStalenessThreshold

```solidity
uint256 immutable oracleStalenessThreshold;
```


### poolAddress

```solidity
address poolAddress;
```


### poolRegistry

```solidity
uint256 public poolRegistry;
```


### assets

```solidity
IERC20[] public assets;
```


### updateWeightRunner

```solidity
UpdateWeightRunner internal immutable updateWeightRunner;
```


### fixEnabled

```solidity
bool fixEnabled = true;
```


## Functions
### constructor


```solidity
constructor(uint40 _updateInterval, address _updateWeightRunner);
```

### getWeights


```solidity
function getWeights() external view returns (int256[] memory);
```

### setWeights


```solidity
function setWeights(int256[] calldata _weights, address _poolAddress, uint40 _lastInterpolationTimePossible)
    external
    override;
```

### getMinimumSwapFeePercentage


```solidity
function getMinimumSwapFeePercentage() external view override returns (uint256);
```

### getMaximumSwapFeePercentage


```solidity
function getMaximumSwapFeePercentage() external view override returns (uint256);
```

### getMinimumInvariantRatio


```solidity
function getMinimumInvariantRatio() external view override returns (uint256);
```

### getMaximumInvariantRatio


```solidity
function getMaximumInvariantRatio() external view override returns (uint256);
```

### getWithinFixWindow


```solidity
function getWithinFixWindow() external view override returns (bool);
```

### getPoolDetail


```solidity
function getPoolDetail(string memory category, string memory name)
    external
    view
    returns (string memory, string memory);
```

### computeInvariant


```solidity
function computeInvariant(uint256[] memory balancesLiveScaled18, Rounding rounding)
    external
    view
    override
    returns (uint256 invariant);
```

### computeBalance


```solidity
function computeBalance(uint256[] memory balancesLiveScaled18, uint256 tokenInIndex, uint256 invariantRatio)
    external
    view
    override
    returns (uint256 newBalance);
```

### onSwap


```solidity
function onSwap(PoolSwapParams calldata params) external override returns (uint256 amountCalculatedScaled18);
```

### getNormalizedWeights


```solidity
function getNormalizedWeights() external view override returns (uint256[] memory);
```

### setInitialWeights


```solidity
function setInitialWeights(int256[] calldata _weights) external;
```

### setRuleForPool


```solidity
function setRuleForPool(PoolSettings calldata _settings) external;
```

### setPoolRegistry


```solidity
function setPoolRegistry(uint256 _poolRegistry) external;
```

### getOracleStalenessThreshold


```solidity
function getOracleStalenessThreshold() external view override returns (uint256);
```

### getQuantAMMWeightedPoolDynamicData


```solidity
function getQuantAMMWeightedPoolDynamicData()
    external
    view
    override
    returns (QuantAMMWeightedPoolDynamicData memory data);
```

### getQuantAMMWeightedPoolImmutableData


```solidity
function getQuantAMMWeightedPoolImmutableData()
    external
    view
    override
    returns (QuantAMMWeightedPoolImmutableData memory data);
```

### setUpdateWeightRunnerAddress


```solidity
function setUpdateWeightRunnerAddress(address _updateWeightRunner) external override;
```

