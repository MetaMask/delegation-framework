// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title TokenTransformationEnforcer
 * @notice Tracks token transformations through protocol interactions (e.g., lending protocols).
 * @dev This enforcer allows tracking multiple tokens per delegationHash, enabling delegation
 *      of an initial token amount and tracking what it transforms into through protocol interactions.
 * @dev The enforcer validates that token usage doesn't exceed tracked amounts.
 * @dev State updates can only be made by the AdapterManager.
 */
contract TokenTransformationEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// State //////////////////////////////

    /// @dev Mapping from delegationHash => token => available amount
    mapping(bytes32 delegationHash => mapping(address token => uint256 amount)) public availableAmounts;

    /// @dev Mapping to track if initial token has been initialized for a delegationHash
    mapping(bytes32 delegationHash => bool initialized) public isInitialized;

    /// @dev Address of the AdapterManager that can update state
    address public immutable adapterManager;

    ////////////////////////////// Events //////////////////////////////

    /// @dev Emitted when asset state is updated for a delegation
    event AssetStateUpdated(bytes32 indexed delegationHash, address indexed token, uint256 oldAmount, uint256 newAmount);

    /// @dev Emitted when tokens are spent from a delegation
    event TokensSpent(bytes32 indexed delegationHash, address indexed token, uint256 amount, uint256 remaining);

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Error thrown when caller is not the AdapterManager
    error NotAdapterManager();

    /// @dev Error thrown when insufficient tokens are available
    error InsufficientTokensAvailable(bytes32 delegationHash, address token, uint256 requested, uint256 available);

    /// @dev Error thrown when invalid terms length is provided
    error InvalidTermsLength();

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Initializes the TokenTransformationEnforcer
     * @param _adapterManager Address of the AdapterManager contract
     */
    constructor(address _adapterManager) {
        if (_adapterManager == address(0)) revert("TokenTransformationEnforcer:invalid-adapter-manager");
        adapterManager = _adapterManager;
    }

    ////////////////////////////// Modifiers //////////////////////////////

    modifier onlyAdapterManager() {
        if (msg.sender != adapterManager) revert NotAdapterManager();
        _;
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Validates that the requested token amount is available for the delegation
     * @dev Expected delegation types:
     *      - Initial delegation: Grants access to an initial token amount (e.g., 1000 USDC)
     *      - Protocol interaction delegations: Used with AdapterManager to track token transformations
     *        through lending protocols (e.g., USDC -> aUSDC via Aave deposit)
     *      - Multi-token delegations: Tracks multiple tokens per delegationHash as tokens are transformed
     * @param _terms Encoded initial token address and amount (52 bytes: 20 bytes token + 32 bytes amount)
     * @param _mode The execution mode (must be Single callType, Default execType)
     * @param _executionCallData The execution call data containing the transfer
     * @param _delegationHash The hash of the delegation
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address,
        address
    )
        public
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        (address initialToken_, uint256 initialAmount_) = getTermsInfo(_terms);
        (address target_,, bytes calldata callData_) = _executionCallData.decodeSingle();

        // Validate that this is an ERC20 transfer
        require(callData_.length == 68, "TokenTransformationEnforcer:invalid-execution-length");
        address token_ = target_; // Token being transferred
        require(bytes4(callData_[0:4]) == IERC20.transfer.selector, "TokenTransformationEnforcer:invalid-method");

        // Decode transfer amount
        uint256 transferAmount_ = uint256(bytes32(callData_[36:68]));

        // Get available amount
        uint256 available_ = availableAmounts[_delegationHash][token_];

        // Initialize from terms only if this is the first use of the initial token
        // Only initialize if: token matches initial token AND delegationHash hasn't been initialized yet
        if (available_ == 0 && !isInitialized[_delegationHash] && token_ == initialToken_) {
            available_ = initialAmount_;
            availableAmounts[_delegationHash][token_] = initialAmount_;
            isInitialized[_delegationHash] = true;
        }

        if (transferAmount_ > available_) {
            revert InsufficientTokensAvailable(_delegationHash, token_, transferAmount_, available_);
        }

        // Deduct from available amount
        availableAmounts[_delegationHash][token_] = available_ - transferAmount_;

        emit TokensSpent(_delegationHash, token_, transferAmount_, available_ - transferAmount_);
    }

    /**
     * @notice Updates the asset state for a delegation after a protocol interaction
     * @dev Only callable by the AdapterManager
     * @param _delegationHash The hash of the delegation
     * @param _token The token address
     * @param _amount The new amount available (adds to existing if token already tracked)
     */
    function updateAssetState(bytes32 _delegationHash, address _token, uint256 _amount) external onlyAdapterManager {
        uint256 oldAmount_ = availableAmounts[_delegationHash][_token];
        uint256 newAmount_ = oldAmount_ + _amount;
        availableAmounts[_delegationHash][_token] = newAmount_;

        emit AssetStateUpdated(_delegationHash, _token, oldAmount_, newAmount_);
    }

    /**
     * @notice Gets the available amount for a specific token in a delegation
     * @param _delegationHash The hash of the delegation
     * @param _token The token address
     * @return The available amount
     */
    function getAvailableAmount(bytes32 _delegationHash, address _token) external view returns (uint256) {
        return availableAmounts[_delegationHash][_token];
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer
     * @param _terms Encoded data: 20 bytes token address + 32 bytes initial amount
     * @return token_ The initial token address
     * @return amount_ The initial amount
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address token_, uint256 amount_) {
        if (_terms.length != 52) revert InvalidTermsLength();
        token_ = address(bytes20(_terms[:20]));
        amount_ = uint256(bytes32(_terms[20:]));
    }
}

