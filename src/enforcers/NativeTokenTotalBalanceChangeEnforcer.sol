// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title NativeTokenTotalBalanceChangeEnforcer
 * @notice Enforces that a recipient's native token balance increases by at least the expected total amount across multiple
 * delegations or decreases by at most the expected total amount across multiple delegations. In a delegation chain,
 * there can be a combination of both increases and decreases, and the enforcer will track the total expected change.
 * @dev Tracks initial balance and accumulates expected increases and decreases per recipient within a redemption
 * @dev This enforcer operates only in default execution mode.
 * @dev Security considerations:
 * - State is shared between enforcers watching the same recipient pair. After transaction execution the state is cleared.
 * - Balance changes are tracked by comparing beforeAll/afterAll balances.
 * - If the delegate is an EOA and not a DeleGator in a situation with multiple delegations, an adapter contract can be used to
 * redeem delegations. An example of this is the src/helpers/DelegationMetaSwapAdapter.sol contract.
 */
contract NativeTokenTotalBalanceChangeEnforcer is CaveatEnforcer {
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
        uint256 validationRemaining;
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
     * @param _delegator Address of the delegator.
     */
    function beforeAllHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32,
        address _delegator,
        address
    )
        public
        override
        onlyDefaultExecutionMode(_mode)
    {
        (bool enforceDecrease_, address recipient_, uint256 amount_) = getTermsInfo(_terms);
        require(amount_ > 0, "NativeTokenTotalBalanceChangeEnforcer:zero-expected-change-amount");
        bytes32 hashKey_ = _getHashKey(msg.sender, recipient_);

        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        if (balanceTracker_.expectedIncrease == 0 && balanceTracker_.expectedDecrease == 0) {
            require(_delegator == recipient_, "NativeTokenTotalBalanceChangeEnforcer:invalid-delegator");
            balanceTracker_.balanceBefore = recipient_.balance;
            emit TrackedBalance(msg.sender, recipient_, recipient_.balance);
        }

        if (_delegator == recipient_) {
            if (enforceDecrease_) {
                balanceTracker_.expectedDecrease += amount_;
            } else {
                balanceTracker_.expectedIncrease += amount_;
            }
        } else {
             // For redelegations, enforce that they can only make restrictions more restrictive
            // This prevents the security vulnerability where redelegations could increase limits
            if (enforceDecrease_) {
                // For decreases: new amount must be <= existing amount (more restrictive)
                require(
                    amount_ <= balanceTracker_.expectedDecrease,
                    "NativeTokenTotalBalanceChangeEnforcer:redelegation-must-be-more-restrictive"
                );
                // Override instead of aggregate
                balanceTracker_.expectedDecrease = amount_;
            } else {
                // For increases: new amount must be >= existing amount (more restrictive)
                require(
                    amount_ >= balanceTracker_.expectedIncrease,
                    "NativeTokenTotalBalanceChangeEnforcer:redelegation-must-be-more-restrictive"
                );
                // Override instead of aggregate
                balanceTracker_.expectedIncrease = amount_;
            }
        }

        balanceTracker_.validationRemaining++;

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

        balanceTracker[hashKey_].validationRemaining--;
        if (balanceTracker[hashKey_].validationRemaining > 0) return;

        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        uint256 expected_;
        if (balanceTracker_.expectedIncrease >= balanceTracker_.expectedDecrease) {
            expected_ = balanceTracker_.expectedIncrease - balanceTracker_.expectedDecrease;
            require(
                recipient_.balance >= balanceTracker_.balanceBefore + expected_,
                "NativeTokenTotalBalanceChangeEnforcer:insufficient-balance-increase"
            );
        } else {
            expected_ = balanceTracker_.expectedDecrease - balanceTracker_.expectedIncrease;
            require(
                recipient_.balance >= balanceTracker_.balanceBefore - expected_,
                "NativeTokenTotalBalanceChangeEnforcer:exceeded-balance-decrease"
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
        require(_terms.length == 53, "NativeTokenTotalBalanceChangeEnforcer:invalid-terms-length");
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
