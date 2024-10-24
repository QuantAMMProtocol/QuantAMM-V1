//SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "./i_compliant_request.sol";
import "@violetprotocol/ethereum-access-token/contracts/AccessTokenConsumer.sol";

/// @title VioletCompliantRequest - Violet compliant request contract
/// @notice This contract is used to check if a request is compliant with Violet rules and to check if a request is authorized by the user to be executed by the pool on their behalf (via an access token) 
contract VioletCompliantRequest is ICompliantRequest, AccessTokenConsumer {
    constructor(address verifier) AccessTokenConsumer(verifier) {}

    function compliantSwapRequest(
        SwapRequest memory request
    ) external view returns (bool) {
        (uint8 v, bytes32 r, bytes32 s, uint256 expiry) = abi.decode(
            request.additionalParams,
            (uint8, bytes32, bytes32, uint256)
        );
        return
            checkAuthSwap(
                v,
                r,
                s,
                expiry,
                request
            );
    }

    /// @param newTokens  Array of new tokens to be added to the pool (if any) 
    /// @param trader the address of the trader
    /// @param targetPool the address of the target pool 
    /// @param executingFor the address of the user that the pool is executing the request for 
    /// @param additionalParams   Additional parameters for the request 
    function compliantDepositRequest(
        address[] memory newTokens,
        address trader,
        address targetPool,
        address executingFor,
        bytes memory additionalParams
    ) external view returns (bool) {
        (uint8 v, bytes32 r, bytes32 s, uint256 expiry) = abi.decode(
            additionalParams,
            (uint8, bytes32, bytes32, uint256)
        );
        return
            checkAuthDeposit(
                v,
                r,
                s,
                expiry,
                newTokens,
                trader,
                targetPool,
                executingFor
            );
    }

    /// @param v violet specific input parameters
    /// @param r violet specific input parameters
    /// @param s violet specific input parameters
    /// @param expiry violet specific input parameters
    function checkAuthSwap(
        uint8 v,
        bytes32 r,
        bytes32 s,
        uint256 expiry,
        SwapRequest memory
    ) public view returns (bool) {
        return verify(v, r, s, expiry); // requiresAuth reverts for non-compliant calls
    }

    /// @param v violet specific input parameters
    /// @param r violet specific input parameters
    /// @param s violet specific input parameters
    /// @param expiry the expiry time for the token
    function checkAuthDeposit(
        uint8 v,
        bytes32 r,
        bytes32 s,
        uint256 expiry,
        address[] memory /*newTokens*/,
        address /*trader*/,
        address /*targetPool*/,
        address /*executingFor*/
    ) public view returns (bool) {
        return verify(v, r, s, expiry); // requiresAuth reverts for non-compliant calls
    }
}
