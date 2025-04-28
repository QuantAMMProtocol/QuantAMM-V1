# EchidnaStoragePack
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/echidna/echidna_storage_pack.sol)

**Inherits:**
[ScalarQuantAMMBaseStorage](/contracts/QuantAMMStorage.sol/abstract.ScalarQuantAMMBaseStorage.md), [ScalarRuleQuantAMMStorage](/contracts/QuantAMMStorage.sol/abstract.ScalarRuleQuantAMMStorage.md), [VectorRuleQuantAMMStorage](/contracts/QuantAMMStorage.sol/abstract.VectorRuleQuantAMMStorage.md)


## State Variables
### mockQuantAMMMatrix

```solidity
int256[] internal mockQuantAMMMatrix;
```


### matrixResult

```solidity
int256[][] internal matrixResult;
```


## Functions
### r_packUnpack32Array


```solidity
function r_packUnpack32Array(int256[] memory sourceArray) external pure;
```

### r_packUnpack128Array


```solidity
function r_packUnpack128Array(int256[] memory sourceArray) external pure;
```

### r_packUnpack128Matrix


```solidity
function r_packUnpack128Matrix(int256[][] memory sourceMatrix) external;
```

