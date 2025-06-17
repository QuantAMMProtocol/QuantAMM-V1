# QuantAMMPoolParameters
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/rules/base/QuantammBasedRuleHelpers.sol)


```solidity
struct QuantAMMPoolParameters {
    address pool;
    uint256 numberOfAssets;
    int128[] lambda;
    int256[] movingAverage;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`pool`|`address`||
|`numberOfAssets`|`uint256`||
|`lambda`|`int128[]`||
|`movingAverage`|`int256[]`||

