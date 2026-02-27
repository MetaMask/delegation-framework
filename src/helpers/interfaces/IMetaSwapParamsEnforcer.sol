// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IMetaSwapParamsEnforcer
 * @notice Interface for reading terms from MetaSwapParamsEnforcer (allowed output tokens, recipient, max slippage).
 * @dev Slippage format: 100e18 = 100%, 10e18 = 10%, 0 = no check.
 */
interface IMetaSwapParamsEnforcer {
    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms abi.encode(IERC20[] allowedTokens, address recipient, uint256 maxSlippagePercent)
     */
    function getTermsInfo(bytes calldata _terms)
        external
        pure
        returns (IERC20[] memory allowedTokens_, address recipient_, uint256 maxSlippagePercent_);
}
