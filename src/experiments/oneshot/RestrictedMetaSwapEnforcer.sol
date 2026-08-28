// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "../../enforcers/CaveatEnforcer.sol";
import { ModeCode } from "../../utils/Types.sol";
import { RestrictedMetaSwapAdapter } from "./RestrictedMetaSwapAdapter.sol";

/**
 * @title RestrictedMetaSwapEnforcer
 * @notice Binds a one-shot MetaSwap execution to a signed token pair, exact input,
 *         minimum output, receiver, adapter, and aggregator.
 * @dev The output rule is `actualBuyAmount >= minBuyAmount`; receiving more is valid.
 *      The before/after balance snapshot proves settlement rather than trusting router return data.
 */
contract RestrictedMetaSwapEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    struct Terms {
        address adapter;
        address sellToken;
        address buyToken;
        address receiver;
        uint256 sellAmount;
        uint256 minBuyAmount;
        bytes32 aggregatorIdHash;
    }

    struct BalanceSnapshot {
        uint256 balanceBefore;
        bool locked;
    }

    mapping(address manager => mapping(bytes32 delegationHash => BalanceSnapshot snapshot)) public snapshots;

    error EnforcerLocked();
    error InvalidExecution();
    error InsufficientBuyAmount(uint256 minimum, uint256 received);

    /**
     * @notice Validates the execution against the maker-signed terms and snapshots output balance.
     * @param _terms ABI-encoded {Terms}.
     * @param _mode Must be single-call/default mode.
     * @param _executionCallData Must call `RestrictedMetaSwapAdapter.swap` with matching values.
     * @param _delegationHash Delegation key used to isolate the temporary snapshot.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address,
        address
    )
        public
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        Terms memory terms_ = abi.decode(_terms, (Terms));
        _validateExecution(terms_, _executionCallData);

        BalanceSnapshot storage snapshot_ = snapshots[msg.sender][_delegationHash];
        if (snapshot_.locked) revert EnforcerLocked();
        snapshot_.locked = true;
        snapshot_.balanceBefore = IERC20(terms_.buyToken).balanceOf(terms_.receiver);
    }

    function _validateExecution(Terms memory _terms, bytes calldata _executionCallData) private pure {
        (address target_, uint256 value_, bytes calldata callData_) = _executionCallData.decodeSingle();
        if (target_ != _terms.adapter || value_ != 0) revert InvalidExecution();
        if (bytes4(callData_[:4]) != RestrictedMetaSwapAdapter.swap.selector) revert InvalidExecution();

        (
            string memory aggregatorId_,
            IERC20 sellToken_,
            IERC20 buyToken_,
            uint256 sellAmount_,
            uint256 minBuyAmount_,
            address receiver_,
            bytes memory swapData_
        ) = abi.decode(callData_[4:], (string, IERC20, IERC20, uint256, uint256, address, bytes));
        swapData_;

        if (
            address(sellToken_) != _terms.sellToken || address(buyToken_) != _terms.buyToken || sellAmount_ != _terms.sellAmount
                || minBuyAmount_ < _terms.minBuyAmount || receiver_ != _terms.receiver
                || keccak256(bytes(aggregatorId_)) != _terms.aggregatorIdHash
        ) {
            revert InvalidExecution();
        }
    }

    /**
     * @notice Proves that the signed receiver obtained at least the signed minimum output.
     */
    function afterHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32 _delegationHash,
        address,
        address
    )
        public
        override
    {
        Terms memory terms_ = abi.decode(_terms, (Terms));
        BalanceSnapshot memory snapshot_ = snapshots[msg.sender][_delegationHash];
        delete snapshots[msg.sender][_delegationHash];

        uint256 received_ = IERC20(terms_.buyToken).balanceOf(terms_.receiver) - snapshot_.balanceBefore;
        if (received_ < terms_.minBuyAmount) revert InsufficientBuyAmount(terms_.minBuyAmount, received_);
    }

    /**
     * @notice Encodes maker-signed caveat terms.
     */
    function encodeTerms(Terms memory _terms) external pure returns (bytes memory) {
        return abi.encode(_terms);
    }
}
