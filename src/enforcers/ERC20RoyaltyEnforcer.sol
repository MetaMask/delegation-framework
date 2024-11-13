// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ERC20RoyaltyEnforcer
 * @notice Enforces royalty payments when redeeming ERC20 token delegations
 * @dev When a delegation is redeemed:
 * 1. Validates the execution is a token transfer to this enforcer
 * 2. Distributes royalties to recipients specified in terms
 * 3. Sends remaining tokens to the redeemer
 */
contract ERC20RoyaltyEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    /// @notice Maps hash key to lock status
    mapping(bytes32 => bool) public isLocked;

    /// @notice Maps hash key to delegator's balance before execution
    mapping(bytes32 => uint256) public delegatorBalanceCache;

    /// @notice Maps hash key to enforcer's balance before execution
    mapping(bytes32 => uint256) public enforcerBalanceCache;

    ////////////////////////////// Types //////////////////////////////

    /// @notice Struct for royalty information
    struct RoyaltyInfo {
        address recipient;
        uint256 amount;
    }

    /// @notice Struct to hold execution details
    struct ExecutionDetails {
        address token;
        address recipient;
        uint256 amount;
    }

    ////////////////////////////// Hooks //////////////////////////////

    /// @notice Validates and processes the beforeHook logic
    /// @dev Validates transfer details and locks execution
    /// @param _terms Encoded royalty terms (recipient, amount pairs)
    /// @param _mode Execution mode (must be single)
    /// @param _executionCallData Encoded execution details
    /// @param _delegationHash Hash of the delegation
    /// @param _delegator Address of the delegator
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _delegator,
        address
    )
        public
        override
        onlySingleExecutionMode(_mode)
    {
        // Get execution details
        ExecutionDetails memory details = _parseExecution(_executionCallData);

        // Validate transfer
        require(details.recipient == address(this), "ERC20RoyaltyEnforcer:invalid-recipient");

        // Calculate total royalties
        uint256 totalRoyalties = _sumRoyalties(_terms);
        require(details.amount >= totalRoyalties, "ERC20RoyaltyEnforcer:insufficient-amount");

        // Cache balances
        bytes32 hashKey = keccak256(abi.encode(_delegator, details.token, _delegationHash));
        delegatorBalanceCache[hashKey] = IERC20(details.token).balanceOf(_delegator);
        enforcerBalanceCache[hashKey] = IERC20(details.token).balanceOf(address(this));

        // Lock execution
        require(!isLocked[hashKey], "ERC20RoyaltyEnforcer:enforcer-is-locked");
        isLocked[hashKey] = true;
    }

    /// @notice Processes royalty distribution
    /// @dev Distributes royalties and sends remaining tokens to redeemer
    function afterHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _delegator,
        address
    )
        public
        override
    {
        ExecutionDetails memory details = _parseExecution(_executionCallData);
        address redeemer = abi.decode(_args, (address));
        require(redeemer != address(0), "ERC20RoyaltyEnforcer:invalid-redeemer");

        // Process royalties
        _distributeRoyalties(details.token, _terms);

        // Send remaining balance
        uint256 remaining = IERC20(details.token).balanceOf(address(this));
        if (remaining > 0) {
            require(IERC20(details.token).transfer(redeemer, remaining), "ERC20RoyaltyEnforcer:invalid-transfer");
        }

        // Unlock
        bytes32 hashKey = keccak256(abi.encode(_delegator, details.token, _delegationHash));
        isLocked[hashKey] = false;
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /// @notice Returns decoded terms info
    /// @param _terms Encoded royalty terms
    /// @param _args Encoded redeemer address
    /// @return royalties_ Array of royalty info structs
    /// @return redeemer_ Address of the redeemer
    function getTermsInfo(
        bytes calldata _terms,
        bytes calldata _args
    )
        public
        pure
        returns (RoyaltyInfo[] memory royalties_, address redeemer_)
    {
        require(_terms.length % 64 == 0, "ERC20RoyaltyEnforcer:invalid-terms-length");
        uint256 count = _terms.length / 64;
        royalties_ = new RoyaltyInfo[](count);

        for (uint256 i; i < count; ++i) {
            (address recipient, uint256 amount) = abi.decode(_terms[(i * 64):((i + 1) * 64)], (address, uint256));
            royalties_[i] = RoyaltyInfo({ recipient: recipient, amount: amount });
        }

        redeemer_ = abi.decode(_args, (address));
        require(redeemer_ != address(0), "ERC20RoyaltyEnforcer:invalid-redeemer");
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /// @notice Parses execution calldata into structured data
    /// @param _calldata Raw execution calldata
    /// @return Structured execution details
    function _parseExecution(bytes calldata _calldata) internal pure returns (ExecutionDetails memory) {
        (address token, uint256 value, bytes calldata data) = ExecutionLib.decodeSingle(_calldata);
        require(value == 0, "ERC20RoyaltyEnforcer:non-zero-value");
        require(data.length >= 4, "ERC20RoyaltyEnforcer:invalid-calldata-length");
        require(bytes4(data[0:4]) == IERC20.transfer.selector, "ERC20RoyaltyEnforcer:invalid-selector");

        (address recipient, uint256 amount) = abi.decode(data[4:], (address, uint256));
        return ExecutionDetails({ token: token, recipient: recipient, amount: amount });
    }

    /// @notice Calculates total royalties from terms
    /// @param _terms Encoded royalty terms
    /// @return Total royalty amount
    function _sumRoyalties(bytes calldata _terms) internal pure returns (uint256) {
        require(_terms.length % 64 == 0, "ERC20RoyaltyEnforcer:invalid-terms-length");
        uint256 total;
        uint256 chunks = _terms.length / 64;

        for (uint256 i; i < chunks; ++i) {
            (, uint256 amount) = abi.decode(_terms[(i * 64):((i + 1) * 64)], (address, uint256));
            total += amount;
        }
        return total;
    }

    /// @notice Distributes royalties to recipients
    /// @param _token Token address
    /// @param _terms Encoded royalty terms
    function _distributeRoyalties(address _token, bytes calldata _terms) internal {
        uint256 chunks = _terms.length / 64;
        for (uint256 i; i < chunks; ++i) {
            (address recipient, uint256 amount) = abi.decode(_terms[(i * 64):((i + 1) * 64)], (address, uint256));
            require(IERC20(_token).transfer(recipient, amount), "ERC20RoyaltyEnforcer:invalid-transfer");
        }
    }
}
