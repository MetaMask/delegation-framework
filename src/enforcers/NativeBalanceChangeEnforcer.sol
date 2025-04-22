// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title NativeBalanceChangeEnforcer
 * @dev This contract allows setting up some guardrails around balance changes. By specifying an amount and a direction
 * (decrease/increase), one can enforce a maximum decrease or minimum increase in after-execution balance.
 * The change can be either a decrease or increase based on the `enforceDecrease` flag.
 * @dev This contract has no enforcement of how the balance changes. It's meant to be used alongside additional enforcers to
 * create granular permissions.
 * @dev This enforcer operates only in default execution mode.
 * @dev Security Notice: This enforcer tracks balance changes by comparing the recipient's balance before and after execution. Since
 * enforcers watching the same recipient share state, a single balance modification may satisfy multiple enforcers simultaneously.
 * Users should avoid tracking the same recipient's balance on multiple enforcers in a single delegation chain to prevent unintended
 * behavior. Given its potential for concurrent condition fulfillment, use this enforcer at your own risk and ensure it aligns with
 * your intended security model.
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
     * @notice This function caches the delegator's native token balance before the delegation is executed.
     * @param _terms 53 packed bytes where:
     * - first byte: boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00)
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: balance change guardrail amount (i.e., minimum increase OR maximum decrease, depending on
     * enforceDecrease)
     * @param _mode The execution mode. (Must be Default execType)
     * @param _delegationHash The hash of the delegation.
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
     * @notice This function enforces that the delegator's native token balance has changed by the expected amount.
     * @param _terms 53 packed bytes where:
     * - first byte: boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00)
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: balance change guardrail amount (i.e., minimum increase OR maximum decrease, depending on
     * enforceDecrease)
     * @param _delegationHash The hash of the delegation.
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
        (bool enforceDecrease_, address recipient_, uint256 amount_) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, _delegationHash);
        delete isLocked[hashKey_];
        if (enforceDecrease_) {
            require(recipient_.balance >= balanceCache[hashKey_] - amount_, "NativeBalanceChangeEnforcer:exceeded-balance-decrease");
        } else {
            require(
                recipient_.balance >= balanceCache[hashKey_] + amount_, "NativeBalanceChangeEnforcer:insufficient-balance-increase"
            );
        }
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms 53 packed bytes where:
     * - first byte: boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00)
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: balance change guardrail amount (i.e., minimum increase OR maximum decrease, depending on
     * enforceDecrease)
     * @return enforceDecrease_ Boolean indicating if the balance should decrease (true) or increase (false).
     * @return recipient_ The address of the recipient whose balance will change.
     * @return amount_ Balance change guardrail amount (i.e., minimum increase OR maximum decrease, depending on
     * enforceDecrease)
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (bool enforceDecrease_, address recipient_, uint256 amount_) {
        require(_terms.length == 53, "NativeBalanceChangeEnforcer:invalid-terms-length");
        enforceDecrease_ = _terms[0] != 0;
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
