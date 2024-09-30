// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode, Delegation } from "../utils/Types.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";

/**
 * @title SwapOfferEnforcer
 * @dev This contract enforces a swap offer, allowing partial transfers if the order is not filled in a single transaction.
 * @dev This caveat enforcer only works when the execution is in single mode.
 * @dev The redeemer must include an allowance delegation when executing the swap to ensure payment.
 */
contract SwapOfferEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    struct SwapOffer {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        uint256 amountInFilled;
        uint256 amountOutFilled;
        address recipient;
    }

    ////////////////////////////// State //////////////////////////////

    mapping(address delegationManager => mapping(bytes32 delegationHash => SwapOffer)) public swapOffers;

    ////////////////////////////// Events //////////////////////////////
    event SwapOfferUpdated(
        address indexed sender,
        address indexed redeemer,
        bytes32 indexed delegationHash,
        uint256 amountInFilled,
        uint256 amountOutFilled
    );

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Enforces the swap offer before the transaction is performed.
     * @param _terms The encoded swap offer terms.
     * @param _args The encoded arguments containing the claimed amount and payment delegation.
     * @param _mode The mode of the execution.
     * @param _executionCallData The transaction the delegate might try to perform.
     * @param _delegationHash The hash of the delegation being operated on.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address,
        address _redeemer
    )
        public
        override
        onlySingleExecutionMode(_mode)
    {
        (uint256 claimedAmount, IDelegationManager delegationManager,) = abi.decode(_args, (uint256, IDelegationManager, bytes));
        
        (uint256 amountInFilled_, uint256 amountOutFilled_) = _validateAndUpdate(_terms, _executionCallData, _delegationHash, claimedAmount);
        
        // Store the payment info for the afterHook
        SwapOffer storage offer = swapOffers[address(delegationManager)][_delegationHash];
        offer.amountInFilled = amountInFilled_;
        offer.amountOutFilled = amountOutFilled_;

        emit SwapOfferUpdated(msg.sender, _redeemer, _delegationHash, amountInFilled_, amountOutFilled_);
    }

    /**
     * @notice Enforces the conditions that should hold after a transaction is performed.
     * @param _terms The encoded swap offer terms.
     * @param _args The encoded arguments containing the claimed amount and payment delegation.
     * @param _delegationHash The hash of the delegation.
     */
    function afterHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode,
        bytes calldata,
        bytes32 _delegationHash,
        address,
        address _redeemer
    )
        public
        override
    {
        (uint256 claimedAmount, IDelegationManager delegationManager, bytes memory permissionContext) = abi.decode(_args, (uint256, IDelegationManager, bytes));
        
        (address tokenIn,,,,address recipient) = getTermsInfo(_terms);

        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = permissionContext;

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = ExecutionLib.encodeSingle(tokenIn, claimedAmount, abi.encodeWithSelector(IERC20.transfer.selector, address(this), claimedAmount));

        ModeCode[] memory encodedModes = new ModeCode[](1);
        encodedModes[0] = ModeLib.encodeSimpleSingle();

        uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));

        // Attempt to redeem the delegation and make the payment
        delegationManager.redeemDelegations(permissionContexts, encodedModes, executionCallDatas);

        // Ensure the contract received the payment
        uint256 balanceAfter = IERC20(tokenIn).balanceOf(address(this));
        require(balanceAfter >= balanceBefore + claimedAmount, "SwapOfferEnforcer:payment-not-received");

        // Transfer the received tokens to the recipient
        require(IERC20(tokenIn).transfer(recipient, claimedAmount), "SwapOfferEnforcer:transfer-to-recipient-failed");
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return tokenIn_ The address of the token being sold.
     * @return tokenOut_ The address of the token being bought.
     * @return amountIn_ The total amount of tokens to be sold.
     * @return amountOut_ The total amount of tokens to be bought.
     * @return recipient_ The address to receive the input tokens.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 amountOut_, address recipient_) {
        require(_terms.length == 148, "SwapOfferEnforcer:invalid-terms-length");

        tokenIn_ = address(bytes20(_terms[:20]));
        tokenOut_ = address(bytes20(_terms[20:40]));
        amountIn_ = uint256(bytes32(_terms[40:72]));
        amountOut_ = uint256(bytes32(_terms[72:104]));
        recipient_ = address(bytes20(_terms[104:124]));
    }

    /**
     * @notice Validates and updates the swap offer.
     * @param _terms The encoded swap offer terms.
     * @param _executionCallData The transaction the delegate might try to perform.
     * @param _delegationHash The hash of the delegation being operated on.
     * @param _claimedAmount The amount claimed to be transferred in.
     * @return amountInFilled_ The updated amount of input tokens filled.
     * @return amountOutFilled_ The updated amount of output tokens filled.
     */
    function _validateAndUpdate(
        bytes calldata _terms,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        uint256 _claimedAmount
    )
        internal
        returns (uint256 amountInFilled_, uint256 amountOutFilled_)
    {
        (address target_,, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(callData_.length == 68, "SwapOfferEnforcer:invalid-execution-length");

        (address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 amountOut_, address recipient_) = getTermsInfo(_terms);

        SwapOffer storage offer = swapOffers[msg.sender][_delegationHash];
        if (offer.tokenIn == address(0)) {
            // Initialize the offer if it doesn't exist
            offer.tokenIn = tokenIn_;
            offer.tokenOut = tokenOut_;
            offer.amountIn = amountIn_;
            offer.amountOut = amountOut_;
            offer.recipient = recipient_;
        } else {
            require(offer.tokenIn == tokenIn_ && offer.tokenOut == tokenOut_ &&
                    offer.amountIn == amountIn_ && offer.amountOut == amountOut_ &&
                    offer.recipient == recipient_,
                    "SwapOfferEnforcer:terms-mismatch");
        }

        require(target_ == tokenOut_, "SwapOfferEnforcer:invalid-token");

        bytes4 selector = bytes4(callData_[0:4]);
        require(selector == IERC20.transfer.selector || selector == IERC20.transferFrom.selector, "SwapOfferEnforcer:invalid-method");

        uint256 amount = uint256(bytes32(callData_[36:68]));

        require(offer.amountOutFilled + amount <= offer.amountOut, "SwapOfferEnforcer:exceeds-output-amount");
        
        amountInFilled_ = offer.amountInFilled + _claimedAmount;
        require(amountInFilled_ <= offer.amountIn, "SwapOfferEnforcer:exceeds-input-amount");
        
        amountOutFilled_ = offer.amountOutFilled + amount;
    }
}
