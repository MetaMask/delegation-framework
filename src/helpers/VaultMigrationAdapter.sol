// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IComplianceVedaTeller } from "./interfaces/IComplianceVedaTeller.sol";
import { Delegation } from "../utils/Types.sol";

/**
 * @title IVedaAdapter
 * @notice Minimal interface for the base Veda adapter methods used during migrations.
 */
interface IVedaAdapter {
    /**
     * @notice Deposits assets through a delegation chain.
     * @param delegations Delegation chain sorted from leaf to root.
     * @param minimumMint Minimum number of vault shares that must be minted.
     */
    function depositByDelegation(Delegation[] calldata delegations, uint256 minimumMint) external;

    /**
     * @notice Withdraws assets through a delegation chain.
     * @param delegations Delegation chain sorted from leaf to root.
     * @param minimumAssets Minimum number of underlying assets that must be returned.
     */
    function withdrawByDelegation(Delegation[] calldata delegations, uint256 minimumAssets) external;
}

/**
 * @title IComplianceVedaAdapter
 * @notice Minimal interface for the premium compliance-gated Veda adapter methods used during migrations.
 */
interface IComplianceVedaAdapter {
    /**
     * @notice Deposits assets through a delegation chain with compliance authorization.
     * @param delegations Delegation chain sorted from leaf to root.
     * @param minimumMint Minimum number of premium vault shares that must be minted.
     * @param compliance Compliance authorization forwarded unchanged to the premium adapter.
     */
    function depositByDelegation(
        Delegation[] calldata delegations,
        uint256 minimumMint,
        IComplianceVedaTeller.ComplianceData calldata compliance
    )
        external;

    /**
     * @notice Withdraws assets through a delegation chain.
     * @param delegations Delegation chain sorted from leaf to root.
     * @param minimumAssets Minimum number of underlying assets that must be returned.
     */
    function withdrawByDelegation(Delegation[] calldata delegations, uint256 minimumAssets) external;
}

/**
 * @title VaultMigrationAdapter
 * @notice Atomically composes the existing base and premium Veda adapters.
 * @dev Delegations remain targeted at the adapter that redeems them. This contract never redeems a delegation
 *      or holds migration assets: the source adapter sends assets to the root delegator and the destination
 *      adapter pulls those assets from the same root delegator. If either leg reverts, the entire migration
 *      transaction (and every preceding item in a batch) is rolled back.
 */
contract VaultMigrationAdapter is Ownable2Step {
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
     * @param minimumAssets Minimum asset bound supplied to the withdrawal leg.
     * @param minimumMint Minimum share bound supplied to the deposit leg.
     */
    event MigrationToPremiumExecuted(address indexed delegator, uint256 minimumAssets, uint256 minimumMint);

    /**
     * @notice Emitted after a premium-to-base migration completes.
     * @param delegator Root delegator whose vault position was migrated.
     * @param minimumAssets Minimum asset bound supplied to the withdrawal leg.
     * @param minimumMint Minimum share bound supplied to the deposit leg.
     */
    event MigrationToBaseExecuted(address indexed delegator, uint256 minimumAssets, uint256 minimumMint);

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

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Thrown when a required constructor address is zero.
    error InvalidZeroAddress();

    /// @dev Thrown when either delegation chain contains fewer than two delegations.
    error InvalidDelegationsLength();

    /// @dev Thrown when a migration batch is empty.
    error InvalidBatchLength();

    /// @dev Thrown when the withdrawal and deposit chains have different root delegators.
    error DelegatorMismatch();

    ////////////////////////////// State //////////////////////////////

    /**
     * @notice Base vault adapter used for base deposits and withdrawals.
     */
    IVedaAdapter public immutable baseAdapter;

    /**
     * @notice Premium compliance-gated adapter used for premium deposits and withdrawals.
     */
    IComplianceVedaAdapter public immutable premiumAdapter;

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Initializes the atomic migration composer.
     * @param _owner Address that owns this contract through Ownable2Step.
     * @param _baseAdapter Address of the base Veda adapter.
     * @param _premiumAdapter Address of the premium compliance-gated Veda adapter.
     */
    constructor(address _owner, address _baseAdapter, address _premiumAdapter) Ownable(_owner) {
        if (_owner == address(0) || _baseAdapter == address(0) || _premiumAdapter == address(0)) {
            revert InvalidZeroAddress();
        }
        baseAdapter = IVedaAdapter(_baseAdapter);
        premiumAdapter = IComplianceVedaAdapter(_premiumAdapter);
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

    ////////////////////////////// Private/Internal Methods //////////////////////////////

    /**
     * @notice Executes one base-to-premium migration.
     * @param _params Migration parameters forwarded to the base and premium adapters.
     */
    function _migrateToPremiumByDelegation(ToPremiumParams calldata _params) internal {
        address delegator_ = _validateDelegators(_params.withdrawalDelegations, _params.depositDelegations);

        baseAdapter.withdrawByDelegation(_params.withdrawalDelegations, _params.minimumAssets);
        premiumAdapter.depositByDelegation(_params.depositDelegations, _params.minimumMint, _params.compliance);

        emit MigrationToPremiumExecuted(delegator_, _params.minimumAssets, _params.minimumMint);
    }

    /**
     * @notice Executes one premium-to-base migration.
     * @param _params Migration parameters forwarded to the premium and base adapters.
     */
    function _migrateToBaseByDelegation(ToBaseParams calldata _params) internal {
        address delegator_ = _validateDelegators(_params.withdrawalDelegations, _params.depositDelegations);

        premiumAdapter.withdrawByDelegation(_params.withdrawalDelegations, _params.minimumAssets);
        baseAdapter.depositByDelegation(_params.depositDelegations, _params.minimumMint);

        emit MigrationToBaseExecuted(delegator_, _params.minimumAssets, _params.minimumMint);
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
}
