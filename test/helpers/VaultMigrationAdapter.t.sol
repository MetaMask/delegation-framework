// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";

import { IComplianceVedaAdapter, IVedaAdapter, VaultMigrationAdapter } from "../../src/helpers/VaultMigrationAdapter.sol";
import { IComplianceVedaTeller } from "../../src/helpers/interfaces/IComplianceVedaTeller.sol";
import { Caveat, Delegation } from "../../src/utils/Types.sol";

contract MockVedaAdapter is IVedaAdapter, IComplianceVedaAdapter {
    uint256 public depositCalls;
    uint256 public withdrawalCalls;
    uint256 public lastMinimumMint;
    uint256 public lastMinimumAssets;
    uint256 public lastDepositDelegationsLength;
    uint256 public lastWithdrawalDelegationsLength;
    uint256 public lastComplianceDeadline;
    bytes32 public lastComplianceSignatureHash;
    bool public revertDeposit;
    MockVedaAdapter public requiredWithdrawalAdapter;

    error DepositFailed();
    error WithdrawalDidNotRunFirst();

    function setRevertDeposit(bool _revertDeposit) external {
        revertDeposit = _revertDeposit;
    }

    function setRequiredWithdrawalAdapter(MockVedaAdapter _adapter) external {
        requiredWithdrawalAdapter = _adapter;
    }

    function depositByDelegation(Delegation[] calldata _delegations, uint256 _minimumMint) external override {
        _recordDeposit(_delegations, _minimumMint);
    }

    function depositByDelegation(
        Delegation[] calldata _delegations,
        uint256 _minimumMint,
        IComplianceVedaTeller.ComplianceData calldata _compliance
    )
        external
        override
    {
        lastComplianceDeadline = _compliance.deadline;
        lastComplianceSignatureHash = keccak256(_compliance.signature);
        _recordDeposit(_delegations, _minimumMint);
    }

    function withdrawByDelegation(
        Delegation[] calldata _delegations,
        uint256 _minimumAssets
    )
        external
        override(IVedaAdapter, IComplianceVedaAdapter)
    {
        ++withdrawalCalls;
        lastMinimumAssets = _minimumAssets;
        lastWithdrawalDelegationsLength = _delegations.length;
    }

    function _recordDeposit(Delegation[] calldata _delegations, uint256 _minimumMint) private {
        if (revertDeposit) revert DepositFailed();
        if (address(requiredWithdrawalAdapter) != address(0) && requiredWithdrawalAdapter.withdrawalCalls() == 0) {
            revert WithdrawalDidNotRunFirst();
        }
        ++depositCalls;
        lastMinimumMint = _minimumMint;
        lastDepositDelegationsLength = _delegations.length;
    }
}

contract VaultMigrationAdapterTest is Test {
    event MigrationToPremiumExecuted(address indexed delegator, uint256 minimumAssets, uint256 minimumMint);
    event MigrationToBaseExecuted(address indexed delegator, uint256 minimumAssets, uint256 minimumMint);
    event BatchMigrationToPremiumExecuted(address indexed caller, uint256 count);
    event BatchMigrationToBaseExecuted(address indexed caller, uint256 count);

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MockVedaAdapter internal baseAdapter;
    MockVedaAdapter internal premiumAdapter;
    VaultMigrationAdapter internal migrationAdapter;

    function setUp() public {
        baseAdapter = new MockVedaAdapter();
        premiumAdapter = new MockVedaAdapter();
        migrationAdapter = new VaultMigrationAdapter(address(this), address(baseAdapter), address(premiumAdapter));
    }

    function test_migrateToPremium_forwardsParametersAndCompliance() public {
        premiumAdapter.setRequiredWithdrawalAdapter(baseAdapter);
        VaultMigrationAdapter.ToPremiumParams memory params_ = _toPremiumParams(ALICE, 91, 82, 1234, hex"abcd");

        vm.expectEmit(true, false, false, true);
        emit MigrationToPremiumExecuted(ALICE, 91, 82);
        migrationAdapter.migrateToPremiumByDelegation(params_);

        assertEq(baseAdapter.withdrawalCalls(), 1);
        assertEq(baseAdapter.lastMinimumAssets(), 91);
        assertEq(baseAdapter.lastWithdrawalDelegationsLength(), 2);
        assertEq(premiumAdapter.depositCalls(), 1);
        assertEq(premiumAdapter.lastMinimumMint(), 82);
        assertEq(premiumAdapter.lastDepositDelegationsLength(), 2);
        assertEq(premiumAdapter.lastComplianceDeadline(), 1234);
        assertEq(premiumAdapter.lastComplianceSignatureHash(), keccak256(hex"abcd"));
    }

    function test_migrateToBase_withdrawsBeforeDeposit() public {
        baseAdapter.setRequiredWithdrawalAdapter(premiumAdapter);
        VaultMigrationAdapter.ToBaseParams memory params_ = _toBaseParams(ALICE, 71, 62);

        vm.expectEmit(true, false, false, true);
        emit MigrationToBaseExecuted(ALICE, 71, 62);
        migrationAdapter.migrateToBaseByDelegation(params_);

        assertEq(premiumAdapter.withdrawalCalls(), 1);
        assertEq(premiumAdapter.lastMinimumAssets(), 71);
        assertEq(baseAdapter.depositCalls(), 1);
        assertEq(baseAdapter.lastMinimumMint(), 62);
    }

    function test_migrateToPremium_isPermissionless() public {
        vm.prank(BOB);
        migrationAdapter.migrateToPremiumByDelegation(_toPremiumParams(ALICE, 1, 1, 1, hex"01"));

        assertEq(baseAdapter.withdrawalCalls(), 1);
        assertEq(premiumAdapter.depositCalls(), 1);
    }

    function test_migrateToPremium_revertsBothLegsWhenDepositFails() public {
        premiumAdapter.setRevertDeposit(true);

        vm.expectRevert(MockVedaAdapter.DepositFailed.selector);
        migrationAdapter.migrateToPremiumByDelegation(_toPremiumParams(ALICE, 1, 1, 1, hex"01"));

        assertEq(baseAdapter.withdrawalCalls(), 0);
        assertEq(premiumAdapter.depositCalls(), 0);
    }

    function test_migrateToBase_revertsOnDelegatorMismatch() public {
        VaultMigrationAdapter.ToBaseParams memory params_ = VaultMigrationAdapter.ToBaseParams({
            withdrawalDelegations: _chain(ALICE, 1), minimumAssets: 1, depositDelegations: _chain(BOB, 2), minimumMint: 1
        });

        vm.expectRevert(VaultMigrationAdapter.DelegatorMismatch.selector);
        migrationAdapter.migrateToBaseByDelegation(params_);
    }

    function test_migrateToPremium_revertsOnShortDelegationChain() public {
        VaultMigrationAdapter.ToPremiumParams memory params_ = _toPremiumParams(ALICE, 1, 1, 1, hex"01");
        params_.withdrawalDelegations = new Delegation[](1);

        vm.expectRevert(VaultMigrationAdapter.InvalidDelegationsLength.selector);
        migrationAdapter.migrateToPremiumByDelegation(params_);
    }

    function test_migrateToPremiumBatch_executesAllItems() public {
        VaultMigrationAdapter.ToPremiumParams[] memory params_ = new VaultMigrationAdapter.ToPremiumParams[](2);
        params_[0] = _toPremiumParams(ALICE, 10, 11, 100, hex"01");
        params_[1] = _toPremiumParams(BOB, 20, 21, 200, hex"02");

        vm.expectEmit(true, false, false, true);
        emit BatchMigrationToPremiumExecuted(address(this), 2);
        migrationAdapter.migrateToPremiumByDelegationBatch(params_);

        assertEq(baseAdapter.withdrawalCalls(), 2);
        assertEq(premiumAdapter.depositCalls(), 2);
        assertEq(premiumAdapter.lastMinimumMint(), 21);
        assertEq(premiumAdapter.lastComplianceDeadline(), 200);
    }

    function test_migrateToBaseBatch_executesAllItems() public {
        VaultMigrationAdapter.ToBaseParams[] memory params_ = new VaultMigrationAdapter.ToBaseParams[](2);
        params_[0] = _toBaseParams(ALICE, 10, 11);
        params_[1] = _toBaseParams(BOB, 20, 21);

        vm.expectEmit(true, false, false, true);
        emit BatchMigrationToBaseExecuted(address(this), 2);
        migrationAdapter.migrateToBaseByDelegationBatch(params_);

        assertEq(premiumAdapter.withdrawalCalls(), 2);
        assertEq(baseAdapter.depositCalls(), 2);
    }

    function test_emptyBatchesRevert() public {
        VaultMigrationAdapter.ToPremiumParams[] memory premiumParams_ = new VaultMigrationAdapter.ToPremiumParams[](0);
        VaultMigrationAdapter.ToBaseParams[] memory baseParams_ = new VaultMigrationAdapter.ToBaseParams[](0);

        vm.expectRevert(VaultMigrationAdapter.InvalidBatchLength.selector);
        migrationAdapter.migrateToPremiumByDelegationBatch(premiumParams_);

        vm.expectRevert(VaultMigrationAdapter.InvalidBatchLength.selector);
        migrationAdapter.migrateToBaseByDelegationBatch(baseParams_);
    }

    function _toPremiumParams(
        address _delegator,
        uint256 _minimumAssets,
        uint256 _minimumMint,
        uint256 _deadline,
        bytes memory _signature
    )
        private
        pure
        returns (VaultMigrationAdapter.ToPremiumParams memory)
    {
        return VaultMigrationAdapter.ToPremiumParams({
            withdrawalDelegations: _chain(_delegator, 1),
            minimumAssets: _minimumAssets,
            depositDelegations: _chain(_delegator, 2),
            minimumMint: _minimumMint,
            compliance: IComplianceVedaTeller.ComplianceData({ deadline: _deadline, signature: _signature })
        });
    }

    function _toBaseParams(
        address _delegator,
        uint256 _minimumAssets,
        uint256 _minimumMint
    )
        private
        pure
        returns (VaultMigrationAdapter.ToBaseParams memory)
    {
        return VaultMigrationAdapter.ToBaseParams({
            withdrawalDelegations: _chain(_delegator, 1),
            minimumAssets: _minimumAssets,
            depositDelegations: _chain(_delegator, 2),
            minimumMint: _minimumMint
        });
    }

    function _chain(address _delegator, uint256 _salt) private pure returns (Delegation[] memory delegations_) {
        delegations_ = new Delegation[](2);
        Caveat[] memory caveats_ = new Caveat[](0);
        delegations_[0] = Delegation({
            delegate: address(0xD1),
            delegator: address(0xD2),
            authority: bytes32(0),
            caveats: caveats_,
            salt: _salt,
            signature: hex""
        });
        delegations_[1] = Delegation({
            delegate: address(0xD2),
            delegator: _delegator,
            authority: bytes32(0),
            caveats: caveats_,
            salt: _salt + 1,
            signature: hex""
        });
    }
}
