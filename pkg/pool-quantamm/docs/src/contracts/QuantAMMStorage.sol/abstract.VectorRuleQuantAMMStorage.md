# VectorRuleQuantAMMStorage
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/QuantAMMStorage.sol)

**Inherits:**
[QuantAMMStorage](/contracts/QuantAMMStorage.sol/abstract.QuantAMMStorage.md)

This logic to pack and unpack vectors is hardcoded for square matrices only as that is the usecase for QuantAMM


## Functions
### _quantAMMPack128Matrix

Packs n 128 bit integers into n/2 256 bit integers


```solidity
function _quantAMMPack128Matrix(int256[][] memory _sourceMatrix, int256[] storage _targetArray) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_sourceMatrix`|`int256[][]`|the matrix to pack|
|`_targetArray`|`int256[]`|the array to pack into|


### _quantAMMUnpack128Matrix

Unpacks packed array into a 2d array of 128 bit integers


```solidity
function _quantAMMUnpack128Matrix(int256[] memory _sourceArray, uint256 _numberOfAssets)
    internal
    pure
    returns (int256[][] memory targetArray);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_sourceArray`|`int256[]`|the array to unpack|
|`_numberOfAssets`|`uint256`|the number of 128 bit integers to unpack|


