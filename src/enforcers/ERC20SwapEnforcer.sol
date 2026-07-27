// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { Execution, ModeCode } from "../utils/Types.sol";

/**
 * @title ERC20SwapEnforcer
 * @notice Allows an ERC-20-funded swap through a specified Uniswap Universal Router-compatible contract while
 * requiring the recipient to receive a minimum amount of an ERC-20 or native token.
 *
 * @dev The execution MUST use batch call type and default execution mode. Depending on `_args`, the batch is:
 * - Approval included (`_args` empty or `0x00`):
 *   1. `sourceToken.approve(swapTarget, amount)`, where `amount > 0`.
 *   2. `swapTarget.execute(...)`.
 * - Approval skipped (`_args == 0x01`):
 *   1. `swapTarget.execute(...)`.
 *
 * The router calldata after the selector is intentionally unrestricted. Both Universal Router `execute` overloads
 * (`execute(bytes,bytes[])` and `execute(bytes,bytes[],uint256)`) are supported. All executions MUST transfer zero
 * native value, so native-source swaps require a separate permission.
 *
 * The destination token is encoded in signed terms. `address(0)` represents the native token. The source token,
 * destination token, swap target, recipient, and minimum output amount are all fixed by the delegation terms.
 *
 * @dev Security considerations:
 * - The approved source amount and router calldata are chosen by the redeemer. This enforcer does not cap source
 *   token expenditure; compose it with an ERC-20 decrease enforcer when a maximum input amount is required.
 * - Skipping approval only validates the batch shape. It does not prove which existing router allowance is consumed.
 * - The swap target must be trusted. Universal Router commands can perform actions beyond a simple swap.
 * - Any unused allowance created by the approval remains after execution.
 */
contract ERC20SwapEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// Constants //////////////////////////////

    /// @dev `execute(bytes,bytes[])`.
    bytes4 public constant EXECUTE_SELECTOR = 0x24856bc3;

    /// @dev `execute(bytes,bytes[],uint256)`.
    bytes4 public constant EXECUTE_WITH_DEADLINE_SELECTOR = 0x3593564c;

    ////////////////////////////// Structs //////////////////////////////

    struct TermsData {
        address sourceToken;
        address destinationToken;
        address swapTarget;
        address recipient;
        uint256 minAmountOut;
    }

    ////////////////////////////// State //////////////////////////////

    mapping(bytes32 hashKey => uint256 balance) public balanceCache;
    mapping(bytes32 hashKey => bool lock) public isLocked;

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Generates the key used to isolate an active swap validation.
     */
    function getHashKey(address _caller, bytes32 _delegationHash) external pure returns (bytes32) {
        return _getHashKey(_caller, _delegationHash);
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Validates the swap batch and caches the recipient's destination-token balance.
     * @param _terms 112 packed bytes:
     * - source token (20 bytes; MUST NOT be address(0))
     * - destination token (20 bytes; address(0) means native token)
     * - swap target (20 bytes)
     * - output recipient (20 bytes)
     * - minimum destination amount (32 bytes)
     * @param _args Empty or `0x00` when approval is included; `0x01` when approval is skipped.
     * @param _mode MUST be batch call type and default execution mode.
     * @param _executionCallData The approval-and-swap or swap-only batch.
     * @param _delegationHash The hash of the delegation carrying this caveat.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
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
        TermsData memory terms_ = getTermsInfo(_terms);
        bool skipApproval_ = getArgsInfo(_args);
        Execution[] calldata executions_ = _executionCallData.decodeBatch();

        uint256 swapIndex_;
        if (skipApproval_) {
            require(executions_.length == 1, "ERC20SwapEnforcer:invalid-batch-size");
        } else {
            require(executions_.length == 2, "ERC20SwapEnforcer:invalid-batch-size");
            _validateApproval(executions_[0], terms_);
            swapIndex_ = 1;
        }
        _validateSwap(executions_[swapIndex_], terms_.swapTarget);

        bytes32 hashKey_ = _getHashKey(msg.sender, _delegationHash);
        require(!isLocked[hashKey_], "ERC20SwapEnforcer:enforcer-is-locked");
        isLocked[hashKey_] = true;
        balanceCache[hashKey_] = _getBalance(terms_.destinationToken, terms_.recipient);
    }

    /**
     * @notice Requires the recipient's destination-token balance to have increased by at least the signed minimum.
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
        TermsData memory terms_ = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, _delegationHash);
        require(isLocked[hashKey_], "ERC20SwapEnforcer:enforcer-not-locked");

        uint256 balanceBefore_ = balanceCache[hashKey_];
        uint256 balanceAfter_ = _getBalance(terms_.destinationToken, terms_.recipient);

        delete isLocked[hashKey_];
        delete balanceCache[hashKey_];

        require(
            balanceAfter_ >= balanceBefore_ && balanceAfter_ - balanceBefore_ >= terms_.minAmountOut,
            "ERC20SwapEnforcer:insufficient-output"
        );
    }

    /**
     * @notice Decodes and validates this enforcer's signed terms.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (TermsData memory termsData_) {
        require(_terms.length == 112, "ERC20SwapEnforcer:invalid-terms-length");

        termsData_.sourceToken = address(bytes20(_terms[0:20]));
        termsData_.destinationToken = address(bytes20(_terms[20:40]));
        termsData_.swapTarget = address(bytes20(_terms[40:60]));
        termsData_.recipient = address(bytes20(_terms[60:80]));
        termsData_.minAmountOut = uint256(bytes32(_terms[80:112]));

        require(termsData_.sourceToken != address(0), "ERC20SwapEnforcer:invalid-source-token");
        require(termsData_.swapTarget != address(0), "ERC20SwapEnforcer:invalid-swap-target");
        require(termsData_.recipient != address(0), "ERC20SwapEnforcer:invalid-recipient");
        require(termsData_.minAmountOut != 0, "ERC20SwapEnforcer:zero-min-amount-out");
        require(
            termsData_.destinationToken == address(0) || termsData_.sourceToken != termsData_.destinationToken,
            "ERC20SwapEnforcer:identical-tokens"
        );
    }

    /**
     * @notice Decodes whether the approval execution should be skipped.
     * @dev Empty args and `0x00` include approval. `0x01` skips approval.
     */
    function getArgsInfo(bytes calldata _args) public pure returns (bool skipApproval_) {
        if (_args.length == 0) return false;
        require(_args.length == 1, "ERC20SwapEnforcer:invalid-args-length");
        uint8 skipApprovalFlag_ = uint8(_args[0]);
        require(skipApprovalFlag_ <= 1, "ERC20SwapEnforcer:invalid-args");
        return skipApprovalFlag_ == 1;
    }

    ////////////////////////////// Private Methods //////////////////////////////

    function _validateApproval(Execution calldata _execution, TermsData memory _terms) private pure {
        require(_execution.target == _terms.sourceToken, "ERC20SwapEnforcer:invalid-approval-target");
        require(_execution.value == 0, "ERC20SwapEnforcer:invalid-approval-value");
        require(_execution.callData.length == 68, "ERC20SwapEnforcer:invalid-approval-calldata");
        require(bytes4(_execution.callData[0:4]) == IERC20.approve.selector, "ERC20SwapEnforcer:invalid-approval-method");

        address spender_ = address(uint160(uint256(bytes32(_execution.callData[4:36]))));
        uint256 amount_ = uint256(bytes32(_execution.callData[36:68]));
        require(spender_ == _terms.swapTarget, "ERC20SwapEnforcer:invalid-approval-spender");
        require(amount_ != 0, "ERC20SwapEnforcer:zero-approval-amount");
    }

    function _validateSwap(Execution calldata _execution, address _swapTarget) private pure {
        require(_execution.target == _swapTarget, "ERC20SwapEnforcer:invalid-swap-target");
        require(_execution.value == 0, "ERC20SwapEnforcer:invalid-swap-value");
        require(_execution.callData.length >= 4, "ERC20SwapEnforcer:invalid-swap-calldata");

        bytes4 selector_ = bytes4(_execution.callData[0:4]);
        require(
            selector_ == EXECUTE_SELECTOR || selector_ == EXECUTE_WITH_DEADLINE_SELECTOR, "ERC20SwapEnforcer:invalid-swap-method"
        );
    }

    function _getBalance(address _token, address _recipient) private view returns (uint256) {
        if (_token == address(0)) return _recipient.balance;
        return IERC20(_token).balanceOf(_recipient);
    }

    function _getHashKey(address _caller, bytes32 _delegationHash) private pure returns (bytes32) {
        return keccak256(abi.encode(_caller, _delegationHash));
    }
}
