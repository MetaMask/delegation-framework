// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity ^0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IWstETH
 * @notice Minimal Lido wstETH surface used by `TreasuryManager.wrapStEth`.
 */
interface IWstETH is IERC20 {
    function wrap(uint256 _stETHAmount) external returns (uint256);

    function getWstETHByStETH(uint256 _stETHAmount) external view returns (uint256);
}
