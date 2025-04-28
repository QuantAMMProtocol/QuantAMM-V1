# MockQuantAMMMathGuard
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/mock/MockQuantAMMMathGuard.sol)

**Inherits:**
[QuantAMMMathGuard](/contracts/rules/base/QuantammMathGuard.sol/abstract.QuantAMMMathGuard.md)


## Functions
### mockGuardQuantAMMWeights


```solidity
function mockGuardQuantAMMWeights(
    int256[] memory _weights,
    int256[] calldata _prevWeights,
    int256 _epsilonMax,
    int256 _absoluteWeightGuardRail
) external pure returns (int256[] memory guardedNewWeights);
```

### mockNormalizeWeightUpdates


```solidity
function mockNormalizeWeightUpdates(int256[] memory _prevWeights, int256[] memory _newWeights, int256 _epsilonMax)
    external
    pure
    returns (int256[] memory normalizedWeights);
```

### mockClampWeights


```solidity
function mockClampWeights(int256[] memory _weights, int256 _absoluteWeightGuardRail)
    external
    pure
    returns (int256[] memory clampedWeights);
```

