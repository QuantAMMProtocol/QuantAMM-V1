# MockUpdateWeightRunner
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/mock/MockUpdateWeightRunner.sol)

**Inherits:**
[UpdateWeightRunner](/contracts/UpdateWeightRunner.sol/contract.UpdateWeightRunner.md)

*Additionally exposes private fields for testing, otherwise normal update weight runner*


## State Variables
### _overrideGetData

```solidity
bool private _overrideGetData;
```


### mockPrices

```solidity
mapping(address => int256[]) public mockPrices;
```


## Functions
### constructor


```solidity
constructor(address _vaultAdmin, address ethOracle, bool overrideGetData) UpdateWeightRunner(_vaultAdmin, ethOracle);
```

### performFirstUpdate


```solidity
function performFirstUpdate(address _pool) external;
```

### calculateMultiplierAndSetWeights


```solidity
function calculateMultiplierAndSetWeights(
    int256[] memory oldWeights,
    int256[] memory newWeights,
    uint40 updateInterval,
    uint64 absWeightGuardRail,
    address pool
) public;
```

### setMockPrices


```solidity
function setMockPrices(address _pool, int256[] memory prices) external;
```

### getData


```solidity
function getData(address _pool) public view override returns (int256[] memory outputData);
```

