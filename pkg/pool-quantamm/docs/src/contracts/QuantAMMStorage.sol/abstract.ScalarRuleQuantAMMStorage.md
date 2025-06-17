# ScalarRuleQuantAMMStorage
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/QuantAMMStorage.sol)

**Inherits:**
[QuantAMMStorage](/contracts/QuantAMMStorage.sol/abstract.QuantAMMStorage.md)

Contains the logic for packing and unpacking storage slots with 128 bit integers for rule weights


## Functions
### _quantAMMPack128Array

Packs n 128 bit integers into n/2 256 bit integers


```solidity
function _quantAMMPack128Array(int256[] memory _sourceArray) internal pure returns (int256[] memory targetArray);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_sourceArray`|`int256[]`|the array to pack|


### _quantAMMUnpack128Array

Unpacks n/2 256 bit integers into n 128 bit integers


```solidity
function _quantAMMUnpack128Array(int256[] memory _sourceArray, uint256 _targetArrayLength)
    internal
    pure
    returns (int256[] memory targetArray);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_sourceArray`|`int256[]`|the array to unpack|
|`_targetArrayLength`|`uint256`|the number of 128 bit integers to unpack|


