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
        require(!usedDelegations[msg.sender][_delegationHash], "MetaSwapApproveSwapEnforcer:delegation-already-used");

        Terms memory terms_ = abi.decode(_terms, (Terms));
        require(terms_.tokenIn != terms_.tokenOut, "MetaSwapApproveSwapEnforcer:identical-tokens");

        Execution[] calldata executions_ = _executionCallData.decodeBatch();

        if (executions_.length == 2) {
            _validateApprove(executions_[0], terms_, terms_.tokenInAmount);
            _validateSwap(executions_[1], terms_);
        } else if (executions_.length == 3) {
            _validateApprove(executions_[0], terms_, 0);
            _validateApprove(executions_[1], terms_, terms_.tokenInAmount);
            _validateSwap(executions_[2], terms_);
        } else {
            revert("MetaSwapApproveSwapEnforcer:invalid-batch-length");
        }

        OutputSnapshot storage snapshot_ = outputSnapshots[msg.sender][_delegationHash];
        require(!snapshot_.active, "MetaSwapApproveSwapEnforcer:output-snapshot-active");
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
        require(remainingAllowance_ == 0, "MetaSwapApproveSwapEnforcer:remaining-allowance");

        uint256 received_ = IERC20(terms_.tokenOut).balanceOf(_delegator) - snapshot_.balanceBefore;
        require(received_ >= terms_.minTokenOut, "MetaSwapApproveSwapEnforcer:insufficient-output");
    }

    function _validateApprove(Execution calldata _execution, Terms memory _terms, uint256 _expectedAmount) private pure {
        require(
            _execution.target == _terms.tokenIn && _execution.value == 0,
            "MetaSwapApproveSwapEnforcer:invalid-approve-call"
        );
        require(
            bytes4(_execution.callData[:4]) == IERC20.approve.selector,
            "MetaSwapApproveSwapEnforcer:invalid-approve-call"
        );

        (address spender_, uint256 amount_) = abi.decode(_execution.callData[4:], (address, uint256));
        require(
            spender_ == _terms.metaSwap && amount_ == _expectedAmount,
            "MetaSwapApproveSwapEnforcer:invalid-approve-call"
        );
    }

    function _validateSwap(Execution calldata _execution, Terms memory _terms) private pure {
        require(
            _execution.target == _terms.metaSwap && _execution.value == 0,
            "MetaSwapApproveSwapEnforcer:invalid-swap-call"
        );
        require(
            bytes4(_execution.callData[:4]) == IMetaSwap.swap.selector, "MetaSwapApproveSwapEnforcer:invalid-swap-call"
        );

        (string memory aggregatorId_, IERC20 tokenFrom_, uint256 amountFrom_, bytes memory swapData_) =
            abi.decode(_execution.callData[4:], (string, IERC20, uint256, bytes));
        aggregatorId_;

        require(
            address(tokenFrom_) == _terms.tokenIn && amountFrom_ == _terms.tokenInAmount,
            "MetaSwapApproveSwapEnforcer:invalid-swap-call"
        );

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

        require(
            swapTokenFrom_ == tokenFrom_ && address(swapTokenTo_) == _terms.tokenOut,
            "MetaSwapApproveSwapEnforcer:invalid-swap-call"
        );
        require(feeTo_ || feeAmount_ + swapAmountFrom_ == amountFrom_, "MetaSwapApproveSwapEnforcer:amount-from-mismatch");
        require(amountTo_ >= _terms.minTokenOut, "MetaSwapApproveSwapEnforcer:invalid-swap-call");
    }

    function getTermsInfo(bytes calldata _terms) external pure returns (Terms memory terms_) {
        terms_ = abi.decode(_terms, (Terms));
    }

    function encodeTerms(Terms calldata _terms) external pure returns (bytes memory) {
        return abi.encode(_terms);
    }
}
