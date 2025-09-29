# QuantAMMWeightedPool
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/QuantAMMWeightedPool.sol)

**Inherits:**
IQuantAMMWeightedPool, IBasePool, BalancerPoolToken, PoolInfo, Version, [ScalarQuantAMMBaseStorage](/contracts/QuantAMMStorage.sol/abstract.ScalarQuantAMMBaseStorage.md), Initializable

QuantAMM Base Weighted pool. One per pool.

*QuantAMM pools are in effect more advanced managed pools. They are fixed to run with the QuantAMM UpdateWeightRunner.
UpdateWeightRunner is reponsible for running automated strategies that determine weight changes in QuantAMM pools.
Given that all the logic is in update weight runner, setWeights is the fundamental access point between the two.
QuantAMM weighted pools define the last set weight time and weight and a block multiplier.
This block multiplier is used to interpolate between the last set weight and the current weight for a given block.
Older mechanisms defined a target weight and a target block index. Like this by storing times instead of weights
we save on SLOADs during weight calculations. It also allows more nuanced weight changes where you carry on a vector
until you either hit a guard rail or call a new setWeight.
Fees for these pools are set in hooks.
Pool Registration will be gated by the QuantAMM team to begin with for security reasons.
At any given block the pool is a fixed weighted balancer pool.
We store weights differently to the standard balancer pool. We store them as a 32 bit int, with the first 16 bits being the weight
and the second 16 bits being the block multiplier. This allows us to store 8 weights in a single 256 bit int.
Changing to a less precise storage has been shown in simulations to have a negligible impact on overall performance of the strategy
while drastically reducing the gas cost.*


## State Variables
### _MIN_SWAP_FEE_PERCENTAGE

```solidity
uint256 private constant _MIN_SWAP_FEE_PERCENTAGE = 0.001e16;
```


### _MAX_SWAP_FEE_PERCENTAGE

```solidity
uint256 private constant _MAX_SWAP_FEE_PERCENTAGE = 10e16;
```


### _FIX_WINDOW

```solidity
uint256 private constant _FIX_WINDOW = 3 * 365 * 24 * 60 * 60;
```


### _totalTokens

```solidity
uint256 private immutable _totalTokens;
```


### poolDetails
*First elem = category, second elem is name, third variable type, fourth elem detail*


```solidity
string[][] private poolDetails;
```


### _normalizedFirstFourWeights
*The weights are stored as 32-bit integers, packed into 256-bit integers. 9 d.p. was shown to have roughly same performance*


```solidity
int256 internal _normalizedFirstFourWeights;
```


### _normalizedSecondFourWeights

```solidity
int256 internal _normalizedSecondFourWeights;
```


### updateWeightRunner

```solidity
UpdateWeightRunner public updateWeightRunner;
```


### deploymentTime

```solidity
uint256 public immutable deploymentTime;
```


### quantammAdmin

```solidity
address internal immutable quantammAdmin;
```


### poolSettings
the pool settings for getting weights and assets keyed by pool


```solidity
QuantAMMBaseGetWeightData poolSettings;
```


### ruleParameters
*The parameters for the rule, validated in each rule separately during set rule*


```solidity
int256[][] public ruleParameters;
```


### lambda
*Decay parameter for exponentially-weighted moving average (0 < λ < 1)*


```solidity
uint64[] public lambda;
```


### epsilonMax
*Maximum allowed delta for a weight update, stored as SD59x18 number*


```solidity
uint64 public epsilonMax;
```


### absoluteWeightGuardRail
*Minimum absolute weight allowed. CODEHAWKS INFO /s/611*


```solidity
uint64 public absoluteWeightGuardRail;
```


### maxTradeSizeRatio
*maximum trade size allowed as a fraction of the pool*


```solidity
uint256 internal maxTradeSizeRatio;
```


### updateInterval
*Minimum amount of seconds between two updates*


```solidity
uint64 public updateInterval;
```


### oracleStalenessThreshold
*the maximum amount of time that an oracle an be stale.*


```solidity
uint256 oracleStalenessThreshold;
```


### poolRegistry
*the admin functionality enabled for this pool.*


```solidity
uint256 public immutable poolRegistry;
```


## Functions
### constructor


```solidity
constructor(NewPoolParams memory params, IVault vault)
    BalancerPoolToken(vault, params.name, params.symbol)
    PoolInfo(vault)
    Version(params.version);
```

### computeBalance


```solidity
function computeBalance(uint256[] memory balancesLiveScaled18, uint256 tokenInIndex, uint256 invariantRatio)
    external
    view
    returns (uint256 newBalance);
```

### getPoolDetail


```solidity
function getPoolDetail(string memory category, string memory name)
    external
    view
    returns (string memory, string memory);
```

### computeInvariant


```solidity
function computeInvariant(uint256[] memory balancesLiveScaled18, Rounding rounding) public view returns (uint256);
```

### getNormalizedWeights


```solidity
function getNormalizedWeights() external view returns (uint256[] memory);
```

### onSwap


```solidity
function onSwap(PoolSwapParams memory request) public view onlyVault returns (uint256);
```

### _getNormalisedWeightPair

Get the normalised weights for a pair of tokens


```solidity
function _getNormalisedWeightPair(
    uint256 tokenIndexOne,
    uint256 tokenIndexTwo,
    uint256 timeSinceLastUpdate,
    uint256 totalTokens
) internal view virtual returns (QuantAMMNormalisedTokenPair memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenIndexOne`|`uint256`|The index of the first token|
|`tokenIndexTwo`|`uint256`|The index of the second token|
|`timeSinceLastUpdate`|`uint256`|The time since the last update|
|`totalTokens`|`uint256`|The total number of tokens in the pool|


### _calculateCurrentBlockWeight

Calculate the current block weight


```solidity
function _calculateCurrentBlockWeight(
    int256[] memory tokenWeights,
    uint256 tokenIndex,
    uint256 timeSinceLastUpdate,
    uint256 tokensInTokenWeights
) internal pure returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenWeights`|`int256[]`|The token weights|
|`tokenIndex`|`uint256`|The index of the token|
|`timeSinceLastUpdate`|`uint256`|The time since the last update|
|`tokensInTokenWeights`|`uint256`|The number of tokens in the specific storage int|


### _getNormalizedWeight

Gets the normalised weight for a token


```solidity
function _getNormalizedWeight(uint256 tokenIndex, uint256 timeSinceLastUpdate, uint256 totalTokens)
    internal
    view
    virtual
    returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenIndex`|`uint256`|The index of the token|
|`timeSinceLastUpdate`|`uint256`|The time since the last update|
|`totalTokens`|`uint256`|The total number of tokens in the pool|


### _getNormalizedWeights

gets the normalised weights for the pool


```solidity
function _getNormalizedWeights() internal view virtual returns (uint256[] memory);
```

### calculateBlockNormalisedWeight

Calculate the normalised weight for a token


```solidity
function calculateBlockNormalisedWeight(int256 weight, int256 multiplier, uint256 timeSinceLastUpdate)
    internal
    pure
    returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`weight`|`int256`|The weight of the token|
|`multiplier`|`int256`|The multiplier for the token|
|`timeSinceLastUpdate`|`uint256`|The time since the last update|


### getMinimumSwapFeePercentage


```solidity
function getMinimumSwapFeePercentage() external pure returns (uint256);
```

### getMaximumSwapFeePercentage


```solidity
function getMaximumSwapFeePercentage() external pure returns (uint256);
```

### getMinimumInvariantRatio


```solidity
function getMinimumInvariantRatio() external pure returns (uint256);
```

### getMaximumInvariantRatio


```solidity
function getMaximumInvariantRatio() external pure returns (uint256);
```

### getQuantAMMWeightedPoolDynamicData


```solidity
function getQuantAMMWeightedPoolDynamicData() external view returns (QuantAMMWeightedPoolDynamicData memory data);
```

### getQuantAMMWeightedPoolImmutableData


```solidity
function getQuantAMMWeightedPoolImmutableData() external view returns (QuantAMMWeightedPoolImmutableData memory data);
```

### getWithinFixWindow


```solidity
function getWithinFixWindow() external view override returns (bool);
```

### setWeights

the main function to update target weights and multipliers from the update weight runner


```solidity
function setWeights(int256[] calldata _weights, address _address, uint40 _lastInteropTime) external override;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_weights`|`int256[]`|the target weights and their block multipliers|
|`_address`|`address`|the target pool address|
|`_lastInteropTime`|`uint40`|the last time the weights can be interpolated|


### _setInitialWeights

the initialising function during registration of the pool with the vault to set the initial weights


```solidity
function _setInitialWeights(int256[] memory _weights) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_weights`|`int256[]`|the target weights|


### initialize

Initialize the pool


```solidity
function initialize(QuantAMMWeightedPoolFactory.CreationNewPoolParams memory params) public initializer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`params`|`QuantAMMWeightedPoolFactory.CreationNewPoolParams`|parameters defined by the factory|


### _splitWeightAndMultipliers

Split the weights and multipliers into two arrays

*Update weight runner gives all weights in a single array shaped like [w1,w2,w3,w4,w5,w6,w7,w8,m1,m2,m3,m4,m5,m6,m7,m8], we need it to be [w1,w2,w3,w4,m1,m2,m3,m4,w5,w6,w7,w8,m5,m6,m7,m8]*


```solidity
function _splitWeightAndMultipliers(int256[] memory weights) internal pure returns (int256[][] memory splitWeights);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`weights`|`int256[]`|The weights and multipliers to split|


### _setRule

Set the rule for this pool


```solidity
function _setRule(QuantAMMWeightedPoolFactory.CreationNewPoolParams memory params) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`params`|`QuantAMMWeightedPoolFactory.CreationNewPoolParams`|parameters defined by the factory creation process|


### getOracleStalenessThreshold


```solidity
function getOracleStalenessThreshold() external view override returns (uint256);
```

### setUpdateWeightRunnerAddress


```solidity
function setUpdateWeightRunnerAddress(address _updateWeightRunner) external override;
```

### getRate


```solidity
function getRate() public pure override returns (uint256);
```

## Events
### WeightsUpdated
The information regarding the weight update. A second event is sent with finalised weights from the updateWeightRunner with precisions used for trading.

*Emitted when the weights of the pool are updated*


```solidity
event WeightsUpdated(
    address indexed poolAddress,
    int256[] calculatedWeightsAndMultipliers,
    uint40 lastInterpolationTimePossible,
    uint40 lastUpdateTime
);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolAddress`|`address`|The address of the pool|
|`calculatedWeightsAndMultipliers`|`int256[]`|The weights and multipliers submitted to be saved. These are in 18dp. Trade precision is in 9dp.|
|`lastInterpolationTimePossible`|`uint40`|The last time the weights can be interpolated|
|`lastUpdateTime`|`uint40`|The last time the weights were updated|

### UpdateWeightRunnerAddressUpdated
Emitted when the update weight runner is updated. This is during break glass situations.


```solidity
event UpdateWeightRunnerAddressUpdated(address indexed oldAddress, address indexed newAddress);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`oldAddress`|`address`|The old address of the update weight runner|
|`newAddress`|`address`|The new address of the update weight runner|

### PoolRuleSet
Emitted when the pool is set in the update weight runner


```solidity
event PoolRuleSet(
    address rule,
    address[][] poolOracles,
    uint64[] lambda,
    int256[][] ruleParameters,
    uint64 epsilonMax,
    uint64 absoluteWeightGuardRail,
    uint40 updateInterval,
    address poolManager,
    address creatorAddress
);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`rule`|`address`|The rule to use for the pool|
|`poolOracles`|`address[][]`|The oracles to use for the pool. [asset oracle][backup oracles for that asset]|
|`lambda`|`uint64[]`|The decay parameter for the rule|
|`ruleParameters`|`int256[][]`|The parameters for the rule|
|`epsilonMax`|`uint64`|The parameter that controls maximum allowed delta for a weight update|
|`absoluteWeightGuardRail`|`uint64`|The parameter that controls minimum allowed absolute weight allowed|
|`updateInterval`|`uint40`|The time between updates|
|`poolManager`|`address`|The address of the pool manager|
|`creatorAddress`|`address`|The address of the creator of the pool|

## Errors
### maxTradeSizeRatioExceeded
*Indicates that the maximum allowed trade size has been exceeded.*


```solidity
error maxTradeSizeRatioExceeded();
```

### WeightedPoolBptRateUnsupported
`getRate` from `IRateProvider` was called on a Weighted Pool.

*It is not safe to nest Weighted Pools as WITH_RATE tokens in other pools, where they function as their own
rate provider. The default `getRate` implementation from `BalancerPoolToken` computes the BPT rate using the
invariant, which has a non-trivial (and non-linear) error. Without the ability to specify a rounding direction,
the rate could be manipulable.
It is fine to nest Weighted Pools as STANDARD tokens, or to use them with external rate providers that are
stable and have at most 1 wei of rounding error (e.g., oracle-based).*


```solidity
error WeightedPoolBptRateUnsupported();
```

## Structs
### NewPoolParams
the pool settings for setting weights keyed by pool


```solidity
struct NewPoolParams {
    string name;
    string symbol;
    uint256 numTokens;
    string version;
    address updateWeightRunner;
    uint256 poolRegistry;
    string[][] poolDetails;
}
```

**Properties**

|Name|Type|Description|
|----|----|-----------|
|`name`|`string`|The name of the pool|
|`symbol`|`string`|The symbol of the pool|
|`numTokens`|`uint256`|The number of tokens in the pool|
|`version`|`string`|The version of the pool|
|`updateWeightRunner`|`address`|The address of the update weight runner|
|`poolRegistry`|`uint256`|The settings of admin functionality of pools|
|`poolDetails`|`string[][]`|The details of the pool. dynamic user driven descriptive data|

### QuantAMMNormalisedTokenPair

```solidity
struct QuantAMMNormalisedTokenPair {
    uint256 firstTokenWeight;
    uint256 secondTokenWeight;
}
```

