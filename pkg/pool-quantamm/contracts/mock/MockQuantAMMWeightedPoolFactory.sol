// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.24;

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IPoolVersion } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IPoolVersion.sol";
import {
    TokenConfig,
    PoolRoleAccounts,
    LiquidityManagement
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BasePoolFactory } from "@balancer-labs/v3-pool-utils/contracts/BasePoolFactory.sol";
import { Version } from "@balancer-labs/v3-solidity-utils/contracts/helpers/Version.sol";

import { IQuantAMMWeightedPool } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IQuantAMMWeightedPool.sol";
import { QuantAMMWeightedPool } from "../QuantAMMWeightedPool.sol";
import { MockQuantAMMWeightedPool } from "./QuantAMMWeightedPoolMock.sol";
import { QuantAMMWeightedPoolFactory } from "../QuantAMMWeightedPoolFactory.sol";
import { IHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IHooks.sol";

import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";

import "@prb/math/contracts/PRBMathSD59x18.sol";

/**
 * @param name The name of the pool
* @param symbol The symbol of the pool
* @param tokens An array of descriptors for the tokens the pool will manage
* @param normalizedWeights The pool weights (must add to FixedPoint.ONE)
* @param roleAccounts Addresses the Vault will allow to change certain pool settings
* @param swapFeePercentage Initial swap fee percentage
* @param poolHooksContract Contract that implements the hooks for the pool
* @param enableDonation If true, the pool will support the donation add liquidity mechanism
* @param disableUnbalancedLiquidity If true, only proportional add and remove liquidity are accepted
* @param salt The salt value that will be passed to create3 deployment

 */

/**
 * @notice General Weighted Pool factory
 * @dev This is the most general factory, which allows up to eight tokens and arbitrary weights.
 */
contract MockQuantAMMWeightedPoolFactory is IPoolVersion, BasePoolFactory, Version {
    // solhint-disable not-rely-on-time

    /// @dev Indicates that the sum of the pool tokens' weights is not FP 1.
    error NormalizedWeightInvariant();

    /// @dev Indicates that one of the pool tokens' weight is below the minimum allowed.
    error MinWeight();

    /// @notice Unsafe or bad configuration for routers and liquidity management
    error ImcompatibleRouterConfiguration();

    string private _poolVersion;
    address private immutable _updateWeightRunner;

    /// @param vault the balancer v3 valt
    /// @param pauseWindowDuration the pause duration
    /// @param factoryVersion factory version
    /// @param poolVersion pool version
    /// @param updateWeightRunner singleton update weight runner
    constructor(
        IVault vault,
        uint32 pauseWindowDuration,
        string memory factoryVersion,
        string memory poolVersion,
        address updateWeightRunner
    ) BasePoolFactory(vault, pauseWindowDuration, type(MockQuantAMMWeightedPool).creationCode) Version(factoryVersion) {
        require(updateWeightRunner != address(0), "update weight runner cannot be default address");
        _poolVersion = poolVersion;
        _updateWeightRunner = updateWeightRunner;
    }

    /// @inheritdoc IPoolVersion
    function getPoolVersion() external view returns (string memory) {
        return _poolVersion;
    }

    function _constructionChecks(QuantAMMWeightedPoolFactory.CreationNewPoolParams memory params) internal pure {     
        //from update weight runner
        uint256 MASK_POOL_PERFORM_UPDATE = 1;
        uint256 MASK_POOL_GET_DATA = 2;
        uint256 MASK_POOL_OWNER_UPDATES = 8;
        uint256 MASK_POOL_QUANTAMM_ADMIN_UPDATES = 16;
        uint256 MASK_POOL_RULE_DIRECT_SET_WEIGHT = 32;

        //CODEHAWKS INFO /s/314
        require(
            (params.poolRegistry & MASK_POOL_PERFORM_UPDATE > 0) ||
            (params.poolRegistry & MASK_POOL_GET_DATA > 0) ||
            (params.poolRegistry & MASK_POOL_OWNER_UPDATES > 0) ||
            (params.poolRegistry & MASK_POOL_QUANTAMM_ADMIN_UPDATES > 0) ||
            (params.poolRegistry & MASK_POOL_RULE_DIRECT_SET_WEIGHT > 0),
            "Invalid pool registry"
        );

        require(params.poolDetails.length <= 50, "Limit exceeds array length");
        for(uint i; i < params.poolDetails.length; i++){
            require(params.poolDetails[i].length == 4, "detail needs all 4 [category, name, type, detail]");
        }
    }

    function _initialisationCheck(QuantAMMWeightedPoolFactory.CreationNewPoolParams memory params) internal view {
        //checks copied from initialise

        //CODEHAWKS INFO /s/696
        require(params._poolSettings.assets.length > 0 
        && params._poolSettings.assets.length == params._initialWeights.length 
        && params._initialWeights.length == params.normalizedWeights.length/*_totalTokens*/, "INVASSWEIG"); //Invalid assets / weights array

        //CODEHAWKS INFO /s/157
        require(params._oracleStalenessThreshold > 0, "INVORCSTAL"); //Invalid oracle staleness threshold
        

        //checks coped from _setRule

        require(address(params._poolSettings.rule) != address(0), "Invalid rule");

        for (uint i; i < params._poolSettings.lambda.length; ++i) {
            int256 currentLambda = int256(uint256(params._poolSettings.lambda[i]));
            require(currentLambda > PRBMathSD59x18.fromInt(0) && currentLambda < PRBMathSD59x18.fromInt(1), "INVLAM"); //Invalid lambda value
        }

        require(
            params._poolSettings.lambda.length == 1 || params._poolSettings.lambda.length == params._initialWeights.length,
            "Either scalar or vector"
        );
        int256 currentEpsilonMax = int256(uint256(params._poolSettings.epsilonMax));
        require(
            currentEpsilonMax > PRBMathSD59x18.fromInt(0) && currentEpsilonMax <= PRBMathSD59x18.fromInt(1),
            "INV_EPMX"
        ); //Invalid epsilonMax value

        //applied both as a max (1 - x) and a min, so it cant be more than 0.49 or less than 0.01
        //all pool logic assumes that absolute guard rail is already stored as an 18dp int256
        require(
            int256(uint256(params._poolSettings.absoluteWeightGuardRail)) <
                PRBMathSD59x18.fromInt(1) / int256(uint256((params._initialWeights.length))) &&
                int256(uint256(params._poolSettings.absoluteWeightGuardRail)) >= 0.01e18,
            "INV_ABSWGT"
        ); //Invalid absoluteWeightGuardRail value

        require(params._poolSettings.oracles.length > 0, "NOPROVORC"); //No oracle indices provided"

        //CODEHAWKS INFO /s/154
        require(params._poolSettings.oracles.length == params._initialWeights.length, "OLNWEIG"); //Oracle length not equal to weights length
        require(params._poolSettings.rule.validParameters(params._poolSettings.ruleParameters), "INVRLEPRM"); //Invalid rule parameters

        //0 is hodl, 1 is trade whole pool which invariant doesnt let you do anyway
        require(params._poolSettings.maxTradeSizeRatio > 0 && params._poolSettings.maxTradeSizeRatio <= 0.3e18, "INVMAXTRADE"); //Invalid max trade size

        //checked copied from _setInitialWeights

        require(params.tokens.length > 1, "At least two tokens are required");
        
        InputHelpers.ensureInputLengthMatch(params.normalizedWeights.length /*_totalTokens */, params._initialWeights.length);
        int256 normalizedSum;

        int256[] memory _weightsAndBlockMultiplier = new int256[](params._initialWeights.length * 2);
        for (uint i; i < params._initialWeights.length; ) {
            if (params._initialWeights[i] < int256(uint256(params._poolSettings.absoluteWeightGuardRail))) {
                revert MinWeight();
            }

            _weightsAndBlockMultiplier[i] = params._initialWeights[i];
            normalizedSum += params._initialWeights[i];
            //Initially register pool with no movement, first update will come and set block multiplier.
            _weightsAndBlockMultiplier[i + params._initialWeights.length] = int256(0);
            unchecked {
                ++i;
            }
        }

        // Ensure that the normalized weights sum to ONE
        if (uint256(normalizedSum) != FixedPoint.ONE) {
            revert NormalizedWeightInvariant();
        }     
    }

    function createWithoutArgs(QuantAMMWeightedPoolFactory.CreationNewPoolParams memory params) external returns (address pool) {
        if (params.roleAccounts.poolCreator != address(0)) {
            revert StandardPoolWithCreator();
        }

        if(params.poolHooksContract != address(0) 
            && IHooks(params.poolHooksContract).getHookFlags().enableHookAdjustedAmounts != params.disableUnbalancedLiquidity){
            revert ImcompatibleRouterConfiguration();
        }
        
        LiquidityManagement memory liquidityManagement = getDefaultLiquidityManagement();
        liquidityManagement.enableDonation = params.enableDonation;
        // disableUnbalancedLiquidity must be set to true if a hook has the flag enableHookAdjustedAmounts = true.
        liquidityManagement.disableUnbalancedLiquidity = params.disableUnbalancedLiquidity;
        require(params.tokens.length == params.normalizedWeights.length, "Token and weight counts must match");
        
        _constructionChecks(params);

        pool = _create(abi.encode(
                QuantAMMWeightedPool.NewPoolParams({
                    name: params.name,
                    symbol: params.symbol,
                    numTokens: params.normalizedWeights.length,
                    //CODEHAWKS INFO /s/26 /s/31 /s/190 /s/468
                    version: _poolVersion,
                    updateWeightRunner: _updateWeightRunner,
                    poolRegistry: params.poolRegistry,
                    poolDetails: params.poolDetails
                }),
                getVault()
            ), params.salt);

        _initialisationCheck(params);

        MockQuantAMMWeightedPool(pool).initialize(params);

        _registerPoolWithVault(
            pool,
            params.tokens,
            params.swapFeePercentage,
            false, // not exempt from protocol fees
            params.roleAccounts,
            params.poolHooksContract,
            liquidityManagement
        );
    }

    /**
     * @notice Deploys a new `WeightedPool`.
     * @dev Tokens must be sorted for pool registration.
     */
    function create(QuantAMMWeightedPoolFactory.CreationNewPoolParams memory params) external returns (address pool, bytes memory poolArgs) {
        if (params.roleAccounts.poolCreator != address(0)) {
            revert StandardPoolWithCreator();
        }
        
        LiquidityManagement memory liquidityManagement = getDefaultLiquidityManagement();
        liquidityManagement.enableDonation = params.enableDonation;
        // disableUnbalancedLiquidity must be set to true if a hook has the flag enableHookAdjustedAmounts = true.
        liquidityManagement.disableUnbalancedLiquidity = params.disableUnbalancedLiquidity;
        
        
        poolArgs = abi.encode(
                QuantAMMWeightedPool.NewPoolParams({
                    name: params.name,
                    symbol: params.symbol,
                    numTokens: params.normalizedWeights.length,
                    //CODEHAWKS INFO /s/26 /s/31 /s/190 /s/468
                    version: _poolVersion,
                    updateWeightRunner: _updateWeightRunner,
                    poolRegistry: params.poolRegistry,
                    poolDetails: params.poolDetails
                }),
                getVault()
            );
        
        //CODEHAWKS INFO /s/_586 /s/860 /s/962
        require(params.tokens.length == params.normalizedWeights.length, "Token and weight counts must match");
        
        _constructionChecks(params);

        pool = _create(poolArgs, params.salt);

        _initialisationCheck(params);
        
        MockQuantAMMWeightedPool(pool).initialize(params);

        _registerPoolWithVault(
            pool,
            params.tokens,
            params.swapFeePercentage,
            false, // not exempt from protocol fees
            params.roleAccounts,
            params.poolHooksContract,
            liquidityManagement
        );
    }
}
