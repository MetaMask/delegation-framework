// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title AllowanceRevocationEnforcer
 * @notice Allows the delegate to revoke an existing token approval on behalf of the delegator. Supports ERC-20
 * `approve`, ERC-721 per-token `approve`, and ERC-721/ERC-1155 `setApprovalForAll`.
 *
 * @dev The execution must transfer zero native value and carry one of the supported approval calldatas (length 68
 * bytes: 4-byte selector + two 32-byte words). Branching is determined as follows:
 * - selector `setApprovalForAll(address operator, bool approved)`:
 *   - `approved` MUST be false, and
 *   - `isApprovedForAll(delegator, operator)` MUST currently be true.
 * - selector `approve(address, uint256)` (shared by ERC-20 and ERC-721):
 *   - if the first parameter is `address(0)` the call is treated as an ERC-721 per-token revocation:
 *     - `getApproved(tokenId)` on the target MUST currently return a non-zero address.
 *   - otherwise the call is treated as an ERC-20 allowance revocation:
 *     - the second parameter (amount) MUST be zero, and
 *     - `allowance(delegator, spender)` on the target MUST currently return non-zero.
 *
 * The pre-existing approval check guarantees the call is strictly a revocation of an existing approval rather than
 * a new grant or a no-op.
 *
 * @dev This enforcer does not consume any terms.
 * @dev Operates only in single call type and default execution mode.
 */
contract AllowanceRevocationEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    /// @dev Calldata length of `approve(address,uint256)` and `setApprovalForAll(address,bool)`:
    /// 4-byte selector + two 32-byte words.
    uint256 private constant _APPROVAL_CALLDATA_LENGTH = 68;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Requires the execution to revoke an existing token approval owned by `_delegator`.
     * @param _mode Must be single call type and default execution mode.
     * @param _executionCallData Single execution targeting the token contract.
     * @param _delegator The delegator, treated as the approval `owner`.
     */
    function beforeHook(
        bytes calldata,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32,
        address _delegator,
        address
    )
        public
        view
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        (address target_, uint256 value_, bytes calldata callData_) = _executionCallData.decodeSingle();

        require(value_ == 0, "AllowanceRevocationEnforcer:invalid-value");
        require(callData_.length == _APPROVAL_CALLDATA_LENGTH, "AllowanceRevocationEnforcer:invalid-execution-length");

        bytes4 selector_ = bytes4(callData_[0:4]);
        if (selector_ == IERC721.setApprovalForAll.selector) {
            _enforceSetApprovalForAllRevocation(target_, callData_, _delegator);
            return;
        }
        if (selector_ == IERC20.approve.selector) {
            address firstParam_ = address(uint160(uint256(bytes32(callData_[4:36]))));
            if (firstParam_ == address(0)) {
                _enforceErc721ApproveRevocation(target_, callData_);
            } else {
                _enforceErc20ApproveRevocation(target_, callData_, _delegator, firstParam_);
            }
            return;
        }
        revert("AllowanceRevocationEnforcer:invalid-method");
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @dev Validates an ERC-20 `approve(spender, 0)` revocation. Requires `allowance(delegator, spender) > 0` on the
     * target.
     */
    function _enforceErc20ApproveRevocation(
        address _target,
        bytes calldata _callData,
        address _delegator,
        address _spender
    )
        private
        view
    {
        require(uint256(bytes32(_callData[36:68])) == 0, "AllowanceRevocationEnforcer:non-zero-amount");

        (bool success_, bytes memory returnData_) =
            _target.staticcall(abi.encodeWithSelector(IERC20.allowance.selector, _delegator, _spender));
        require(success_ && returnData_.length >= 32, "AllowanceRevocationEnforcer:allowance-call-failed");
        require(abi.decode(returnData_, (uint256)) != 0, "AllowanceRevocationEnforcer:no-allowance-to-revoke");
    }

    /**
     * @dev Validates an ERC-721 `approve(address(0), tokenId)` revocation. Requires `getApproved(tokenId)` on the
     * target to be non-zero (i.e. an approval is currently set).
     */
    function _enforceErc721ApproveRevocation(address _target, bytes calldata _callData) private view {
        uint256 tokenId_ = uint256(bytes32(_callData[36:68]));

        (bool success_, bytes memory returnData_) =
            _target.staticcall(abi.encodeWithSelector(IERC721.getApproved.selector, tokenId_));
        require(success_ && returnData_.length >= 32, "AllowanceRevocationEnforcer:getApproved-call-failed");
        require(abi.decode(returnData_, (address)) != address(0), "AllowanceRevocationEnforcer:no-approval-to-revoke");
    }

    /**
     * @dev Validates a `setApprovalForAll(operator, false)` revocation. Requires `isApprovedForAll(delegator,
     * operator)` on the target to currently be true.
     */
    function _enforceSetApprovalForAllRevocation(address _target, bytes calldata _callData, address _delegator) private view {
        address operator_ = address(uint160(uint256(bytes32(_callData[4:36]))));
        bool approved_ = uint256(bytes32(_callData[36:68])) != 0;
        require(!approved_, "AllowanceRevocationEnforcer:not-a-revocation");

        (bool success_, bytes memory returnData_) =
            _target.staticcall(abi.encodeWithSelector(IERC721.isApprovedForAll.selector, _delegator, operator_));
        require(success_ && returnData_.length >= 32, "AllowanceRevocationEnforcer:isApprovedForAll-call-failed");
        require(abi.decode(returnData_, (bool)), "AllowanceRevocationEnforcer:no-approval-to-revoke");
    }
}
