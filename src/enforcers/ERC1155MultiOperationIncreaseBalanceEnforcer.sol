// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ERC1155MultiOperationIncreaseBalanceEnforcer
 * @notice Enforces that a recipient's token balance increases by at least the expected amount across multiple delegations.
 * Tracks balance changes from the first beforeAllHook call to the last afterAllHook call within a redemption.
 *
 * @dev This enforcer operates in delegation chains where multiple delegations may affect the same recipient/token/tokenId pair.
 * State is shared between enforcers watching the same recipient/token/tokenId pair and is cleared after transaction execution.
 *
 * @dev Only operates in default execution mode.
 *
 * @dev Security considerations:
 * - State is shared between enforcers watching the same recipient/token/tokenId pair.
 * - Balance changes are tracked by comparing first beforeAll/last afterAll balances in batch delegations.
 * - If the delegate is an EOA and not a DeleGator in multi-delegation scenarios, use an adapter contract
 *   like DelegationMetaSwapAdapter.sol to redeem delegations.
 * - If there are multiple instances of this enforcer tracking the same recipient/token/tokenId pair inside a redemption the
 *   balance increase will be aggregated.
 */
contract ERC1155MultiOperationIncreaseBalanceEnforcer is CaveatEnforcer {
    ////////////////////////////// Events //////////////////////////////

    event TrackedBalance(
        address indexed delegationManager, address indexed recipient, address indexed token, uint256 tokenId, uint256 balance
    );
    event UpdatedExpectedBalance(
        address indexed delegationManager, address indexed recipient, address indexed token, uint256 tokenId, uint256 expected
    );
    event ValidatedBalance(
        address indexed delegationManager, address indexed recipient, address indexed token, uint256 tokenId, uint256 expected
    );

    ////////////////////////////// State //////////////////////////////

    struct BalanceTracker {
        uint256 balanceBefore;
        uint256 expectedIncrease;
        uint256 validationRemaining;
    }

    struct TermsData {
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
     * @param _terms 104 bytes where:
     * - first 20 bytes: address of the ERC1155 token
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: token ID
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
        TermsData memory terms_ = getTermsInfo(_terms);
        require(terms_.amount > 0, "ERC1155MultiOperationIncreaseBalanceEnforcer:zero-expected-change-amount");
        bytes32 hashKey_ = _getHashKey(msg.sender, terms_.token, terms_.recipient, terms_.tokenId);
        uint256 balance_ = IERC1155(terms_.token).balanceOf(terms_.recipient, terms_.tokenId);
        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        if (balanceTracker_.expectedIncrease == 0) {
            balanceTracker_.balanceBefore = balance_;
            emit TrackedBalance(msg.sender, terms_.recipient, terms_.token, terms_.tokenId, balance_);
        }

        balanceTracker_.expectedIncrease += terms_.amount;
        balanceTracker_.validationRemaining++;

        balanceTracker[hashKey_] = balanceTracker_;

        emit UpdatedExpectedBalance(msg.sender, terms_.recipient, terms_.token, terms_.tokenId, terms_.amount);
    }

    /**
     * @notice This function validates that the recipient's token balance has changed within expected limits.
     * @param _terms 104 bytes where:
     * - first 20 bytes: address of the ERC1155 token
     * - next 20 bytes: address of the recipient
     * - next 32 bytes: token ID
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
        TermsData memory terms_ = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, terms_.token, terms_.recipient, terms_.tokenId);

        balanceTracker[hashKey_].validationRemaining--;

        // Only validate on the last afterAllHook if there are multiple enforcers tracking the same recipient/token/tokenId pair
        if (balanceTracker[hashKey_].validationRemaining > 0) return;

        BalanceTracker memory balanceTracker_ = balanceTracker[hashKey_];

        uint256 balance_ = IERC1155(terms_.token).balanceOf(terms_.recipient, terms_.tokenId);

        require(
            balance_ >= balanceTracker_.balanceBefore + balanceTracker_.expectedIncrease,
            "ERC1155MultiOperationIncreaseBalanceEnforcer:insufficient-balance-increase"
        );

        emit ValidatedBalance(msg.sender, terms_.recipient, terms_.token, terms_.tokenId, balanceTracker_.expectedIncrease);

        delete balanceTracker[hashKey_];
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms Encoded data that is used during the execution hooks.
     * @return TermsData Struct that consists of:
     * - token_ The address of the ERC1155 token.
     * - recipient_ The address of the recipient of the token.
     * - tokenId_ The ID of the ERC1155 token.
     * - amount_ Balance change guardrail amount (i.e., minimum increase)
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (TermsData memory) {
        require(_terms.length == 104, "ERC1155MultiOperationIncreaseBalanceEnforcer:invalid-terms-length");
        return TermsData({
            token: address(bytes20(_terms[:20])),
            recipient: address(bytes20(_terms[20:40])),
            tokenId: uint256(bytes32(_terms[40:72])),
            amount: uint256(bytes32(_terms[72:]))
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
