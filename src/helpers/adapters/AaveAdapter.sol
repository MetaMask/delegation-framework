// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAdapter } from "../interfaces/IAdapter.sol";

/**
 * @notice Simplified Aave Pool interface for supply
 * @dev In production, use the official Aave IPool interface
 */
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/**
 * @notice Aave Data Provider interface to get aToken address
 * @dev In production, use the official Aave IProtocolDataProvider interface
 */
interface IAaveDataProvider {
    function getReserveTokensAddresses(address asset) external view returns (address aTokenAddress, address, address);
}

/**
 * @notice Interface for wrapping/unwrapping aTokens
 * @dev Wraps rebasing aTokens into fixed-supply wrapped tokens for easier tracking
 */
interface IATokenWrapper {
    function wrap(address aToken, uint256 amount) external returns (uint256 wrappedAmount);
    function unwrap(address aToken, uint256 wrappedAmount) external returns (uint256 aTokenAmount);
    function getWrappedToken(address aToken) external view returns (address wrappedToken);
}

/**
 * @title AaveAdapter
 * @notice Adapter for Aave lending protocol interactions
 * @dev Handles deposit, withdraw, borrow, and repay actions for Aave V3
 * @dev TODO: Validate and test using Aave's ATokenVault (ERC-4626) for direct deposit/withdraw
 *      of wrapped tokens without manual wrapping/unwrapping conversion steps. ATokenVault allows:
 *      - Direct deposit: underlying → vault.deposit() → wrapped token (no manual wrap needed)
 *      - Direct withdraw: wrapped token → vault.withdraw() → underlying (no manual unwrap needed)
 *      This would simplify the flow and eliminate the need for aTokenWrapper.
 */
contract AaveAdapter is IAdapter {
    using SafeERC20 for IERC20;

    ////////////////////////////// Constants //////////////////////////////

    /// @dev Hash of "deposit" action string
    bytes32 public constant ACTION_DEPOSIT = keccak256(bytes("deposit"));

    /// @dev Hash of "withdraw" action string
    bytes32 public constant ACTION_WITHDRAW = keccak256(bytes("withdraw"));

    ////////////////////////////// State //////////////////////////////

    /// @dev Aave Pool contract address
    address public immutable aavePool;

    /// @dev Aave Data Provider contract address
    address public immutable aaveDataProvider;

    /// @dev AToken Wrapper contract address
    address public immutable aTokenWrapper;

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Error thrown when action is not supported
    error UnsupportedAction(string action);

    /// @dev Error thrown when protocol address doesn't match Aave Pool
    error InvalidProtocolAddress();

    /// @dev Error thrown when address is zero
    error InvalidZeroAddress();

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Initializes the AaveAdapter
     * @param _aavePool The Aave Pool contract address
     * @param _aaveDataProvider The Aave Data Provider contract address
     * @param _aTokenWrapper The AToken Wrapper contract address
     */
    constructor(address _aavePool, address _aaveDataProvider, address _aTokenWrapper) {
        if (_aavePool == address(0) || _aaveDataProvider == address(0) || _aTokenWrapper == address(0)) {
            revert InvalidZeroAddress();
        }
        aavePool = _aavePool;
        aaveDataProvider = _aaveDataProvider;
        aTokenWrapper = _aTokenWrapper;
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Executes an Aave protocol action and returns transformation info
     * @param _protocolAddress The Aave Pool address (must match aavePool)
     * @param _action The action to perform ("deposit" or "withdraw")
     * @param _tokenFrom The input token address
     * @param _amountFrom The amount of input tokens to use
     * @param _actionData Additional data containing the AdapterManager address for balance measurement
     * @return transformationInfo_ The transformation information
     */
    function executeProtocolAction(
        address _protocolAddress,
        string calldata _action,
        IERC20 _tokenFrom,
        uint256 _amountFrom,
        bytes calldata _actionData
    )
        external
        override
        returns (TransformationInfo memory transformationInfo_)
    {
        if (_protocolAddress != aavePool) revert InvalidProtocolAddress();

        address adapterManager_ = abi.decode(_actionData, (address));

        bytes32 actionHash_ = keccak256(bytes(_action));

        if (actionHash_ == ACTION_DEPOSIT) {
            return _handleDeposit(_tokenFrom, _amountFrom, adapterManager_);
        } else if (actionHash_ == ACTION_WITHDRAW) {
            return _handleWithdraw(_tokenFrom, _amountFrom, _actionData, adapterManager_);
        } else {
            revert UnsupportedAction(_action);
        }
    }

    ////////////////////////////// Private Methods //////////////////////////////

    /**
     * @notice Handles Aave deposit action
     * @param _tokenFrom The underlying token to deposit (already transferred to this adapter)
     * @param _amountFrom The amount to deposit
     * @param _adapterManager The AdapterManager address (for returning wrapped tokens)
     * @return transformationInfo_ The transformation information
     */
    function _handleDeposit(
        IERC20 _tokenFrom,
        uint256 _amountFrom,
        address _adapterManager
    )
        private
        returns (TransformationInfo memory transformationInfo_)
    {
        (address aTokenAddress_,,) = IAaveDataProvider(aaveDataProvider).getReserveTokensAddresses(address(_tokenFrom));
        IERC20 aToken_ = IERC20(aTokenAddress_);

        // Supply underlying tokens to Aave Pool, receiving aTokens directly to this adapter
        // The underlying tokens were already transferred from AdapterManager to this adapter
        uint256 currentAllowance_ = _tokenFrom.allowance(address(this), aavePool);
        if (currentAllowance_ < _amountFrom) {
            if (currentAllowance_ > 0) {
                _tokenFrom.safeDecreaseAllowance(aavePool, currentAllowance_);
            }
            _tokenFrom.safeIncreaseAllowance(aavePool, _amountFrom);
        }
        IAavePool(aavePool).supply(address(_tokenFrom), _amountFrom, address(this), 0);

        // Wrap the aTokens received from Aave
        uint256 aTokenBalance_ = aToken_.balanceOf(address(this));
        aToken_.safeIncreaseAllowance(aTokenWrapper, aTokenBalance_);
        uint256 wrappedAmount_ = IATokenWrapper(aTokenWrapper).wrap(aTokenAddress_, aTokenBalance_);

        address wrappedTokenAddress_ = IATokenWrapper(aTokenWrapper).getWrappedToken(aTokenAddress_);
        if (wrappedTokenAddress_ == address(0)) revert InvalidZeroAddress();

        // Transfer wrapped tokens back to AdapterManager
        IERC20 wrappedToken_ = IERC20(wrappedTokenAddress_);
        wrappedToken_.safeTransfer(_adapterManager, wrappedAmount_);

        return TransformationInfo({
            tokenFrom: address(_tokenFrom), amountFrom: _amountFrom, tokenTo: wrappedTokenAddress_, amountTo: wrappedAmount_
        });
    }

    /**
     * @notice Handles Aave withdraw action
     * @param _wrappedToken The wrapped aToken to withdraw (already transferred to this adapter)
     * @param _amountFrom The amount of wrapped token to withdraw
     * @param _actionData Additional data containing underlying token address and AdapterManager address
     * @param _adapterManager The AdapterManager address (for returning underlying tokens)
     * @return transformationInfo_ The transformation information
     */
    function _handleWithdraw(
        IERC20 _wrappedToken,
        uint256 _amountFrom,
        bytes calldata _actionData,
        address _adapterManager
    )
        private
        returns (TransformationInfo memory transformationInfo_)
    {
        // _actionData is: abi.encode(adapterManager, abi.encode(adapterManager, underlyingToken))
        // Decode to get the originalActionData, then decode that to get underlyingToken
        (, bytes memory originalActionData_) = abi.decode(_actionData, (address, bytes));
        (, address underlyingToken_) = abi.decode(originalActionData_, (address, address));
        (address aTokenAddress_,,) = IAaveDataProvider(aaveDataProvider).getReserveTokensAddresses(underlyingToken_);
        IERC20 aToken_ = IERC20(aTokenAddress_);

        // Unwrap the wrapped tokens to get aTokens in this adapter's balance
        uint256 aTokenBalanceBefore_ = aToken_.balanceOf(address(this));
        _wrappedToken.safeIncreaseAllowance(aTokenWrapper, _amountFrom);
        IATokenWrapper(aTokenWrapper).unwrap(aTokenAddress_, _amountFrom);
        uint256 aTokenAmount_ = aToken_.balanceOf(address(this)) - aTokenBalanceBefore_;

        // Withdraw underlying tokens from Aave Pool, receiving them directly to this adapter
        IERC20 underlyingTokenContract_ = IERC20(underlyingToken_);
        uint256 underlyingBalanceBefore_ = underlyingTokenContract_.balanceOf(address(this));
        IAavePool(aavePool).withdraw(underlyingToken_, aTokenAmount_, address(this));
        uint256 underlyingAmount_ = underlyingTokenContract_.balanceOf(address(this)) - underlyingBalanceBefore_;

        // Transfer underlying tokens back to AdapterManager
        underlyingTokenContract_.safeTransfer(_adapterManager, underlyingAmount_);

        transformationInfo_.tokenFrom = address(_wrappedToken);
        transformationInfo_.amountFrom = _amountFrom;
        transformationInfo_.tokenTo = underlyingToken_;
        transformationInfo_.amountTo = underlyingAmount_;
    }
}
