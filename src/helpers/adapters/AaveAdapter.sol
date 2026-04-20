// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAdapter } from "../interfaces/IAdapter.sol";
import { IAavePool, IAaveDataProvider, IStaticATokenFactory, IERC4626 } from "../interfaces/IAave.sol";

/**
 * @title AaveAdapter
 * @notice Adapter for Aave lending protocol interactions
 * @dev Handles deposit and withdraw actions for Aave V3
 * @dev Wraps rebasing aTokens into static aTokens (stataTokens) using Aave's ERC-4626 wrapper
 *      This converts rebasing tokens into fixed-supply tokens for easier tracking
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

    /// @dev StaticATokenFactory contract address
    address public immutable staticATokenFactory;

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
     * @param _staticATokenFactory The StaticATokenFactory contract address
     */
    constructor(address _aavePool, address _aaveDataProvider, address _staticATokenFactory) {
        if (_aavePool == address(0) || _aaveDataProvider == address(0) || _staticATokenFactory == address(0)) {
            revert InvalidZeroAddress();
        }
        aavePool = _aavePool;
        aaveDataProvider = _aaveDataProvider;
        staticATokenFactory = _staticATokenFactory;
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
        address staticATokenAddress_ = IStaticATokenFactory(staticATokenFactory).getStataToken(address(_tokenFrom));
        if (staticATokenAddress_ == address(0)) revert InvalidZeroAddress();

        address wrapperAsset_ = IERC4626(staticATokenAddress_).asset();
        (address aTokenAddress_,,) = IAaveDataProvider(aaveDataProvider).getReserveTokensAddresses(address(_tokenFrom));
        uint256 wrappedShares_;

        if (wrapperAsset_ == aTokenAddress_) {
            // Deposit to Aave first, then wrap aTokens
            uint256 currentAllowance_ = _tokenFrom.allowance(address(this), aavePool);
            if (currentAllowance_ < _amountFrom) {
                if (currentAllowance_ > 0) {
                    _tokenFrom.safeDecreaseAllowance(aavePool, currentAllowance_);
                }
                _tokenFrom.safeIncreaseAllowance(aavePool, _amountFrom);
            }
            IAavePool(aavePool).supply(address(_tokenFrom), _amountFrom, address(this), 0);

            uint256 aTokenBalance_ = IERC20(aTokenAddress_).balanceOf(address(this));
            IERC20(aTokenAddress_).safeIncreaseAllowance(staticATokenAddress_, aTokenBalance_);
            wrappedShares_ = IERC4626(staticATokenAddress_).deposit(aTokenBalance_, _adapterManager);
        } else if (wrapperAsset_ == address(_tokenFrom)) {
            // Wrapper handles Aave deposit internally
            _tokenFrom.safeIncreaseAllowance(staticATokenAddress_, _amountFrom);
            wrappedShares_ = IERC4626(staticATokenAddress_).deposit(_amountFrom, _adapterManager);
        } else {
            revert InvalidProtocolAddress();
        }

        return TransformationInfo({
            tokenFrom: address(_tokenFrom), amountFrom: _amountFrom, tokenTo: staticATokenAddress_, amountTo: wrappedShares_
        });
    }

    /**
     * @notice Handles Aave withdraw action
     * @param _wrappedToken The wrapped static aToken to withdraw (already transferred to this adapter)
     * @param _amountFrom The amount of wrapped token shares to withdraw
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
        (, bytes memory originalActionData_) = abi.decode(_actionData, (address, bytes));
        (, address underlyingToken_) = abi.decode(originalActionData_, (address, address));

        address staticATokenAddress_ = IStaticATokenFactory(staticATokenFactory).getStataToken(underlyingToken_);
        if (staticATokenAddress_ == address(0) || address(_wrappedToken) != staticATokenAddress_) {
            revert InvalidProtocolAddress();
        }

        address wrapperAsset_ = IERC4626(staticATokenAddress_).asset();
        (address aTokenAddress_,,) = IAaveDataProvider(aaveDataProvider).getReserveTokensAddresses(underlyingToken_);

        uint256 underlyingAmount_;

        if (wrapperAsset_ == aTokenAddress_) {
            uint256 aTokenBalanceBefore_ = IERC20(aTokenAddress_).balanceOf(address(this));
            IERC4626(staticATokenAddress_).redeem(_amountFrom, address(this), address(this));
            uint256 aTokenAmount_ = IERC20(aTokenAddress_).balanceOf(address(this)) - aTokenBalanceBefore_;

            uint256 underlyingBalanceBefore_ = IERC20(underlyingToken_).balanceOf(address(this));
            IAavePool(aavePool).withdraw(underlyingToken_, aTokenAmount_, address(this));
            underlyingAmount_ = IERC20(underlyingToken_).balanceOf(address(this)) - underlyingBalanceBefore_;
        } else if (wrapperAsset_ == underlyingToken_) {
            uint256 underlyingBalanceBefore_ = IERC20(underlyingToken_).balanceOf(address(this));
            IERC4626(staticATokenAddress_).redeem(_amountFrom, address(this), address(this));
            underlyingAmount_ = IERC20(underlyingToken_).balanceOf(address(this)) - underlyingBalanceBefore_;
        } else {
            revert InvalidProtocolAddress();
        }

        IERC20(underlyingToken_).safeTransfer(_adapterManager, underlyingAmount_);

        transformationInfo_.tokenFrom = address(_wrappedToken);
        transformationInfo_.amountFrom = _amountFrom;
        transformationInfo_.tokenTo = underlyingToken_;
        transformationInfo_.amountTo = underlyingAmount_;
    }
}
