# QuantAMMWeightedPoolFactory
[Git Source](https://github.com/QuantAMMProtocol/QuantAMM-V1/blob/3cfe58cf30c64b95a2607d2672fb541c48d807e0/contracts/QuantAMMWeightedPoolFactory.sol)

**Inherits:**
IPoolVersion, BasePoolFactory, Version

General Weighted Pool factory

*This is the most general factory, which allows up to eight tokens and arbitrary weights.*


## State Variables
### _poolVersion

```solidity
string private _poolVersion;
```


### _updateWeightRunner

```solidity
address private immutable _updateWeightRunner;
```


## Functions
### constructor


```solidity
constructor(
    IVault vault,
    uint32 pauseWindowDuration,
    string memory factoryVersion,
    string memory poolVersion,
    address updateWeightRunner
) BasePoolFactory(vault, pauseWindowDuration, type(QuantAMMWeightedPool).creationCode) Version(factoryVersion);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vault`|`IVault`|the balancer v3 valt|
|`pauseWindowDuration`|`uint32`|the pause duration|
|`factoryVersion`|`string`|factory version|
|`poolVersion`|`string`|pool version|
|`updateWeightRunner`|`address`|singleton update weight runner|


### getPoolVersion


```solidity
function getPoolVersion() external view returns (string memory);
```

### _constructionChecks


```solidity
function _constructionChecks(CreationNewPoolParams memory params) internal pure;
```

### _initialisationCheck


```solidity
function _initialisationCheck(CreationNewPoolParams memory params) internal view;
```

### createWithoutArgs


```solidity
function createWithoutArgs(CreationNewPoolParams memory params) external returns (address pool);
```

### create

Deploys a new `WeightedPool`.

*Tokens must be sorted for pool registration.*


```solidity
function create(CreationNewPoolParams memory params) external returns (address pool, bytes memory poolArgs);
```

## Errors
### NormalizedWeightInvariant
*Indicates that the sum of the pool tokens' weights is not FP 1.*


```solidity
error NormalizedWeightInvariant();
```

### MinWeight
*Indicates that one of the pool tokens' weight is below the minimum allowed.*


```solidity
error MinWeight();
```

### ImcompatibleRouterConfiguration
Unsafe or bad configuration for routers and liquidity management


```solidity
error ImcompatibleRouterConfiguration();
```

## Structs
### CreationNewPoolParams

```solidity
struct CreationNewPoolParams {
    string name;
    string symbol;
    TokenConfig[] tokens;
    uint256[] normalizedWeights;
    PoolRoleAccounts roleAccounts;
    uint256 swapFeePercentage;
    address poolHooksContract;
    bool enableDonation;
    bool disableUnbalancedLiquidity;
    bytes32 salt;
    int256[] _initialWeights;
    IQuantAMMWeightedPool.PoolSettings _poolSettings;
    int256[] _initialMovingAverages;
    int256[] _initialIntermediateValues;
    uint256 _oracleStalenessThreshold;
    uint256 poolRegistry;
    string[][] poolDetails;
}
```

