# ScalarQuantAMMBaseStorage
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/QuantAMMStorage.sol)

Contains the logic for packing and unpacking storage slots with 32 bit integers


## State Variables
### MAX32

```solidity
int256 private constant MAX32 = int256(type(int32).max);
```


### MIN32

```solidity
int256 private constant MIN32 = int256(type(int32).min);
```


## Functions
### quantAMMPackEight32

Packs eight 32 bit integers into one 256 bit integer


```solidity
function quantAMMPackEight32(
    int256 _firstInt,
    int256 _secondInt,
    int256 _thirdInt,
    int256 _fourthInt,
    int256 _fifthInt,
    int256 _sixthInt,
    int256 _seventhInt,
    int256 _eighthInt
) internal pure returns (int256 packed);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_firstInt`|`int256`|the first integer to pack|
|`_secondInt`|`int256`|the second integer to pack|
|`_thirdInt`|`int256`|the third integer to pack|
|`_fourthInt`|`int256`|the fourth integer to pack|
|`_fifthInt`|`int256`|the fifth integer to pack|
|`_sixthInt`|`int256`|the sixth integer to pack|
|`_seventhInt`|`int256`|the seventh integer to pack|
|`_eighthInt`|`int256`|the eighth integer to pack|


### quantAMMUnpack32

Unpacks a 256 bit integer into 8 32 bit integers


```solidity
function quantAMMUnpack32(int256 sourceElem) internal pure returns (int256[] memory targetArray);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sourceElem`|`int256`|the integer to unpack|


### quantAMMUnpack32Array

Unpacks a 256 bit integer into n 32 bit integers


```solidity
function quantAMMUnpack32Array(int256[] memory _sourceArray, uint256 _targetArrayLength)
    internal
    pure
    returns (int256[] memory targetArray);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_sourceArray`|`int256[]`|the array to unpack|
|`_targetArrayLength`|`uint256`|the number of 32 bit integers to unpack|


### quantAMMPack32Array

Packs an array of 32 bit integers into an array of 256 bit integers


```solidity
function quantAMMPack32Array(int256[] memory _sourceArray) internal pure returns (int256[] memory targetArray);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_sourceArray`|`int256[]`|the array to pack|


