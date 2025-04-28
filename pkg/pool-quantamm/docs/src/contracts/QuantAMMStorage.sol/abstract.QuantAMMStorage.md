# QuantAMMStorage
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/QuantAMMStorage.sol)

Contains the logic for packing and unpacking storage slots with 128 bit integers


## State Variables
### MAX128

```solidity
int256 private constant MAX128 = int256(type(int128).max);
```


### MIN128

```solidity
int256 private constant MIN128 = int256(type(int128).min);
```


## Functions
### _quantAMMPackTwo128

Packs two 128 bit integers into one 256 bit integer


```solidity
function _quantAMMPackTwo128(int256 _leftInt, int256 _rightInt) internal pure returns (int256 packed);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_leftInt`|`int256`|the left integer to pack|
|`_rightInt`|`int256`|the right integer to pack|


