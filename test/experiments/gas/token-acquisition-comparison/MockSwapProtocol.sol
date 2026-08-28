// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Mintable token used only by the token-acquisition gas benchmark.
contract TokenAcquisitionBenchmarkERC20 is ERC20 {
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) { }

    /// @notice Mints benchmark liquidity.
    function mint(address _recipient, uint256 _amount) external {
        _mint(_recipient, _amount);
    }
}

/// @notice Deterministic protocol shared by both benchmark paths.
contract MockSwapProtocol {
    using SafeERC20 for IERC20;

    uint256 public constant OUTPUT_MULTIPLIER = 2;

    /// @notice Pulls input from the caller and pays exactly twice the input to the requested recipient.
    function swap(
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _tokenInAmount,
        address _recipient
    )
        external
        returns (uint256 tokenOutAmount_)
    {
        _tokenIn.safeTransferFrom(msg.sender, address(this), _tokenInAmount);

        tokenOutAmount_ = _tokenInAmount * OUTPUT_MULTIPLIER;
        _tokenOut.safeTransfer(_recipient, tokenOutAmount_);
    }
}
