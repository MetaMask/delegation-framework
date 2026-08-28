// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMetaSwap } from "../../helpers/interfaces/IMetaSwap.sol";

/**
 * @title RestrictedMetaSwapAdapter
 * @notice Executes a MetaSwap quote while enforcing the actual minimum ERC20 output.
 * @dev The caller must approve this adapter for `_sellAmount`. Pair this adapter with
 *      {RestrictedMetaSwapEnforcer} so the maker signs the token pair, input amount,
 *      receiver, minimum output, aggregator, and adapter address.
 */
contract RestrictedMetaSwapAdapter {
    using SafeERC20 for IERC20;

    IMetaSwap public immutable metaSwap;

    error IdenticalTokens();
    error InvalidZeroAddress();
    error InsufficientBuyAmount(uint256 minimum, uint256 received);

    /**
     * @notice Sets the only MetaSwap settlement contract this adapter can call.
     * @param _metaSwap Immutable MetaSwap contract.
     */
    constructor(IMetaSwap _metaSwap) {
        if (address(_metaSwap) == address(0)) revert InvalidZeroAddress();
        metaSwap = _metaSwap;
    }

    /**
     * @notice Swaps an exact input amount and sends all received output to `_receiver`.
     * @param _aggregatorId MetaSwap aggregator identifier, bound by the signed enforcer terms.
     * @param _sellToken Exact token taken from the maker.
     * @param _buyToken Exact token expected from MetaSwap.
     * @param _sellAmount Exact input amount.
     * @param _minBuyAmount Minimum output; receiving more is allowed.
     * @param _receiver Signed output receiver.
     * @param _swapData Dynamic MetaSwap route data.
     * @return buyAmount_ Actual output delivered to `_receiver`.
     */
    function swap(
        string calldata _aggregatorId,
        IERC20 _sellToken,
        IERC20 _buyToken,
        uint256 _sellAmount,
        uint256 _minBuyAmount,
        address _receiver,
        bytes calldata _swapData
    )
        external
        returns (uint256 buyAmount_)
    {
        if (address(_sellToken) == address(_buyToken)) revert IdenticalTokens();
        if (address(_sellToken) == address(0) || address(_buyToken) == address(0) || _receiver == address(0)) {
            revert InvalidZeroAddress();
        }

        uint256 sellBalanceBefore_ = _sellToken.balanceOf(address(this));
        uint256 buyBalanceBefore_ = _buyToken.balanceOf(address(this));

        _sellToken.safeTransferFrom(msg.sender, address(this), _sellAmount);
        _sellToken.forceApprove(address(metaSwap), _sellAmount);
        metaSwap.swap(_aggregatorId, _sellToken, _sellAmount, _swapData);

        buyAmount_ = _buyToken.balanceOf(address(this)) - buyBalanceBefore_;
        if (buyAmount_ < _minBuyAmount) revert InsufficientBuyAmount(_minBuyAmount, buyAmount_);

        _buyToken.safeTransfer(_receiver, buyAmount_);

        uint256 unusedSell_ = _sellToken.balanceOf(address(this)) - sellBalanceBefore_;
        if (unusedSell_ > 0) _sellToken.safeTransfer(msg.sender, unusedSell_);
    }
}
