// SPDX-License-Identifier: MIT AND Apache-2.0

pragma solidity 0.8.23;

import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract BasicERC1155 is ERC1155, Ownable2Step {
    ////////////////////////////// State //////////////////////////////

    uint256 public tokenId;

    ////////////////////////////// Constructor  //////////////////////////////

    /// @dev Initializes the BasicERC1155 contract.
    /// @param _owner The owner of the ERC20 token. Also addres that received the initial amount of tokens.
    /// @param _name The name of the ERC20 token.
    /// @param _symbol The symbol of the ERC20 token.
    /// @param _baseUri The base URI of the tokens.
    constructor(
        address _owner,
        string memory _name,
        string memory _symbol,
        string memory _baseUri
    )
        Ownable(_owner)
        ERC1155(_baseUri)
    { }

    ////////////////////////////// External Methods //////////////////////////////

    /// @dev Allows the onwner to burn tokens from the specified user.
    /// @param _from The address of the user from whom the tokens will be burned.
    /// @param _id The token id to burn.
    /// @param _value The amount of tokens to burn.
    function burn(address _from, uint256 _id, uint256 _value) external onlyOwner {
        _burn(_from, _id, _value);
    }

    /// @dev Allows the owner to mint new tokens and assigns them to the specified user.
    /// @param _to The address of the user to whom the tokens will be minted.
    /// @param _id The token id to mint.
    /// @param _value The amount of tokens to mint.
    /// @param _data Any data related to the token.
    function mint(address _to, uint256 _id, uint256 _value, bytes memory _data) external onlyOwner {
        _mint(_to, _id, _value, _data);
    }
}
