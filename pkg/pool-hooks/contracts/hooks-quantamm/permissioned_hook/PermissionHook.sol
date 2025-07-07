// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IHooks.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    AddLiquidityKind,
    AddLiquidityParams,
    LiquidityManagement,
    RemoveLiquidityKind,
    TokenConfig,
    HookFlags
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { VaultGuard } from "@balancer-labs/v3-vault/contracts/VaultGuard.sol";
import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";
import { PoolSwapParams, AfterSwapParams } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { RestrictionListProvider } from "./RestrictionListProvider.sol";
import { IRouterCommon } from "@balancer-labs/v3-interfaces/contracts/vault/IRouterCommon.sol";

contract PermissionHook is BaseHooks, VaultGuard, Ownable {
    using FixedPoint for uint256;

    /**
     * @notice The pool does not support adding liquidity through donation.
     * @dev There is an existing similar error (IVaultErrors.DoesNotSupportDonation), but hooks should not throw
     * "Vault" errors.
     */
    error PoolDoesNotSupportDonation();

    error PermissionDenied(
        RestrictionListProvider.ListType listType,
        address addr,
        uint256 action
    );

    RestrictionListProvider private _restrictionListProvider;
    RestrictionListProvider.ListType private _permissionType;

    // Greylist reasons
    uint256 constant GREYLIST_ADD = 1;
    uint256 constant GREYLIST_REMOVE = 2;
    uint256 constant GREYLIST_SWAP = 4;

    constructor(IVault vault, address restrictionListProvider, RestrictionListProvider.ListType permissionType) VaultGuard(vault) Ownable(msg.sender) {
        // Ensure the restriction list provider is a valid contract
        if (restrictionListProvider == address(0)) {
            revert("Invalid restriction list provider address");
        }
        _permissionType = permissionType;
        _restrictionListProvider = RestrictionListProvider(restrictionListProvider);
    }

    /// @inheritdoc IHooks
    function onRegister(
        address,
        address,
        TokenConfig[] memory,
        LiquidityManagement calldata liquidityManagement
    ) public view override onlyVault returns (bool) {
        // NOTICE: In real hooks, make sure this function is properly implemented (e.g. check the factory, and check
        // that the given pool is from the factory). Returning true unconditionally allows any pool, with any
        // configuration, to use this hook.

        // This hook requires donation support to work (see above).
        if (liquidityManagement.enableDonation == false) {
            revert PoolDoesNotSupportDonation();
        }

        return true;
    }

    /// @notice Emitted when the restriction list provider is updated
    /// @param oldProvider The address of the previous restriction list provider
    /// @param newProvider The address of the new restriction list provider
    /// @param updatedBy The address of the entity that performed the update
    event RestrictionListProviderUpdated(
        address indexed oldProvider,
        address indexed newProvider,
        address indexed updatedBy
    );

    /**
     * @notice Updates the restriction list provider address.
     * @dev This function can only be called by the contract owner.
     * @param newProvider The address of the new restriction list provider.
     */
    function updateRestrictionListProvider(address newProvider) external onlyOwner {
        if (newProvider == address(0)) {
            revert("Invalid restriction list provider address");
        }

        address oldProvider = address(_restrictionListProvider);

        _restrictionListProvider = RestrictionListProvider(newProvider);

        emit RestrictionListProviderUpdated(oldProvider, newProvider, msg.sender);
    }

    /// @inheritdoc IHooks
    function getHookFlags() public pure override returns (HookFlags memory) {
        HookFlags memory hookFlags;
        // `enableHookAdjustedAmounts` must be true for all contracts that modify the `amountCalculated`
        // in after hooks. Otherwise, the Vault will ignore any "hookAdjusted" amounts, and the transaction
        // might not settle. (It should be false if the after hooks do something else.)
        hookFlags.enableHookAdjustedAmounts = true;
        hookFlags.shouldCallAfterRemoveLiquidity = true;
        return hookFlags;
    }

    function _checkActionPermission(uint256 action, address router) internal view {
        address userAddress = IRouterCommon(router).getSender();

        (RestrictionListProvider.ListType list, uint256 value) = _restrictionListProvider.checkRestrictionLists(
            _permissionType,
            userAddress,
            action
        );

        if (value != 0) {
            revert PermissionDenied(list, userAddress, action);
        }
    }

    /// @inheritdoc BaseHooks
    function onBeforeAddLiquidity(
        address router,
        address,
        AddLiquidityKind,
        uint256[] memory,
        uint256,
        uint256[] memory,
        bytes memory
    ) public view override onlyVault returns (bool) {
        _checkActionPermission(GREYLIST_ADD, router);

        return true;
    }

    /// @inheritdoc IHooks
    function onBeforeRemoveLiquidity(
        address router,
        address,
        RemoveLiquidityKind,
        uint256,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public view override returns (bool) {
        
        _checkActionPermission(GREYLIST_REMOVE, router);

        return true;
    }


    /// @inheritdoc IHooks
    function onBeforeSwap(PoolSwapParams calldata swapParams, address) public view override returns (bool) {
        
        _checkActionPermission(GREYLIST_SWAP, swapParams.router);
        
        return true;
    }
}
