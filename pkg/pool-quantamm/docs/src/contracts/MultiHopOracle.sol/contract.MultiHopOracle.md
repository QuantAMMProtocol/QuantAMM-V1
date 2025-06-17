# MultiHopOracle
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/MultiHopOracle.sol)

**Inherits:**
OracleWrapper

For tokens where no direct oracle / price feeds exists, multiple oracle wrappers can be combined to one.


## State Variables
### oracles
configuration for the oracles


```solidity
HopConfig[] public oracles;
```


## Functions
### constructor


```solidity
constructor(HopConfig[] memory _oracles);
```

### _getData

Returns the latest data from one oracle hopping across n oracles


```solidity
function _getData() internal view override returns (int216 data, uint40 timestamp);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`data`|`int216`|the latest data from the oracle in the QuantAMM format|
|`timestamp`|`uint40`|the timestamp of the data retrieval|


## Structs
### HopConfig
Configuration for one hop

*Fits in one storage slot*


```solidity
struct HopConfig {
    OracleWrapper oracle;
    bool invert;
}
```

