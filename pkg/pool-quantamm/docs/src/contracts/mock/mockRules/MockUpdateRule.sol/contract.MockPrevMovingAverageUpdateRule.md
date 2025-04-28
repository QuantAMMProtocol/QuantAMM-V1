# MockPrevMovingAverageUpdateRule
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/mock/mockRules/MockUpdateRule.sol)

**Inherits:**
[MockUpdateRule](/contracts/mock/mockRules/MockUpdateRule.sol/contract.MockUpdateRule.md)


## Functions
### constructor


```solidity
constructor(address _updateWeightRunner) MockUpdateRule(_updateWeightRunner);
```

### _requiresPrevMovingAverage


```solidity
function _requiresPrevMovingAverage() internal pure override returns (uint16);
```

### movingAveragesLength


```solidity
function movingAveragesLength(address _pool) public view returns (uint256);
```

