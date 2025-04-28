# QuantAMMWeightedMathMock
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/mock/QuantAMMWeightedMathMock.sol)


## Functions
### computeInvariant


```solidity
function computeInvariant(uint256[] memory normalizedWeights, uint256[] memory balances, Rounding rounding)
    external
    pure
    returns (uint256);
```

### computeOutGivenExactIn


```solidity
function computeOutGivenExactIn(
    uint256 balanceIn,
    uint256 weightIn,
    uint256 balanceOut,
    uint256 weightOut,
    uint256 amountIn
) external pure returns (uint256);
```

### computeInGivenExactOut


```solidity
function computeInGivenExactOut(
    uint256 balanceIn,
    uint256 weightIn,
    uint256 balanceOut,
    uint256 weightOut,
    uint256 amountOut
) external pure returns (uint256);
```

