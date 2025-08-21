// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ERC721TotalBalanceChangeEnforcer
 * @notice Enforces that a recipient's token balance increases by at least the expected total amount across multiple delegations
 * or decreases by at most the expected total amount across multiple delegations. In a delegation chain there can be a combination
 * of both increases and decreases and the enforcer will track the total expected change.
 * @dev Tracks initial balance and accumulates expected increases and decreases per recipient/token pair within a redemption
 * @dev This enforcer operates only in default execution mode.
 * @dev Security considerations:
 * - State is shared between enforcers watching the same recipient/token pair. After transaction execution the state is cleared.
 * - Balance changes are tracked by comparing beforeAll/afterAll balances.
 * - If the delegate is an EOA and not a DeleGator in a situation with multiple delegations, an adapter contract can be used to
 * redeem delegations. An example of this is the src/helpers/DelegationMetaSwapAdapter.sol contract.
 */
contract ERC721TotalBalanceChangeEnforcer is CaveatEnforcer {
    ////////////////////////////// Events //////////////////////////////

    event TrackedBalance(address indexed delegationManager, address indexed recipient, address indexed token, uint256 balance);
    event UpdatedExpectedBalance(
        address indexed delegationManager, address indexed recipient, address indexed token, uint256 expected
    );
    event ValidatedBalance(address indexed delegationManager, address indexed recipient, address indexed token, uint256 expected);

    ////////////////////////////// State //////////////////////////////

    struct BalanceTracker {
        uint256 balanceBefore;
        uint256 expectedIncrease;
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
     * @param _terms 72 bytes where:
     * - first 20 bytes: address of the ERC721 token
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: balance change guardrail amount (i.e., minimum increase)
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
        (address token_, address recipient_, uint256 amount_) = getTermsInfo(_terms);
        require(amount_ > 0, "ERC721TotalBalanceChangeEnforcer:zero-expected-change-amount");
        bytes32 hashKey_ = _getHashKey(msg.sender, token_, recipient_);

        uint256 currentBalance_ = IERC721(token_).balanceOf(recipient_);

        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        if (balanceTracker_.expectedIncrease == 0) {
            balanceTracker_.balanceBefore = currentBalance_;
            emit TrackedBalance(msg.sender, recipient_, token_, currentBalance_);
        }

        balanceTracker_.expectedIncrease += amount_;
        balanceTracker_.validationRemaining++;

        balanceTracker[hashKey_] = balanceTracker_;

        emit UpdatedExpectedBalance(msg.sender, recipient_, token_, amount_);
    }

    /**
     * @notice This function enforces that the delegator's ERC721 token balance has changed by the expected amount.
     * @param _terms 72 bytes where:
     * - first 20 bytes: address of the ERC721 token
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: balance change guardrail amount (i.e., minimum increase)
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
        (address token_, address recipient_,) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, token_, recipient_);

        balanceTracker[hashKey_].validationRemaining--;

        // Only validate on the last afterAllHook if there are multiple enforcers tracking the same recipient/token pair
        if (balanceTracker[hashKey_].validationRemaining > 0) return;

        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        uint256 balance_ = IERC721(token_).balanceOf(recipient_);

        require(
            balance_ >= balanceTracker_.balanceBefore + balanceTracker_.expectedIncrease,
            "ERC721TotalBalanceChangeEnforcer:insufficient-balance-increase"
        );

        emit ValidatedBalance(msg.sender, recipient_, token_, balanceTracker_.expectedIncrease);
        delete balanceTracker[hashKey_];
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms Encoded data that is used during the execution hooks.
     * @return token_ The address of the ERC721 token.
     * @return recipient_ The address of the recipient of the token.
     * @return amount_ Balance change guardrail amount (i.e., minimum increase)
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address token_, address recipient_, uint256 amount_) {
        require(_terms.length == 72, "ERC721TotalBalanceChangeEnforcer:invalid-terms-length");
        token_ = address(bytes20(_terms[0:20]));
        recipient_ = address(bytes20(_terms[20:40]));
        amount_ = uint256(bytes32(_terms[40:]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     */
    function _getHashKey(address _caller, address _token, address _recipient) private pure returns (bytes32) {
        return keccak256(abi.encode(_caller, _token, _recipient));
    }
}
