// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { Delegation, ModeCode } from "../utils/Types.sol";
import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { IComplianceVedaTeller } from "./interfaces/IComplianceVedaTeller.sol";

/**
 * @title ComplianceVedaAdapter
 * @notice Adapter contract that enables compliance-gated Veda BoringVault deposit and withdrawal operations
 *         through MetaMask's delegation framework
 * @dev This contract acts as an intermediary between users and a compliance-enabled Veda Teller
 *      (`TellerWithMultiAssetSupport` Base V0.3 / `TellerWithYieldStreaming`), enabling delegation-based
 *      token operations without requiring direct token approvals from the user to the vault.
 *
 *      Architecture:
 *      - BoringVault: The ERC20 vault share token that also custodies assets. On deposit, the vault pulls
 *        tokens from the caller via `safeTransferFrom`, so this adapter must approve the BoringVault.
 *      - Teller: The contract that orchestrates deposits/withdrawals. Deposits use the struct-based
 *        `deposit(DepositParams, to, referral, ComplianceData)` selector. Withdrawals use
 *        `teller.withdraw()` on TellerWithYieldStreaming.
 *      - depositToken: The single ERC20 token used for both deposits and withdrawals. Fixed at construction;
 *        deposits transfer this token into the vault, and withdrawals redeem vault shares back to this token.
 *
 *      Compliance:
 *      - An off-chain backend verifies that the share recipient (`to`) is an approved account and produces
 *        an EIP-191 (`personal_sign`) signature. The Teller recovers the signer and checks that the signer
 *        holds the configured `complianceSignerRole` on the Teller's `RolesAuthority`.
 *      - The digest is `keccak256(abi.encode(teller, chainId, msg.sender, to, asset, amount, deadline))`,
 *        then prefixed with `"\x19Ethereum Signed Message:\n32"`. There is no separate nonce: replay
 *        protection is the Teller's `usedComplianceSignatures` map of that digest.
 *      - Because this adapter is `msg.sender` on the Teller call, the signature MUST bind this adapter as
 *        the caller and the root delegator as `to` (share recipient). A signature issued for a direct user
 *        deposit cannot be reused through this adapter.
 *      - When `allowlistedRouterRole` is enabled on the Teller, this adapter must hold that role so it can
 *        mint shares to `to != msg.sender`. Withdrawals are not compliance-gated.
 *
 *      Delegation Flow:
 *      1. The user creates an initial delegation to an "operator" address (a DeleGator-upgraded account).
 *         This delegation includes:
 *         - A transfer enforcer to control which tokens/shares and amounts can be transferred
 *         - A redeemer enforcer that restricts redemption to only the ComplianceVedaAdapter contract
 *
 *      2. The operator then redelegates to this ComplianceVedaAdapter contract with additional constraints:
 *         - Allowed methods enforcer limiting which functions can be called
 *         - Limited calls enforcer restricting the delegation to a single execution
 *
 *      3. For deposits: the adapter redeems the delegation chain, transfers tokens from the user to itself,
 *         and calls `teller.deposit(...)` with the caller-supplied `ComplianceData` to mint shares to the user.
 *         For withdrawals: the adapter redeems the delegation chain, transfers vault shares from the user
 *         to itself, and calls `teller.withdraw()` to burn shares and send `depositToken` assets to the user.
 *
 *      Requirements:
 *      - ComplianceVedaAdapter must approve the BoringVault to spend deposit tokens. The constructor sets
 *        this allowance to `type(uint256).max`, and the owner-only `ensureAllowance()` function
 *        can be used as a fail-safe to restore it to max if it were ever reduced.
 *
 *      Leaf Caveat Format:
 *      - The first caveat of the leaf delegation (`_delegations[0].caveats[0]`) must follow the
 *        ERC20TransferAmountEnforcer terms format: abi.encodePacked(address token, uint256 amount) (52 bytes).
 *        The adapter parses only the amount from these terms; the token address encoded in bytes 0–19 is
 *        consumed by the enforcer itself and is not read by this adapter.
 *
 * @notice Security consideration: Anyone can call `depositByDelegation` and `withdrawByDelegation` — there is no
 *      caller restriction. Security is enforced entirely through the delegation chain and, for deposits, the
 *      Teller's compliance check. The redelegation from the operator to this adapter MUST include an
 *      `ERC20TransferAmountEnforcer` caveat capped to exactly the intended deposit or withdrawal amount, and it
 *      MUST be the first caveat (`caveats[0]`) of that redelegation — the adapter reads the amount directly from
 *      `_delegations[0].caveats[0].terms`. Once that amount is transferred the enforcer's running total is
 *      exhausted and any replay attempt will revert, making the delegation effectively single-use. A delegation
 *      without this enforcer as the first caveat (or with an amount larger than intended) could be exploited by
 *      any caller to transfer more tokens than authorised. A valid compliance signature is additionally bound to
 *      this adapter, the recipient, the asset, the amount, and a deadline; it cannot be replayed after the Teller
 *      marks the digest as used.
 */
contract ComplianceVedaAdapter is Ownable2Step {
    using SafeERC20 for IERC20;
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    /**
     * @notice Parameters for a single deposit operation in a batch
     * @dev `compliance` is forwarded to the Teller unchanged. Each stream needs its own signature because
     *      the digest includes amount and deadline, and used signatures cannot be replayed.
     */
    struct DepositParams {
        Delegation[] delegations;
        uint256 minimumMint;
        IComplianceVedaTeller.ComplianceData compliance;
    }

    /**
     * @notice Parameters for a single withdrawal operation in a batch
     */
    struct WithdrawParams {
        Delegation[] delegations;
        uint256 minimumAssets;
    }

    ////////////////////////////// Events //////////////////////////////

    /**
     * @notice Emitted when a deposit operation is executed via delegation
     * @param delegator Address of the token owner (delegator)
     * @param token Address of the deposited token
     * @param amount Amount of tokens deposited
     * @param shares Amount of vault shares minted to the delegator
     */
    event DepositExecuted(address indexed delegator, address indexed token, uint256 amount, uint256 shares);

    /**
     * @notice Emitted when a withdrawal operation is executed via delegation
     * @param delegator Address of the share owner (delegator)
     * @param token Address of the underlying token withdrawn (always `depositToken`)
     * @param shareAmount Amount of vault shares burned
     * @param assetsOut Amount of underlying tokens sent to the delegator
     */
    event WithdrawExecuted(address indexed delegator, address indexed token, uint256 shareAmount, uint256 assetsOut);

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

    /// @dev Thrown when the leaf caveat terms are shorter than 52 bytes (ERC20TransferAmountEnforcer format)
    error InvalidTermsLength();

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
     * @notice The compliance-gated Teller contract for deposit and withdrawal operations
     */
    IComplianceVedaTeller public immutable teller;

    /**
     * @notice The ERC20 token used for all deposits and withdrawals
     * @dev Fixed at construction. Deposits transfer this token into the vault; withdrawals redeem vault
     *      shares back to this token.
     */
    IERC20 public immutable depositToken;

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Initializes the adapter with delegation manager, BoringVault, Teller, and deposit token addresses
     * @param _owner Address of the contract owner
     * @param _delegationManager Address of the delegation manager contract
     * @param _boringVault Address of the BoringVault (token approval target)
     * @param _teller Address of the compliance-gated Teller contract (deposit entry point)
     * @param _depositToken Address of the ERC20 token used for all deposits and withdrawals
     */
    constructor(
        address _owner,
        address _delegationManager,
        address _boringVault,
        address _teller,
        address _depositToken
    )
        Ownable(_owner)
    {
        if (_delegationManager == address(0) || _boringVault == address(0) || _teller == address(0) || _depositToken == address(0))
        {
            revert InvalidZeroAddress();
        }

        delegationManager = IDelegationManager(_delegationManager);
        boringVault = _boringVault;
        teller = IComplianceVedaTeller(_teller);
        depositToken = IERC20(_depositToken);

        // Approve BoringVault to pull tokens
        depositToken.forceApprove(boringVault, type(uint256).max);
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Deposits tokens into a Veda BoringVault using delegation-based token transfer
     * @dev Redeems the delegation to transfer `depositToken` from the user to this adapter, then calls deposit
     *      on the Teller which mints vault shares directly to the original token owner.
     *      Requires at least 2 delegations forming a chain from user to operator to this adapter.
     *      The deposit amount is parsed from the first caveat of the leaf delegation
     *      (`_delegations[0].caveats[0].terms`), which must follow the ERC20TransferAmountEnforcer
     *      format: abi.encodePacked(address token, uint256 amount).
     *      `_compliance` is forwarded as-is. The Teller verifies deadline, EIP-191 signature, signer role,
     *      and unused digest. The signed `msg.sender` field must be this adapter and `to` must be the
     *      root delegator.
     * @param _delegations Array of Delegation objects, sorted leaf to root
     * @param _minimumMint Minimum vault shares the caller expects to receive, used as a sanity-check
     *      bound. The Veda vault conversion is always at fair value; rate drift from yield streaming
     *      is negligible. A tolerance of 0.1-0.5% is recommended. If this check causes a revert,
     *      no funds are lost — retry with a fresh quote.
     * @param _compliance Backend-issued compliance approval (`deadline` + `signature`) for this deposit
     * @notice Security consideration: Callable by anyone. The redelegation passed in MUST include an
     *      `ERC20TransferAmountEnforcer` as its first caveat (`caveats[0]`), capped to exactly the intended
     *      deposit amount, to prevent over-spending or replay.
     */
    function depositByDelegation(
        Delegation[] calldata _delegations,
        uint256 _minimumMint,
        IComplianceVedaTeller.ComplianceData calldata _compliance
    )
        external
    {
        _executeDepositByDelegation(_delegations, _minimumMint, _compliance);
    }

    /**
     * @notice Deposits tokens using multiple delegation streams, executed sequentially
     * @dev Each element is executed one after the other. The amount for each stream is parsed
     *      from the first caveat of each stream's leaf delegation. Each stream must carry its own
     *      `ComplianceData`; a signature cannot be reused across streams.
     * @param _depositStreams Array of deposit parameters
     * @notice Security consideration: Callable by anyone. Each redelegation in the batch MUST include an
     *      `ERC20TransferAmountEnforcer` as its first caveat (`caveats[0]`), capped to exactly the intended
     *      deposit amount, to prevent over-spending or replay.
     */
    function depositByDelegationBatch(DepositParams[] calldata _depositStreams) external {
        uint256 streamsLength_ = _depositStreams.length;
        if (streamsLength_ == 0) revert InvalidBatchLength();

        for (uint256 i = 0; i < streamsLength_;) {
            DepositParams calldata params_ = _depositStreams[i];
            _executeDepositByDelegation(params_.delegations, params_.minimumMint, params_.compliance);
            unchecked {
                ++i;
            }
        }

        emit BatchDepositExecuted(msg.sender, streamsLength_);
    }

    /**
     * @notice Withdraws `depositToken` from a Veda BoringVault using delegation-based share transfer
     * @dev Redeems the delegation to transfer vault shares to this adapter, then calls withdraw
     *      on the Teller which burns shares and sends `depositToken` assets directly to the original share owner.
     *      Requires at least 2 delegations forming a chain from user to operator to this adapter.
     *      The share amount is parsed from the first caveat of the leaf delegation
     *      (`_delegations[0].caveats[0].terms`), which must follow the ERC20TransferAmountEnforcer
     *      format: abi.encodePacked(address boringVault, uint256 shareAmount).
     *      Withdrawals are not compliance-gated by the Teller.
     * @param _delegations Array of Delegation objects, sorted leaf to root
     * @param _minimumAssets Minimum underlying assets the caller expects to receive, used as a
     *      sanity-check bound. The Veda vault conversion is always at fair value; rate drift from
     *      yield streaming is negligible. A tolerance of 0.1-0.5% is recommended. If this check
     *      causes a revert, no funds are lost — retry with a fresh quote.
     * @notice Security consideration: Callable by anyone. The redelegation passed in MUST include an
     *      `ERC20TransferAmountEnforcer` as its first caveat (`caveats[0]`), capped to exactly the intended
     *      share amount, to prevent over-spending or replay.
     */
    function withdrawByDelegation(Delegation[] calldata _delegations, uint256 _minimumAssets) external {
        _executeWithdrawByDelegation(_delegations, _minimumAssets);
    }

    /**
     * @notice Withdraws `depositToken` using multiple delegation streams, executed sequentially
     * @dev Each element is executed one after the other. The share amount for each stream is parsed
     *      from the first caveat of each stream's leaf delegation.
     * @param _withdrawStreams Array of withdraw parameters
     * @notice Security consideration: Callable by anyone. Each redelegation in the batch MUST include an
     *      `ERC20TransferAmountEnforcer` as its first caveat (`caveats[0]`), capped to exactly the intended
     *      share amount, to prevent over-spending or replay.
     */
    function withdrawByDelegationBatch(WithdrawParams[] calldata _withdrawStreams) external {
        uint256 streamsLength_ = _withdrawStreams.length;
        if (streamsLength_ == 0) revert InvalidBatchLength();

        for (uint256 i = 0; i < streamsLength_;) {
            WithdrawParams calldata params_ = _withdrawStreams[i];
            _executeWithdrawByDelegation(params_.delegations, params_.minimumAssets);
            unchecked {
                ++i;
            }
        }

        emit BatchWithdrawExecuted(msg.sender, streamsLength_);
    }

    /**
     * @notice Emergency function to recover tokens accidentally sent to this contract
     * @dev This contract should never hold ERC20 tokens as all token operations are handled
     *      through delegation-based transfers that move tokens directly between users and the BoringVault.
     *      This function is only for recovering tokens sent to this contract by mistake.
     *      Recommended delegation: restrict this owner action by token, recipient, amount, and call count.
     * @param _token The token to be recovered
     * @param _amount The amount of tokens to recover
     * @param _recipient The address to receive the recovered tokens
     */
    function withdrawEmergency(IERC20 _token, uint256 _amount, address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert InvalidRecipient();

        _token.safeTransfer(_recipient, _amount);

        emit StuckTokensWithdrawn(_token, _recipient, _amount);
    }

    /**
     * @notice Resets the deposit token allowance for the BoringVault to `type(uint256).max`
     * @dev Fail-safe function. The constructor already sets the allowance to `type(uint256).max`
     *      the allowance should realistically never be exhausted. This function exists only as a
     *      defensive measure. The owner can restore it to max.
     *      Recommended delegation: allow only this selector and limit it to one call.
     */
    function ensureAllowance() external onlyOwner {
        depositToken.forceApprove(boringVault, type(uint256).max);
    }

    ////////////////////////////// Private/Internal Methods //////////////////////////////

    /**
     * @notice Parses the transfer amount from ERC20TransferAmountEnforcer terms
     * @dev Terms format: abi.encodePacked(address token, uint256 amount) = 52 bytes.
     *      The token address (bytes 0–19) is validated by the enforcer itself and is not read here.
     *      Only the amount (bytes 20–51) is returned.
     * @param _terms The raw terms bytes from a caveat
     * @return amount_ The uint256 amount encoded in bytes 20-51
     */
    function _parseERC20TransferTerms(bytes calldata _terms) private pure returns (uint256 amount_) {
        if (_terms.length < 52) revert InvalidTermsLength();
        amount_ = uint256(bytes32(_terms[20:52]));
    }

    /**
     * @notice Internal implementation of deposit by delegation
     * @dev Parses the deposit amount from the first caveat of the leaf delegation
     *      via `_parseERC20TransferTerms`. Uses `depositToken` as the transfer token.
     *      Forwards `_compliance` to the Teller; this adapter is `msg.sender` and `to` is the root delegator.
     * @param _delegations Delegation chain, sorted leaf to root
     * @param _minimumMint Minimum vault shares expected (sanity-check bound)
     * @param _compliance Backend-issued compliance approval for this deposit
     */
    function _executeDepositByDelegation(
        Delegation[] calldata _delegations,
        uint256 _minimumMint,
        IComplianceVedaTeller.ComplianceData calldata _compliance
    )
        internal
    {
        uint256 length_ = _delegations.length;
        if (length_ < 2) revert InvalidDelegationsLength();

        uint256 amount_ = _parseERC20TransferTerms(_delegations[0].caveats[0].terms);
        address rootDelegator_ = _delegations[length_ - 1].delegator;

        // Redeem delegation: transfer tokens from user to this adapter
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] =
            ExecutionLib.encodeSingle(address(depositToken), 0, abi.encodeCall(IERC20.transfer, (address(this), amount_)));

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        // Deposit into Teller: pulls depositToken from this adapter, mints shares to root delegator
        uint256 shares_ = teller.deposit(
            IComplianceVedaTeller.DepositParams({
                depositAsset: address(depositToken), depositAmount: amount_, minimumMint: _minimumMint
            }),
            rootDelegator_,
            address(0),
            _compliance
        );

        emit DepositExecuted(rootDelegator_, address(depositToken), amount_, shares_);
    }

    /**
     * @notice Internal implementation of withdraw by delegation
     * @dev Parses the share amount from the first caveat of the leaf delegation
     *      via `_parseERC20TransferTerms`. Redeems vault shares and sends `depositToken` to the root delegator.
     * @param _delegations Delegation chain, sorted leaf to root
     * @param _minimumAssets Minimum underlying assets expected (sanity-check bound)
     */
    function _executeWithdrawByDelegation(Delegation[] calldata _delegations, uint256 _minimumAssets) internal {
        uint256 length_ = _delegations.length;
        if (length_ < 2) revert InvalidDelegationsLength();

        uint256 shareAmount_ = _parseERC20TransferTerms(_delegations[0].caveats[0].terms);
        address rootDelegator_ = _delegations[length_ - 1].delegator;

        // Redeem delegation: transfer vault shares from user to this adapter
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] =
            ExecutionLib.encodeSingle(boringVault, 0, abi.encodeCall(IERC20.transfer, (address(this), shareAmount_)));

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        // Withdraw from Teller: burns shares from this adapter, sends depositToken to root delegator
        uint256 assetsOut_ = teller.withdraw(address(depositToken), shareAmount_, _minimumAssets, rootDelegator_);

        emit WithdrawExecuted(rootDelegator_, address(depositToken), shareAmount_, assetsOut_);
    }
}
