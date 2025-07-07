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

/**
 * @title RestrictionListProvider
 * @dev Contract for managing restriction lists (Blacklist, Greylist, Whitelist) with associated values.
 *      Allows the owner to add, reset, and query addresses in these lists.
 * @author GitHub Copilot
 */
contract RestrictionListProvider is Ownable {
    constructor(IVault vault) Ownable(msg.sender) {
        // solhint-disable-previous-line no-empty-blocks
    }

    /**
     * @dev Enum representing the type of restriction list.
     * @param Blacklist Addresses that are restricted due to sanctions.
     * @param Greylist Addresses with limited permissions for specific actions.
     * @param Whitelist Addresses that are explicitly allowed.
     */
    enum ListType {
        Blacklist,
        Greylist,
        Whitelist
    }

    uint256 constant OFAC_SANCTION = 1;
    uint256 constant UN_SANCTION = 2;

    // Greylist reasons
    uint256 constant GREYLIST_ADD = 1;
    uint256 constant GREYLIST_REMOVE = 2;
    uint256 constant GREYLIST_SWAP = 4;
    uint256 internal constant _GREY_MASK = GREYLIST_ADD | GREYLIST_REMOVE | GREYLIST_SWAP;

    /**
     * @dev Error thrown when an unknown blacklist reason is provided.
     * @param addr The address that has an unknown blacklist reason.
     */
    error UnknownBlacklistReason(address addr);

    /**
     * @dev Error thrown when an unknown greylist action is provided.
     * @param addr The address that has an unknown greylist action.
     * @param action The unknown action value.
     */
    error UnknownGreylistAction(address addr, uint256 action);

    /**
     * @dev Error thrown when an address is found in both Blacklist and Greylist.
     * @param addr The address that is in both lists.
     */
    error AddressInBothBlacklistAndGreylist(address addr);

    /**
     * @dev Error thrown when an address is found in the Greylist or Blacklist while attempting to add it to the Whitelist.
     * @param addr The address that is in the Greylist or Blacklist.
     */
    error AddressInGreylistOrBlacklist(address addr);
    /**
     * @dev Mapping to store blacklist values for addresses.
     */
    mapping(address => uint256) public blacklist;

    /**
     * @dev Mapping to store greylist values for addresses.
     */
    mapping(address => uint256) public greylist;

    /**
     * @dev Mapping to store whitelist values for addresses.
     */
    mapping(address => uint256) public whitelist;

    /**
     * @dev Event emitted when an address is added to a restriction list.
     * @param listType The type of restriction list.
     * @param addr The address added to the list.
     * @param value The associated value for the address.
     */
    event AddressAdded(ListType listType, address indexed addr, uint256 value);

    /**
     * @dev Event emitted when an address is reset in a restriction list.
     * @param listType The type of restriction list.
     * @param addr The address reset in the list.
     */
    event AddressReset(ListType listType, address indexed addr);

    /**
     * @dev Error thrown when an invalid list type is provided.
     */
    error InvalidListType();

    /**
     * @notice Adds multiple addresses to a restriction list with a specified value.
     * @dev Only callable by the owner.
     * @param listType The type of restriction list.
     * @param addresses The array of addresses to add.
     * @param value The associated value for the addresses.
     */
    function addAddresses(ListType listType, address[] calldata addresses, uint256 value) external onlyOwner {
        for (uint256 i = 0; i < addresses.length; i++) {
            _addAddress(listType, addresses[i], value);
        }
    }

    /**
     * @notice Resets multiple addresses in a restriction list.
     * @dev Only callable by the owner.
     * @param listType The type of restriction list.
     * @param addresses The array of addresses to reset.
     */
    function resetAddresses(ListType listType, address[] calldata addresses) external onlyOwner {
        for (uint256 i = 0; i < addresses.length; i++) {
            _resetAddress(listType, addresses[i]);
        }
    }

    /**
     * @notice Retrieves the value associated with an address in a restriction list.
     * @param listType The type of restriction list.
     * @param addr The address to query.
     * @return The value associated with the address in the specified list.
     */
    function getAddressRestrictedListValue(ListType listType, address addr) external view returns (uint256) {
        if (listType == ListType.Blacklist) {
            return blacklist[addr];
        } else if (listType == ListType.Greylist) {
            return greylist[addr];
        } else if (listType == ListType.Whitelist) {
            return whitelist[addr];
        } else {
            revert InvalidListType();
        }
    }

    /**
     * @notice Checks if multiple addresses have a specific value in a restriction list.
     * @param listType The type of restriction list.
     * @param addresses The array of addresses to check.
     * @param value The value to compare against.
     * @return An array of booleans indicating whether each address matches the value.
     */
    function checkRestrictionList(
        ListType listType,
        address[] calldata addresses,
        uint256 value
    ) external view returns (bool[] memory) {
        bool[] memory results = new bool[](addresses.length);
        for (uint256 i = 0; i < addresses.length; i++) {
            if (listType == ListType.Blacklist) {
                results[i] = (blacklist[addresses[i]] == value);
            } else if (listType == ListType.Greylist) {
                results[i] = (greylist[addresses[i]] == value);
            } else if (listType == ListType.Whitelist) {
                results[i] = (whitelist[addresses[i]] == value);
            } else {
                revert InvalidListType();
            }
        }
        return results;
    }

    /**
     * @notice Checks if an address satisfies the restriction list conditions based on the specified action.
     * @param listType The type of restriction list (Blacklist, Greylist, Whitelist).
     * @param addr The address to check.
     * @param action The action value to validate against for Greylist.
     * @return listTypeTriggered The ListType that triggered the restriction, or ListType.Whitelist if the address satisfies the conditions.
     * @return valueTriggered The value that triggered the restriction, or 0 if the address satisfies the conditions.
     */
    function checkRestrictionLists(
        ListType listType,
        address addr,
        uint256 action
    ) external view returns (ListType listTypeTriggered, uint256 valueTriggered) {
        if (listType == ListType.Whitelist) {
            return (ListType.Whitelist, whitelist[addr]);
        } else {
            uint256 blacklistValue = blacklist[addr];
            if (blacklistValue != 0) {
                return (ListType.Blacklist, blacklistValue);
            }
            uint256 greylistValue = greylist[addr];
            if (greylistValue == 0) {
                return (ListType.Greylist, greylistValue);
            }
            if ((greylistValue & action) > 0) {
                return (ListType.Greylist, greylistValue);
            } else {
                return (ListType.Greylist, 0);
            }
        }
    }

    /**
     * @dev Internal function to add an address to a restriction list with a specified value.
     * @param listType The type of restriction list.
     * @param addr The address to add.
     * @param value The associated value for the address.
     */
    function _addAddress(ListType listType, address addr, uint256 value) internal {
        if (listType == ListType.Blacklist) {
            if ((value & OFAC_SANCTION == 0) && (value & UN_SANCTION == 0)) {
                revert UnknownBlacklistReason(addr);
            }
            if (greylist[addr] != 0) {
                revert AddressInBothBlacklistAndGreylist(addr);
            }
            blacklist[addr] = value;
        } else if (listType == ListType.Greylist) {
            if (blacklist[addr] != 0) {
                revert AddressInBothBlacklistAndGreylist(addr);
            }

            if (value == 0 || (value & ~_GREY_MASK) != 0) {
                revert UnknownGreylistAction(addr, value);
            }

            greylist[addr] = value;
        } else if (listType == ListType.Whitelist) {
            if (blacklist[addr] != 0 || greylist[addr] != 0) {
                revert AddressInGreylistOrBlacklist(addr);
            }
            whitelist[addr] = value;
        } else {
            revert InvalidListType();
        }
        emit AddressAdded(listType, addr, value);
    }

    /**
     * @dev Internal function to reset an address in a restriction list.
     * @param listType The type of restriction list.
     * @param addr The address to reset.
     */
    function _resetAddress(ListType listType, address addr) internal {
        if (listType == ListType.Blacklist) {
            blacklist[addr] = 0;
        } else if (listType == ListType.Greylist) {
            greylist[addr] = 0;
        } else if (listType == ListType.Whitelist) {
            whitelist[addr] = 0;
        } else {
            revert InvalidListType();
        }
        emit AddressReset(listType, addr);
    }
}
