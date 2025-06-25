// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ERC1155TotalBalanceChangeEnforcer
 * @notice Enforces that a recipient's token balance increases by at least the expected total amount across multiple delegations
 * or decreases by at most the expected total amount across multiple delegations. In a delegation chain, there can be a combination
 * of both increases and decreases, and the enforcer will track the total expected change.
 * @dev Tracks initial balance and accumulates expected increases and decreases per recipient/token pair within a redemption
 * @dev This enforcer operates only in default execution mode.
 * @dev Security considerations:
 * - State is shared between enforcers watching the same recipient/token pair. After transaction execution, the state is cleared.
 * - Balance changes are tracked by comparing beforeAll/afterAll balances.
 * - If the delegate is an EOA and not a DeleGator in a situation with multiple delegations, an adapter contract can be used to
 * redeem delegations. An example of this is the src/helpers/DelegationMetaSwapAdapter.sol contract.
 */
contract ERC1155TotalBalanceChangeEnforcer is CaveatEnforcer {
    ////////////////////////////// Events //////////////////////////////

    event TrackedBalance(
        address indexed delegationManager, address indexed recipient, address indexed token, uint256 tokenId, uint256 balance
    );
    event UpdatedExpectedBalance(
        address indexed delegationManager,
        address indexed recipient,
        address indexed token,
        uint256 tokenId,
        bool enforceDecrease,
        uint256 expected
    );
    event ValidatedBalance(
        address indexed delegationManager, address indexed recipient, address indexed token, uint256 tokenId, uint256 expected
    );

    ////////////////////////////// State //////////////////////////////

    struct BalanceTracker {
        uint256 balanceBefore;
        uint256 expectedIncrease;
        uint256 expectedDecrease;
    }

    struct TermsData {
        bool enforceDecrease;
        address token;
        address recipient;
        uint256 tokenId;
        uint256 amount;
    }

    mapping(bytes32 hashKey => BalanceTracker balance) public balanceTracker;

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     * @param _caller Address of the sender calling the enforcer.
     * @param _token ERC1155 token being compared in the beforeHook and afterHook.
     * @param _recipient The address of the recipient of the token.
     * @param _tokenId The ID of the ERC1155 token.
     * @return The hash to be used as key of the mapping.
     */
    function getHashKey(address _caller, address _token, address _recipient, uint256 _tokenId) external pure returns (bytes32) {
        return _getHashKey(_caller, _token, _recipient, _tokenId);
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice This function caches the recipient's ERC1155 token balance before the delegation is executed.
     * @param _terms 105 bytes where:
     * - first byte: boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00)
     * - next 20 bytes: address of the ERC1155 token
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: token ID
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
        TermsData memory terms_ = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, terms_.token, terms_.recipient, terms_.tokenId);
        uint256 balance_ = IERC1155(terms_.token).balanceOf(terms_.recipient, terms_.tokenId);
        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        if (balanceTracker_.expectedIncrease == 0 && balanceTracker_.expectedDecrease == 0) {
            balanceTracker_.balanceBefore = balance_;
            emit TrackedBalance(msg.sender, terms_.recipient, terms_.token, terms_.tokenId, balance_);
        } else {
            require(balanceTracker_.balanceBefore == balance_, "ERC1155TotalBalanceChangeEnforcer:balance-changed");
        }

        if (terms_.enforceDecrease) {
            balanceTracker_.expectedDecrease += terms_.amount;
        } else {
            balanceTracker_.expectedIncrease += terms_.amount;
        }

        balanceTracker[hashKey_] = balanceTracker_;

        emit UpdatedExpectedBalance(
            msg.sender, terms_.recipient, terms_.token, terms_.tokenId, terms_.enforceDecrease, terms_.amount
        );
    }

    /**
     * @notice This function enforces that the recipient's ERC1155 token balance has changed by the expected amount.
     * @param _terms 105 bytes where:
     * - first byte: boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00)
     * - next 20 bytes: address of the ERC1155 token
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: token ID
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
        TermsData memory terms_ = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, terms_.token, terms_.recipient, terms_.tokenId);

        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        // already validated
        if (balanceTracker_.expectedIncrease == 0 && balanceTracker_.expectedDecrease == 0) return;

        uint256 balance_ = IERC1155(terms_.token).balanceOf(terms_.recipient, terms_.tokenId);

        uint256 expected_;
        if (balanceTracker_.expectedIncrease >= balanceTracker_.expectedDecrease) {
            expected_ = balanceTracker_.expectedIncrease - balanceTracker_.expectedDecrease;
            require(
                balance_ >= balanceTracker_.balanceBefore + expected_,
                "ERC1155TotalBalanceChangeEnforcer:insufficient-balance-increase"
            );
        } else {
            expected_ = balanceTracker_.expectedDecrease - balanceTracker_.expectedIncrease;
            require(
                balance_ >= balanceTracker_.balanceBefore - expected_, "ERC1155TotalBalanceChangeEnforcer:exceeded-balance-decrease"
            );
        }

        delete balanceTracker[hashKey_];

        emit ValidatedBalance(msg.sender, terms_.recipient, terms_.token, terms_.tokenId, expected_);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms Encoded data that is used during the execution hooks.
     * @return TermsData Struct that consists of:
     * - enforceDecrease_ Boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00).
     * - token_ The address of the ERC1155 token.
     * - recipient_ The address of the recipient of the token.
     * - tokenId_ The ID of the ERC1155 token.
     * - amount_ Balance change guardrail amount (i.e., minimum increase OR maximum decrease, depending on
     * enforceDecrease)
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (TermsData memory) {
        require(_terms.length == 105, "ERC1155TotalBalanceChangeEnforcer:invalid-terms-length");
        return TermsData({
            enforceDecrease: _terms[0] != 0,
            token: address(bytes20(_terms[1:21])),
            recipient: address(bytes20(_terms[21:41])),
            tokenId: uint256(bytes32(_terms[41:73])),
            amount: uint256(bytes32(_terms[73:]))
        });
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run. Produced by hashing the provided values.
     */
    function _getHashKey(address _caller, address _token, address _recipient, uint256 _tokenId) private pure returns (bytes32) {
        return keccak256(abi.encode(_caller, _token, _recipient, _tokenId));
    }
}
