//SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

/// @title Interface to define any compliance requirements. Defined by pool creators for individual pools
interface ICompliantRequest {

    /// @param buyToken the address of the token you want to buy
    /// @param sellToken the address of the token you want to sell
    /// @param buyAmount the reserve quantity you want to buy of the buy token
    /// @param sellAmount the reserve quantity you want to sell of the sell token
    /// @param trader the address of the account that is performing the transaction
    /// @param pool the pool address
    /// @param executingFor the address of the beneficiary if the trader is acting on behalf of someone
    /// @param additionalParams bytes to define specific additional requirements
    struct SwapRequest {
        address buyToken;
        address sellToken;
        uint256 buyAmount;
        uint256 sellAmount;
        address trader;
        address pool;
        address executingFor;
        bytes additionalParams;
    }


    function compliantSwapRequest(
        SwapRequest memory request
    ) external view returns (bool);
    

    //function compliantBlockTradeRequest(
    //    address[] memory buyTokens,
    //    address[] memory sellTokens,
    //    uint256[] memory buyAmountBreakdowns,
    //    uint256[] memory sellAmountBreakdowns,
    //    address trader,
    //    address pool,
    //    address executingFor,
    //    bytes memory additionalParams
    //) external view returns (bool);


    /// @param newTokens the addresses of tokens being deposited into the vault
    /// @param trader the address of the account that is performing the transaction
    /// @param targetPool the pool you want to deposit in
    /// @param executingFor the address of the ultimate benefitiary if the trader is acting for someone
    /// @param additionalParams any additional dynamic params needed
    function compliantDepositRequest(
        address[] memory newTokens, 
        address trader, 
        address targetPool,
        address executingFor,
        bytes calldata additionalParams
    ) external view returns (bool);
}
