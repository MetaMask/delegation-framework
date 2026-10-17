// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ExecutionBoundEnforcer
 * @notice Enforces that the actual execution at redemption exactly matches a pre-signed ExecutionIntent.
 * @dev Unlike ExactExecutionEnforcer (which encodes the expected execution statically in terms at
 *      delegation time), this enforcer binds execution dynamically at redemption time via a second
 *      EIP-712 signature.
 *
 *      The delegator signs the delegation (who may redeem) and commits to an authorized signer in terms.
 *      The authorized signer signs the ExecutionIntent (what must be executed).
 *      These may be different keys, enabling session keys, agents, and co-signers.
 *
 *      terms: abi.encode(address authorizedSigner)
 *      args:  abi.encode(ExecutionIntent intent, bytes signature)
 *
 *      The nonce is scoped by (delegationManager, account, nonce) and consumed only after successful
 *      signature verification, preventing griefing via invalid signature nonce consumption.
 *      Scoping by msg.sender (the delegation manager) prevents direct beforeHook calls from
 *      consuming nonces outside of a legitimate redemption flow.
 *
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 */
contract ExecutionBoundEnforcer is CaveatEnforcer, EIP712 {
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    ////////////////////////////// Structs //////////////////////////////

    struct ExecutionIntent {
        address account;
        address target;
        uint256 value;
        bytes32 dataHash;
        uint256 nonce;
        uint256 deadline;
    }

    ////////////////////////////// State //////////////////////////////

    bytes32 private constant EXECUTION_INTENT_TYPEHASH = keccak256(
        "ExecutionIntent(address account,address target,uint256 value,bytes32 dataHash,uint256 nonce,uint256 deadline)"
    );

    mapping(address delegationManager => mapping(address account => mapping(uint256 nonce => bool))) public usedNonces;

    ////////////////////////////// Events //////////////////////////////

    event NonceConsumed(address indexed delegationManager, address indexed account, uint256 nonce);

    ////////////////////////////// Errors //////////////////////////////

    error AccountMismatch(address intentAccount, address delegator);
    error TargetMismatch(address intentTarget, address executionTarget);
    error ValueMismatch(uint256 intentValue, uint256 executionValue);
    error DataHashMismatch(bytes32 intentDataHash, bytes32 executionDataHash);
    error IntentExpired(uint256 deadline, uint256 blockTimestamp);
    error NonceAlreadyUsed(address delegationManager, address account, uint256 nonce);
    error InvalidSignature();
    error InvalidTermsLength();

    ////////////////////////////// Constructor //////////////////////////////

    constructor() EIP712("ExecutionBoundEnforcer", "1") { }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Enforces that the actual execution exactly matches the signed ExecutionIntent.
     * @param _terms             abi.encode(address authorizedSigner) — delegator commits to trusted signer.
     * @param _args              abi.encode(ExecutionIntent intent, bytes signature)
     * @param _mode              Must be single callType, default execType.
     * @param _executionCallData The actual execution calldata to be validated.
     * @param _delegator         The delegating smart account. Must match intent.account.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32,
        address _delegator,
        address
    )
        public
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        address authorizedSigner_ = getTermsInfo(_terms);

        (ExecutionIntent memory intent, bytes memory signature) =
            abi.decode(_args, (ExecutionIntent, bytes));

        (address target_, uint256 value_, bytes calldata callData_) = _executionCallData.decodeSingle();

        if (intent.account != _delegator) revert AccountMismatch(intent.account, _delegator);
        if (intent.target != target_) revert TargetMismatch(intent.target, target_);
        if (intent.value != value_) revert ValueMismatch(intent.value, value_);

        bytes32 executionDataHash_ = keccak256(callData_);
        if (intent.dataHash != executionDataHash_) revert DataHashMismatch(intent.dataHash, executionDataHash_);

        if (intent.deadline != 0 && block.timestamp > intent.deadline) {
            revert IntentExpired(intent.deadline, block.timestamp);
        }

        if (usedNonces[msg.sender][intent.account][intent.nonce]) {
            revert NonceAlreadyUsed(msg.sender, intent.account, intent.nonce);
        }

        usedNonces[msg.sender][intent.account][intent.nonce] = true;
        emit NonceConsumed(msg.sender, intent.account, intent.nonce);

        bytes32 digest_ = _hashTypedDataV4(_hashIntent(intent));
        if (!SignatureChecker.isValidSignatureNow(authorizedSigner_, digest_, signature)) revert InvalidSignature();
    }

    /**
     * @notice Decodes the terms used in this enforcer.
     * @param _terms abi.encode(address authorizedSigner)
     * @return authorizedSigner_ The address authorized to sign ExecutionIntents for this delegation.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address authorizedSigner_) {
        if (_terms.length != 32) revert InvalidTermsLength();
        authorizedSigner_ = address(bytes20(_terms[12:32]));
    }

    /**
     * @notice Decodes the args used in this enforcer.
     * @param _args abi.encode(ExecutionIntent intent, bytes signature)
     */
    function getArgsInfo(bytes calldata _args)
        public
        pure
        returns (ExecutionIntent memory intent_, bytes memory signature_)
    {
        (intent_, signature_) = abi.decode(_args, (ExecutionIntent, bytes));
    }

    /**
     * @notice Computes the EIP-712 digest for a given intent.
     */
    function intentDigest(ExecutionIntent calldata _intent) external view returns (bytes32) {
        return _hashTypedDataV4(_hashIntent(_intent));
    }

    /**
     * @notice Returns whether a nonce has been consumed.
     */
    function isNonceUsed(address _delegationManager, address _account, uint256 _nonce) external view returns (bool) {
        return usedNonces[_delegationManager][_account][_nonce];
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    function _hashIntent(ExecutionIntent memory _intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EXECUTION_INTENT_TYPEHASH,
                _intent.account,
                _intent.target,
                _intent.value,
                _intent.dataHash,
                _intent.nonce,
                _intent.deadline
            )
        );
    }
}
