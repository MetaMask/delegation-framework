// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title NativeBalanceGteEnforcer
 * @dev This contract enforces that a recipient's native token balance has increased by at least the specified amount
 * after the execution has been executed, measured between the `beforeHook` and `afterHook` calls, regardless of what the execution
 * is.
 * @dev This contract does not enforce how the balance increases. It is meant to be used with additional enforcers to create
 * granular permissions.
 * @dev This enforcer operates only in default execution mode.
 */
contract NativeBalanceGteEnforcer is CaveatEnforcer {
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
     * @param _terms 52 packed bytes where the first 20 bytes are the recipient's address, and the next 32 bytes
     * are the minimum balance increase required.
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
        (address recipient_,) = getTermsInfo(_terms);

        require(!isLocked[hashKey_], "NativeBalanceGteEnforcer:enforcer-is-locked");
        isLocked[hashKey_] = true;
        balanceCache[hashKey_] = recipient_.balance;
    }

    /**
     * @notice Ensures that the recipient's native token balance has increased by at least the specified amount.
     * @param _terms 52 packed bytes where the first 20 bytes are the recipient's address, and the next 32 bytes
     * are the minimum balance increase required.
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
        (address recipient_, uint256 amount_) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, _delegationHash);
        delete isLocked[hashKey_];
        require(recipient_.balance >= balanceCache[hashKey_] + amount_, "NativeBalanceGteEnforcer:balance-not-gt");
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms 52 packed bytes where the first 20 bytes are the recipient's address, and the next 32 bytes
     * specify the minimum balance increase required.
     * @return recipient_ The address of the recipient who will receive the tokens.
     * @return amount_ requiredIncrease_ The minimum balance increase required.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address recipient_, uint256 amount_) {
        require(_terms.length == 52, "NativeBalanceGteEnforcer:invalid-terms-length");
        recipient_ = address(bytes20(_terms[:20]));
        amount_ = uint256(bytes32(_terms[20:]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run, produced by hashing the provided values.
     */
    function _getHashKey(address _caller, bytes32 _delegationHash) private pure returns (bytes32) {
        return keccak256(abi.encode(_caller, _delegationHash));
    }
}
