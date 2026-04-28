// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IWstETH {
    /**
     * @notice Exchanges stETH for wstETH at the current share ratio.
     * @dev Pulls `_stETHAmount` of stETH from `msg.sender` (sender must have approved this amount first) and mints
     *      the corresponding wstETH amount to `msg.sender`. Reverts if `_stETHAmount` is zero.
     * @param _stETHAmount Amount of stETH to wrap.
     * @return Amount of wstETH minted to `msg.sender`.
     */
    function wrap(uint256 _stETHAmount) external returns (uint256);
}
