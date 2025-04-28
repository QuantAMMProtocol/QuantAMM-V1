# EchidnaQuantAMMMathGuard
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/echidna/echidna_update_weight_runner.sol)

**Inherits:**
[QuantAMMMathGuard](/contracts/rules/base/QuantammMathGuard.sol/abstract.QuantAMMMathGuard.md)


## State Variables
### weights

```solidity
int256[] public weights;
```


## Functions
### constructor


```solidity
constructor();
```

### weight_update_two_tokens


```solidity
function weight_update_two_tokens(uint8 weightDeltaDivisor, uint8 epsilonMaxDivisor) public;
```

### weight_update_multiple_tokens


```solidity
function weight_update_multiple_tokens(uint8 numWeights, uint8 weightDeltaDivisor, uint8 epsilonMaxDivisor) public;
```

### echidna_check_weights


```solidity
function echidna_check_weights() public view returns (bool);
```

