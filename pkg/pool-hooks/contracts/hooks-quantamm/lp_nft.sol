//SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title LPNFT contract for QuantAMM LP NFTs 
/// @notice implements ERC721 for LP NFTs 
contract LPNFT is ERC721 {

    uint256 numMinted;

    /// @notice the address of the QuantAMM pool this token is for
    address public vault;

    /// @notice Exception to be thrown when a transfer is attempted
    error NonTransferable();

    /// @notice Modifier for only allowing the pool to call certain functions
    modifier onlyVault() {
        require(msg.sender == vault, "VAULTONLY"); //Action only allowed by pool
        _;
    }


    constructor(
        string memory _name,
        string memory _symbol,
        address _vault
    ) ERC721(_name, _symbol) {
        vault = _vault;
    }

    /// @param _to the address to mint the NFT to
    function mint(address _to) public onlyVault returns (uint256 tokenId) {
        tokenId = ++numMinted; // We start minting at 1
        _mint(_to, tokenId);
    }

    /// @param _tokenId the id of the NFT to burn
    function burn(uint256 _tokenId) public onlyVault {
        _burn(_tokenId);
    }
}
