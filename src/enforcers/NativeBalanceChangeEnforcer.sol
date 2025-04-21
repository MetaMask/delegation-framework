// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title NativeBalanceChangeEnforcer
 * @dev This contract enforces that a recipient's native token balance has changed by at least the specified amount
 * after the execution has been executed, measured between the `beforeHook` and `afterHook` calls, regardless of what the execution
 * is. The change can be either an increase or decrease based on the `shouldBalanceIncrease` flag.
 * @dev This contract does not enforce how the balance changes. It is meant to be used with additional enforcers to create
 * granular permissions.
 * @dev This enforcer operates only in default execution mode.
 * @dev Security Notice: This enforcer tracks balance changes by comparing the recipient's balance before and after execution.
 * Since enforcers watching the same recipient share state, a single balance modification may satisfy multiple enforcers
 * simultaneously. Users should avoid tracking the same recipient's balance on multiple enforcers in a single delegation chain to
 * prevent unintended behavior.
 */
contract NativeBalanceChangeEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    mapping(bytes32 hashKey => uint256 balance) public balanceCache;
    mapping(bytes32 hashKey => bool lock) public isLocked;

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run, produced by hashing the provided values.
     * @param _caller Address of the sender calling the enforcer.
     * @param _delegationHash The hash of the delegation.
     * @return The hash to be used as key of the mapping.
     */
    function getHashKey(address _caller, bytes32 _delegationHash) external pure returns (bytes32) {
        return _getHashKey(_caller, _delegationHash);
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Caches the recipient's native token balance before the delegation is executed.
     * @param _terms 53 packed bytes where:
     * - first byte: boolean indicating if the balance should increase
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: amount the balance should change by
     * @param _delegationHash The hash of the delegation being operated on.
     * @param _mode The execution mode. (Must be Default execType)
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32 _delegationHash,
        address,
        address
    )
        public
        override
        onlyDefaultExecutionMode(_mode)
    {
        bytes32 hashKey_ = _getHashKey(msg.sender, _delegationHash);
        (, address recipient_,) = getTermsInfo(_terms);

        require(!isLocked[hashKey_], "NativeBalanceChangeEnforcer:enforcer-is-locked");
        isLocked[hashKey_] = true;
        balanceCache[hashKey_] = recipient_.balance;
    }

    /**
     * @notice Ensures that the recipient's native token balance has changed by at least the specified amount.
     * @param _terms 53 packed bytes where:
     * - first byte: boolean indicating if the balance should increase
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: amount the balance should change by
     * @param _delegationHash The hash of the delegation being operated on.
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
        (bool shouldBalanceIncrease_, address recipient_, uint256 amount_) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, _delegationHash);
        delete isLocked[hashKey_];
        if (shouldBalanceIncrease_) {
            require(
                recipient_.balance >= balanceCache[hashKey_] + amount_, "NativeBalanceChangeEnforcer:insufficient-balance-increase"
            );
        } else {
            require(recipient_.balance >= balanceCache[hashKey_] - amount_, "NativeBalanceChangeEnforcer:exceeded-balance-decrease");
        }
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms 53 packed bytes where:
     * - first byte: boolean indicating if the balance should increase
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: amount the balance should change by
     * @return shouldBalanceIncrease_ Boolean indicating if the balance should increase (true) or decrease (false).
     * @return recipient_ The address of the recipient whose balance will change.
     * @return amount_ The minimum balance change required.
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (bool shouldBalanceIncrease_, address recipient_, uint256 amount_)
    {
        require(_terms.length == 53, "NativeBalanceChangeEnforcer:invalid-terms-length");
        shouldBalanceIncrease_ = _terms[0] != 0;
        recipient_ = address(bytes20(_terms[1:21]));
        amount_ = uint256(bytes32(_terms[21:]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run, produced by hashing the provided values.
     */
    function _getHashKey(address _caller, bytes32 _delegationHash) private pure returns (bytes32) {
        return keccak256(abi.encode(_caller, _delegationHash));
    }
}
