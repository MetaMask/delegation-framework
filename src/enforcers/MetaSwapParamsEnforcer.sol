// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title MetaSwapParamsEnforcer
 * @notice Enforces that the output token of a swap (tokenTo) is in the root delegator's allowed list.
 * @dev Used by DelegationMetaSwapAdapter. Terms = abi.encode(IERC20[] allowedTokens, address recipient, uint256
 * maxSlippagePercent).
 *      recipient and maxSlippagePercent are read by the adapter only; this enforcer only validates tokenTo.
 *      Slippage format: 100e18 = 100%, 10e18 = 10%, 0 = no per-delegation check.
 *      Args = abi.encode(IERC20 tokenTo), set by the adapter before redeem.
 *      allowedTokens must not be empty. Use a single element ANY_TOKEN to allow any output token; otherwise tokenTo must be in
 * allowedTokens.
 */
contract MetaSwapParamsEnforcer is CaveatEnforcer {
    ////////////////////////////// Constants //////////////////////////////

    /// @dev Special token value. When allowedTokens has length 1 and this value, any tokenTo is allowed.
    address public constant ANY_TOKEN = address(0xa11);

    /// @dev Maximum allowed slippage: 100% in 18-decimal fixed point (100e18). Values must be in [0, PERCENT_100].
    uint256 public constant PERCENT_100 = 100e18;

    ////////////////////////////// External Functions //////////////////////////////

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms abi.encode(IERC20[] allowedTokens, address recipient, uint256 maxSlippagePercent)
     * @return allowedTokens_ Output tokens permitted by the root delegator (length >= 1; use [ANY_TOKEN] for any).
     * @return recipient_ Address to receive swap output (address(0) = root delegator).
     * @return maxSlippagePercent_ Max slippage (100e18 = 100%, 10e18 = 10%; 0 = no check; must be <= PERCENT_100).
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (IERC20[] memory allowedTokens_, address recipient_, uint256 maxSlippagePercent_)
    {
        (allowedTokens_, recipient_, maxSlippagePercent_) = abi.decode(_terms, (IERC20[], address, uint256));
        require(allowedTokens_.length != 0, "MetaSwapParamsEnforcer:invalid-empty-allowed-tokens");
        require(maxSlippagePercent_ <= PERCENT_100, "MetaSwapParamsEnforcer:invalid-max-slippage");
    }

    /**
     * @notice Enforces that the swap output token (args) is in the allowed list (terms).
     * @param _terms abi.encode(IERC20[] allowedTokens, address recipient, uint256 maxSlippagePercent)
     * @param _args abi.encode(IERC20 tokenTo) — the output token from the swap execution
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode _mode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        pure
        override
        onlyDefaultExecutionMode(_mode)
    {
        (IERC20[] memory allowedTokens_,,) = getTermsInfo(_terms);
        IERC20 tokenTo_ = abi.decode(_args, (IERC20));

        if (allowedTokens_.length == 1 && address(allowedTokens_[0]) == ANY_TOKEN) return;

        for (uint256 i = 0; i < allowedTokens_.length; ++i) {
            if (address(allowedTokens_[i]) == address(tokenTo_)) return;
        }
        revert("MetaSwapParamsEnforcer:token-to-not-allowed");
    }
}
