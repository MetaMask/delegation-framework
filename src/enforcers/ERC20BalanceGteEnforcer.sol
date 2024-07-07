// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { Action } from "../utils/Types.sol";

/**
 * @title ERC20BalanceGteEnforcer
 * @dev This contract enforces that the delegator's ERC20 balance has increased by at least the specified amount
 * after the action has been executed, measured between the `beforeHook` and `afterHook` calls, regardless of what the action is.
 * @dev This contract has no enforcement of how the balance increases. It's meant to be used alongside additional enforcers to
 * create granular permissions.
 */
contract ERC20BalanceGteEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    mapping(bytes32 hashKey => uint256 balance) public balanceCache;
    mapping(bytes32 hashKey => bool lock) public isLocked;

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     * @param _caller Address of the sender calling the enforcer.
     * @param _token Token being compared in the beforeHook and beforeHook.
     * @param _delegationHash The hash of the delegation.
     * @return The hash to be used as key of the mapping.
     */
    function getHashKey(address _caller, address _token, bytes32 _delegationHash) external pure returns (bytes32) {
        return _getHashKey(_caller, _token, _delegationHash);
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice This function caches the delegators ERC20 balance before the delegation is executed.
     * @param _terms 52 packed bytes where: the first 20 bytes are the address of the token, the next 32 bytes
     * are the amount the balance should be greater than
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        Action calldata,
        bytes32 _delegationHash,
        address _delegator,
        address
    )
        public
        override
    {
        (address token_,) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, token_, _delegationHash);
        require(!isLocked[hashKey_], "ERC20BalanceGteEnforcer:enforcer-is-locked");
        isLocked[hashKey_] = true;
        uint256 balance_ = IERC20(token_).balanceOf(_delegator);
        balanceCache[hashKey_] = balance_;
    }

    /**
     * @notice This function enforces that the delegators ERC20 balance has increased by at least the amount provided.
     * @param _terms 52 packed bytes where: the first 20 bytes are the address of the token, the next 32 bytes
     * are the amount the balance should be greater than
     */
    function afterHook(
        bytes calldata _terms,
        bytes calldata,
        Action calldata,
        bytes32 _delegationHash,
        address _delegator,
        address
    )
        public
        override
    {
        (address token_, uint256 amount_) = getTermsInfo(_terms);
        bytes32 hashKey_ = _getHashKey(msg.sender, token_, _delegationHash);
        delete isLocked[hashKey_];
        uint256 balance_ = IERC20(token_).balanceOf(_delegator);
        require(balance_ >= balanceCache[hashKey_] + amount_, "ERC20BalanceGteEnforcer:balance-not-gt");
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return token_ The address of the token.
     * @return amount_ The amount the balance should be greater than.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address token_, uint256 amount_) {
        require(_terms.length == 52, "ERC20BalanceGteEnforcer:invalid-terms-length");
        token_ = address(bytes20(_terms[:20]));
        amount_ = uint256(bytes32(_terms[20:]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     */
    function _getHashKey(address _caller, address _token, bytes32 _delegationHash) private pure returns (bytes32) {
        return keccak256(abi.encode(_caller, _token, _delegationHash));
    }
}
