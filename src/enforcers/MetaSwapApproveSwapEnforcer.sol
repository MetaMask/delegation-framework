// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { IMetaSwap } from "../helpers/interfaces/IMetaSwap.sol";
import { Execution, ModeCode } from "../utils/Types.sol";

/**
 * @title MetaSwapApproveSwapEnforcer
 * @notice Enforces a one-shot batch of ERC20 approval followed by a direct MetaSwap swap.
 * @dev Supports `approve(amount), swap` and `approve(0), approve(amount), swap`.
 */
contract MetaSwapApproveSwapEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    struct Terms {
        address metaSwap;
        address tokenIn;
        address tokenOut;
        uint256 tokenInAmount;
        uint256 minTokenOut;
    }

    struct OutputSnapshot {
        uint256 balanceBefore;
        bool active;
    }

    mapping(address manager => mapping(bytes32 delegationHash => bool used)) public usedDelegations;
    mapping(address manager => mapping(bytes32 delegationHash => OutputSnapshot snapshot)) public outputSnapshots;

    event DelegationExecuted(address indexed delegationManager, bytes32 indexed delegationHash, address indexed delegator);

    error DelegationAlreadyUsed();
    error InvalidBatchLength();
    error InvalidApproveCall();
    error InvalidSwapCall();
    error AmountFromMismatch();
    error OutputSnapshotActive();
    error InsufficientOutput(uint256 minimum, uint256 received);
    error IdenticalTokens();
    error RemainingAllowance(uint256 remaining);

    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _delegator,
        address
    )
        public
        override
        onlyBatchCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        if (usedDelegations[msg.sender][_delegationHash]) revert DelegationAlreadyUsed();

        Terms memory terms_ = abi.decode(_terms, (Terms));
        if (terms_.tokenIn == terms_.tokenOut) revert IdenticalTokens();

        Execution[] calldata executions_ = _executionCallData.decodeBatch();

        if (executions_.length == 2) {
            _validateApprove(executions_[0], terms_, terms_.tokenInAmount);
            _validateSwap(executions_[1], terms_);
        } else if (executions_.length == 3) {
            _validateApprove(executions_[0], terms_, 0);
            _validateApprove(executions_[1], terms_, terms_.tokenInAmount);
            _validateSwap(executions_[2], terms_);
        } else {
            revert InvalidBatchLength();
        }

        OutputSnapshot storage snapshot_ = outputSnapshots[msg.sender][_delegationHash];
        if (snapshot_.active) revert OutputSnapshotActive();
        snapshot_.active = true;
        snapshot_.balanceBefore = IERC20(terms_.tokenOut).balanceOf(_delegator);
        usedDelegations[msg.sender][_delegationHash] = true;

        emit DelegationExecuted(msg.sender, _delegationHash, _delegator);
    }

    function afterHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32 _delegationHash,
        address _delegator,
        address
    )
        public
        override
    {
        Terms memory terms_ = abi.decode(_terms, (Terms));
        OutputSnapshot memory snapshot_ = outputSnapshots[msg.sender][_delegationHash];
        delete outputSnapshots[msg.sender][_delegationHash];

        uint256 remainingAllowance_ = IERC20(terms_.tokenIn).allowance(_delegator, terms_.metaSwap);
        if (remainingAllowance_ != 0) revert RemainingAllowance(remainingAllowance_);

        uint256 received_ = IERC20(terms_.tokenOut).balanceOf(_delegator) - snapshot_.balanceBefore;
        if (received_ < terms_.minTokenOut) revert InsufficientOutput(terms_.minTokenOut, received_);
    }

    function _validateApprove(Execution calldata _execution, Terms memory _terms, uint256 _expectedAmount) private pure {
        if (_execution.target != _terms.tokenIn || _execution.value != 0) revert InvalidApproveCall();
        if (bytes4(_execution.callData[:4]) != IERC20.approve.selector) revert InvalidApproveCall();

        (address spender_, uint256 amount_) = abi.decode(_execution.callData[4:], (address, uint256));
        if (spender_ != _terms.metaSwap || amount_ != _expectedAmount) revert InvalidApproveCall();
    }

    function _validateSwap(Execution calldata _execution, Terms memory _terms) private pure {
        if (_execution.target != _terms.metaSwap || _execution.value != 0) revert InvalidSwapCall();
        if (bytes4(_execution.callData[:4]) != IMetaSwap.swap.selector) revert InvalidSwapCall();

        (string memory aggregatorId_, IERC20 tokenFrom_, uint256 amountFrom_, bytes memory swapData_) =
            abi.decode(_execution.callData[4:], (string, IERC20, uint256, bytes));
        aggregatorId_;

        if (address(tokenFrom_) != _terms.tokenIn || amountFrom_ != _terms.tokenInAmount) revert InvalidSwapCall();

        (, // address(0)
            IERC20 swapTokenFrom_,
            IERC20 swapTokenTo_,
            uint256 swapAmountFrom_,
            uint256 amountTo_,, // metadata
            uint256 feeAmount_,, // feeWallet
            bool feeTo_
        ) = abi.decode(
            abi.encodePacked(abi.encode(address(0)), swapData_),
            (address, IERC20, IERC20, uint256, uint256, bytes, uint256, address, bool)
        );

        if (swapTokenFrom_ != tokenFrom_ || address(swapTokenTo_) != _terms.tokenOut) revert InvalidSwapCall();
        if (!feeTo_ && feeAmount_ + swapAmountFrom_ != amountFrom_) revert AmountFromMismatch();
        if (amountTo_ < _terms.minTokenOut) revert InvalidSwapCall();
    }

    function getTermsInfo(bytes calldata _terms) external pure returns (Terms memory terms_) {
        terms_ = abi.decode(_terms, (Terms));
    }

    function encodeTerms(Terms calldata _terms) external pure returns (bytes memory) {
        return abi.encode(_terms);
    }
}
