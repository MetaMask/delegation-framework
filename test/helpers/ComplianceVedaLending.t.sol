// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { IComplianceVedaTeller } from "../../src/helpers/interfaces/IComplianceVedaTeller.sol";
import { ComplianceVedaAdapter } from "../../src/helpers/ComplianceVedaAdapter.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { RedeemerEnforcer } from "../../src/enforcers/RedeemerEnforcer.sol";
import { Delegation, Caveat } from "../../src/utils/Types.sol";
import { BaseTest } from "../utils/BaseTest.t.sol";
import { Implementation, SignatureType, TestUser } from "../utils/Types.t.sol";

interface IRolesAuthority {
    function owner() external view returns (address);
    function setUserRole(address user, uint8 role, bool enabled) external;
    function setRoleCapability(uint8 role, address target, bytes4 functionSig, bool enabled) external;
}

interface ITellerConfiguration {
    function owner() external view returns (address);
    function setTransferRestrictions(uint8 transferAllowedRole, uint8 allowlistedRouterRole) external;
}

/// forge-config: default.evm_version = "cancun"
contract ComplianceVedaLendingTest is BaseTest {
    IComplianceVedaTeller internal constant TELLER = IComplianceVedaTeller(0xB0025a2eBc0474d4F28E975F0D3E70471246ebae);
    IERC20 internal constant BORING_VAULT = IERC20(0xBFeC8c2b1ccea3931a1363E4CaC27352c1C908B7);
    IERC20 internal constant MUSD = IERC20(0xacA92E438df0B2401fF60dA7E4337B687a2435DA);
    IRolesAuthority internal constant ROLES_AUTHORITY = IRolesAuthority(0x00f0CF4f540D1d47470f565Ecb11a75E073c2dd0);

    address internal constant MUSD_WHALE = 0x6cb5094cfe45Ee97938702637478fe7146A8FA0f;
    uint8 internal constant COMPLIANCE_SIGNER_ROLE = 36;
    uint8 internal constant TRANSFER_ALLOWED_ROLE = 37;
    uint8 internal constant TEST_ROUTER_ROLE = 254;

    uint256 internal constant INITIAL_MUSD_BALANCE = 100_000e6;
    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;
    uint256 internal constant COMPLIANCE_SIGNER_KEY = 0xC011A11CE;

    ERC20TransferAmountEnforcer internal erc20TransferAmountEnforcer;
    RedeemerEnforcer internal redeemerEnforcer;
    ComplianceVedaAdapter internal adapter;
    address internal adapterOwner;
    address internal complianceSigner;

    function setUp() public override {
        vm.createSelectFork(vm.envString("MONAD_RPC_URL"));

        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
        super.setUp();

        adapterOwner = makeAddr("ComplianceVedaAdapter Owner");
        complianceSigner = vm.addr(COMPLIANCE_SIGNER_KEY);
        erc20TransferAmountEnforcer = new ERC20TransferAmountEnforcer();
        redeemerEnforcer = new RedeemerEnforcer();
        adapter = new ComplianceVedaAdapter(
            adapterOwner, address(delegationManager), address(BORING_VAULT), address(TELLER), address(MUSD)
        );

        _configureForkRoles();

        vm.prank(MUSD_WHALE);
        require(MUSD.transfer(address(users.alice.deleGator), INITIAL_MUSD_BALANCE), "mUSD funding failed");

        vm.label(address(adapter), "ComplianceVedaAdapter");
        vm.label(address(TELLER), "Veda Compliance Teller");
        vm.label(address(BORING_VAULT), "Premium mUSD Vault");
        vm.label(address(MUSD), "mUSD");
        vm.label(complianceSigner, "Compliance Signer");
    }

    function test_deposit_direct_withCompliance() public {
        uint256 deadline_ = block.timestamp + 30 minutes;
        bytes memory signature_ = _signCompliance(
            address(users.alice.deleGator), address(users.alice.deleGator), DEPOSIT_AMOUNT, deadline_, COMPLIANCE_SIGNER_KEY
        );

        vm.startPrank(address(users.alice.deleGator));
        MUSD.approve(address(BORING_VAULT), DEPOSIT_AMOUNT);
        uint256 shares_ = TELLER.deposit(
            IComplianceVedaTeller.DepositParams(address(MUSD), DEPOSIT_AMOUNT, 0),
            address(users.alice.deleGator),
            address(0),
            IComplianceVedaTeller.ComplianceData(deadline_, signature_)
        );
        vm.stopPrank();

        assertGt(shares_, 0);
        assertEq(BORING_VAULT.balanceOf(address(users.alice.deleGator)), shares_);
    }

    function test_deposit_viaAdapter_withCompliance() public {
        uint256 shares_ = _depositViaAdapter(DEPOSIT_AMOUNT, 0, block.timestamp + 30 minutes);

        assertGt(shares_, 0);
        assertEq(MUSD.balanceOf(address(adapter)), 0);
        assertEq(BORING_VAULT.balanceOf(address(adapter)), 0);
    }

    function test_withdraw_viaAdapter_afterComplianceDeposit() public {
        _depositViaAdapter(DEPOSIT_AMOUNT, 0, block.timestamp + 30 minutes);
        uint256 shares_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));
        uint256 assetsBefore_ = MUSD.balanceOf(address(users.alice.deleGator));
        Delegation[] memory delegations_ = _createDelegationChain(address(BORING_VAULT), shares_, 1);

        vm.prank(address(users.bob.deleGator));
        adapter.withdrawByDelegation(delegations_, 0);

        assertEq(BORING_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertGt(MUSD.balanceOf(address(users.alice.deleGator)), assetsBefore_);
        assertEq(BORING_VAULT.balanceOf(address(adapter)), 0);
    }

    function test_deposit_batch_withUniqueComplianceApprovals() public {
        uint256 firstAmount_ = DEPOSIT_AMOUNT;
        uint256 secondAmount_ = DEPOSIT_AMOUNT / 2;
        ComplianceVedaAdapter.DepositParams[] memory streams_ = new ComplianceVedaAdapter.DepositParams[](2);
        streams_[0] = _buildDepositParams(firstAmount_, 10, block.timestamp + 20 minutes);
        streams_[1] = _buildDepositParams(secondAmount_, 11, block.timestamp + 21 minutes);

        vm.prank(address(users.bob.deleGator));
        adapter.depositByDelegationBatch(streams_);

        assertGt(BORING_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(MUSD.balanceOf(address(adapter)), 0);
    }

    function test_withdraw_batch_afterComplianceDeposits() public {
        _depositViaAdapter(DEPOSIT_AMOUNT, 12, block.timestamp + 20 minutes);
        uint256 shares_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));
        uint256 firstShareAmount_ = shares_ / 2;

        ComplianceVedaAdapter.WithdrawParams[] memory streams_ = new ComplianceVedaAdapter.WithdrawParams[](2);
        streams_[0] = ComplianceVedaAdapter.WithdrawParams({
            delegations: _createDelegationChain(address(BORING_VAULT), firstShareAmount_, 13), minimumAssets: 0
        });
        streams_[1] = ComplianceVedaAdapter.WithdrawParams({
            delegations: _createDelegationChain(address(BORING_VAULT), shares_ - firstShareAmount_, 14), minimumAssets: 0
        });

        vm.prank(address(users.bob.deleGator));
        adapter.withdrawByDelegationBatch(streams_);

        assertEq(BORING_VAULT.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(BORING_VAULT.balanceOf(address(adapter)), 0);
    }

    function test_reverts_replayedComplianceSignatureWithFreshDelegation() public {
        uint256 deadline_ = block.timestamp + 30 minutes;
        _depositViaAdapter(DEPOSIT_AMOUNT, 20, deadline_);

        Delegation[] memory freshDelegations_ = _createDelegationChain(address(MUSD), DEPOSIT_AMOUNT, 21);
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _complianceData(address(users.alice.deleGator), DEPOSIT_AMOUNT, deadline_, COMPLIANCE_SIGNER_KEY);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        adapter.depositByDelegation(freshDelegations_, 0, compliance_);
    }

    function test_reverts_expiredComplianceSignature() public {
        uint256 deadline_ = block.timestamp - 1;
        Delegation[] memory delegations_ = _createDelegationChain(address(MUSD), DEPOSIT_AMOUNT, 30);
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _complianceData(address(users.alice.deleGator), DEPOSIT_AMOUNT, deadline_, COMPLIANCE_SIGNER_KEY);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        adapter.depositByDelegation(delegations_, 0, compliance_);
    }

    function test_reverts_wrongComplianceSigner() public {
        uint256 deadline_ = block.timestamp + 30 minutes;
        Delegation[] memory delegations_ = _createDelegationChain(address(MUSD), DEPOSIT_AMOUNT, 31);
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _complianceData(address(users.alice.deleGator), DEPOSIT_AMOUNT, deadline_, 0xBAD);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        adapter.depositByDelegation(delegations_, 0, compliance_);
    }

    function test_reverts_signatureForWrongRecipient() public {
        uint256 deadline_ = block.timestamp + 30 minutes;
        Delegation[] memory delegations_ = _createDelegationChain(address(MUSD), DEPOSIT_AMOUNT, 32);
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _complianceData(address(users.bob.deleGator), DEPOSIT_AMOUNT, deadline_, COMPLIANCE_SIGNER_KEY);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        adapter.depositByDelegation(delegations_, 0, compliance_);
    }

    function test_reverts_minimumMintTooHigh() public {
        uint256 deadline_ = block.timestamp + 30 minutes;
        Delegation[] memory delegations_ = _createDelegationChain(address(MUSD), DEPOSIT_AMOUNT, 33);
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _complianceData(address(users.alice.deleGator), DEPOSIT_AMOUNT, deadline_, COMPLIANCE_SIGNER_KEY);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        adapter.depositByDelegation(delegations_, type(uint256).max, compliance_);
    }

    function test_reverts_emptyBatches() public {
        ComplianceVedaAdapter.DepositParams[] memory deposits_ = new ComplianceVedaAdapter.DepositParams[](0);
        ComplianceVedaAdapter.WithdrawParams[] memory withdrawals_ = new ComplianceVedaAdapter.WithdrawParams[](0);

        vm.expectRevert(ComplianceVedaAdapter.InvalidBatchLength.selector);
        adapter.depositByDelegationBatch(deposits_);
        vm.expectRevert(ComplianceVedaAdapter.InvalidBatchLength.selector);
        adapter.withdrawByDelegationBatch(withdrawals_);
    }

    function _configureForkRoles() internal {
        address authorityOwner_ = ROLES_AUTHORITY.owner();
        address tellerOwner_ = ITellerConfiguration(address(TELLER)).owner();
        assertEq(authorityOwner_, tellerOwner_);

        vm.startPrank(authorityOwner_);
        ROLES_AUTHORITY.setUserRole(complianceSigner, COMPLIANCE_SIGNER_ROLE, true);
        ROLES_AUTHORITY.setUserRole(address(adapter), TRANSFER_ALLOWED_ROLE, true);
        ROLES_AUTHORITY.setUserRole(address(adapter), TEST_ROUTER_ROLE, true);
        ROLES_AUTHORITY.setRoleCapability(TEST_ROUTER_ROLE, address(TELLER), IComplianceVedaTeller.withdraw.selector, true);
        ITellerConfiguration(address(TELLER)).setTransferRestrictions(TRANSFER_ALLOWED_ROLE, TEST_ROUTER_ROLE);
        vm.stopPrank();
    }

    function _depositViaAdapter(uint256 _amount, uint256 _salt, uint256 _deadline) internal returns (uint256 shares_) {
        uint256 sharesBefore_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));
        Delegation[] memory delegations_ = _createDelegationChain(address(MUSD), _amount, _salt);
        IComplianceVedaTeller.ComplianceData memory compliance_ =
            _complianceData(address(users.alice.deleGator), _amount, _deadline, COMPLIANCE_SIGNER_KEY);

        vm.prank(address(users.bob.deleGator));
        adapter.depositByDelegation(delegations_, 0, compliance_);
        shares_ = BORING_VAULT.balanceOf(address(users.alice.deleGator)) - sharesBefore_;
    }

    function _buildDepositParams(
        uint256 _amount,
        uint256 _salt,
        uint256 _deadline
    )
        internal
        view
        returns (ComplianceVedaAdapter.DepositParams memory)
    {
        return ComplianceVedaAdapter.DepositParams({
            delegations: _createDelegationChain(address(MUSD), _amount, _salt),
            minimumMint: 0,
            compliance: _complianceData(address(users.alice.deleGator), _amount, _deadline, COMPLIANCE_SIGNER_KEY)
        });
    }

    function _createDelegationChain(
        address _token,
        uint256 _amount,
        uint256 _salt
    )
        internal
        view
        returns (Delegation[] memory delegations_)
    {
        Delegation memory root_ = _createTransferDelegation(users.alice, _token, type(uint256).max, _salt);
        Delegation memory leaf_ = _createAdapterRedelegation(EncoderLib._getDelegationHash(root_), _token, _amount, _salt);

        delegations_ = new Delegation[](2);
        delegations_[0] = leaf_;
        delegations_[1] = root_;
    }

    function _createTransferDelegation(
        TestUser memory _delegator,
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
        caveats_[1] = Caveat({ args: hex"", enforcer: address(redeemerEnforcer), terms: abi.encodePacked(address(adapter)) });

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
            delegate: address(adapter),
            delegator: address(users.bob.deleGator),
            authority: _authority,
            caveats: caveats_,
            salt: _salt,
            signature: hex""
        });
        return signDelegation(users.bob, delegation_);
    }

    function _complianceData(
        address _recipient,
        uint256 _amount,
        uint256 _deadline,
        uint256 _signerKey
    )
        internal
        view
        returns (IComplianceVedaTeller.ComplianceData memory)
    {
        return IComplianceVedaTeller.ComplianceData({
            deadline: _deadline, signature: _signCompliance(address(adapter), _recipient, _amount, _deadline, _signerKey)
        });
    }

    function _signCompliance(
        address _caller,
        address _recipient,
        uint256 _amount,
        uint256 _deadline,
        uint256 _signerKey
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 messageHash_ =
            keccak256(abi.encode(address(TELLER), block.chainid, _caller, _recipient, address(MUSD), _amount, _deadline));
        bytes32 ethSignedMessageHash_ = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash_));
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(_signerKey, ethSignedMessageHash_);
        return abi.encodePacked(r_, s_, v_);
    }
}
