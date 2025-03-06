// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../QuantAMMWeightedPoolFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { PoolRoleAccounts, TokenConfig, TokenType } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { IQuantAMMWeightedPool } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IQuantAMMWeightedPool.sol";
import { IUpdateRule } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/IUpdateRule.sol";
import { OracleWrapper } from "@balancer-labs/v3-interfaces/contracts/pool-quantamm/OracleWrapper.sol";

import { Script } from "forge-std/Script.sol";

import "forge-std/console.sol"; // Import the console library

contract CreatePoolBroadcast is Script {

    function _createPoolParams() internal view returns (QuantAMMWeightedPoolFactory.CreationNewPoolParams memory retParams) {
        IRateProvider[] memory rateProviders;
        PoolRoleAccounts memory roleAccounts;
        
        address[] memory tokens = new address[](2);
        //USDC sepolia
        tokens[0] = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8;
        
        //WBTC sepolia
        tokens[1] = 0x29f2D40B0605204364af54EC677bD022dA425d03;
    
        IERC20[] memory tokensIERC20 = new IERC20[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            tokensIERC20[i] = IERC20(tokens[i]);        }
        
        TokenConfig[] memory tokenConfig = new TokenConfig[](tokens.length);
        for (uint256 i = 0; i < asIERC20(tokens).length; ++i) {
            tokenConfig[i].token = asIERC20(tokens)[i];
            if(rateProviders.length > 0) {
                tokenConfig[i].rateProvider = rateProviders[i];
                tokenConfig[i].tokenType = rateProviders[i] == IRateProvider(address(0))
                    ? TokenType.STANDARD
                    : TokenType.WITH_RATE;
            }
        }
    
        tokenConfig = sortTokenConfig(tokenConfig);
    
        uint64[] memory lambdas = new uint64[](1);
        lambdas[0] = 0.2e18;
    
        int256[] memory intermediateValueStubs = new int256[](2);
        intermediateValueStubs[0] = 1e18;
        intermediateValueStubs[1] = 1e18;
        
        int256[][] memory parameters = new int256[][](1);
        parameters[0] = new int256[](1);
        parameters[0][0] = 0.2e18;
    
        address[][] memory oracles = new address[][](2);
        oracles[0] = new address[](1);
        oracles[1] = new address[](1);
        //USDC
        oracles[0][0] = 0x809CEbbb376A97D175570b5c71ED2a219ACd6f21;
        
        //WBTC
        oracles[1][0] = 0xdA841aEEE267b4607f8F0F3622e99060D64644EF;
        
        uint256[] memory normalizedWeights = new uint256[](tokens.length);
        normalizedWeights[0] = uint256(0.5e18);
        normalizedWeights[1] = uint256(0.5e18);
    
        int256[] memory intNormalizedWeights = new int256[](tokens.length);
        intNormalizedWeights[0] = 0.5e18;
        intNormalizedWeights[1] = 0.5e18;
        
        string[][] memory poolDetails = new string[][](1);
        poolDetails[0] = new string[](4);
        poolDetails[0][0] = "Overview";
        poolDetails[0][1] = "Adaptability";
        poolDetails[0][2] = "number";
        poolDetails[0][3] = "5";
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, block.timestamp));
        console.log("starting params");
        retParams = QuantAMMWeightedPoolFactory.CreationNewPoolParams(
        //string name;
            "test quantamm pool",
        //string symbol;
            "test",
        //TokenConfig[] tokens;
            tokenConfig,
        //uint256[] normalizedWeights;
            normalizedWeights,
        //PoolRoleAccounts roleAccounts;
            roleAccounts,
        //uint256 swapFeePercentage;
            0.02e18,
        //address poolHooksContract;
            address(0),
        //bool enableDonation;
            true,
        //bool disableUnbalancedLiquidity;
            false, // Do not disable unbalanced add/remove liquidity
        //bytes32 salt;
            salt,
        //int256[] _initialWeights;
            intNormalizedWeights,
        //IQuantAMMWeightedPool.PoolSettings _poolSettings;
            IQuantAMMWeightedPool.PoolSettings(
                //IERC20[] assets;
                asIERC20(tokens),
                //IUpdateRule rule;
                IUpdateRule(0xd728f8c62949BbfB4E3D1701C263887F313e9B4e),
                //address[][] oracles;
                oracles,
                //uint16 updateInterval;
                60,
                //uint64[] lambda;
                lambdas,
                //uint64 epsilonMax;
                0.2e18,
                //uint64 absoluteWeightGuardRail;
                0.2e18,
                //uint64 maxTradeSizeRatio;
                0.3e18,
                //int256[][] ruleParameters;    
                parameters,
                //address poolManager;
                msg.sender
            ),
        //int256[] _initialMovingAverages;
            intermediateValueStubs,
        //int256[] _initialIntermediateValues;
            intermediateValueStubs,
        //uint256 _oracleStalenessThreshold;
            3600,
        //uint256 poolRegistry;
            16,//able to set weights
        //string[][] poolDetails;
            poolDetails
        );
    }
    
    function asIERC20(address[] memory addresses) internal pure returns (IERC20[] memory tokens) {
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            tokens := addresses
        }
    }
    //taken out of IVault to avoid using the buildTokenConfig function
    function sortTokenConfig(TokenConfig[] memory tokenConfig) public pure returns (TokenConfig[] memory) {
        for (uint256 i = 0; i < tokenConfig.length - 1; ++i) {
            for (uint256 j = 0; j < tokenConfig.length - i - 1; j++) {
                if (tokenConfig[j].token > tokenConfig[j + 1].token) {
                    // Swap if they're out of order.
                    (tokenConfig[j], tokenConfig[j + 1]) = (tokenConfig[j + 1], tokenConfig[j]);
                }
            }
        }
    
        return tokenConfig;
    }
    function run() external {
    
        vm.startBroadcast();
        
        console.log("Creating pool");
        // Instance of the factory contract
        QuantAMMWeightedPoolFactory factory = QuantAMMWeightedPoolFactory(0x09191Ca061108c03D41b9a154e20C6f188291404);

        console.log("Creating params");
        // Define the parameters for the new pool
        QuantAMMWeightedPoolFactory.CreationNewPoolParams memory params = _createPoolParams();
    
        console.log("Creating pool without args");
        // Wrapping the call to create the pool in a try-catch block
        try factory.createWithoutArgs(params) returns (address pool) {
            console.log("Pool created successfully at address:", pool);
        } catch (bytes memory error) {
            console.log("Pool creation failed with error:", string(error));
        }
    
        vm.stopBroadcast();
    }
}