// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { console } from "forge-std/console.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode, Delegation } from "../utils/Types.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";

/**
 * @title SwapOfferEnforcer
 * @dev This contract enforces a swap offer, allowing partial transfers if the order is not filled in a single transaction.
 * @dev This caveat enforcer only works when the execution is in single mode.
 * @dev The redeemer must include an allowance delegation when executing the swap to ensure payment.
 */
contract MultiPointOfferEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    struct Amount {
        uint256 tokenInPerTokenOut;
        uint256 time;
    }

    struct SwapOffer {
        address tokenIn;
        address tokenOut;
        Amount[] amounts;
        address recipient;
    }

    struct SwapOfferArgs {
        uint256 offeredAmount;
        IDelegationManager delegationManager;
        bytes permissionContext;
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
     * @param terms The encoded swap offer terms.
     * @param args The encoded arguments containing the claimed amount and payment delegation.
     * @param mode The mode of the execution.
     * @param executionCallData The transaction the delegate might try to perform.
     * @param delegationHash The hash of the delegation being operated on.
     */
    function beforeHook(
        bytes calldata terms,
        bytes calldata args,
        ModeCode mode,
        bytes calldata executionCallData,
        bytes32 delegationHash,
        address,
        address redeemer
    )
        public
        override
        onlySingleExecutionMode(mode)
    {
    }
    /**
     * @notice Enforces the conditions that should hold after a transaction is performed.
     * @param terms The encoded swap offer terms.
     * @param args The encoded arguments containing the claimed amount and payment delegation.
     * @param delegationHash The hash of the delegation.
     */
    function afterHook(
        bytes calldata terms,
        bytes calldata args,
        ModeCode mode,
        bytes calldata executionCallData,
        bytes32 delegationHash,
        address,
        address redeemer
    )
        public
        override
    {
        SwapOffer memory offer = abi.decode(terms, (SwapOffer));
        SwapOfferArgs memory args = abi.decode(args, (SwapOfferArgs));

        (uint256 currentExchangeRate, uint256 amountIn) = _validateAndUpdate(offer, executionCallData);
        uint256 amountToTransferIn = args.offeredAmount;

        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = args.permissionContext;

        uint256 balanceBefore = IERC20(offer.tokenIn).balanceOf(address(this));

        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = ExecutionLib.encodeSingle(
            offer.tokenIn,
            0,
            abi.encodeWithSelector(IERC20.transfer.selector, address(this), amountToTransferIn)
        );

        ModeCode[] memory encodedModes = new ModeCode[](1);
        encodedModes[0] = ModeLib.encodeSimpleSingle();

        // Attempt to redeem the delegation and make the payment to this contract first
        args.delegationManager.redeemDelegations(permissionContexts, encodedModes, executionCallDatas);
        
        // Ensure this contract received the payment
        uint256 balanceAfter = IERC20(offer.tokenIn).balanceOf(address(this));
        console.log("Balance before:");
        console.logUint(balanceBefore);
        console.log("Balance after:");
        console.logUint(balanceAfter);
        console.log("Expected increase:");
        console.logUint(amountToTransferIn);
        require(balanceAfter >= balanceBefore + amountToTransferIn, "SwapOfferEnforcer:payment-not-received");

        // Transfer from this contract to the offer issuer
        IERC20(offer.tokenIn).transfer(offer.recipient, amountToTransferIn);

        // Reset the swap offer
        delete swapOffers[address(args.delegationManager)][delegationHash];
    }


    /**
     * @notice Validates and updates the swap offer.
     * @param offer The SwapOffer struct containing the offer details.
     * @param executionCallData The transaction the delegate might try to perform.
     * @return currentExchangeRate The current exchange rate based on the offer's price points.
     */
    function _validateAndUpdate(
        SwapOffer memory offer,
        bytes calldata executionCallData
    )
        internal
        returns (uint256 currentExchangeRate, uint256 amountIn)
    {
        // Calculate the current exchange rate
        currentExchangeRate = _getCurrentPrice(offer);

        // Validate the execution call data
        (address target, uint256 value, bytes calldata callData) = ExecutionLib.decodeSingle(executionCallData);
        
        console.log("Target:");
        console.logAddress(target);
        console.log("Expected:");
        console.logAddress(offer.tokenOut);
        require(target == offer.tokenOut, "MultiPointOfferEnforcer:invalid-target");
        
        console.log("Value:");
        console.logUint(value);
        require(value == 0, "MultiPointOfferEnforcer:non-zero-value");
        
        console.log("Calldata length:");
        console.logUint(callData.length);
        require(callData.length >= 68, "MultiPointOfferEnforcer:invalid-calldata-length");
        
        bytes4 selector = bytes4(callData[0:4]);
        console.log("Selector:");
        console.logBytes4(selector);
        console.log("Expected:");
        console.logBytes4(IERC20.transfer.selector);
        require(selector == IERC20.transfer.selector, "MultiPointOfferEnforcer:invalid-method");
        
        uint256 amountOut = uint256(bytes32(callData[36:68]));
        amountIn = (amountOut * currentExchangeRate) / 1e18;

        return (currentExchangeRate, amountIn);
    }
    /**
     * @notice Calculates the current price based on the current time and the price points.
     * @param offer The SwapOffer struct containing the offer details.
     * @return The current price (inputTokenPerOutputToken).
     */
    function _getCurrentPrice(SwapOffer memory offer) internal view returns (uint256) {
        uint256 currentTime = block.timestamp;
        console.log("Number of price points:");
        console.logUint(offer.amounts.length);
        require(offer.amounts.length >= 2, "MultiPointOfferEnforcer:insufficient-price-points");

        for (uint i = 1; i < offer.amounts.length; i++) {
            if (currentTime <= offer.amounts[i].time) {
                uint256 timeRange = offer.amounts[i].time - offer.amounts[i-1].time;
                uint256 priceRange = offer.amounts[i].tokenInPerTokenOut > offer.amounts[i-1].tokenInPerTokenOut ?
                    offer.amounts[i].tokenInPerTokenOut - offer.amounts[i-1].tokenInPerTokenOut :
                    offer.amounts[i-1].tokenInPerTokenOut - offer.amounts[i].tokenInPerTokenOut;
                uint256 timeElapsed = currentTime - offer.amounts[i-1].time;
                uint256 priceChange = (priceRange * timeElapsed) / timeRange;

                return offer.amounts[i].tokenInPerTokenOut > offer.amounts[i-1].tokenInPerTokenOut ?
                    offer.amounts[i-1].tokenInPerTokenOut + priceChange :
                    offer.amounts[i-1].tokenInPerTokenOut - priceChange;
            }
        }

        return offer.amounts[offer.amounts.length - 1].tokenInPerTokenOut;
    }
}
