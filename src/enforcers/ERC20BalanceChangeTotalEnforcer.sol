// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ERC20BalanceChangeTotalEnforcer
 * @notice Enforces that a recipient's token balance increases by at least the expected total amount across multiple delegations
 * @dev Tracks initial balance and accumulates expected increases per recipient/token pair within a delegation chain
 * @dev Only operates in default execution mode
 * @dev Terms format: token (20 bytes) + recipient (20 bytes) + expected increase (12 bytes)
 * @dev Security considerations:
 * - State is shared between enforcers watching the same recipient/token pair
 * - A single balance change can satisfy multiple enforcer instances simultaneously
 * - Balance changes are tracked by comparing before/after balances
 */
contract ERC20BalanceChangeTotalEnforcer is CaveatEnforcer {
    ////////////////////////////// Events //////////////////////////////
    event BalanceTracked(address indexed delegationManager, address indexed recipient, address indexed token, uint256 balance);
    event ExpectedIncreaseUpdated(
        address indexed delegationManager, address indexed token, address indexed recipient, uint256 expected
    );
    event BalanceValidated(address indexed delegationManager, address indexed recipient, address indexed token, uint256 expected);

    ////////////////////////////// State //////////////////////////////

    mapping(bytes32 hashKey => uint256 amount) public balanceBefore;
    mapping(bytes32 hashKey => uint256 amount) public totalExpected;

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     * @param _caller Address of the sender calling the enforcer.
     * @param _token Token being compared in the beforeHook and afterHook.
     * @param _recipient Address of the recipient whose balance is being tracked.
     * @return The hash to be used as key of the mapping.
     */
    function getHashKey(address _caller, address _token, address _recipient) external pure returns (bytes32) {
        return _getHashKey(_caller, _token, _recipient);
    }

    /**
     * @notice This function caches the recipient's initial token balance and accumulates the expected increase.
     * @param _terms 52 packed bytes where:
     * - first 20 bytes: address of the token
     * - next 20 bytes: address of the recipient
     * - next 12 bytes: expected balance increase amount
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
        (address token_, address recipient_, uint256 expected_) = getTermsInfo(_terms);

        bytes32 hashKey_ = _getHashKey(msg.sender, token_, recipient_);
        uint256 storedBalance_ = balanceBefore[hashKey_];
        uint256 currentBalance_ = IERC20(token_).balanceOf(recipient_);
        if (storedBalance_ == 0) {
            balanceBefore[hashKey_] = currentBalance_;
            emit BalanceTracked(msg.sender, recipient_, token_, currentBalance_);
        } else {
            require(storedBalance_ == currentBalance_, "ERC20BalanceChangeTotalEnforcer:balance-before-differs");
        }

        totalExpected[hashKey_] += expected_;
        emit ExpectedIncreaseUpdated(msg.sender, token_, recipient_, expected_);
    }

    /**
     * @notice This function validates that the recipient's token balance has increased by at least the total expected amount.
     * @param _terms 52 packed bytes where:
     * - first 20 bytes: address of the token
     * - next 20 bytes: address of the recipient
     * - next 12 bytes: expected balance increase amount
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
        uint256 expected_ = totalExpected[hashKey_];
        if (expected_ == 0) return; // validation has already been made

        uint256 storedBalance_ = balanceBefore[hashKey_];
        uint256 currentBalance_ = IERC20(token_).balanceOf(recipient_);

        require(currentBalance_ >= storedBalance_ + expected_, "ERC20BalanceChangeTotalEnforcer:insufficient-balance-increase");
        emit BalanceValidated(msg.sender, recipient_, token_, expected_);

        delete balanceBefore[hashKey_];
        delete totalExpected[hashKey_];
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return token_ The address of the token.
     * @return recipient_ The address of the recipient.
     * @return expected_ The expected balance increase amount.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address token_, address recipient_, uint256 expected_) {
        require(_terms.length == 52, "ERC20BalanceChangeTotalEnforcer:invalid-terms-length");
        token_ = address(bytes20(_terms[:20]));
        recipient_ = address(bytes20(_terms[20:40]));
        expected_ = uint256(bytes32(_terms[40:]));
    }

    /**
     * @notice Generates the key that identifies the run. Produced by the hash of the values used.
     */
    function _getHashKey(address _caller, address _token, address _recipient) private pure returns (bytes32) {
        return keccak256(abi.encode(_caller, _token, _recipient));
    }
}
