# EchidnaMovingAverage
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/echidna/echidna_moving_average.sol)

**Inherits:**
[QuantAMMMathMovingAverage](/contracts/rules/base/QuantammMathMovingAverage.sol/abstract.QuantAMMMathMovingAverage.md)


## State Variables
### lambda

```solidity
int128[] public lambda;
```


### movingAverage

```solidity
int256[] public movingAverage;
```


## Functions
### constructor


```solidity
constructor();
```

### calculate_moving_average


```solidity
function calculate_moving_average(int256[] calldata _newData) public;
```

### echidna_calc_does_not_revert


```solidity
function echidna_calc_does_not_revert() public pure returns (bool);
```

