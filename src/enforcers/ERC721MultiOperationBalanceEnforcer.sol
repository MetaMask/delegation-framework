// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ERC721MultiOperationBalanceEnforcer
 * @notice Enforces that a recipient's ERC721 token balance changes within expected limits across multiple delegations.
 * Tracks balance changes from the first beforeAllHook call to the last afterAllHook call within a redemption.
 *
 * For balance increases: ensures the final balance is at least the initial balance plus the expected increase.
 * For balance decreases: ensures the final balance is at least the initial balance minus the expected decrease.
 *
 * @dev This enforcer operates in delegation chains where multiple delegations may affect the same recipient/token pair.
 * State is shared between enforcers watching the same recipient/token pair and is cleared after transaction execution.
 *
 * @dev Only operates in default execution mode (ModeCode 0).
 *
 * @dev Security considerations:
 * - State is shared between enforcers watching the same recipient/token pair
 * - Balance changes are tracked by comparing first beforeAll/last afterAll balances in batch delegations
 * - If the delegate is an EOA and not a DeleGator in multi-delegation scenarios, use an adapter contract
 *   like DelegationMetaSwapAdapter.sol to redeem delegations
 * - Redelegations can only make restrictions more restrictive (cannot increase limits)
 * - Delegator must equal recipient for first delegation in a chain of delegations
 * - Only if delegator is equal to recipient do the amounts aggregate
 */
contract ERC721MultiOperationBalanceEnforcer is CaveatEnforcer {
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
     * @param _token ERC721 token being compared in the beforeHook and afterHook.
     * @param _recipient The address of the recipient of the token.
     * @return The hash to be used as key of the mapping.
     */
    function getHashKey(address _caller, address _token, address _recipient) external pure returns (bytes32) {
        return _getHashKey(_caller, _token, _recipient);
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice This function caches the delegator's initial ERC721 token balance and accumulates the expected increase or decrease.
     * @param _terms 73 bytes where:
     * - first byte: boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00)
     * - next 20 bytes: address of the ERC721 token
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
        (bool enforceDecrease_, address token_, address recipient_, uint256 amount_) = getTermsInfo(_terms);
        require(amount_ > 0, "ERC721MultiOperationBalanceEnforcer:zero-expected-change-amount");
        bytes32 hashKey_ = _getHashKey(msg.sender, token_, recipient_);

        uint256 currentBalance_ = IERC721(token_).balanceOf(recipient_);

        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        if (balanceTracker_.expectedIncrease == 0 && balanceTracker_.expectedDecrease == 0) {
            require(_delegator == recipient_, "ERC721MultiOperationBalanceEnforcer:invalid-delegator");
            balanceTracker_.balanceBefore = currentBalance_;
            emit TrackedBalance(msg.sender, recipient_, token_, currentBalance_);
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
                    "ERC721MultiOperationBalanceEnforcer:decrease-must-be-more-restrictive"
                );
                // Override instead of aggregate
                balanceTracker_.expectedDecrease = amount_;
            } else {
                // For increases: new amount must be >= existing amount (more restrictive)
                require(
                    amount_ >= balanceTracker_.expectedIncrease,
                    "ERC721MultiOperationBalanceEnforcer:increase-must-be-more-restrictive"
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
     * @notice This function validates that the recipient's token balance has changed within expected limits.
     * @param _terms 73 bytes where:
     * - first byte: boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00)
     * - next 20 bytes: address of the ERC721 token
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

        uint256 balance_ = IERC721(token_).balanceOf(recipient_);

        uint256 expected_;
        if (balanceTracker_.expectedIncrease >= balanceTracker_.expectedDecrease) {
            expected_ = balanceTracker_.expectedIncrease - balanceTracker_.expectedDecrease;
            require(
                balance_ >= balanceTracker_.balanceBefore + expected_,
                "ERC721MultiOperationBalanceEnforcer:insufficient-balance-increase"
            );
        } else {
            expected_ = balanceTracker_.expectedDecrease - balanceTracker_.expectedIncrease;
            require(
                balance_ >= balanceTracker_.balanceBefore - expected_,
                "ERC721MultiOperationBalanceEnforcer:exceeded-balance-decrease"
            );
        }

        delete balanceTracker[hashKey_];

        emit ValidatedBalance(msg.sender, recipient_, token_, expected_);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms Encoded data that is used during the execution hooks.
     * @return enforceDecrease_ Boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00).
     * @return token_ The address of the ERC721 token.
     * @return recipient_ The address of the recipient of the token.
     * @return amount_ Balance change guardrail amount (i.e., minimum increase OR maximum decrease, depending on
     * enforceDecrease)
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (bool enforceDecrease_, address token_, address recipient_, uint256 amount_)
    {
        require(_terms.length == 73, "ERC721MultiOperationBalanceEnforcer:invalid-terms-length");
        enforceDecrease_ = _terms[0] != 0;
        token_ = address(bytes20(_terms[1:21]));
        recipient_ = address(bytes20(_terms[21:41]));
        amount_ = uint256(bytes32(_terms[41:]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     */
    function _getHashKey(address _caller, address _token, address _recipient) private pure returns (bytes32) {
        return keccak256(abi.encode(_caller, _token, _recipient));
    }
}
