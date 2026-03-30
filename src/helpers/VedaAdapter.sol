// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { Delegation, ModeCode } from "../utils/Types.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { IVedaTeller } from "./interfaces/IVedaTeller.sol";

/**
 * @title VedaAdapter
 * @notice Adapter contract that enables Veda BoringVault deposit and withdrawal operations through MetaMask's
 *         delegation framework
 * @dev This contract acts as an intermediary between users and Veda's BoringVault, enabling delegation-based
 *      token operations without requiring direct token approvals.
 *
 *      Architecture:
 *      - BoringVault: The ERC20 vault share token that also custodies assets. On deposit, the vault pulls
 *        tokens from the caller via `safeTransferFrom`, so this adapter must approve the BoringVault.
 *      - Teller: The contract that orchestrates deposits/withdrawals. The adapter calls `teller.deposit()`
 *        for deposits and `teller.withdraw()` for withdrawals (user-facing, no special
 *        role needed).
 *
 *      Delegation Flow:
 *      1. The user creates an initial delegation to an "operator" address (a DeleGator-upgraded account).
 *         This delegation includes:
 *         - A transfer enforcer to control which tokens/shares and amounts can be transferred
 *         - A redeemer enforcer that restricts redemption to only the VedaAdapter contract
 *
 *      2. The operator then redelegates to this VedaAdapter contract with additional constraints:
 *         - Allowed methods enforcer limiting which functions can be called
 *         - Limited calls enforcer restricting the delegation to a single execution
 *
 *      3. For deposits: the adapter redeems the delegation chain, transfers tokens from the user to itself,
 *         approves the BoringVault, and calls `teller.deposit()` to mint shares to the user.
 *         For withdrawals: the adapter redeems the delegation chain, transfers vault shares from the user
 *         to itself, and calls `teller.withdraw()` to burn shares and send underlying assets to the user.
 *
 *      Requirements:
 *      - VedaAdapter must approve the BoringVault to spend deposit tokens
 */
contract VedaAdapter is Ownable2Step {
    using SafeERC20 for IERC20;
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    /**
     * @notice Parameters for a single deposit operation in a batch
     */
    struct DepositParams {
        Delegation[] delegations;
        address token;
        uint256 amount;
        uint256 minimumMint;
    }

    /**
     * @notice Parameters for a single withdrawal operation in a batch
     */
    struct WithdrawParams {
        Delegation[] delegations;
        address token;
        uint256 shareAmount;
        uint256 minimumAssets;
    }

    ////////////////////////////// Events //////////////////////////////

    /**
     * @notice Emitted when a deposit operation is executed via delegation
     * @param delegator Address of the token owner (delegator)
     * @param delegate Address of the executor (delegate)
     * @param token Address of the deposited token
     * @param amount Amount of tokens deposited
     * @param shares Amount of vault shares minted to the delegator
     */
    event DepositExecuted(
        address indexed delegator, address indexed delegate, address indexed token, uint256 amount, uint256 shares
    );

    /**
     * @notice Emitted when a withdrawal operation is executed via delegation
     * @param delegator Address of the share owner (delegator)
     * @param delegate Address of the executor (delegate)
     * @param token Address of the underlying token withdrawn
     * @param shareAmount Amount of vault shares burned
     * @param assetsOut Amount of underlying tokens sent to the delegator
     */
    event WithdrawExecuted(
        address indexed delegator, address indexed delegate, address indexed token, uint256 shareAmount, uint256 assetsOut
    );

    /**
     * @notice Emitted when a batch deposit is completed
     * @param caller Address of the batch executor
     * @param count Number of deposit streams executed
     */
    event BatchDepositExecuted(address indexed caller, uint256 count);

    /**
     * @notice Emitted when a batch withdrawal is completed
     * @param caller Address of the batch executor
     * @param count Number of withdrawal streams executed
     */
    event BatchWithdrawExecuted(address indexed caller, uint256 count);

    /**
     * @notice Emitted when stuck tokens are withdrawn by owner
     * @param token Address of the token withdrawn
     * @param recipient Address of the recipient
     * @param amount Amount of tokens withdrawn
     */
    event StuckTokensWithdrawn(IERC20 indexed token, address indexed recipient, uint256 amount);

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Thrown when a zero address is provided for required parameters
    error InvalidZeroAddress();

    /// @dev Thrown when a zero address is provided for the recipient
    error InvalidRecipient();

    /// @dev Thrown when the delegation chain has fewer than 2 delegations
    error InvalidDelegationsLength();

    /// @dev Thrown when the batch array is empty
    error InvalidBatchLength();

    /// @dev Thrown when msg.sender is not the leaf delegator
    error NotLeafDelegator();

    ////////////////////////////// State //////////////////////////////

    /**
     * @notice The DelegationManager contract used to redeem delegations
     */
    IDelegationManager public immutable delegationManager;

    /**
     * @notice The BoringVault contract (approval target for token transfers)
     */
    address public immutable boringVault;

    /**
     * @notice The Teller contract for deposit and withdrawal operations
     */
    IVedaTeller public immutable teller;

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Initializes the adapter with delegation manager, BoringVault, and Teller addresses
     * @param _owner Address of the contract owner
     * @param _delegationManager Address of the delegation manager contract
     * @param _boringVault Address of the BoringVault (token approval target)
     * @param _teller Address of the Teller contract (deposit entry point)
     */
    constructor(address _owner, address _delegationManager, address _boringVault, address _teller) Ownable(_owner) {
        if (_delegationManager == address(0) || _boringVault == address(0) || _teller == address(0)) {
            revert InvalidZeroAddress();
        }

        delegationManager = IDelegationManager(_delegationManager);
        boringVault = _boringVault;
        teller = IVedaTeller(_teller);
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Deposits tokens into a Veda BoringVault using delegation-based token transfer
     * @dev Redeems the delegation to transfer tokens to this adapter, then calls deposit
     *      on the Teller which mints vault shares directly to the original token owner.
     *      Requires at least 2 delegations forming a chain from user to operator to this adapter.
     * @param _delegations Array of Delegation objects, sorted leaf to root
     * @param _token Address of the token to deposit
     * @param _amount Amount of tokens to deposit
     * @param _minimumMint Minimum vault shares the user expects to receive (slippage protection)
     */
    function depositByDelegation(Delegation[] memory _delegations, address _token, uint256 _amount, uint256 _minimumMint) external {
        _executeDepositByDelegation(_delegations, _token, _amount, _minimumMint, msg.sender);
    }

    /**
     * @notice Deposits tokens using multiple delegation streams, executed sequentially
     * @dev Each element is executed one after the other. The caller must be the delegator
     *      (first delegate in the chain) for each stream.
     * @param _depositStreams Array of deposit parameters
     */
    function depositByDelegationBatch(DepositParams[] memory _depositStreams) external {
        uint256 streamsLength_ = _depositStreams.length;
        if (streamsLength_ == 0) revert InvalidBatchLength();

        address caller_ = msg.sender;
        for (uint256 i = 0; i < streamsLength_;) {
            DepositParams memory params_ = _depositStreams[i];
            _executeDepositByDelegation(params_.delegations, params_.token, params_.amount, params_.minimumMint, caller_);
            unchecked {
                ++i;
            }
        }

        emit BatchDepositExecuted(caller_, streamsLength_);
    }

    /**
     * @notice Withdraws underlying tokens from a Veda BoringVault using delegation-based share transfer
     * @dev Redeems the delegation to transfer vault shares to this adapter, then calls withdraw
     *      on the Teller which burns shares and sends underlying assets directly to the original share owner.
     *      Requires at least 2 delegations forming a chain from user to operator to this adapter.
     * @param _delegations Array of Delegation objects, sorted leaf to root
     * @param _token Address of the underlying token to receive
     * @param _shareAmount Amount of vault shares to redeem
     * @param _minimumAssets Minimum underlying assets the user expects to receive (slippage protection)
     */
    function withdrawByDelegation(
        Delegation[] memory _delegations,
        address _token,
        uint256 _shareAmount,
        uint256 _minimumAssets
    )
        external
    {
        _executeWithdrawByDelegation(_delegations, _token, _shareAmount, _minimumAssets, msg.sender);
    }

    /**
     * @notice Withdraws underlying tokens using multiple delegation streams, executed sequentially
     * @dev Each element is executed one after the other. The caller must be the delegator
     *      (first delegate in the chain) for each stream.
     * @param _withdrawStreams Array of withdraw parameters
     */
    function withdrawByDelegationBatch(WithdrawParams[] memory _withdrawStreams) external {
        uint256 streamsLength_ = _withdrawStreams.length;
        if (streamsLength_ == 0) revert InvalidBatchLength();

        address caller_ = msg.sender;
        for (uint256 i = 0; i < streamsLength_;) {
            WithdrawParams memory params_ = _withdrawStreams[i];
            _executeWithdrawByDelegation(params_.delegations, params_.token, params_.shareAmount, params_.minimumAssets, caller_);
            unchecked {
                ++i;
            }
        }

        emit BatchWithdrawExecuted(caller_, streamsLength_);
    }

    /**
     * @notice Emergency function to recover tokens accidentally sent to this contract
     * @dev This contract should never hold ERC20 tokens as all token operations are handled
     *      through delegation-based transfers that move tokens directly between users and the BoringVault.
     *      This function is only for recovering tokens sent to this contract by mistake.
     * @param _token The token to be recovered
     * @param _amount The amount of tokens to recover
     * @param _recipient The address to receive the recovered tokens
     */
    function withdrawEmergency(IERC20 _token, uint256 _amount, address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert InvalidRecipient();

        _token.safeTransfer(_recipient, _amount);

        emit StuckTokensWithdrawn(_token, _recipient, _amount);
    }

    ////////////////////////////// Private/Internal Methods //////////////////////////////

    /**
     * @notice Ensures sufficient token allowance for a spender to pull tokens
     * @dev Checks current allowance and sets exact amount if insufficient, avoiding accumulation
     * @param _token Token to manage allowance for
     * @param _spender Address that needs to spend the tokens
     * @param _amount Amount needed for the operation
     */
    function _ensureAllowance(IERC20 _token, address _spender, uint256 _amount) private {
        uint256 allowance_ = _token.allowance(address(this), _spender);
        if (allowance_ < _amount) {
            _token.forceApprove(_spender, _amount);
        }
    }

    /**
     * @notice Internal implementation of deposit by delegation
     * @param _delegations Delegation chain, sorted leaf to root
     * @param _token Token to deposit
     * @param _amount Amount to deposit
     * @param _minimumMint Minimum vault shares expected
     * @param _caller Authorized caller (must match leaf delegator)
     */
    function _executeDepositByDelegation(
        Delegation[] memory _delegations,
        address _token,
        uint256 _amount,
        uint256 _minimumMint,
        address _caller
    )
        internal
    {
        uint256 length_ = _delegations.length;
        if (length_ < 2) revert InvalidDelegationsLength();
        if (_delegations[0].delegator != _caller) revert NotLeafDelegator();
        if (_token == address(0)) revert InvalidZeroAddress();

        address rootDelegator_ = _delegations[length_ - 1].delegator;

        // Redeem delegation: transfer tokens from user to this adapter
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);
        bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), _amount));
        executionCallDatas_[0] = ExecutionLib.encodeSingle(_token, 0, encodedTransfer_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        // Approve BoringVault to pull tokens, then deposit via Teller
        _ensureAllowance(IERC20(_token), boringVault, _amount);
        uint256 shares_ = teller.deposit(_token, _amount, _minimumMint, rootDelegator_, address(0));

        emit DepositExecuted(rootDelegator_, _caller, _token, _amount, shares_);
    }

    /**
     * @notice Internal implementation of withdraw by delegation
     * @param _delegations Delegation chain, sorted leaf to root
     * @param _token Underlying token to receive
     * @param _shareAmount Amount of vault shares to redeem
     * @param _minimumAssets Minimum underlying assets expected
     * @param _caller Authorized caller (must match leaf delegator)
     */
    function _executeWithdrawByDelegation(
        Delegation[] memory _delegations,
        address _token,
        uint256 _shareAmount,
        uint256 _minimumAssets,
        address _caller
    )
        internal
    {
        uint256 length_ = _delegations.length;
        if (length_ < 2) revert InvalidDelegationsLength();
        if (_delegations[0].delegator != _caller) revert NotLeafDelegator();
        if (_token == address(0)) revert InvalidZeroAddress();

        address rootDelegator_ = _delegations[length_ - 1].delegator;

        // Redeem delegation: transfer vault shares from user to this adapter
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);
        bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), _shareAmount));
        executionCallDatas_[0] = ExecutionLib.encodeSingle(boringVault, 0, encodedTransfer_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        // Withdraw from Teller: burns shares from this adapter, sends underlying to root delegator
        uint256 assetsOut_ = teller.withdraw(_token, _shareAmount, _minimumAssets, rootDelegator_);

        emit WithdrawExecuted(rootDelegator_, _caller, _token, _shareAmount, assetsOut_);
    }
}
