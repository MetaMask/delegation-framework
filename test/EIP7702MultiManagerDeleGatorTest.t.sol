// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { CALLTYPE_DELEGATECALL, ModeLib } from "@erc7579/lib/ModeLib.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { BaseTest } from "./utils/BaseTest.t.sol";
import { Counter } from "./utils/Counter.t.sol";
import { SigningUtilsLib } from "./utils/SigningUtilsLib.t.sol";
import { StorageUtilsLib } from "./utils/StorageUtilsLib.t.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { DeployEIP7702MultiManagerDeleGator } from "../script/DeployEIP7702MultiManagerDeleGator.s.sol";
import { DelegationManager } from "../src/DelegationManager.sol";
import { EIP7702MultiManagerDeleGator } from "../src/EIP7702/EIP7702MultiManagerDeleGator.sol";
import { EIP7702MultiManagerDeleGatorCore } from "../src/EIP7702/EIP7702MultiManagerDeleGatorCore.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { IERC7821 } from "../src/interfaces/IERC7821.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { ERC1271Lib } from "../src/libraries/ERC1271Lib.sol";
import { CALLTYPE_BATCH, CALLTYPE_SINGLE, EXECTYPE_DEFAULT, MODE_DEFAULT } from "../src/utils/Constants.sol";
import { Caveat, Delegation, Execution, ExecType, ModeCode, ModePayload, ModeSelector } from "../src/utils/Types.sol";

contract EIP7702MultiManagerDeleGatorTest is BaseTest {
    DelegationManager internal additionalDelegationManager;
    Counter internal counter;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702MultiManager;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();
        additionalDelegationManager = new DelegationManager(makeAddr("Additional DelegationManager Owner"));
        counter = new Counter(address(users.alice.deleGator));
    }

    function test_defaultsAndMetadata() public {
        EIP7702MultiManagerDeleGator account_ = _account();
        assertEq(account_.NAME(), "EIP7702MultiManagerDeleGator");
        assertEq(account_.VERSION(), "1.0.0");
        assertEq(address(account_.defaultDelegationManager1()), address(delegationManager));
        assertEq(address(account_.defaultDelegationManager2()), address(defaultDelegationManager2));
        assertTrue(account_.isApprovedDelegationManager(delegationManager));
        assertTrue(account_.isApprovedDelegationManager(defaultDelegationManager2));
        assertFalse(account_.isApprovedDelegationManager(additionalDelegationManager));
    }

    function test_constructorRejectsInvalidDefaults() public {
        IDelegationManager zero_ = IDelegationManager(address(0));
        IDelegationManager noCode_ = IDelegationManager(makeAddr("No code"));

        vm.expectRevert(EIP7702MultiManagerDeleGatorCore.InvalidDelegationManager.selector);
        new EIP7702MultiManagerDeleGator(zero_, defaultDelegationManager2);

        vm.expectRevert(abi.encodeWithSelector(EIP7702MultiManagerDeleGatorCore.DelegationManagerHasNoCode.selector, noCode_));
        new EIP7702MultiManagerDeleGator(noCode_, defaultDelegationManager2);

        vm.expectRevert(EIP7702MultiManagerDeleGatorCore.InvalidDelegationManager.selector);
        new EIP7702MultiManagerDeleGator(delegationManager, zero_);

        vm.expectRevert(abi.encodeWithSelector(EIP7702MultiManagerDeleGatorCore.DelegationManagerHasNoCode.selector, noCode_));
        new EIP7702MultiManagerDeleGator(delegationManager, noCode_);

        vm.expectRevert(EIP7702MultiManagerDeleGatorCore.DuplicateDefaultDelegationManager.selector);
        new EIP7702MultiManagerDeleGator(delegationManager, delegationManager);
    }

    function test_deploymentScriptDryRun() public {
        vm.setEnv("SALT", "eip7702-multi-manager-test");
        vm.setEnv("DEFAULT_DELEGATION_MANAGER_1", vm.toString(address(delegationManager)));
        vm.setEnv("DEFAULT_DELEGATION_MANAGER_2", vm.toString(address(defaultDelegationManager2)));
        DeployEIP7702MultiManagerDeleGator deployScript_ = new DeployEIP7702MultiManagerDeleGator();
        deployScript_.setUp();

        EIP7702MultiManagerDeleGator implementation_ = deployScript_.run();
        assertEq(address(implementation_.defaultDelegationManager1()), address(delegationManager));
        assertEq(address(implementation_.defaultDelegationManager2()), address(defaultDelegationManager2));
    }

    function test_defaultsCannotBeApprovedOrRevoked() public {
        EIP7702MultiManagerDeleGator account_ = _account();
        vm.startPrank(address(account_));

        vm.expectRevert(
            abi.encodeWithSelector(EIP7702MultiManagerDeleGatorCore.DelegationManagerAlreadyApproved.selector, delegationManager)
        );
        account_.approveDelegationManager(delegationManager);

        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702MultiManagerDeleGatorCore.DelegationManagerAlreadyApproved.selector, defaultDelegationManager2
            )
        );
        account_.approveDelegationManager(defaultDelegationManager2);

        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702MultiManagerDeleGatorCore.DefaultDelegationManagerCannotBeRevoked.selector, delegationManager
            )
        );
        account_.revokeDelegationManager(delegationManager);

        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702MultiManagerDeleGatorCore.DefaultDelegationManagerCannotBeRevoked.selector, defaultDelegationManager2
            )
        );
        account_.revokeDelegationManager(defaultDelegationManager2);
        vm.stopPrank();
    }

    function test_directSelfAdministersAdditionalDelegationManager() public {
        EIP7702MultiManagerDeleGator account_ = _account();

        vm.expectEmit(true, false, false, true);
        emit EIP7702MultiManagerDeleGatorCore.ApprovedDelegationManager(additionalDelegationManager);
        vm.prank(address(account_));
        account_.approveDelegationManager(additionalDelegationManager);
        assertTrue(account_.isApprovedDelegationManager(additionalDelegationManager));

        vm.expectEmit(true, false, false, true);
        emit EIP7702MultiManagerDeleGatorCore.RevokedDelegationManager(additionalDelegationManager);
        vm.prank(address(account_));
        account_.revokeDelegationManager(additionalDelegationManager);
        assertFalse(account_.isApprovedDelegationManager(additionalDelegationManager));
    }

    function test_exactERC7201SlotStoresMutableApproval() public {
        bytes32 storageLocation_ = StorageUtilsLib.getStorageLocation("DeleGator.EIP7702MultiManager.v1");
        assertEq(storageLocation_, 0x4ffe8763039a0c1b60d7504fab186e7e570dca76b49af35bcd94b7cdae58b300);

        _approveAdditional();
        bytes32 approvalSlot_ = keccak256(abi.encode(address(additionalDelegationManager), storageLocation_));
        assertEq(vm.load(address(_account()), approvalSlot_), bytes32(uint256(1)));

        vm.prank(address(_account()));
        _account().revokeDelegationManager(additionalDelegationManager);
        assertEq(vm.load(address(_account()), approvalSlot_), bytes32(0));
    }

    function test_rejectsInvalidDuplicateAbsentAndUnauthorizedAdministration() public {
        EIP7702MultiManagerDeleGator account_ = _account();
        IDelegationManager noCode_ = IDelegationManager(makeAddr("No code"));

        vm.expectRevert(EIP7702MultiManagerDeleGatorCore.NotSelf.selector);
        account_.approveDelegationManager(additionalDelegationManager);

        vm.startPrank(address(account_));
        vm.expectRevert(EIP7702MultiManagerDeleGatorCore.InvalidDelegationManager.selector);
        account_.approveDelegationManager(IDelegationManager(address(0)));

        vm.expectRevert(abi.encodeWithSelector(EIP7702MultiManagerDeleGatorCore.DelegationManagerHasNoCode.selector, noCode_));
        account_.approveDelegationManager(noCode_);

        account_.approveDelegationManager(additionalDelegationManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702MultiManagerDeleGatorCore.DelegationManagerAlreadyApproved.selector, additionalDelegationManager
            )
        );
        account_.approveDelegationManager(additionalDelegationManager);
        account_.revokeDelegationManager(additionalDelegationManager);

        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702MultiManagerDeleGatorCore.DelegationManagerNotApproved.selector, additionalDelegationManager
            )
        );
        account_.revokeDelegationManager(additionalDelegationManager);
        vm.stopPrank();
    }

    function test_defaultAndAdditionalExecutorPaths() public {
        EIP7702MultiManagerDeleGator account_ = _account();
        _approveAdditional();
        bytes memory execution_ = ExecutionLib.encodeSingle(address(counter), 0, abi.encodeCall(Counter.unsafeIncrement, ()));

        vm.prank(address(delegationManager));
        account_.executeFromExecutor(singleDefaultMode, execution_);
        vm.prank(address(defaultDelegationManager2));
        account_.executeFromExecutor(singleDefaultMode, execution_);
        vm.prank(address(additionalDelegationManager));
        account_.executeFromExecutor(singleDefaultMode, execution_);
        assertEq(counter.count(), 3);

        vm.prank(address(account_));
        account_.revokeDelegationManager(additionalDelegationManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702MultiManagerDeleGatorCore.DelegationManagerNotApproved.selector, additionalDelegationManager
            )
        );
        vm.prank(address(additionalDelegationManager));
        account_.executeFromExecutor(singleDefaultMode, execution_);
    }

    function test_delegationManagerSelfCallAdministersMutableSet() public {
        EIP7702MultiManagerDeleGator account_ = _account();
        bytes memory approveCall_ = ExecutionLib.encodeSingle(
            address(account_), 0, abi.encodeCall(account_.approveDelegationManager, (additionalDelegationManager))
        );

        vm.prank(address(delegationManager));
        account_.executeFromExecutor(singleDefaultMode, approveCall_);
        assertTrue(account_.isApprovedDelegationManager(additionalDelegationManager));

        bytes memory revokeCall_ = ExecutionLib.encodeSingle(
            address(account_), 0, abi.encodeCall(account_.revokeDelegationManager, (additionalDelegationManager))
        );
        vm.prank(address(additionalDelegationManager));
        account_.executeFromExecutor(singleDefaultMode, revokeCall_);
        assertFalse(account_.isApprovedDelegationManager(additionalDelegationManager));
    }

    function test_delegationManagerCannotSelfCallRevokeDefault() public {
        EIP7702MultiManagerDeleGator account_ = _account();
        bytes memory revokeDefaultCall_ = ExecutionLib.encodeSingle(
            address(account_), 0, abi.encodeCall(account_.revokeDelegationManager, (delegationManager))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702MultiManagerDeleGatorCore.DefaultDelegationManagerCannotBeRevoked.selector, delegationManager
            )
        );
        vm.prank(address(defaultDelegationManager2));
        account_.executeFromExecutor(singleDefaultMode, revokeDefaultCall_);
        assertTrue(account_.isApprovedDelegationManager(delegationManager));
    }

    function test_batchRollbackRevertsManagerAdministration() public {
        EIP7702MultiManagerDeleGator account_ = _account();
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] =
            Execution(address(account_), 0, abi.encodeCall(account_.approveDelegationManager, (additionalDelegationManager)));
        executions_[1] = Execution(address(new Reverter()), 0, abi.encodeCall(Reverter.fail, ()));

        vm.expectRevert();
        vm.prank(address(delegationManager));
        account_.executeFromExecutor(batchDefaultMode, ExecutionLib.encodeBatch(executions_));
        assertFalse(account_.isApprovedDelegationManager(additionalDelegationManager));
    }

    function test_batchTryCommitsApprovalBeforeLaterFailure() public {
        EIP7702MultiManagerDeleGator account_ = _account();
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] =
            Execution(address(account_), 0, abi.encodeCall(account_.approveDelegationManager, (additionalDelegationManager)));
        executions_[1] = Execution(address(new Reverter()), 0, abi.encodeCall(Reverter.fail, ()));

        vm.prank(address(delegationManager));
        bytes[] memory returnData_ = account_.executeFromExecutor(batchTryMode, ExecutionLib.encodeBatch(executions_));

        assertEq(returnData_.length, 2);
        assertTrue(account_.isApprovedDelegationManager(additionalDelegationManager));
    }

    function test_approvedReentrantDelegationManagerCanAdminister() public {
        EIP7702MultiManagerDeleGator account_ = _account();
        ReentrantDelegationManager reentrant_ = new ReentrantDelegationManager(account_, singleDefaultMode);
        vm.prank(address(account_));
        account_.approveDelegationManager(IDelegationManager(address(reentrant_)));

        bytes memory outer_ = ExecutionLib.encodeSingle(
            address(reentrant_),
            0,
            abi.encodeCall(ReentrantDelegationManager.approve, (IDelegationManager(address(additionalDelegationManager))))
        );
        vm.prank(address(delegationManager));
        account_.executeFromExecutor(singleDefaultMode, outer_);
        assertTrue(account_.isApprovedDelegationManager(additionalDelegationManager));
    }

    function test_managerSpecificRedeemEnableDisableAndStatus() public {
        EIP7702MultiManagerDeleGator account_ = _account();
        _approveAdditional();
        Delegation memory delegation_ = _signedDelegation(additionalDelegationManager);
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        vm.prank(address(account_));
        account_.disableDelegation(additionalDelegationManager, delegation_);
        assertTrue(account_.isDelegationDisabled(additionalDelegationManager, delegationHash_));
        assertFalse(account_.isDelegationDisabled(delegationManager, delegationHash_));

        vm.prank(address(account_));
        account_.enableDelegation(additionalDelegationManager, delegation_);
        assertFalse(account_.isDelegationDisabled(additionalDelegationManager, delegationHash_));

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory contexts_ = new bytes[](1);
        contexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = singleDefaultMode;
        bytes[] memory executions_ = new bytes[](1);
        executions_[0] = ExecutionLib.encodeSingle(address(counter), 0, abi.encodeCall(Counter.unsafeIncrement, ()));

        vm.prank(users.bob.addr);
        additionalDelegationManager.redeemDelegations(contexts_, modes_, executions_);
        assertEq(counter.count(), 1);

        Delegation memory defaultDelegation_ = _signedDelegation(delegationManager);
        defaultDelegation_.delegate = address(account_);
        defaultDelegation_.signature = "";
        bytes32 defaultTypedDataHash_ = MessageHashUtils.toTypedDataHash(
            delegationManager.getDomainHash(), EncoderLib._getDelegationHash(defaultDelegation_)
        );
        defaultDelegation_.signature = SigningUtilsLib.signHash_EOA(users.alice.privateKey, defaultTypedDataHash_);
        delegations_[0] = defaultDelegation_;
        contexts_[0] = abi.encode(delegations_);
        vm.prank(address(account_));
        account_.redeemDelegations(delegationManager, contexts_, modes_, executions_);
        assertEq(counter.count(), 2);
    }

    function test_unapprovedDelegationManagerRoutingAndStatusRevert() public {
        EIP7702MultiManagerDeleGator account_ = _account();
        bytes[] memory contexts_ = new bytes[](0);
        ModeCode[] memory modes_ = new ModeCode[](0);
        bytes[] memory executions_ = new bytes[](0);
        bytes memory expectedError_ = abi.encodeWithSelector(
            EIP7702MultiManagerDeleGatorCore.DelegationManagerNotApproved.selector, additionalDelegationManager
        );

        vm.expectRevert(expectedError_);
        vm.prank(address(account_));
        account_.redeemDelegations(additionalDelegationManager, contexts_, modes_, executions_);

        vm.expectRevert(expectedError_);
        account_.isDelegationDisabled(additionalDelegationManager, bytes32(0));
    }

    function test_unapprovedDelegationManagerDirectRedemptionRevertsAtAccount() public {
        Delegation memory delegation_ = _signedDelegation(additionalDelegationManager);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory contexts_ = new bytes[](1);
        contexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = singleDefaultMode;
        bytes[] memory executions_ = new bytes[](1);
        executions_[0] = ExecutionLib.encodeSingle(address(counter), 0, abi.encodeCall(Counter.unsafeIncrement, ()));

        vm.prank(users.bob.addr);
        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702MultiManagerDeleGatorCore.DelegationManagerNotApproved.selector, additionalDelegationManager
            )
        );
        additionalDelegationManager.redeemDelegations(contexts_, modes_, executions_);
        assertEq(counter.count(), 0);
    }

    function test_allSupportedExecutionModes() public {
        EIP7702MultiManagerDeleGator account_ = _account();
        bytes memory success_ = ExecutionLib.encodeSingle(address(counter), 0, abi.encodeCall(Counter.unsafeIncrement, ()));
        bytes memory failure_ = ExecutionLib.encodeSingle(address(new Reverter()), 0, abi.encodeCall(Reverter.fail, ()));
        Execution[] memory batchSuccess_ = new Execution[](2);
        batchSuccess_[0] = Execution(address(counter), 0, abi.encodeCall(Counter.unsafeIncrement, ()));
        batchSuccess_[1] = batchSuccess_[0];
        Execution[] memory batchTry_ = new Execution[](2);
        batchTry_[0] = batchSuccess_[0];
        batchTry_[1] = Execution(address(new Reverter()), 0, abi.encodeCall(Reverter.fail, ()));

        vm.startPrank(address(delegationManager));
        account_.executeFromExecutor(singleDefaultMode, success_);
        account_.executeFromExecutor(singleTryMode, failure_);
        account_.executeFromExecutor(batchDefaultMode, ExecutionLib.encodeBatch(batchSuccess_));
        account_.executeFromExecutor(batchTryMode, ExecutionLib.encodeBatch(batchTry_));
        vm.stopPrank();
        assertEq(counter.count(), 4);

        vm.startPrank(address(account_));
        account_.execute(Execution(address(counter), 0, abi.encodeCall(Counter.unsafeIncrement, ())));
        account_.execute(singleDefaultMode, success_);
        account_.execute(singleTryMode, failure_);
        account_.execute(batchDefaultMode, ExecutionLib.encodeBatch(batchSuccess_));
        account_.execute(batchTryMode, ExecutionLib.encodeBatch(batchTry_));
        vm.stopPrank();
        assertEq(counter.count(), 9);
    }

    function test_fullModeValidationMatchesSupportsExecutionMode() public {
        EIP7702MultiManagerDeleGator account_ = _account();
        bytes memory execution_ = ExecutionLib.encodeSingle(address(counter), 0, abi.encodeCall(Counter.unsafeIncrement, ()));
        ModeCode selectorMode_ =
            ModeLib.encode(CALLTYPE_SINGLE, EXECTYPE_DEFAULT, ModeSelector.wrap(0x01020304), ModePayload.wrap(0));
        ModeCode payloadMode_ =
            ModeLib.encode(CALLTYPE_SINGLE, EXECTYPE_DEFAULT, MODE_DEFAULT, ModePayload.wrap(bytes22(uint176(1))));
        ModeCode execMode_ = ModeLib.encode(CALLTYPE_SINGLE, ExecType.wrap(0x02), MODE_DEFAULT, ModePayload.wrap(0));
        ModeCode batchExecMode_ = ModeLib.encode(CALLTYPE_BATCH, ExecType.wrap(0x02), MODE_DEFAULT, ModePayload.wrap(0));
        ModeCode invalidCallMode_ = ModeLib.encode(CALLTYPE_DELEGATECALL, EXECTYPE_DEFAULT, MODE_DEFAULT, ModePayload.wrap(0));

        assertFalse(account_.supportsExecutionMode(selectorMode_));
        assertFalse(account_.supportsExecutionMode(payloadMode_));
        assertFalse(account_.supportsExecutionMode(execMode_));
        assertFalse(account_.supportsExecutionMode(invalidCallMode_));

        vm.startPrank(address(delegationManager));
        vm.expectRevert(abi.encodeWithSelector(EIP7702MultiManagerDeleGatorCore.UnsupportedCallType.selector, CALLTYPE_SINGLE));
        account_.executeFromExecutor(selectorMode_, execution_);
        vm.expectRevert(abi.encodeWithSelector(EIP7702MultiManagerDeleGatorCore.UnsupportedCallType.selector, CALLTYPE_SINGLE));
        account_.executeFromExecutor(payloadMode_, execution_);
        vm.expectRevert(abi.encodeWithSelector(EIP7702MultiManagerDeleGatorCore.UnsupportedExecType.selector, ExecType.wrap(0x02)));
        account_.executeFromExecutor(execMode_, execution_);
        vm.expectRevert(abi.encodeWithSelector(EIP7702MultiManagerDeleGatorCore.UnsupportedExecType.selector, ExecType.wrap(0x02)));
        account_.executeFromExecutor(batchExecMode_, ExecutionLib.encodeBatch(new Execution[](0)));
        vm.expectRevert(
            abi.encodeWithSelector(EIP7702MultiManagerDeleGatorCore.UnsupportedCallType.selector, CALLTYPE_DELEGATECALL)
        );
        account_.executeFromExecutor(invalidCallMode_, execution_);
        vm.stopPrank();

        vm.startPrank(address(account_));
        vm.expectRevert(abi.encodeWithSelector(EIP7702MultiManagerDeleGatorCore.UnsupportedCallType.selector, CALLTYPE_SINGLE));
        account_.execute(selectorMode_, execution_);
        vm.expectRevert(abi.encodeWithSelector(EIP7702MultiManagerDeleGatorCore.UnsupportedExecType.selector, ExecType.wrap(0x02)));
        account_.execute(execMode_, execution_);
        vm.expectRevert(abi.encodeWithSelector(EIP7702MultiManagerDeleGatorCore.UnsupportedExecType.selector, ExecType.wrap(0x02)));
        account_.execute(batchExecMode_, ExecutionLib.encodeBatch(new Execution[](0)));
        vm.expectRevert(
            abi.encodeWithSelector(EIP7702MultiManagerDeleGatorCore.UnsupportedCallType.selector, CALLTYPE_DELEGATECALL)
        );
        account_.execute(invalidCallMode_, execution_);
        vm.stopPrank();
    }

    function test_erc1271InterfacesAndTokenReceivers() public {
        EIP7702MultiManagerDeleGator account_ = _account();
        bytes32 hash_ = keccak256("multi-DelegationManager");
        bytes memory signature_ = SigningUtilsLib.signHash_EOA(users.alice.privateKey, hash_);
        assertEq(account_.isValidSignature(hash_, signature_), ERC1271Lib.EIP1271_MAGIC_VALUE);
        assertEq(
            account_.isValidSignature(hash_, SigningUtilsLib.signHash_EOA(users.bob.privateKey, hash_)),
            ERC1271Lib.SIG_VALIDATION_FAILED
        );

        assertTrue(account_.supportsInterface(type(IERC165).interfaceId));
        assertTrue(account_.supportsInterface(type(IERC1271).interfaceId));
        assertTrue(account_.supportsInterface(type(IERC721Receiver).interfaceId));
        assertTrue(account_.supportsInterface(type(IERC1155Receiver).interfaceId));
        assertTrue(account_.supportsInterface(type(IERC7821).interfaceId));
        assertEq(account_.onERC721Received(address(this), address(this), 1, ""), IERC721Receiver.onERC721Received.selector);
        assertEq(account_.onERC1155Received(address(this), address(this), 1, 1, ""), IERC1155Receiver.onERC1155Received.selector);
        assertEq(
            account_.onERC1155BatchReceived(address(this), address(this), new uint256[](0), new uint256[](0), ""),
            IERC1155Receiver.onERC1155BatchReceived.selector
        );

        vm.expectRevert(EIP7702MultiManagerDeleGatorCore.UnauthorizedCallContext.selector);
        eip7702MultiManagerDeleGatorImpl.isValidSignature(hash_, signature_);
    }

    function test_sameImplementationStoragePersistsAcrossCodeChanges() public {
        EIP7702MultiManagerDeleGator account_ = _account();
        _approveAdditional();
        vm.etch(address(account_), "");
        vm.etch(address(account_), bytes.concat(hex"ef0100", abi.encodePacked(eip7702MultiManagerDeleGatorImpl)));

        assertTrue(account_.isApprovedDelegationManager(delegationManager));
        assertTrue(account_.isApprovedDelegationManager(defaultDelegationManager2));
        assertTrue(account_.isApprovedDelegationManager(additionalDelegationManager));
    }

    function testFuzz_additionalDelegationManagerTransition(address _delegationManager) public {
        EIP7702MultiManagerDeleGator account_ = _account();
        vm.assume(
            uint160(_delegationManager) > 0xff && _delegationManager != address(account_)
                && _delegationManager != address(delegationManager) && _delegationManager != address(defaultDelegationManager2)
        );
        vm.etch(_delegationManager, hex"00");
        IDelegationManager delegationManager_ = IDelegationManager(_delegationManager);

        vm.prank(address(account_));
        account_.approveDelegationManager(delegationManager_);
        assertTrue(account_.isApprovedDelegationManager(delegationManager_));
        vm.prank(address(account_));
        account_.revokeDelegationManager(delegationManager_);
        assertFalse(account_.isApprovedDelegationManager(delegationManager_));
    }

    function testFuzz_malformedCalldataReverts(bytes calldata _calldata) public {
        vm.assume(_calldata.length < 52);
        vm.expectRevert();
        vm.prank(address(delegationManager));
        _account().executeFromExecutor(singleDefaultMode, _calldata);
    }

    function _account() internal view returns (EIP7702MultiManagerDeleGator) {
        return EIP7702MultiManagerDeleGator(payable(address(users.alice.deleGator)));
    }

    function _approveAdditional() internal {
        EIP7702MultiManagerDeleGator account_ = _account();
        vm.prank(address(account_));
        account_.approveDelegationManager(additionalDelegationManager);
    }

    function _signedDelegation(DelegationManager _delegationManager) internal view returns (Delegation memory delegation_) {
        delegation_ = Delegation({
            delegate: users.bob.addr,
            delegator: address(_account()),
            authority: _delegationManager.ROOT_AUTHORITY(),
            caveats: new Caveat[](0),
            salt: 0,
            signature: ""
        });
        bytes32 typedDataHash_ =
            MessageHashUtils.toTypedDataHash(_delegationManager.getDomainHash(), EncoderLib._getDelegationHash(delegation_));
        delegation_.signature = SigningUtilsLib.signHash_EOA(users.alice.privateKey, typedDataHash_);
    }

    receive() external payable { }
}

contract ReentrantDelegationManager {
    EIP7702MultiManagerDeleGator internal immutable account;
    ModeCode internal immutable mode;

    constructor(EIP7702MultiManagerDeleGator _account, ModeCode _mode) {
        account = _account;
        mode = _mode;
    }

    function approve(IDelegationManager _delegationManager) external {
        account.executeFromExecutor(
            mode,
            ExecutionLib.encodeSingle(address(account), 0, abi.encodeCall(account.approveDelegationManager, (_delegationManager)))
        );
    }
}

contract Reverter {
    function fail() external pure {
        revert();
    }
}
