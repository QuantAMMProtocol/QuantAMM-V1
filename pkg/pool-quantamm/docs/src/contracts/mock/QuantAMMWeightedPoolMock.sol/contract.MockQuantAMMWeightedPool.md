# MockQuantAMMWeightedPool
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/mock/QuantAMMWeightedPoolMock.sol)

**Inherits:**
[QuantAMMWeightedPool](/contracts/QuantAMMWeightedPool.sol/contract.QuantAMMWeightedPool.md)


## State Variables
### _normalizedWeights

```solidity
uint256[] private _normalizedWeights;
```


## Functions
### constructor


```solidity
constructor(NewPoolParams memory params, IVault vault) QuantAMMWeightedPool(params, vault);
```

### setNormalizedWeight


```solidity
function setNormalizedWeight(uint256 tokenIndex, uint256 newWeight) external;
```

### setNormalizedWeights


```solidity
function setNormalizedWeights(uint256[2] memory newWeights) external;
```

### _getNormalizedWeight


```solidity
function _getNormalizedWeight(uint256 tokenIndex, uint256, uint256) internal view override returns (uint256);
```

### _getNormalizedWeights


```solidity
function _getNormalizedWeights() internal view override returns (uint256[] memory);
```

