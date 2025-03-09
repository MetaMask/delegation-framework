// SPDX-License-Identifier: MIT AND Apache-2.0

pragma solidity 0.8.23;

import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract BasicERC20 is ERC20, Ownable2Step {
    ////////////////////////////// Constructor  //////////////////////////////

    /// @dev Initializes the BasicERC20 contract.
    /// @param _owner The owner of the ERC20 token. Also addres that received the initial amount of tokens.
    /// @param _name The name of the ERC20 token.
    /// @param _symbol The symbol of the ERC20 token.
    /// @param _initialAmount The initial supply of the ERC20 token.
    constructor(
        address _owner,
        string memory _name,
        string memory _symbol,
        uint256 _initialAmount
    )
        Ownable(_owner)
        ERC20(_name, _symbol)
    {
        if (_initialAmount > 0) _mint(_owner, _initialAmount);
    }

    ////////////////////////////// External Methods //////////////////////////////

    /// @dev Allows the onwner to burn tokens from the specified user.
    /// @param _user The address of the user from whom the tokens will be burned.
    /// @param _amount The amount of tokens to burn.
    function burn(address _user, uint256 _amount) external onlyOwner {
        _burn(_user, _amount);
    }

    /// @dev Allows the owner to mint new tokens and assigns them to the specified user.
    /// @param _user The address of the user to whom the tokens will be minted.
    /// @param _amount The amount of tokens to mint.
    function mint(address _user, uint256 _amount) external onlyOwner {
        _mint(_user, _amount);
    }
}
