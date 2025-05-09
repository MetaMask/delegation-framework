// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ERC1155BalanceChangeEnforcer
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
contract ERC1155BalanceChangeEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    mapping(bytes32 hashKey => uint256 balance) public balanceCache;
    mapping(bytes32 hashKey => bool lock) public isLocked;

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     * @param _caller Address of the sender calling the enforcer.
     * @param _token ERC1155 token being compared in the beforeHook and afterHook.
     * @param _recipient The address of the recipient of the token.
     * @param _tokenId The ID of the ERC1155 token.
     * @param _delegationHash The hash of the delegation.
     * @return The hash to be used as key of the mapping.
     */
    function getHashKey(
        address _caller,
        address _token,
        address _recipient,
        uint256 _tokenId,
        bytes32 _delegationHash
    )
        external
        pure
        returns (bytes32)
    {
        return _getHashKey(_caller, _token, _recipient, _tokenId, _delegationHash);
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
        (, address token_, address recipient_, uint256 tokenId_,) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, token_, recipient_, tokenId_, _delegationHash);
        require(!isLocked[hashKey_], "ERC1155BalanceChangeEnforcer:enforcer-is-locked");
        isLocked[hashKey_] = true;
        uint256 balance_ = IERC1155(token_).balanceOf(recipient_, tokenId_);
        balanceCache[hashKey_] = balance_;
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
        (bool enforceDecrease_, address token_, address recipient_, uint256 tokenId_, uint256 amount_) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, token_, recipient_, tokenId_, _delegationHash);
        delete isLocked[hashKey_];
        uint256 balance_ = IERC1155(token_).balanceOf(recipient_, tokenId_);
        if (enforceDecrease_) {
            require(balance_ >= balanceCache[hashKey_] - amount_, "ERC1155BalanceChangeEnforcer:exceeded-balance-decrease");
        } else {
            require(balance_ >= balanceCache[hashKey_] + amount_, "ERC1155BalanceChangeEnforcer:insufficient-balance-increase");
        }
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms Encoded data that is used during the execution hooks.
     * @return enforceDecrease_ Boolean indicating if the balance should decrease (true | 0x01) or increase (false | 0x00).
     * @return token_ The address of the ERC1155 token.
     * @return recipient_ The address of the recipient of the token.
     * @return tokenId_ The ID of the ERC1155 token.
     * @return amount_ Balance change guardrail amount (i.e., minimum increase OR maximum decrease, depending on
     * enforceDecrease)
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (bool enforceDecrease_, address token_, address recipient_, uint256 tokenId_, uint256 amount_)
    {
        require(_terms.length == 105, "ERC1155BalanceChangeEnforcer:invalid-terms-length");
        enforceDecrease_ = _terms[0] != 0;
        token_ = address(bytes20(_terms[1:21]));
        recipient_ = address(bytes20(_terms[21:41]));
        tokenId_ = uint256(bytes32(_terms[41:73]));
        amount_ = uint256(bytes32(_terms[73:]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run. Produced by hashing the provided values.
     */
    function _getHashKey(
        address _caller,
        address _token,
        address _recipient,
        uint256 _tokenId,
        bytes32 _delegationHash
    )
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_caller, _token, _recipient, _tokenId, _delegationHash));
    }
}
