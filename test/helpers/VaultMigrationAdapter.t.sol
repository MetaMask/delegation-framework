// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { IComplianceVedaTeller } from "../../src/helpers/interfaces/IComplianceVedaTeller.sol";
import { IVedaTeller } from "../../src/helpers/interfaces/IVedaTeller.sol";
import { VedaAdapter } from "../../src/helpers/VedaAdapter.sol";
import { ComplianceVedaAdapter } from "../../src/helpers/ComplianceVedaAdapter.sol";
import { VaultMigrationAdapter } from "../../src/helpers/VaultMigrationAdapter.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { RedeemerEnforcer } from "../../src/enforcers/RedeemerEnforcer.sol";
import { Delegation, Caveat } from "../../src/utils/Types.sol";
import { BaseTest } from "../utils/BaseTest.t.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { Implementation, SignatureType, TestUser } from "../utils/Types.t.sol";

contract MockBoringVault is ERC20, Ownable {
    using SafeERC20 for IERC20;

    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) Ownable(msg.sender) { }

    function enter(address _from, IERC20 _asset, uint256 _assets, address _to, uint256 _shares) external onlyOwner {
        _asset.safeTransferFrom(_from, address(this), _assets);
        _mint(_to, _shares);
    }

    function exit(address _from, IERC20 _asset, uint256 _assets, address _to, uint256 _shares) external onlyOwner {
        _burn(_from, _shares);
        _asset.safeTransfer(_to, _assets);
    }
}

contract MockVedaTeller is IVedaTeller, IComplianceVedaTeller {
    MockBoringVault public immutable vault;
    IERC20 public immutable asset;

    bool public revertDeposit;
    uint256 public lastComplianceDeadline;
    bytes32 public lastComplianceSignatureHash;

    error DepositFailed();
    error InsufficientMint();
    error InsufficientAssets();

    constructor(IERC20 _asset, string memory _vaultName, string memory _vaultSymbol) {
        asset = _asset;
        vault = new MockBoringVault(_vaultName, _vaultSymbol);
    }

    function setRevertDeposit(bool _revertDeposit) external {
        revertDeposit = _revertDeposit;
    }

    function deposit(
        address _depositAsset,
        uint256 _depositAmount,
        uint256 _minimumMint,
        address
    )
        external
        payable
        override
        returns (uint256)
    {
        return _deposit(_depositAsset, _depositAmount, _minimumMint, msg.sender);
    }

    function deposit(
        address _depositAsset,
        uint256 _depositAmount,
        uint256 _minimumMint,
        address _to,
        address
    )
        external
        payable
        override
        returns (uint256)
    {
        return _deposit(_depositAsset, _depositAmount, _minimumMint, _to);
    }

    function deposit(
        DepositParams calldata _params,
        address _to,
        address,
        ComplianceData calldata _compliance
    )
        external
        payable
        override
        returns (uint256)
    {
        lastComplianceDeadline = _compliance.deadline;
        lastComplianceSignatureHash = keccak256(_compliance.signature);
        return _deposit(_params.depositAsset, _params.depositAmount, _params.minimumMint, _to);
    }

    function withdraw(
        address _withdrawAsset,
        uint256 _shareAmount,
        uint256 _minimumAssets,
        address _to
    )
        external
        override(IVedaTeller, IComplianceVedaTeller)
        returns (uint256)
    {
        if (_shareAmount < _minimumAssets) revert InsufficientAssets();
        vault.exit(msg.sender, IERC20(_withdrawAsset), _shareAmount, _to, _shareAmount);
        return _shareAmount;
    }

    function _deposit(address _depositAsset, uint256 _depositAmount, uint256 _minimumMint, address _to) private returns (uint256) {
        if (revertDeposit) revert DepositFailed();
        if (_depositAmount < _minimumMint) revert InsufficientMint();
        vault.enter(msg.sender, IERC20(_depositAsset), _depositAmount, _to, _depositAmount);
        return _depositAmount;
    }
}

/**
 * @title VaultMigrationAdapter Test
 * @notice Tests atomic base <-> premium vault migrations through signed delegation chains.
 * @dev Uses in-process mock Tellers that actually pull tokens and mint/burn shares at 1:1 so
 *      assertions can follow token amounts the same way as VedaLending and ComplianceVedaLending.
 */
contract VaultMigrationAdapterTest is BaseTest {
    uint256 internal constant INITIAL_MUSD_BALANCE = 100_000e6;
    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;
    uint256 internal constant COMPLIANCE_SIGNER_KEY = 0xC011A11CE;

    ERC20TransferAmountEnforcer internal erc20TransferAmountEnforcer;
    RedeemerEnforcer internal redeemerEnforcer;

    BasicERC20 internal musd;
    MockVedaTeller internal baseTeller;
    MockVedaTeller internal premiumTeller;
    IERC20 internal baseVault;
    IERC20 internal premiumVault;
    VedaAdapter internal baseAdapter;
    ComplianceVedaAdapter internal premiumAdapter;
    VaultMigrationAdapter internal migrationAdapter;
    address internal adapterOwner;

    event MigrationToPremiumExecuted(address indexed delegator, uint256 minimumAssets, uint256 minimumMint);
    event MigrationToBaseExecuted(address indexed delegator, uint256 minimumAssets, uint256 minimumMint);
    event BatchMigrationToPremiumExecuted(address indexed caller, uint256 count);
    event BatchMigrationToBaseExecuted(address indexed caller, uint256 count);

    function setUp() public override {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
        super.setUp();

        adapterOwner = makeAddr("VaultMigrationAdapter Owner");
        erc20TransferAmountEnforcer = new ERC20TransferAmountEnforcer();
        redeemerEnforcer = new RedeemerEnforcer();

        musd = new BasicERC20(address(this), "mUSD", "mUSD", 0);
        baseTeller = new MockVedaTeller(musd, "Base mUSD Vault", "bmUSD");
        premiumTeller = new MockVedaTeller(musd, "Premium mUSD Vault", "pmUSD");
        baseVault = IERC20(address(baseTeller.vault()));
        premiumVault = IERC20(address(premiumTeller.vault()));

        baseAdapter =
            new VedaAdapter(adapterOwner, address(delegationManager), address(baseVault), address(baseTeller), address(musd));
        premiumAdapter = new ComplianceVedaAdapter(
            adapterOwner, address(delegationManager), address(premiumVault), address(premiumTeller), address(musd)
        );
        migrationAdapter = new VaultMigrationAdapter(adapterOwner, address(baseAdapter), address(premiumAdapter));

        musd.mint(address(users.alice.deleGator), INITIAL_MUSD_BALANCE);
        musd.mint(address(users.carol.deleGator), INITIAL_MUSD_BALANCE);

        vm.label(address(musd), "mUSD");
        vm.label(address(baseVault), "Base Vault");
        vm.label(address(premiumVault), "Premium Vault");
        vm.label(address(baseAdapter), "VedaAdapter");
        vm.label(address(premiumAdapter), "ComplianceVedaAdapter");
        vm.label(address(migrationAdapter), "VaultMigrationAdapter");
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new VaultMigrationAdapter(address(0), address(baseAdapter), address(premiumAdapter));

        vm.expectRevert(VaultMigrationAdapter.InvalidZeroAddress.selector);
        new VaultMigrationAdapter(adapterOwner, address(0), address(premiumAdapter));

        vm.expectRevert(VaultMigrationAdapter.InvalidZeroAddress.selector);
        new VaultMigrationAdapter(adapterOwner, address(baseAdapter), address(0));
    }

    function test_migrateToPremium_movesSharesAndLeavesNoDust() public {
        _depositToBase(users.alice, DEPOSIT_AMOUNT, 0);

        uint256 aliceMusdBefore_ = musd.balanceOf(address(users.alice.deleGator));
        uint256 baseShares_ = baseVault.balanceOf(address(users.alice.deleGator));
        assertEq(baseShares_, DEPOSIT_AMOUNT);
        assertEq(aliceMusdBefore_, INITIAL_MUSD_BALANCE - DEPOSIT_AMOUNT);

        VaultMigrationAdapter.ToPremiumParams memory params_ =
            _toPremiumParams(users.alice, baseShares_, DEPOSIT_AMOUNT, 1, DEPOSIT_AMOUNT, 2, block.timestamp + 30 minutes);

        vm.expectEmit(true, false, false, true, address(migrationAdapter));
        emit MigrationToPremiumExecuted(address(users.alice.deleGator), 0, 0);
        vm.prank(address(users.bob.deleGator));
        migrationAdapter.migrateToPremiumByDelegation(params_);

        assertEq(baseVault.balanceOf(address(users.alice.deleGator)), 0, "Base shares should be burned");
        assertEq(premiumVault.balanceOf(address(users.alice.deleGator)), DEPOSIT_AMOUNT, "Premium shares should be minted 1:1");
        assertEq(musd.balanceOf(address(users.alice.deleGator)), aliceMusdBefore_, "Underlying should settle back with Alice");
        _assertNoAdapterDust();
        assertEq(premiumTeller.lastComplianceDeadline(), block.timestamp + 30 minutes);
        assertEq(
            premiumTeller.lastComplianceSignatureHash(), keccak256(_signCompliance(DEPOSIT_AMOUNT, block.timestamp + 30 minutes))
        );
    }

    function test_migrateToBase_movesSharesAndLeavesNoDust() public {
        _depositToPremium(users.alice, DEPOSIT_AMOUNT, 10, block.timestamp + 30 minutes);

        uint256 aliceMusdBefore_ = musd.balanceOf(address(users.alice.deleGator));
        uint256 premiumShares_ = premiumVault.balanceOf(address(users.alice.deleGator));
        assertEq(premiumShares_, DEPOSIT_AMOUNT);

        VaultMigrationAdapter.ToBaseParams memory params_ = _toBaseParams(users.alice, premiumShares_, 11, DEPOSIT_AMOUNT, 12);

        vm.expectEmit(true, false, false, true, address(migrationAdapter));
        emit MigrationToBaseExecuted(address(users.alice.deleGator), 0, 0);
        vm.prank(address(users.bob.deleGator));
        migrationAdapter.migrateToBaseByDelegation(params_);

        assertEq(premiumVault.balanceOf(address(users.alice.deleGator)), 0, "Premium shares should be burned");
        assertEq(baseVault.balanceOf(address(users.alice.deleGator)), DEPOSIT_AMOUNT, "Base shares should be minted 1:1");
        assertEq(musd.balanceOf(address(users.alice.deleGator)), aliceMusdBefore_, "Underlying should settle back with Alice");
        _assertNoAdapterDust();
    }

    function test_migrateToPremium_isPermissionless() public {
        _depositToBase(users.alice, DEPOSIT_AMOUNT, 20);
        uint256 baseShares_ = baseVault.balanceOf(address(users.alice.deleGator));

        vm.prank(address(users.carol.deleGator));
        migrationAdapter.migrateToPremiumByDelegation(
            _toPremiumParams(users.alice, baseShares_, DEPOSIT_AMOUNT, 21, DEPOSIT_AMOUNT, 22, block.timestamp + 30 minutes)
        );

        assertEq(baseVault.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(premiumVault.balanceOf(address(users.alice.deleGator)), DEPOSIT_AMOUNT);
        assertEq(premiumVault.balanceOf(address(users.carol.deleGator)), 0, "Caller must not receive shares");
        _assertNoAdapterDust();
    }

    function test_migrateToPremium_revertsBothLegsWhenDepositFails() public {
        _depositToBase(users.alice, DEPOSIT_AMOUNT, 30);
        uint256 baseShares_ = baseVault.balanceOf(address(users.alice.deleGator));
        uint256 aliceMusdBefore_ = musd.balanceOf(address(users.alice.deleGator));
        premiumTeller.setRevertDeposit(true);
        VaultMigrationAdapter.ToPremiumParams memory params_ =
            _toPremiumParams(users.alice, baseShares_, DEPOSIT_AMOUNT, 31, DEPOSIT_AMOUNT, 32, block.timestamp + 30 minutes);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert(MockVedaTeller.DepositFailed.selector);
        migrationAdapter.migrateToPremiumByDelegation(params_);

        assertEq(baseVault.balanceOf(address(users.alice.deleGator)), baseShares_, "Base shares must roll back");
        assertEq(premiumVault.balanceOf(address(users.alice.deleGator)), 0, "No premium shares should be minted");
        assertEq(musd.balanceOf(address(users.alice.deleGator)), aliceMusdBefore_, "Underlying must roll back");
        _assertNoAdapterDust();
    }

    function test_migrateToBase_revertsOnDelegatorMismatch() public {
        _depositToPremium(users.alice, DEPOSIT_AMOUNT, 40, block.timestamp + 30 minutes);
        uint256 aliceShares_ = premiumVault.balanceOf(address(users.alice.deleGator));

        VaultMigrationAdapter.ToBaseParams memory params_ = VaultMigrationAdapter.ToBaseParams({
            withdrawalDelegations: _createDelegationChain(
                users.alice, address(premiumAdapter), address(premiumVault), aliceShares_, 41
            ),
            minimumAssets: 0,
            depositDelegations: _createDelegationChain(users.carol, address(baseAdapter), address(musd), DEPOSIT_AMOUNT, 42),
            minimumMint: 0
        });

        vm.expectRevert(VaultMigrationAdapter.DelegatorMismatch.selector);
        migrationAdapter.migrateToBaseByDelegation(params_);

        assertEq(premiumVault.balanceOf(address(users.alice.deleGator)), aliceShares_);
        assertEq(baseVault.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(baseVault.balanceOf(address(users.carol.deleGator)), 0);
    }

    function test_migrateToPremium_revertsOnShortDelegationChain() public {
        _depositToBase(users.alice, DEPOSIT_AMOUNT, 50);
        VaultMigrationAdapter.ToPremiumParams memory params_ = _toPremiumParams(
            users.alice,
            baseVault.balanceOf(address(users.alice.deleGator)),
            DEPOSIT_AMOUNT,
            51,
            DEPOSIT_AMOUNT,
            52,
            block.timestamp + 30 minutes
        );
        params_.withdrawalDelegations = new Delegation[](1);

        vm.expectRevert(VaultMigrationAdapter.InvalidDelegationsLength.selector);
        migrationAdapter.migrateToPremiumByDelegation(params_);

        assertEq(baseVault.balanceOf(address(users.alice.deleGator)), DEPOSIT_AMOUNT);
        assertEq(premiumVault.balanceOf(address(users.alice.deleGator)), 0);
    }

    function test_migrateToPremiumBatch_movesExactAmountsForEachDelegator() public {
        uint256 aliceAmount_ = 300e6;
        uint256 carolAmount_ = 400e6;
        _depositToBase(users.alice, aliceAmount_, 60);
        _depositToBase(users.carol, carolAmount_, 61);

        VaultMigrationAdapter.ToPremiumParams[] memory params_ = new VaultMigrationAdapter.ToPremiumParams[](2);
        params_[0] = _toPremiumParams(users.alice, aliceAmount_, aliceAmount_, 62, aliceAmount_, 63, block.timestamp + 20 minutes);
        params_[1] = _toPremiumParams(users.carol, carolAmount_, carolAmount_, 64, carolAmount_, 65, block.timestamp + 21 minutes);

        vm.expectEmit(true, false, false, true, address(migrationAdapter));
        emit BatchMigrationToPremiumExecuted(address(users.bob.deleGator), 2);
        vm.prank(address(users.bob.deleGator));
        migrationAdapter.migrateToPremiumByDelegationBatch(params_);

        assertEq(baseVault.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(baseVault.balanceOf(address(users.carol.deleGator)), 0);
        assertEq(premiumVault.balanceOf(address(users.alice.deleGator)), aliceAmount_);
        assertEq(premiumVault.balanceOf(address(users.carol.deleGator)), carolAmount_);
        assertEq(musd.balanceOf(address(users.alice.deleGator)), INITIAL_MUSD_BALANCE - aliceAmount_);
        assertEq(musd.balanceOf(address(users.carol.deleGator)), INITIAL_MUSD_BALANCE - carolAmount_);
        _assertNoAdapterDust();
    }

    function test_migrateToBaseBatch_movesExactAmountsForEachDelegator() public {
        uint256 aliceAmount_ = 250e6;
        uint256 carolAmount_ = 350e6;
        _depositToPremium(users.alice, aliceAmount_, 70, block.timestamp + 20 minutes);
        _depositToPremium(users.carol, carolAmount_, 71, block.timestamp + 21 minutes);

        VaultMigrationAdapter.ToBaseParams[] memory params_ = new VaultMigrationAdapter.ToBaseParams[](2);
        params_[0] = _toBaseParams(users.alice, aliceAmount_, 72, aliceAmount_, 73);
        params_[1] = _toBaseParams(users.carol, carolAmount_, 74, carolAmount_, 75);

        vm.expectEmit(true, false, false, true, address(migrationAdapter));
        emit BatchMigrationToBaseExecuted(address(users.bob.deleGator), 2);
        vm.prank(address(users.bob.deleGator));
        migrationAdapter.migrateToBaseByDelegationBatch(params_);

        assertEq(premiumVault.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(premiumVault.balanceOf(address(users.carol.deleGator)), 0);
        assertEq(baseVault.balanceOf(address(users.alice.deleGator)), aliceAmount_);
        assertEq(baseVault.balanceOf(address(users.carol.deleGator)), carolAmount_);
        _assertNoAdapterDust();
    }

    function test_emptyBatchesRevert() public {
        VaultMigrationAdapter.ToPremiumParams[] memory premiumParams_ = new VaultMigrationAdapter.ToPremiumParams[](0);
        VaultMigrationAdapter.ToBaseParams[] memory baseParams_ = new VaultMigrationAdapter.ToBaseParams[](0);

        vm.expectRevert(VaultMigrationAdapter.InvalidBatchLength.selector);
        migrationAdapter.migrateToPremiumByDelegationBatch(premiumParams_);

        vm.expectRevert(VaultMigrationAdapter.InvalidBatchLength.selector);
        migrationAdapter.migrateToBaseByDelegationBatch(baseParams_);
    }

    function _depositToBase(TestUser memory _delegator, uint256 _amount, uint256 _salt) internal {
        Delegation[] memory delegations_ = _createDelegationChain(_delegator, address(baseAdapter), address(musd), _amount, _salt);

        vm.prank(address(users.bob.deleGator));
        baseAdapter.depositByDelegation(delegations_, 0);
    }

    function _depositToPremium(TestUser memory _delegator, uint256 _amount, uint256 _salt, uint256 _deadline) internal {
        Delegation[] memory delegations_ =
            _createDelegationChain(_delegator, address(premiumAdapter), address(musd), _amount, _salt);
        IComplianceVedaTeller.ComplianceData memory compliance_ = _complianceData(_amount, _deadline);

        vm.prank(address(users.bob.deleGator));
        premiumAdapter.depositByDelegation(delegations_, 0, compliance_);
    }

    function _toPremiumParams(
        TestUser memory _delegator,
        uint256 _shareAmount,
        uint256 _assetAmount,
        uint256 _withdrawalSalt,
        uint256 _depositAmount,
        uint256 _depositSalt,
        uint256 _deadline
    )
        internal
        view
        returns (VaultMigrationAdapter.ToPremiumParams memory)
    {
        return VaultMigrationAdapter.ToPremiumParams({
            withdrawalDelegations: _createDelegationChain(
                _delegator, address(baseAdapter), address(baseVault), _shareAmount, _withdrawalSalt
            ),
            minimumAssets: 0,
            depositDelegations: _createDelegationChain(
                _delegator, address(premiumAdapter), address(musd), _depositAmount, _depositSalt
            ),
            minimumMint: 0,
            compliance: _complianceData(_assetAmount, _deadline)
        });
    }

    function _toBaseParams(
        TestUser memory _delegator,
        uint256 _shareAmount,
        uint256 _withdrawalSalt,
        uint256 _depositAmount,
        uint256 _depositSalt
    )
        internal
        view
        returns (VaultMigrationAdapter.ToBaseParams memory)
    {
        return VaultMigrationAdapter.ToBaseParams({
            withdrawalDelegations: _createDelegationChain(
                _delegator, address(premiumAdapter), address(premiumVault), _shareAmount, _withdrawalSalt
            ),
            minimumAssets: 0,
            depositDelegations: _createDelegationChain(
                _delegator, address(baseAdapter), address(musd), _depositAmount, _depositSalt
            ),
            minimumMint: 0
        });
    }

    function _createDelegationChain(
        TestUser memory _delegator,
        address _adapter,
        address _token,
        uint256 _amount,
        uint256 _salt
    )
        internal
        view
        returns (Delegation[] memory delegations_)
    {
        Delegation memory root_ = _createTransferDelegation(_delegator, _adapter, _token, type(uint256).max, _salt);
        Delegation memory leaf_ = _createAdapterRedelegation(_adapter, EncoderLib._getDelegationHash(root_), _token, _amount, _salt);

        delegations_ = new Delegation[](2);
        delegations_[0] = leaf_;
        delegations_[1] = root_;
    }

    function _createTransferDelegation(
        TestUser memory _delegator,
        address _adapter,
        address _token,
        uint256 _amount,
        uint256 _salt
    )
        internal
        view
        returns (Delegation memory)
    {
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: abi.encodePacked(_token, _amount) });
        caveats_[1] = Caveat({ args: hex"", enforcer: address(redeemerEnforcer), terms: abi.encodePacked(_adapter) });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(_delegator.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: _salt,
            signature: hex""
        });
        return signDelegation(_delegator, delegation_);
    }

    function _createAdapterRedelegation(
        address _adapter,
        bytes32 _authority,
        address _token,
        uint256 _amount,
        uint256 _salt
    )
        internal
        view
        returns (Delegation memory)
    {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: abi.encodePacked(_token, _amount) });

        Delegation memory delegation_ = Delegation({
            delegate: _adapter,
            delegator: address(users.bob.deleGator),
            authority: _authority,
            caveats: caveats_,
            salt: _salt,
            signature: hex""
        });
        return signDelegation(users.bob, delegation_);
    }

    function _complianceData(
        uint256 _amount,
        uint256 _deadline
    )
        internal
        view
        returns (IComplianceVedaTeller.ComplianceData memory)
    {
        return IComplianceVedaTeller.ComplianceData({ deadline: _deadline, signature: _signCompliance(_amount, _deadline) });
    }

    function _signCompliance(uint256 _amount, uint256 _deadline) internal view returns (bytes memory) {
        bytes32 messageHash_ = keccak256(
            abi.encode(
                address(premiumTeller),
                block.chainid,
                address(premiumAdapter),
                address(users.alice.deleGator),
                address(musd),
                _amount,
                _deadline
            )
        );
        bytes32 ethSignedMessageHash_ = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash_));
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(COMPLIANCE_SIGNER_KEY, ethSignedMessageHash_);
        return abi.encodePacked(r_, s_, v_);
    }

    function _assertNoAdapterDust() internal {
        assertEq(musd.balanceOf(address(baseAdapter)), 0);
        assertEq(musd.balanceOf(address(premiumAdapter)), 0);
        assertEq(musd.balanceOf(address(migrationAdapter)), 0);
        assertEq(baseVault.balanceOf(address(baseAdapter)), 0);
        assertEq(premiumVault.balanceOf(address(premiumAdapter)), 0);
        assertEq(baseVault.balanceOf(address(migrationAdapter)), 0);
        assertEq(premiumVault.balanceOf(address(migrationAdapter)), 0);
    }
}
