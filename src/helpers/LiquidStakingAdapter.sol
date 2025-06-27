// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { IWithdrawalQueue } from "./interfaces/IWithdrawalQueue.sol";
import { Delegation, ModeCode } from "../utils/Types.sol";

/// @title LiquidStakingAdapter
/// @notice Adapter contract for liquid staking withdrawal operations using delegations
/// @dev Handles stETH withdrawals through Lido's withdrawal queue using delegation-based permissions
contract LiquidStakingAdapter is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Thrown when a zero address is provided for required parameters
    error InvalidZeroAddress();

    /// @notice Thrown when wrong number of delegations is provided
    error WrongNumberOfDelegations();

    /// @notice Thrown when no amounts are specified for withdrawal
    error NoAmountsSpecified();

    /// @dev Error while transferring the native token to the recipient.
    error FailedNativeTokenTransfer(address recipient);

    /// @notice Delegation manager for handling delegated operations
    IDelegationManager public immutable delegationManager;
    /// @notice Lido withdrawal queue contract
    IWithdrawalQueue public immutable withdrawalQueue;
    /// @notice stETH token contract
    IERC20 public immutable stETH;

    /// @notice Event emitted when withdrawal requests are created
    /// @param delegator Address of the delegator (stETH owner)
    /// @param amounts Array of withdrawal amounts
    /// @param requestIds Array of withdrawal request IDs created
    event WithdrawalRequestsCreated(address indexed delegator, uint256[] amounts, uint256[] requestIds);

    /// @notice Event emitted when tokens are withdrawn
    /// @param token Address of the token withdrawn
    /// @param recipient Address of the recipient
    /// @param amount Amount of tokens withdrawn
    event TokensWithdrawn(IERC20 indexed token, address indexed recipient, uint256 amount);

    /// @notice Initializes the adapter with required contract addresses
    /// @param _owner Address of the owner of the contract
    /// @param _delegationManager Address of the delegation manager contract
    /// @param _withdrawalQueue Address of the Lido withdrawal queue contract
    /// @param _stETH Address of the stETH token contract
    constructor(address _owner, address _delegationManager, address _withdrawalQueue, address _stETH) Ownable(_owner) {
        if (_delegationManager == address(0) || _withdrawalQueue == address(0) || _stETH == address(0)) revert InvalidZeroAddress();

        delegationManager = IDelegationManager(_delegationManager);
        withdrawalQueue = IWithdrawalQueue(_withdrawalQueue);
        stETH = IERC20(_stETH);
    }

    /// @notice Request withdrawals using delegation-based stETH transfer
    /// @dev Uses a delegation to transfer stETH, then requests withdrawals. The delegator owns the withdrawal requests.
    /// @param _delegations Array containing a single delegation for stETH transfer
    /// @param _amounts Array of stETH amounts to withdraw
    /// @return requestIds_ Array of withdrawal request IDs
    function requestWithdrawalsByDelegation(
        Delegation[] memory _delegations,
        uint256[] memory _amounts
    )
        external
        returns (uint256[] memory requestIds_)
    {
        if (_delegations.length != 1) revert WrongNumberOfDelegations();

        address delegator_ = _delegations[0].delegator;
        uint256 totalAmount_ = _calculateTotalAmount(_amounts);

        // Redeem delegation to transfer stETH to this contract
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);
        bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), totalAmount_));
        executionCallDatas_[0] = ExecutionLib.encodeSingle(address(stETH), 0, encodedTransfer_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        // Execute common withdrawal logic
        requestIds_ = _requestWithdrawals(_amounts, totalAmount_, delegator_);
    }

    /// @notice Request withdrawals with permit using delegation-based operation
    /// @dev Delegates can execute this function to request withdrawals using permit signatures
    /// @param _amounts Array of stETH amounts to withdraw
    /// @param _permit Permit signature data for gasless approval
    /// @return requestIds_ Array of withdrawal request IDs
    function requestWithdrawalsWithPermitByDelegation(
        uint256[] memory _amounts,
        IWithdrawalQueue.PermitInput memory _permit
    )
        external
        returns (uint256[] memory requestIds_)
    {
        uint256 totalAmount_ = _calculateTotalAmount(_amounts);

        // Use permit to approve stETH transfer
        IERC20Permit(address(stETH)).permit(
            msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s
        );

        // Transfer stETH from sender to this contract
        stETH.safeTransferFrom(msg.sender, address(this), totalAmount_);

        // Execute common withdrawal logic
        requestIds_ = _requestWithdrawals(_amounts, totalAmount_, msg.sender);
    }

    /**
     * @notice Withdraws a specified token from the contract to a recipient.
     * @dev Only callable by the contract owner.
     * @param _token The token to be withdrawn (use address(0) for native token).
     * @param _amount The amount of tokens (or native) to withdraw.
     * @param _recipient The address to receive the withdrawn tokens.
     */
    function withdraw(IERC20 _token, uint256 _amount, address _recipient) external onlyOwner {
        if (address(_token) == address(0)) {
            (bool success_,) = _recipient.call{ value: _amount }("");

            if (!success_) revert FailedNativeTokenTransfer(_recipient);
        } else {
            IERC20(_token).safeTransfer(_recipient, _amount);
        }

        emit TokensWithdrawn(_token, _recipient, _amount);
    }

    /// @notice Internal function to handle common withdrawal request logic
    /// @param _amounts Array of stETH amounts to withdraw
    /// @param _totalAmount Total amount of stETH to withdraw
    /// @param _delegator Address of the delegator who will own the withdrawal requests
    /// @return requestIds_ Array of withdrawal request IDs
    function _requestWithdrawals(
        uint256[] memory _amounts,
        uint256 _totalAmount,
        address _delegator
    )
        internal
        returns (uint256[] memory requestIds_)
    {
        _ensureAllowance(_totalAmount);

        requestIds_ = withdrawalQueue.requestWithdrawals(_amounts, _delegator);

        emit WithdrawalRequestsCreated(_delegator, _amounts, requestIds_);
    }

    /// @notice Ensures sufficient token allowance for withdrawal queue operations
    /// @dev Checks current allowance and increases to max if needed
    /// @param _amount Amount needed for the operation
    function _ensureAllowance(uint256 _amount) private {
        uint256 allowance_ = stETH.allowance(address(this), address(withdrawalQueue));
        if (allowance_ < _amount) {
            stETH.safeIncreaseAllowance(address(withdrawalQueue), type(uint256).max);
        }
    }

    /// @notice Calculates total amount from amounts array
    /// @param _amounts Array of amounts to sum
    /// @return total_ Total amount
    function _calculateTotalAmount(uint256[] memory _amounts) private pure returns (uint256 total_) {
        if (_amounts.length == 0) revert NoAmountsSpecified();

        uint256 length_ = _amounts.length;
        for (uint256 i = 0; i < length_; i++) {
            total_ += _amounts[i];
        }
        return total_;
    }
}
