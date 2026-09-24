// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { VedaAdapter } from "./VedaAdapter.sol";
import { ComplianceVedaAdapter } from "./ComplianceVedaAdapter.sol";
import { IComplianceVedaTeller } from "./interfaces/IComplianceVedaTeller.sol";
import { IRolesAuthority } from "./interfaces/IRolesAuthority.sol";
import { Delegation, ModeCode } from "../utils/Types.sol";

/**
 * @title VaultMigrationHelper
 * @notice Atomically composes the existing base and premium Veda adapters, and moves premium shares with
 *         a compliance signature.
 * @dev Vault-to-vault migrations keep delegations targeted at the adapter that redeems them. Premium share
 *      transfers are redeemed by this helper: the chain must pin `transfer` `to` to this contract and name
 *      this contract as redeemer. This helper must hold `transferAllowedRole` on the premium Teller so Veda
 *      allows the first hop (helper is `to`) and the second hop (helper is `from`/`operator`).
 *
 *      Leaf Caveat Format:
 *      - For `premiumTransfer`, the first caveat of the leaf delegation (`_delegations[0].caveats[0]`) must
 *        follow the ERC20TransferAmountEnforcer terms format: abi.encodePacked(address token, uint256 amount)
 *        (52 bytes). This helper parses only the amount from these terms; the token address encoded in
 *        bytes 0–19 is consumed by the enforcer itself and is not read here. A delegation without this
 *        enforcer as the first caveat (or with an amount other than the owner's full premium balance)
 *        will revert.
 */
contract VaultMigrationHelper is Ownable2Step {
    using SafeERC20 for IERC20;

    /**
     * @notice Parameters for one base-to-premium migration.
     * @param withdrawalDelegations Delegation chain redeemed by the base adapter to withdraw base vault shares.
     * @param minimumAssets Minimum underlying assets that the base withdrawal must return.
     * @param depositDelegations Delegation chain redeemed by the premium adapter to deposit the withdrawn assets.
     * @param minimumMint Minimum premium vault shares that the destination deposit must mint.
     * @param compliance Compliance authorization forwarded unchanged to the premium adapter.
     */
    struct ToPremiumParams {
        Delegation[] withdrawalDelegations;
        uint256 minimumAssets;
        Delegation[] depositDelegations;
        uint256 minimumMint;
        IComplianceVedaTeller.ComplianceData compliance;
    }

    /**
     * @notice Parameters for one premium-to-base migration.
     * @param withdrawalDelegations Delegation chain redeemed by the premium adapter to withdraw premium shares.
     * @param minimumAssets Minimum underlying assets that the premium withdrawal must return.
     * @param depositDelegations Delegation chain redeemed by the base adapter to deposit the withdrawn assets.
     * @param minimumMint Minimum base vault shares that the destination deposit must mint.
     */
    struct ToBaseParams {
        Delegation[] withdrawalDelegations;
        uint256 minimumAssets;
        Delegation[] depositDelegations;
        uint256 minimumMint;
    }

    ////////////////////////////// Events //////////////////////////////

    /**
     * @notice Emitted after a base-to-premium migration completes.
     * @param delegator Root delegator whose vault position was migrated.
     * @param sourceShares Base vault shares withdrawn.
     * @param destShares Premium vault shares minted.
     */
    event MigrationToPremiumExecuted(address indexed delegator, uint256 sourceShares, uint256 destShares);

    /**
     * @notice Emitted after a premium-to-base migration completes.
     * @param delegator Root delegator whose vault position was migrated.
     * @param sourceShares Premium vault shares withdrawn.
     * @param destShares Base vault shares minted.
     */
    event MigrationToBaseExecuted(address indexed delegator, uint256 sourceShares, uint256 destShares);

    /**
     * @notice Emitted after a batch of base-to-premium migrations completes.
     * @param caller Address that submitted the permissionless batch.
     * @param count Number of migrations executed.
     */
    event BatchMigrationToPremiumExecuted(address indexed caller, uint256 count);

    /**
     * @notice Emitted after a batch of premium-to-base migrations completes.
     * @param caller Address that submitted the permissionless batch.
     * @param count Number of migrations executed.
     */
    event BatchMigrationToBaseExecuted(address indexed caller, uint256 count);

    /**
     * @notice Emitted after a compliance-gated premium share transfer.
     * @param from Share owner whose full premium balance was moved.
     * @param to Compliance-approved recipient.
     * @param amount Number of premium vault shares transferred.
     */
    event PremiumTransferExecuted(address indexed from, address indexed to, uint256 amount);

    /**
     * @notice Emitted when stuck tokens are withdrawn by owner.
     * @param token Address of the token withdrawn.
     * @param recipient Address of the recipient.
     * @param amount Amount of tokens withdrawn.
     */
    event StuckTokensWithdrawn(IERC20 indexed token, address indexed recipient, uint256 amount);

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Thrown when a required constructor address is zero.
    error InvalidZeroAddress();

    /// @dev Thrown when a zero address is provided for the recipient.
    error InvalidRecipient();

    /// @dev Thrown when either delegation chain contains fewer than two delegations.
    error InvalidDelegationsLength();

    /// @dev Thrown when a migration batch is empty.
    error InvalidBatchLength();

    /// @dev Thrown when the withdrawal and deposit chains have different root delegators.
    error DelegatorMismatch();

    /// @dev Thrown when the leaf caveat terms are shorter than 52 bytes.
    error InvalidTermsLength();

    /// @dev Thrown when the premium share balance is zero or does not match the leaf caveat amount.
    error InvalidTransferAmount();

    /// @dev Thrown when compliance signature verification fails.
    error ComplianceCheckFailed();

    /// @dev Thrown when the premium Teller has compliance signer checks disabled (`complianceSignerRole == 255`).
    error ComplianceDisabled();

    ////////////////////////////// State //////////////////////////////

    /**
     * @notice Base vault adapter used for base deposits and withdrawals.
     */
    VedaAdapter public immutable baseAdapter;

    /**
     * @notice Premium compliance-gated adapter used for premium deposits and withdrawals.
     */
    ComplianceVedaAdapter public immutable premiumAdapter;

    /**
     * @notice Compliance message hashes already consumed by `premiumTransfer`.
     */
    mapping(bytes32 messageHash => bool used) public usedComplianceSignatures;

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Initializes the helper with its owner and the base and premium Veda adapters.
     * @param _owner Address of the contract owner.
     * @param _baseAdapter Address of the base Veda adapter.
     * @param _premiumAdapter Address of the premium compliance-gated Veda adapter.
     */
    constructor(address _owner, address _baseAdapter, address _premiumAdapter) Ownable(_owner) {
        if (_baseAdapter == address(0) || _premiumAdapter == address(0)) {
            revert InvalidZeroAddress();
        }
        baseAdapter = VedaAdapter(_baseAdapter);
        premiumAdapter = ComplianceVedaAdapter(_premiumAdapter);
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Migrates one delegator from the base vault to the premium vault.
     * @dev The withdrawal chain is redeemed by `baseAdapter`; the deposit chain and compliance data are
     *      forwarded to `premiumAdapter`.
     * @param _params Withdrawal, deposit, slippage, and compliance parameters for the migration.
     * @notice Security consideration: Callable by anyone. Security remains enforced by the delegation chains,
     *      their caveats, and the premium Teller's compliance validation.
     */
    function migrateToPremiumByDelegation(ToPremiumParams calldata _params) external {
        _migrateToPremiumByDelegation(_params);
    }

    /**
     * @notice Migrates multiple delegators from base to premium sequentially in one atomic transaction.
     * @dev A revert from any withdrawal or deposit leg rolls back the entire batch.
     * @param _params Migration parameters for each stream.
     * @notice Security consideration: Callable by anyone. Every delegation chain remains independently enforced.
     */
    function migrateToPremiumByDelegationBatch(ToPremiumParams[] calldata _params) external {
        uint256 length_ = _params.length;
        if (length_ == 0) revert InvalidBatchLength();

        for (uint256 i = 0; i < length_;) {
            _migrateToPremiumByDelegation(_params[i]);
            unchecked {
                ++i;
            }
        }

        emit BatchMigrationToPremiumExecuted(msg.sender, length_);
    }

    /**
     * @notice Migrates one delegator from the premium vault to the base vault.
     * @dev The withdrawal chain is redeemed by `premiumAdapter`; the deposit chain is redeemed by `baseAdapter`.
     * @param _params Withdrawal, deposit, and slippage parameters for the migration.
     * @notice Security consideration: Callable by anyone. Security remains enforced by the delegation chains
     *      and their caveats.
     */
    function migrateToBaseByDelegation(ToBaseParams calldata _params) external {
        _migrateToBaseByDelegation(_params);
    }

    /**
     * @notice Migrates multiple delegators from premium to base sequentially in one atomic transaction.
     * @dev A revert from any withdrawal or deposit leg rolls back the entire batch.
     * @param _params Migration parameters for each stream.
     * @notice Security consideration: Callable by anyone. Every delegation chain remains independently enforced.
     */
    function migrateToBaseByDelegationBatch(ToBaseParams[] calldata _params) external {
        uint256 length_ = _params.length;
        if (length_ == 0) revert InvalidBatchLength();

        for (uint256 i = 0; i < length_;) {
            _migrateToBaseByDelegation(_params[i]);
            unchecked {
                ++i;
            }
        }

        emit BatchMigrationToBaseExecuted(msg.sender, length_);
    }

    /**
     * @notice Moves `from`'s entire premium vault balance to `to` after a compliance signature check.
     * @dev The delegation chain must be redeemable only by this helper and must pin `transfer` `to` to this
     *      helper. Production must grant this helper `transferAllowedRole` on the premium Teller.
     *      The transfer amount is parsed from the first caveat of the leaf delegation
     *      (`_delegations[0].caveats[0].terms`), which must follow the ERC20TransferAmountEnforcer
     *      format: abi.encodePacked(address token, uint256 amount).
     * @param _from Share owner and root delegator.
     * @param _to Compliance-approved recipient of the premium shares.
     * @param _delegations Chain sorted leaf to root. Leaf `delegate` must be this helper.
     * @param _compliance Backend-issued EIP-191 approval (`deadline` + `signature`).
     * @notice Security consideration: Callable by anyone. The compliance signature is bound to this helper,
     *      the premium Teller, `from`, `to`, the premium vault, the full share balance, and the deadline.
     *      A Teller deposit signature cannot be reused because it binds the Teller address, not this helper.
     *      The redelegation MUST include an `ERC20TransferAmountEnforcer` as its first caveat (`caveats[0]`),
     *      capped to exactly the owner's full premium balance. Reverts when Teller compliance is disabled.
     */
    function premiumTransfer(
        address _from,
        address _to,
        Delegation[] calldata _delegations,
        IComplianceVedaTeller.ComplianceData calldata _compliance
    )
        external
    {
        if (_from == address(0) || _to == address(0)) revert InvalidZeroAddress();

        uint256 length_ = _delegations.length;
        if (length_ < 2) revert InvalidDelegationsLength();
        if (_delegations[length_ - 1].delegator != _from) revert DelegatorMismatch();

        IERC20 vault_ = IERC20(premiumAdapter.boringVault());
        uint256 amount_ = vault_.balanceOf(_from);
        if (amount_ == 0 || amount_ != _parseERC20TransferTerms(_delegations[0].caveats[0].terms)) {
            revert InvalidTransferAmount();
        }

        _verifyTransferCompliance(_from, _to, address(vault_), amount_, _compliance);

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] =
            ExecutionLib.encodeSingle(address(vault_), 0, abi.encodeCall(IERC20.transfer, (address(this), amount_)));

        premiumAdapter.delegationManager().redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);
        vault_.safeTransfer(_to, amount_);

        emit PremiumTransferExecuted(_from, _to, amount_);
    }

    /**
     * @notice Emergency function to recover tokens accidentally sent to this contract.
     * @dev Migrations should not leave balances here. `premiumTransfer` only holds shares mid-transaction.
     *      This function is only for recovering tokens sent to this contract by mistake.
     * @param _token The token to be recovered.
     * @param _amount The amount of tokens to recover.
     * @param _recipient The address to receive the recovered tokens.
     */
    function withdrawEmergency(IERC20 _token, uint256 _amount, address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert InvalidRecipient();

        _token.safeTransfer(_recipient, _amount);

        emit StuckTokensWithdrawn(_token, _recipient, _amount);
    }

    ////////////////////////////// Private/Internal Methods //////////////////////////////

    /**
     * @notice Executes one base-to-premium migration.
     * @param _params Migration parameters forwarded to the base and premium adapters.
     */
    function _migrateToPremiumByDelegation(ToPremiumParams calldata _params) internal {
        address delegator_ = _validateDelegators(_params.withdrawalDelegations, _params.depositDelegations);
        IERC20 sourceVault_ = IERC20(baseAdapter.boringVault());
        IERC20 destVault_ = IERC20(premiumAdapter.boringVault());
        uint256 sourceBefore_ = sourceVault_.balanceOf(delegator_);
        uint256 destBefore_ = destVault_.balanceOf(delegator_);

        baseAdapter.withdrawByDelegation(_params.withdrawalDelegations, _params.minimumAssets);
        premiumAdapter.depositByDelegation(_params.depositDelegations, _params.minimumMint, _params.compliance);

        emit MigrationToPremiumExecuted(
            delegator_, sourceBefore_ - sourceVault_.balanceOf(delegator_), destVault_.balanceOf(delegator_) - destBefore_
        );
    }

    /**
     * @notice Executes one premium-to-base migration.
     * @param _params Migration parameters forwarded to the premium and base adapters.
     */
    function _migrateToBaseByDelegation(ToBaseParams calldata _params) internal {
        address delegator_ = _validateDelegators(_params.withdrawalDelegations, _params.depositDelegations);
        IERC20 sourceVault_ = IERC20(premiumAdapter.boringVault());
        IERC20 destVault_ = IERC20(baseAdapter.boringVault());
        uint256 sourceBefore_ = sourceVault_.balanceOf(delegator_);
        uint256 destBefore_ = destVault_.balanceOf(delegator_);

        premiumAdapter.withdrawByDelegation(_params.withdrawalDelegations, _params.minimumAssets);
        baseAdapter.depositByDelegation(_params.depositDelegations, _params.minimumMint);

        emit MigrationToBaseExecuted(
            delegator_, sourceBefore_ - sourceVault_.balanceOf(delegator_), destVault_.balanceOf(delegator_) - destBefore_
        );
    }

    /**
     * @notice Validates both delegation chains and returns their shared root delegator.
     * @param _withdrawalDelegations Source-vault withdrawal chain sorted from leaf to root.
     * @param _depositDelegations Destination-vault deposit chain sorted from leaf to root.
     * @return delegator_ Shared root delegator that owns both sides of the migration.
     */
    function _validateDelegators(
        Delegation[] calldata _withdrawalDelegations,
        Delegation[] calldata _depositDelegations
    )
        private
        pure
        returns (address delegator_)
    {
        uint256 withdrawalLength_ = _withdrawalDelegations.length;
        uint256 depositLength_ = _depositDelegations.length;
        if (withdrawalLength_ < 2 || depositLength_ < 2) revert InvalidDelegationsLength();

        delegator_ = _withdrawalDelegations[withdrawalLength_ - 1].delegator;
        if (delegator_ != _depositDelegations[depositLength_ - 1].delegator) revert DelegatorMismatch();
    }

    /**
     * @notice Parses the transfer amount from ERC20TransferAmountEnforcer terms.
     * @dev Terms format: abi.encodePacked(address token, uint256 amount) = 52 bytes.
     *      The token address (bytes 0–19) is validated by the enforcer itself and is not read here.
     *      Only the amount (bytes 20–51) is returned.
     */
    function _parseERC20TransferTerms(bytes calldata _terms) private pure returns (uint256 amount_) {
        if (_terms.length < 52) revert InvalidTermsLength();
        amount_ = uint256(bytes32(_terms[20:52]));
    }

    /**
     * @notice Verifies a transfer compliance signature using the Teller's signer role and window.
     * @dev The digest starts with this helper's address so it cannot equal a Teller deposit hash.
     *      Reverts if the Teller has disabled compliance (`complianceSignerRole == 255`).
     */
    function _verifyTransferCompliance(
        address _from,
        address _to,
        address _vault,
        uint256 _amount,
        IComplianceVedaTeller.ComplianceData calldata _compliance
    )
        private
    {
        IComplianceVedaTeller teller_ = premiumAdapter.teller();
        uint8 complianceSignerRole_ = teller_.complianceSignerRole();
        if (complianceSignerRole_ == type(uint8).max) revert ComplianceDisabled();

        bytes32 messageHash_ = keccak256(
            abi.encode(address(this), address(teller_), block.chainid, _from, _to, _vault, _amount, _compliance.deadline)
        );
        if (usedComplianceSignatures[messageHash_]) revert ComplianceCheckFailed();
        if (block.timestamp > _compliance.deadline) revert ComplianceCheckFailed();

        uint96 complianceWindow_ = teller_.complianceWindow();
        if (complianceWindow_ > 0 && _compliance.deadline > block.timestamp + complianceWindow_) {
            revert ComplianceCheckFailed();
        }

        bytes32 ethSignedHash_ = MessageHashUtils.toEthSignedMessageHash(messageHash_);
        address recovered_ = ECDSA.recover(ethSignedHash_, _compliance.signature);
        if (!IRolesAuthority(teller_.authority()).doesUserHaveRole(recovered_, complianceSignerRole_)) {
            revert ComplianceCheckFailed();
        }

        usedComplianceSignatures[messageHash_] = true;
    }
}
