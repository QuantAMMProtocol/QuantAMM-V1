# MockRuleInvoker
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/mock/MockRuleInvoker.sol)

*Used to test rules in isolation with provided values*


## State Variables
### weights

```solidity
int256[] weights;
```


## Functions
### getWeights


```solidity
function getWeights() public view returns (int256[] memory);
```

### invokeRule


```solidity
function invokeRule(
    UpdateRule _rule,
    int256[] calldata prevWeights,
    int256[] calldata data,
    address pool,
    int256[][] calldata parameters,
    uint64[] calldata lambdaStore,
    uint64 epsilonMax,
    uint64 absoluteWeightGuardRail
) external;
```

