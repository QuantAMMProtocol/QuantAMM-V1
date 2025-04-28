# MockChannelFollowingRule
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/mock/mockRules/MockChannelFollowing.sol)

**Inherits:**
[ChannelFollowingUpdateRule](/contracts/rules/ChannelFollowingUpdateRule.sol/contract.ChannelFollowingUpdateRule.md)


## State Variables
### weights

```solidity
int256[] weights;
```


## Functions
### constructor


```solidity
constructor(address _updateWeightRunner) ChannelFollowingUpdateRule(_updateWeightRunner);
```

### GetResultWeights


```solidity
function GetResultWeights() external view returns (int256[] memory results);
```

### GetMovingAverages


```solidity
function GetMovingAverages(address poolAddress, uint256 numAssets) external view returns (int256[] memory results);
```

### GetIntermediateValues


```solidity
function GetIntermediateValues(address poolAddress, uint256 numAssets)
    external
    view
    returns (int256[] memory results);
```

### CalculateUnguardedWeights


```solidity
function CalculateUnguardedWeights(
    int256[] calldata _prevWeights,
    int256[] calldata _data,
    address _pool,
    int256[][] calldata _parameters,
    int128[] memory _lambda,
    int256[] memory _movingAverageData
) external;
```

