// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ERC721BalanceGteEnforcer
 * @dev This contract enforces that the ERC721 token balance of a recipient has increased by at least the specified amount
 * after the execution, measured between the `beforeHook` and `afterHook` calls, regardless of what the execution is.
 * @dev This enforcer operates only in default execution mode.
 */
contract ERC721BalanceGteEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    mapping(bytes32 hashKey => uint256 balance) public balanceCache;
    mapping(bytes32 hashKey => bool lock) public isLocked;

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     * @param _caller Address of the sender calling the enforcer.
     * @param _token ERC721 token being compared in the beforeHook and afterHook.
     * @param _recipient The address of the recipient of the token.
     * @param _delegationHash The hash of the delegation.
     * @return The hash to be used as key of the mapping.
     */
    function getHashKey(
        address _caller,
        address _token,
        address _recipient,
        bytes32 _delegationHash
    )
        external
        pure
        returns (bytes32)
    {
        return _getHashKey(_caller, _token, _recipient, _delegationHash);
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice This function caches the delegator's ERC721 token balance before the delegation is executed.
     * @param _terms 72 bytes where:
     * - first 20 bytes: address of the ERC721 token,
     * - next 20 bytes: address of the recipient,
     * - next 32 bytes: amount the balance should increase by.
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
        (address token_, address recipient_,) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, token_, recipient_, _delegationHash);
        require(!isLocked[hashKey_], "ERC721BalanceGteEnforcer:enforcer-is-locked");
        isLocked[hashKey_] = true;
        uint256 balance_ = IERC721(token_).balanceOf(recipient_);
        balanceCache[hashKey_] = balance_;
    }

    /**
     * @notice This function enforces that the delegator's ERC721 token balance has increased by at least the amount provided.
     * @param _terms 72 bytes where:
     * - first 20 bytes: address of the ERC721 token,
     * - next 20 bytes: address of the recipient,
     * - next 32 bytes: amount the balance should increase by.
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
        (address token_, address recipient_, uint256 amount_) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, token_, recipient_, _delegationHash);
        delete isLocked[hashKey_];
        uint256 balance_ = IERC721(token_).balanceOf(recipient_);
        require(balance_ >= balanceCache[hashKey_] + amount_, "ERC721BalanceGteEnforcer:balance-not-gt");
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms Encoded data that is used during the execution hooks.
     * @return token_ The address of the ERC721 token.
     * @return recipient_ The address of the recipient of the token.
     * @return amount_ The amount the balance should increase by.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address token_, address recipient_, uint256 amount_) {
        require(_terms.length == 72, "ERC721BalanceGteEnforcer:invalid-terms-length");
        token_ = address(bytes20(_terms[:20]));
        recipient_ = address(bytes20(_terms[20:40]));
        amount_ = uint256(bytes32(_terms[40:]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     */
    function _getHashKey(
        address _caller,
        address _token,
        address _recipient,
        bytes32 _delegationHash
    )
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_caller, _token, _recipient, _delegationHash));
    }
}
