// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ERC20TotalBalanceChangeEnforcer
 * @notice Enforces that a recipient's token balance increases by at least the expected total amount across multiple delegations
 * or decreases by at most the expected total amount across multiple delegations. In a delegation chain, there can be a combination
 * of both increases and decreases and the enforcer will track the total expected change.
 * @dev Tracks initial balance and accumulates expected increases and decreases per recipient/token pair within a redemption
 * @dev Only operates in default execution mode
 * @dev Security considerations:
 * - State is shared between enforcers watching the same recipient/token pair. After transaction execution, the state is cleared.
 * - Balance changes are tracked by comparing beforeAll/afterAll balances.
 * - If the delegate is an EOA and not a DeleGator in a situation with multiple delegations, an adapter contract can be used to
 * redeem delegations. An example of this is the src/helpers/DelegationMetaSwapAdapter.sol contract.
 */
contract ERC20TotalBalanceChangeEnforcer is CaveatEnforcer {
    ////////////////////////////// Events //////////////////////////////

    event TrackedBalance(address indexed delegationManager, address indexed recipient, address indexed token, uint256 balance);
    event UpdatedExpectedBalance(
        address indexed delegationManager, address indexed recipient, address indexed token, bool enforceDecrease, uint256 expected
    );
    event ValidatedBalance(address indexed delegationManager, address indexed recipient, address indexed token, uint256 expected);

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
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     * @param _caller Address of the sender calling the enforcer.
     * @param _token Token being compared in the beforeAllHook and afterAllHook.
     * @param _recipient Address of the recipient whose balance is being tracked.
     * @return The hash to be used as key of the mapping.
     */
    function getHashKey(address _caller, address _token, address _recipient) external pure returns (bytes32) {
        return _getHashKey(_caller, _token, _recipient);
    }

    /**
     * @notice This function caches the recipient's initial token balance and accumulates the expected increase and decrease.
     * @param _terms 73 packed bytes where:
     * - first byte: boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00)
     * - next 20 bytes: address of the token
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
        address _delegator,
        address
    )
        public
        override
        onlyDefaultExecutionMode(_mode)
    {
        (bool enforceDecrease_, address token_, address recipient_, uint256 amount_) = getTermsInfo(_terms);
        require(amount_ > 0, "ERC20TotalBalanceChangeEnforcer:zero-expected-change-amount");

        bytes32 hashKey_ = _getHashKey(msg.sender, token_, recipient_);
        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        uint256 currentBalance_ = IERC20(token_).balanceOf(recipient_);
        if (balanceTracker_.expectedDecrease == 0 && balanceTracker_.expectedIncrease == 0) {
            require(_delegator == recipient_, "ERC20TotalBalanceChangeEnforcer:invalid-delegator");
            balanceTracker_.balanceBefore = currentBalance_;
            emit TrackedBalance(msg.sender, recipient_, token_, currentBalance_);
        }

        if (_delegator == recipient_) {
            // Only the original delegator can aggregate changes
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
                    "ERC20TotalBalanceChangeEnforcer:redelegation-must-be-more-restrictive"
                );
                // Override instead of aggregate
                balanceTracker_.expectedDecrease = amount_;
            } else {
                // For increases: new amount must be >= existing amount (more restrictive)
                require(
                    amount_ >= balanceTracker_.expectedIncrease,
                    "ERC20TotalBalanceChangeEnforcer:redelegation-must-be-more-restrictive"
                );
                // Override instead of aggregate
                balanceTracker_.expectedIncrease = amount_;
            }
        }

        balanceTracker_.validationRemaining++;

        balanceTracker[hashKey_] = balanceTracker_;

        emit UpdatedExpectedBalance(msg.sender, recipient_, token_, enforceDecrease_, amount_);
    }

    /**
     * @notice This function validates that the recipient's token balance has changed by at least the total expected amount.
     * @param _terms 73 packed bytes where:
     * - first byte: boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00)
     * - next 20 bytes: address of the token
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
        (, address token_, address recipient_,) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, token_, recipient_);

        balanceTracker[hashKey_].validationRemaining--;

        if (balanceTracker[hashKey_].validationRemaining > 0) return;

        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        uint256 currentBalance_ = IERC20(token_).balanceOf(recipient_);
        uint256 expected_;
        if (balanceTracker_.expectedIncrease >= balanceTracker_.expectedDecrease) {
            expected_ = balanceTracker_.expectedIncrease - balanceTracker_.expectedDecrease;
            require(
                currentBalance_ >= balanceTracker_.balanceBefore + expected_,
                "ERC20TotalBalanceChangeEnforcer:insufficient-balance-increase"
            );
        } else {
            expected_ = balanceTracker_.expectedDecrease - balanceTracker_.expectedIncrease;
            require(
                currentBalance_ >= balanceTracker_.balanceBefore - expected_,
                "ERC20TotalBalanceChangeEnforcer:exceeded-balance-decrease"
            );
        }

        delete balanceTracker[hashKey_];
        emit ValidatedBalance(msg.sender, recipient_, token_, expected_);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return enforceDecrease_ Boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00).
     * @return token_ The address of the token.
     * @return recipient_ The address of the recipient.
     * @return amount_ Balance change guardrail amount (i.e., minimum increase OR maximum decrease, depending on
     * enforceDecrease)
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (bool enforceDecrease_, address token_, address recipient_, uint256 amount_)
    {
        require(_terms.length == 73, "ERC20TotalBalanceChangeEnforcer:invalid-terms-length");
        enforceDecrease_ = _terms[0] != 0;
        token_ = address(bytes20(_terms[1:21]));
        recipient_ = address(bytes20(_terms[21:41]));
        amount_ = uint256(bytes32(_terms[41:]));
    }

    /**
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     */
    function _getHashKey(address _caller, address _token, address _recipient) private pure returns (bytes32) {
        return keccak256(abi.encode(_caller, _token, _recipient));
    }
}
