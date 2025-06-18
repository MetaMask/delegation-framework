// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title NativeTotalBalanceChangeEnforcer
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
contract NativeTotalBalanceChangeEnforcer is CaveatEnforcer {
    ////////////////////////////// Events //////////////////////////////

    event TrackedBalance(address indexed delegationManager, address indexed recipient, uint256 balance);
    event UpdatedExpectedBalance(
        address indexed delegationManager, address indexed recipient, bool enforceDecrease, uint256 expected
    );
    event ValidatedBalance(address indexed delegationManager, address indexed recipient, uint256 expected);

    ////////////////////////////// State //////////////////////////////

    struct BalanceTracker {
        uint256 balanceBefore;
        uint256 expectedIncrease;
        uint256 expectedDecrease;
    }

    mapping(bytes32 hashKey => BalanceTracker balance) public balanceTracker;

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run, produced by hashing the provided values.
     * @param _caller Address of the sender calling the enforcer.
     * @param _recipient Address of the recipient.
     * @return The hash to be used as key of the mapping.
     */
    function getHashKey(address _caller, address _recipient) external pure returns (bytes32) {
        return _getHashKey(_caller, _recipient);
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
     */
    function beforeAllHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        override
        onlyDefaultExecutionMode(_mode)
    {
        (bool enforceDecrease_, address recipient_, uint256 amount_) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, recipient_);

        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        if (balanceTracker_.expectedIncrease == 0 && balanceTracker_.expectedDecrease == 0) {
            balanceTracker_.balanceBefore = recipient_.balance;
            emit TrackedBalance(msg.sender, recipient_, recipient_.balance);
        } else {
            require(balanceTracker_.balanceBefore == recipient_.balance, "NativeTotalBalanceChangeEnforcer:balance-changed");
        }

        if (enforceDecrease_) {
            balanceTracker_.expectedDecrease += amount_;
        } else {
            balanceTracker_.expectedIncrease += amount_;
        }

        balanceTracker[hashKey_] = balanceTracker_;

        emit UpdatedExpectedBalance(msg.sender, recipient_, enforceDecrease_, amount_);
    }

    /**
     * @notice This function enforces that the delegator's native token balance has changed by the expected amount.
     * @param _terms 53 packed bytes where:
     * - first byte: boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00)
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: balance change guardrail amount (i.e., minimum increase OR maximum decrease, depending on
     * enforceDecrease)
     */
    function afterAllHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        override
    {
        (, address recipient_,) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, recipient_);

        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        if (balanceTracker_.expectedIncrease == 0 && balanceTracker_.expectedDecrease == 0) return;

        uint256 expected_;
        if (balanceTracker_.expectedIncrease >= balanceTracker_.expectedDecrease) {
            expected_ = balanceTracker_.expectedIncrease - balanceTracker_.expectedDecrease;
            require(
                recipient_.balance >= balanceTracker_.balanceBefore + expected_,
                "NativeTotalBalanceChangeEnforcer:insufficient-balance-increase"
            );
        } else {
            expected_ = balanceTracker_.expectedDecrease - balanceTracker_.expectedIncrease;
            require(
                recipient_.balance >= balanceTracker_.balanceBefore - expected_,
                "NativeTotalBalanceChangeEnforcer:exceeded-balance-decrease"
            );
        }

        delete balanceTracker[hashKey_];

        emit ValidatedBalance(msg.sender, recipient_, expected_);
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
        require(_terms.length == 53, "NativeTotalBalanceChangeEnforcer:invalid-terms-length");
        enforceDecrease_ = _terms[0] != 0;
        recipient_ = address(bytes20(_terms[1:21]));
        amount_ = uint256(bytes32(_terms[21:]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run, produced by hashing the provided values.
     */
    function _getHashKey(address _caller, address _recipient) private pure returns (bytes32) {
        return keccak256(abi.encode(_caller, _recipient));
    }
}
