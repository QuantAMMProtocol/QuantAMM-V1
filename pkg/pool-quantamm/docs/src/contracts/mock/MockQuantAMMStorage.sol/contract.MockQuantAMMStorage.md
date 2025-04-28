# MockQuantAMMStorage
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/mock/MockQuantAMMStorage.sol)

**Inherits:**
[ScalarRuleQuantAMMStorage](/contracts/QuantAMMStorage.sol/abstract.ScalarRuleQuantAMMStorage.md), [ScalarQuantAMMBaseStorage](/contracts/QuantAMMStorage.sol/abstract.ScalarQuantAMMBaseStorage.md), [VectorRuleQuantAMMStorage](/contracts/QuantAMMStorage.sol/abstract.VectorRuleQuantAMMStorage.md)


## State Variables
### mockQuantAMMMatrix

```solidity
int256[] public mockQuantAMMMatrix;
```


### matrixResult

```solidity
int256[][] public matrixResult;
```


## Functions
### ExternalEncode


```solidity
function ExternalEncode(int256 leftInt, int256 rightInt) external pure returns (int256 result);
```

### ExternalDecode


```solidity
function ExternalDecode(int256 sourceInt) external pure returns (int256[] memory result);
```

### ExternalEncode


```solidity
function ExternalEncode(int64 leftInt, int128 rightInt) external pure returns (int256 result);
```

### ExternalEncodeArray


```solidity
function ExternalEncodeArray(int256[] memory sourceArray) external pure returns (int256[] memory result);
```

### ExternalQuantAMMPack32Array


```solidity
function ExternalQuantAMMPack32Array(int256[] memory sourceArray) external pure returns (int256[] memory result);
```

### ExternalEncodeDecode128Array


```solidity
function ExternalEncodeDecode128Array(int256[] memory sourceArray, uint256 targetLength)
    external
    pure
    returns (int256[] memory result);
```

### ExternalEncodeDecode32Array


```solidity
function ExternalEncodeDecode32Array(int256[] memory sourceArray, uint256 targetLength)
    external
    pure
    returns (int256[] memory result);
```

### ExternalEncodeDecodeMatrix


```solidity
function ExternalEncodeDecodeMatrix(int256[][] memory sourceMatrix) external returns (int256[][] memory result);
```

### GetMatrixResult


```solidity
function GetMatrixResult() external view returns (int256[][] memory);
```

### ExternalSingleEncode


```solidity
function ExternalSingleEncode(int256 leftInt, int256 rightInt) external pure returns (int256 result);
```

### ExternalDecode128


```solidity
function ExternalDecode128(int256[] memory sourceArray, uint256 resultArrayLength)
    external
    pure
    returns (int256[] memory resultArray);
```

### ExternalSingleDecode


```solidity
function ExternalSingleDecode(int256 leftInt) external pure returns (int256 result);
```

