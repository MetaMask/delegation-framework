// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { ExactExecutionBatchLimitedCallsEnforcer } from "../../enforcers/ExactExecutionBatchLimitedCallsEnforcer.sol";
import { ModeCode, Execution } from "../../utils/Types.sol";

/**
 * @title ExactExecutionBatchLimitedCallsProfileEnforcer
 * @notice Versioned external profile extending {ExactExecutionBatchLimitedCallsEnforcer} with validity window and full
 *         `ModeCode` binding for limit-order style delegations.
 *
 * @dev TERMS LAYOUT — `abi.encodePacked(uint256 limit, uint128 validAfter, uint128 validUntil, bytes32 modeCode,
 * ExecutionLib.encodeBatch(...))`:
 *        - `terms[0:32]`   : maximum redemptions (inherited limited-calls semantics).
 *        - `terms[32:48]`  : `validAfter` — redemption allowed only when `block.timestamp > validAfter` (0 = unset).
 *        - `terms[48:64]`  : `validUntil` — redemption allowed only when `block.timestamp < validUntil` (0 = unset).
 *        - `terms[64:96]`  : expected full `ModeCode` (bytes32) passed to `executeFromExecutor`.
 *        - `terms[96:]`    : expected batch encoding (`ExecutionLib.encodeBatch(Execution[])`).
 *
 * @dev Profile version `1` for off-chain encoders.
 */
contract ExactExecutionBatchLimitedCallsProfileEnforcer is ExactExecutionBatchLimitedCallsEnforcer {
    uint256 public constant PROFILE_VERSION = 1;
    uint256 internal constant PROFILE_HEADER_BYTES = 96;

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
        onlyBatchCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        _profileBeforeHook(_terms, _mode, _executionCallData, _delegationHash);
    }

    function _profileBeforeHook(
        bytes calldata _terms,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash
    )
        internal
    {
        require(_terms.length >= PROFILE_HEADER_BYTES, "ExactExecutionBatchLimitedCallsProfileEnforcer:invalid-terms-length");

        uint256 limit_ = uint256(bytes32(_terms[0:32]));
        uint128 validAfter_ = uint128(bytes16(_terms[32:48]));
        uint128 validUntil_ = uint128(bytes16(_terms[48:64]));
        ModeCode expectedMode_ = ModeCode.wrap(bytes32(_terms[64:96]));

        _validateProfileWindow(validAfter_, validUntil_);
        require(
            ModeCode.unwrap(_mode) == ModeCode.unwrap(expectedMode_), "ExactExecutionBatchLimitedCallsProfileEnforcer:invalid-mode"
        );
        _validateExactExecution(_terms, _executionCallData);

        uint256 callCount_ = ++callCounts[msg.sender][_delegationHash];
        require(callCount_ <= limit_, "ExactExecutionBatchLimitedCallsProfileEnforcer:limit-exceeded");
    }

    function _validateProfileWindow(uint128 _validAfter, uint128 _validUntil) internal view {
        if (_validAfter > 0) {
            require(block.timestamp > _validAfter, "ExactExecutionBatchLimitedCallsProfileEnforcer:too-early");
        }
        if (_validUntil > 0) {
            require(block.timestamp < _validUntil, "ExactExecutionBatchLimitedCallsProfileEnforcer:expired");
        }
    }

    function _validateExactExecution(bytes calldata _terms, bytes calldata _executionCallData) internal pure {
        require(
            keccak256(_terms[PROFILE_HEADER_BYTES:]) == keccak256(_executionCallData),
            "ExactExecutionBatchLimitedCallsProfileEnforcer:invalid-execution"
        );
    }

    function getProfileTermsInfo(bytes calldata _terms)
        public
        pure
        returns (uint256 limit_, uint128 validAfter_, uint128 validUntil_, ModeCode expectedMode_, Execution[] memory executions_)
    {
        require(_terms.length >= PROFILE_HEADER_BYTES, "ExactExecutionBatchLimitedCallsProfileEnforcer:invalid-terms-length");
        limit_ = uint256(bytes32(_terms[0:32]));
        (validAfter_, validUntil_, expectedMode_) = _decodeProfileHeader(_terms);
        executions_ = ExecutionLib.decodeBatch(_terms[PROFILE_HEADER_BYTES:]);
    }

    function _decodeProfileHeader(bytes calldata _terms)
        internal
        pure
        returns (uint128 validAfter_, uint128 validUntil_, ModeCode expectedMode_)
    {
        validAfter_ = uint128(bytes16(_terms[32:48]));
        validUntil_ = uint128(bytes16(_terms[48:64]));
        expectedMode_ = ModeCode.wrap(bytes32(_terms[64:96]));
    }
}
