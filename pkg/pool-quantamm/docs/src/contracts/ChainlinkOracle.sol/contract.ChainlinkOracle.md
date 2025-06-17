# ChainlinkOracle
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/ChainlinkOracle.sol)

**Inherits:**
OracleWrapper

Contains the logic for retrieving data from a Chainlink oracle and converting it to the QuantAMM format using the oracle wrapper contract


## State Variables
### priceFeed

```solidity
AggregatorV3Interface internal immutable priceFeed;
```


### normalizationFactor
Difference of feed result to 18 decimals. We store the difference instead of the oracle decimals for optimization reasons (saves a subtraction in _getData)


```solidity
uint256 internal immutable normalizationFactor;
```


## Functions
### constructor


```solidity
constructor(address _chainlinkFeed);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_chainlinkFeed`|`address`|the address of the Chainlink oracle to wrap|


### _getData

Returns the latest data from the oracle in the QuantAMM format


```solidity
function _getData() internal view override returns (int216, uint40);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`int216`|data the latest data from the oracle in the QuantAMM format|
|`<none>`|`uint40`|timestamp the timestamp of the data retrieval|


