# MockChainlinkOracle
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/mock/MockChainlinkOracles.sol)

**Inherits:**
OracleWrapper


## State Variables
### fixedReply

```solidity
int216 private fixedReply;
```


### delay

```solidity
uint256 private immutable delay;
```


### oracleTimestamp

```solidity
uint40 public oracleTimestamp;
```


### throwOnUpdate

```solidity
bool throwOnUpdate;
```


## Functions
### constructor


```solidity
constructor(int216 _fixedReply, uint256 _delay);
```

### setThrowOnUpdate


```solidity
function setThrowOnUpdate(bool _throwOnUpdate) public;
```

### updateData


```solidity
function updateData(int216 _fixedReply, uint40 _timestamp) public;
```

### _getData


```solidity
function _getData() internal view override returns (int216 data, uint40 timestamp);
```

