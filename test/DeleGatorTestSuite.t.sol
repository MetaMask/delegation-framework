// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IEntryPoint, EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import { BaseTest } from "./utils/BaseTest.t.sol";
import { Delegation, Caveat, PackedUserOperation, Delegation, Action } from "../src/utils/Types.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { Counter } from "./utils/Counter.t.sol";
import { StorageUtilsLib } from "./utils/StorageUtilsLib.t.sol";
import { SigningUtilsLib } from "./utils/SigningUtilsLib.t.sol";
import { ExecutionLib } from "../src/libraries/ExecutionLib.sol";

import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { IDeleGatorCore } from "../src/interfaces/IDeleGatorCore.sol";
import { IDeleGatorCoreFull } from "../src/interfaces/IDeleGatorCoreFull.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { AllowedMethodsEnforcer } from "../src/enforcers/AllowedMethodsEnforcer.sol";
import { AllowedTargetsEnforcer } from "../src/enforcers/AllowedTargetsEnforcer.sol";

abstract contract DeleGatorTestSuite is BaseTest {
    using MessageHashUtils for bytes32;

    ////////////////////////////// Setup //////////////////////

    Counter aliceDeleGatorCounter;
    Counter bobDeleGatorCounter;

    function setUp() public virtual override {
        super.setUp();

        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        vm.label(address(allowedMethodsEnforcer), "Allowed Methods Enforcer");
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        vm.label(address(allowedTargetsEnforcer), "Allowed Targets Enforcer");

        aliceDeleGatorCounter = new Counter(address(users.alice.deleGator));
        bobDeleGatorCounter = new Counter(address(users.bob.deleGator));
    }

    ////////////////////////////// State //////////////////////////////

    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    bytes32 private DELEGATIONS_STORAGE_LOCATION = StorageUtilsLib.getStorageLocation("DeleGator.Delegations");
    bytes32 private DELEGATOR_CORE_STORAGE_LOCATION = StorageUtilsLib.getStorageLocation("DeleGator.Core");
    bytes32 private INITIALIZABLE_STORAGE_LOCATION = StorageUtilsLib.getStorageLocation("openzeppelin.storage.Initializable");

    ////////////////////////////// Events //////////////////////////////

    event Deposited(address indexed account, uint256 totalDeposit);
    event EnabledDelegation(
        bytes32 indexed delegationHash, address indexed delegator, address indexed delegate, Delegation delegation
    );
    event DisabledDelegation(
        bytes32 indexed delegationHash, address indexed delegator, address indexed delegate, Delegation delegation
    );
    event Upgraded(address indexed implementation);
    event SetEntryPoint(IEntryPoint indexed entryPoint);
    event Initialized(uint64 version);
    event BeforeExecution();

    event UserOperationRevertReason(bytes32 indexed userOpHash, address indexed sender, uint256 nonce, bytes revertReason);
    event UserOperationEvent(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed paymaster,
        uint256 nonce,
        bool success,
        uint256 actualGasCost,
        uint256 actualGasUsed
    );
    event Withdrawn(address indexed account, address withdrawAddress, uint256 amount);
    event ExecutedAction(address indexed to, uint256 value, bool success, bytes errorMessage);
    event SentPrefund(address indexed sender, uint256 amount, bool success);
    event RedeemedDelegation(address indexed rootDelegator, address indexed redeemer, Delegation delegation);

    ////////////////////////////// Core Functionality //////////////////////////////

    function test_erc165_supportsInterface() public {
        // should support the following interfaces
        assertTrue(users.alice.deleGator.supportsInterface(type(IERC165).interfaceId));
        assertTrue(users.alice.deleGator.supportsInterface(type(IERC1271).interfaceId));
        assertTrue(users.alice.deleGator.supportsInterface(type(IERC1155Receiver).interfaceId));
        assertTrue(users.alice.deleGator.supportsInterface(type(IERC721Receiver).interfaceId));
        assertTrue(users.alice.deleGator.supportsInterface(type(IDeleGatorCore).interfaceId));
    }

    // should allow the delegator account to receive native tokens
    function test_allow_receiveNativeToken() public {
        uint256 balanceBefore_ = address(users.alice.deleGator).balance;
        (bool success_,) = address(users.alice.deleGator).call{ value: 1 ether }("");
        assertTrue(success_);
        assertEq(address(users.alice.deleGator).balance, balanceBefore_ + 1 ether);
    }

    // should allow retrieval of the nonce
    function test_allow_getNonce() public {
        // Get Alice's nonce
        uint256 nonce_ = users.alice.deleGator.getNonce();
        assertEq(nonce_, 0);
    }

    // should allow retrieval of the nonce
    function test_allow_getNonceWithKey() public {
        // Get Alice's nonce
        uint256 nonce_ = users.alice.deleGator.getNonce(uint192(100));
        assertEq(nonce_, 1844674407370955161600);
    }

    // should allow retrieval of the deposit in the entry point
    function test_allow_getDeposit() public {
        // Get Alice's deposit
        uint256 deposit_ = users.alice.deleGator.getDeposit();
        assertEq(deposit_, 0);
    }

    // should allow retrieval of the entry point
    function test_allow_getEntryPoint() public {
        // Get entry point address
        address entryPoint_ = address(users.alice.deleGator.entryPoint());
        assertEq(entryPoint_, address(entryPoint));
    }

    // should allow Alice to enable/disable an offchain Delegation with a Delegation struct
    function test_allow_updatingOffchainDelegationDisabledStateWithStruct() public {
        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Get delegation hash
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        PackedUserOperation memory disableUserOp_ = createAndSignUserOp(
            users.alice,
            address(users.alice.deleGator),
            abi.encodeWithSignature(
                "disableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation_
            )
        );
        PackedUserOperation memory enableUserOp_ = createAndSignUserOp(
            users.alice,
            address(users.alice.deleGator),
            abi.encodeWithSignature(
                "enableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation_
            )
        );

        // check before revoking
        bool isDisabled_ = users.alice.deleGator.isDelegationDisabled(delegationHash_);
        assertEq(isDisabled_, false);

        // Disable delegation
        vm.expectEmit(true, true, true, true);
        emit DisabledDelegation(delegationHash_, address(users.alice.deleGator), users.bob.addr, delegation_);
        submitUserOp_Bundler(disableUserOp_);
        isDisabled_ = users.alice.deleGator.isDelegationDisabled(delegationHash_);
        assertEq(isDisabled_, true);

        // Enable delegation
        vm.expectEmit(true, true, true, true);
        emit EnabledDelegation(delegationHash_, address(users.alice.deleGator), users.bob.addr, delegation_);
        submitUserOp_Bundler(enableUserOp_);
        isDisabled_ = users.alice.deleGator.isDelegationDisabled(delegationHash_);
        assertEq(isDisabled_, false);
    }

    // should not allow Alice to delegate if she is not the delegator
    function test_notAllow_delegatingForAnotherDelegator() public {
        // Creating an invalid delegation where Alice is not the delegator.
        Delegation memory delegation_ = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        // Create UserOp
        bytes memory userOpCallData_ = abi.encodeWithSignature(
            "enableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation_
        );

        PackedUserOperation memory userOp_ = createAndSignUserOp(users.alice, address(users.alice.deleGator), userOpCallData_);
        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);

        // Expect a revert event
        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash_, address(users.alice.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidDelegator.selector)
        );

        // Submit the UserOp
        submitUserOp_Bundler(userOp_);
    }

    // should not allow Alice to disable an invalid delegation
    function test_notAllow_disablingInvalidDelegation() public {
        Delegation memory delegation_ = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        // Create UserOp
        bytes memory userOpCallData_ = abi.encodeWithSignature(
            "disableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation_
        );

        PackedUserOperation memory userOp_ = createAndSignUserOp(users.alice, address(users.alice.deleGator), userOpCallData_);
        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);

        // Expect a revert event
        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash_, address(users.alice.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidDelegator.selector)
        );

        // Submit the UserOp
        submitUserOp_Bundler(userOp_);
    }

    // should not allow using a delegation without a signature
    function test_notAllow_delegationWithoutSignature() public {
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        vm.expectRevert(abi.encodeWithSelector(IDelegationManager.EmptySignature.selector));

        vm.prank(address(users.bob.deleGator));
        users.bob.deleGator.redeemDelegation(abi.encode(delegations_), action_);
    }

    // should not allow to enable already enabled delegation
    function test_notAllow_enableAlreadyEnabledDelegation() public {
        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        // Create UserOp
        bytes memory userOpCallData_ = abi.encodeWithSignature(
            "enableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation_
        );

        PackedUserOperation memory userOp_ = createAndSignUserOp(users.alice, address(users.alice.deleGator), userOpCallData_);
        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);

        // Expect a revert event
        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash_, address(users.alice.deleGator), 0, abi.encodeWithSelector(IDelegationManager.AlreadyEnabled.selector)
        );

        // Submit the UserOp
        submitUserOp_Bundler(userOp_);
    }

    function test_notAllow_disableAlreadyDisabledDelegation() public {
        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        // Get delegation hash
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        // Get stored delegation disabled state
        bool isDisabled_ = users.alice.deleGator.isDelegationDisabled(delegationHash_);
        assertFalse(isDisabled_);

        // Disable delegation
        execute_UserOp(
            users.alice,
            abi.encodeWithSignature(
                "disableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation_
            )
        );
        isDisabled_ = users.alice.deleGator.isDelegationDisabled(delegationHash_);
        assertTrue(isDisabled_);

        // Create UserOp
        PackedUserOperation memory disableUserOp_ = createAndSignUserOp(
            users.alice,
            address(users.alice.deleGator),
            abi.encodeWithSignature(
                "disableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation_
            )
        );
        bytes32 userOpHash_ = entryPoint.getUserOpHash(disableUserOp_);
        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash_, address(users.alice.deleGator), 1, abi.encodeWithSelector(IDelegationManager.AlreadyDisabled.selector)
        );

        // Submit the UserOp
        submitUserOp_Bundler(disableUserOp_);
    }

    // should allow Alice to disable an offchain Delegation
    function test_allow_disableOffchainDelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        delegation_ = signDelegation(users.alice, delegation_);

        // Create Bob's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, action_);

        // Get intermediate count
        uint256 intermediateValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(intermediateValue_, initialValue_ + 1);

        execute_UserOp(
            users.alice,
            abi.encodeWithSignature(
                "disableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation_
            )
        );

        bytes memory userOpCallData_ =
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations_), action_);

        uint256[] memory signers_ = new uint256[](1);
        signers_[0] = users.bob.privateKey;

        PackedUserOperation memory userOp_ = createAndSignUserOp(users.bob, address(users.bob.deleGator), userOpCallData_);

        PackedUserOperation[] memory userOps_ = new PackedUserOperation[](1);
        userOps_[0] = userOp_;
        vm.prank(bundler);

        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);

        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash_,
            address(users.bob.deleGator),
            1,
            abi.encodeWithSelector(IDelegationManager.CannotUseADisabledDelegation.selector)
        );

        entryPoint.handleOps(userOps_, bundler);

        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has not increased
        assertEq(finalValue_, intermediateValue_);
    }

    // should allow Alice to reset a disabled delegation
    function test_allow_resetDisabledDelegation() public {
        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Get delegation hash
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        // Get stored delegation disabled state
        bool isDisabled_ = users.alice.deleGator.isDelegationDisabled(delegationHash_);
        assertFalse(isDisabled_);

        // Disable delegation
        execute_UserOp(
            users.alice,
            abi.encodeWithSignature(
                "disableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation_
            )
        );
        isDisabled_ = users.alice.deleGator.isDelegationDisabled(delegationHash_);
        assertTrue(isDisabled_);

        // Enable delegation
        execute_UserOp(
            users.alice,
            abi.encodeWithSignature(
                "enableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation_
            )
        );
        isDisabled_ = users.alice.deleGator.isDelegationDisabled(delegationHash_);
        assertFalse(isDisabled_);
    }

    // should emit an event when the action_ is executed
    function test_emit_executedActionEvent() public {
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Bob's Delegator redeems the delegation
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Creating a valid action
        vm.prank(address(entryPoint));
        vm.expectEmit(true, true, true, true, address(users.alice.deleGator));
        emit ExecutedAction(action_.to, action_.value, true, hex"");
        users.alice.deleGator.execute(action_);

        // Validate that the count has increased by 1
        uint256 updatedValue_ = aliceDeleGatorCounter.count();
        assertEq(updatedValue_, initialValue_ + 1);

        // Creating a invalid action_
        action_.value = 1;
        vm.prank(address(entryPoint));
        // Expect it to emit a reverted event
        vm.expectEmit(true, true, true, true, address(users.alice.deleGator));
        vm.expectRevert(abi.encodeWithSelector(ExecutionLib.FailedExecutionWithoutReason.selector));
        emit ExecutedAction(action_.to, action_.value, false, hex"");
        users.alice.deleGator.execute(action_);
    }

    // should emit an event when paying the prefund
    function test_emit_sentPrefund() public {
        PackedUserOperation memory packedUserOperation_;
        vm.startPrank(address(entryPoint));

        vm.expectEmit(true, true, true, true, address(users.alice.deleGator));
        emit SentPrefund(address(entryPoint), 1, true);
        users.alice.deleGator.validateUserOp(packedUserOperation_, bytes32(0), 1);

        vm.expectEmit(true, true, true, true, address(users.alice.deleGator));
        emit SentPrefund(address(entryPoint), type(uint256).max, false);
        users.alice.deleGator.validateUserOp(packedUserOperation_, bytes32(0), type(uint256).max);
    }

    // should allow anyone to redeem an open Delegation (offchain)
    function test_allow_offchainOpenDelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();
        uint256 updatedValue_;

        // Create delegation
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            args: hex"",
            enforcer: address(allowedTargetsEnforcer),
            terms: abi.encodePacked(address(aliceDeleGatorCounter))
        });
        Delegation memory delegation_ = Delegation({
            delegate: ANY_DELEGATE,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        delegation_ = signDelegation(users.alice, delegation_);

        // Bob's Delegator redeems the delegation
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, action_);

        // Validate that the count has increased by 1
        updatedValue_ = aliceDeleGatorCounter.count();
        assertEq(updatedValue_, initialValue_ + 1);
        initialValue_ = updatedValue_;

        // Bob redeems the delegation
        vm.prank(users.bob.addr);
        delegationManager.redeemDelegation(abi.encode(delegations_), action_);

        // Validate that the count has increased by 1
        updatedValue_ = aliceDeleGatorCounter.count();
        assertEq(updatedValue_, initialValue_ + 1);
    }

    // should allow anyone to redelegate an open Delegation (offchain)
    function test_allow_offchainOpenDelegationRedelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();
        uint256 updatedValue_;

        // Create Alice's open delegation
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            args: hex"",
            enforcer: address(allowedTargetsEnforcer),
            terms: abi.encodePacked(address(aliceDeleGatorCounter))
        });
        Delegation memory aliceDelegation_ = Delegation({
            delegate: ANY_DELEGATE,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 aliceDelegationHash_ = EncoderLib._getDelegationHash(aliceDelegation_);
        aliceDelegation_ = signDelegation(users.alice, aliceDelegation_);

        // Bob's DeleGator redelegates the open delegation
        Delegation memory bobDelegation_ = Delegation({
            delegate: users.carol.addr,
            delegator: address(users.bob.deleGator),
            authority: aliceDelegationHash_,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        bobDelegation_ = signDelegation(users.bob, bobDelegation_);

        // Carol redeems the delegation
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = bobDelegation_;
        delegations_[1] = aliceDelegation_;

        // Carol redeems the delegation
        vm.prank(users.carol.addr);
        delegationManager.redeemDelegation(abi.encode(delegations_), action_);

        // Validate that the count has increased by 1
        updatedValue_ = aliceDeleGatorCounter.count();
        assertEq(updatedValue_, initialValue_ + 1);
    }

    // should NOT allow Bob to redeem a delegation with poorly formed data
    function test_notAllow_invalidRedeemDelegationData() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: users.bob.addr,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        // Create Bob's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        vm.prank(users.bob.addr);
        vm.expectRevert();
        delegationManager.redeemDelegation(abi.encode("quack"), action_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has not increased
        assertEq(finalValue_, initialValue_);
    }

    // should not allow call to Implementation's validateUserOp
    function test_notAllow_callFromNonProxyAddress_ValidateUserOp() public {
        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Create Alice's UserOp
        bytes memory userOpCallData_ = abi.encodeWithSelector(IDelegationManager.enableDelegation.selector, delegation_);
        PackedUserOperation memory userOp_ = createAndSignUserOp(users.alice, address(users.alice.deleGator), userOpCallData_);
        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);

        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        vm.prank(address(entryPoint));
        hybridDeleGatorImpl.validateUserOp(userOp_, userOpHash_, 0);
    }

    // should not allow call to Implementation's IsValidSignature
    function test_notAllow_callFromNonProxyAddress_IsValidSignature() public {
        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Create Alice's UserOp
        bytes memory userOpCallData_ = abi.encodeWithSelector(IDelegationManager.enableDelegation.selector, delegation_);
        PackedUserOperation memory userOp_ = createAndSignUserOp(users.alice, address(users.alice.deleGator), userOpCallData_);
        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);

        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        vm.prank(address(entryPoint));
        hybridDeleGatorImpl.isValidSignature(userOpHash_, userOp_.signature);
    }

    // should allow Bob's DeleGator to redeem a Delegation through a UserOp (offchain)
    function test_allow_deleGatorInvokeOffchainDelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        delegation_ = signDelegation(users.alice, delegation_);

        // Create Bob's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, action_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue_, initialValue_ + 1);
    }

    // should allow Bob to redeem a Delegation through a UserOp (offchain)
    function test_allow_eoaInvokeOffchainDelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: users.bob.addr,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        delegation_ = signDelegation(users.alice, delegation_);

        // Create Bob's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Redeem Bob's delegation
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        vm.prank(users.bob.addr);
        delegationManager.redeemDelegation(abi.encode(delegations_), action_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue_, initialValue_ + 1);
    }

    // should allow Bob (EOA) to redelegate a Delegation (offchain)
    function test_allow_eoaRedelegateOffchainDelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create Alice's delegation to Bob
        Delegation memory delegation1_ = Delegation({
            delegate: users.bob.addr,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        delegation1_ = signDelegation(users.alice, delegation1_);
        bytes32 delegationHash1_ = EncoderLib._getDelegationHash(delegation1_);

        // Create Bob's Delegation to Carol
        Delegation memory delegation2_ = Delegation({
            delegate: users.carol.addr,
            delegator: users.bob.addr,
            authority: delegationHash1_,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash2_ = EncoderLib._getDelegationHash(delegation2_);
        bytes32 domainHash_ = delegationManager.getDomainHash();
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(domainHash_, delegationHash2_);
        delegation2_.signature = SigningUtilsLib.signHash_EOA(users.bob.privateKey, typedDataHash_);

        // Create Carol's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Redeem Carol's delegation
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = delegation2_;
        delegations_[1] = delegation1_;

        vm.prank(users.carol.addr);
        delegationManager.redeemDelegation(abi.encode(delegations_), action_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue_, initialValue_ + 1);
    }

    // should not allow Carol to claim a delegation when EOA signature doesn't match the delegator
    function test_notAllow_eoaRedelegateOffchainDelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create Alice's delegation to Bob
        Delegation memory delegation1_ = Delegation({
            delegate: users.bob.addr,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        delegation1_ = signDelegation(users.alice, delegation1_);
        bytes32 delegationHash1_ = EncoderLib._getDelegationHash(delegation1_);

        // Create Bob's Delegation to Carol (signed by Dave)
        Delegation memory delegation2_ = Delegation({
            delegate: users.carol.addr,
            delegator: users.bob.addr,
            authority: delegationHash1_,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash2_ = EncoderLib._getDelegationHash(delegation2_);
        bytes32 domainHash_ = delegationManager.getDomainHash();
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(domainHash_, delegationHash2_);
        delegation2_.signature = SigningUtilsLib.signHash_EOA(users.dave.privateKey, typedDataHash_);

        // Create Carol's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Redeem Carol's delegation
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = delegation2_;
        delegations_[1] = delegation1_;

        vm.prank(users.carol.addr);
        vm.expectRevert(abi.encodeWithSelector(IDelegationManager.InvalidSignature.selector));
        delegationManager.redeemDelegation(abi.encode(delegations_), action_);

        // Get final count
        // Validate that the count has increased by 1
        uint256 finalValue_ = aliceDeleGatorCounter.count();
        assertEq(finalValue_, initialValue_);
    }

    // should allow Bob to redeem a Delegation with Caveats through a UserOp (offchain)
    function test_allow_invokeOffchainDelegationWithCaveats() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create Caveats
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({
            args: hex"",
            enforcer: address(allowedTargetsEnforcer),
            terms: abi.encodePacked(address(aliceDeleGatorCounter))
        });
        caveats_[1] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(Counter.increment.selector) });

        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        delegation_ = signDelegation(users.alice, delegation_);

        // Create Bob's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, action_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue_, initialValue_ + 1);
    }

    // should allow Carol's DeleGator to claim an offchain redelegation from Bob
    function test_allow_chainOfOffchainDelegationToDeleGators() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory aliceDelegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        aliceDelegation_ = signDelegation(users.alice, aliceDelegation_);

        // Create Bob's delegation to Carol
        Delegation memory bobDelegation_ = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(aliceDelegation_),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign Bob's delegation
        bobDelegation_ = signDelegation(users.bob, bobDelegation_);

        // Create Carol's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Carol's UserOp
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = bobDelegation_;
        delegations_[1] = aliceDelegation_;

        invokeDelegation_UserOp(users.carol, delegations_, action_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue_, initialValue_ + 1);
    }

    // should not allow Carol to redelegate a delegation to Bob
    function test_notAllow_chainOfOffchainDelegationToDeleGators() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create delegation from Alice to Bob
        Delegation memory aliceDelegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        aliceDelegation_ = signDelegation(users.alice, aliceDelegation_);

        // Create Carol's delegation to Dave
        Delegation memory carolDelegation_ = Delegation({
            delegate: address(users.dave.deleGator),
            delegator: address(users.carol.deleGator),
            authority: EncoderLib._getDelegationHash(aliceDelegation_),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign Carol's delegation
        carolDelegation_ = signDelegation(users.carol, carolDelegation_);

        // Create Dave's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Dave's UserOp
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = carolDelegation_;
        delegations_[1] = aliceDelegation_;

        PackedUserOperation memory userOp_ = createAndSignUserOp(
            users.dave,
            address(users.dave.deleGator),
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations_), action_)
        );

        PackedUserOperation[] memory userOps_ = new PackedUserOperation[](1);
        userOps_[0] = userOp_;
        vm.prank(bundler);

        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);

        // Expect it to emit a reverted event
        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash_, address(users.dave.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidDelegate.selector)
        );

        entryPoint.handleOps(userOps_, bundler);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has not increased
        assertEq(finalValue_, initialValue_);
    }

    // should shortcircuit Carol's DeleGator's delegation redemption to increase Alice's DeleGator's Counter
    function test_executesFirstRootAuthorityFound() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory aliceDelegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        aliceDelegation_ = signDelegation(users.alice, aliceDelegation_);

        // Create Bob's delegation to Carol
        Delegation memory bobDelegation_ = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign Bob's delegation
        bobDelegation_ = signDelegation(users.bob, bobDelegation_);

        // Create Carol's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Carol's UserOp
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = bobDelegation_;
        delegations_[1] = aliceDelegation_;

        invokeDelegation_UserOp(users.carol, delegations_, action_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has not increased by 1
        assertEq(finalValue_, initialValue_);
    }

    // should allow Carol to claim an offchain redelegation from Bob
    function test_allow_chainOfOffchainDelegationToEoa() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory aliceDelegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        aliceDelegation_ = signDelegation(users.alice, aliceDelegation_);

        // Create Bob's delegation to Carol
        Delegation memory bobDelegation_ = Delegation({
            delegate: users.carol.addr,
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(aliceDelegation_),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign Bob's delegation
        bobDelegation_ = signDelegation(users.bob, bobDelegation_);

        // Create Carol's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Carol's UserOp
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = bobDelegation_;
        delegations_[1] = aliceDelegation_;

        vm.prank(users.carol.addr);
        delegationManager.redeemDelegation(abi.encode(delegations_), action_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue_, initialValue_ + 1);
    }

    // should allow Alice to execute multiple actions_ in a single UserOp
    function test_allow_multiAction_UserOp() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create actions_
        Action[] memory actions_ = new Action[](2);
        actions_[0] =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        actions_[1] =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Actions
        executeBatch_UserOp(users.alice, actions_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the delegations_ were worked
        assertEq(finalValue_, initialValue_ + 2);
    }

    // should not allow to execute empty Actions
    function test_notAllow_emptyAction_UserOp() public {
        //Create Actions
        Action[] memory actions_ = new Action[](0);

        bytes memory userOpCallData__ = abi.encodeWithSelector(IDeleGatorCoreFull.executeBatch.selector, actions_);
        PackedUserOperation memory userOp_ = createUserOp(address(users.alice.deleGator), userOpCallData__);
        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);
        userOp_.signature = signHash(users.alice, userOpHash_.toEthSignedMessageHash());

        PackedUserOperation[] memory userOps_ = new PackedUserOperation[](1);
        userOps_[0] = userOp_;
        vm.prank(bundler);

        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash_, address(users.alice.deleGator), 0, abi.encodeWithSelector(ExecutionLib.InvalidActionsLength.selector)
        );
        entryPoint.handleOps(userOps_, payable(bundler));
    }

    // should allow Bob to execute multiple actions_ that redeem delegations_ in a single UserOp (offchain)
    function test_allow_multiActionDelegationClaim_Offchain_UserOp() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create Alice's delegation to Bob
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        delegation_ = signDelegation(users.alice, delegation_);

        // Create Action
        Action memory incrementAction_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Invoke delegation calldata
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        bytes memory invokeDelegationCalldata_ =
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations_), incrementAction_);

        // Create invoke delegation Actions
        Action[] memory redemptionActions_ = new Action[](2);
        redemptionActions_[0] = Action({ to: address(users.bob.deleGator), value: 0, data: invokeDelegationCalldata_ });
        redemptionActions_[1] = Action({ to: address(users.bob.deleGator), value: 0, data: invokeDelegationCalldata_ });

        // Execute delegations_
        executeBatch_UserOp(users.bob, redemptionActions_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the counts were increased
        assertEq(finalValue_, initialValue_ + 2);
    }

    // should allow Alice to execute a combination of actions_ through a single UserOp
    function test_allow_multiActionCombination_UserOp() public {
        // Get DeleGator's Counter's initial count
        uint256 initialValueAlice_ = aliceDeleGatorCounter.count();
        uint256 initialValueBob_ = bobDeleGatorCounter.count();

        // Create Alice's delegation to Bob
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        delegation = signDelegation(users.alice, delegation);

        // Invoke delegation calldata
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation;

        bytes memory invokeDelegationCalldata_ = abi.encodeWithSelector(
            IDeleGatorCoreFull.redeemDelegation.selector,
            abi.encode(delegations_),
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) })
        );

        // Create invoke delegation Actions
        Action[] memory redemptionActions_ = new Action[](2);
        redemptionActions_[0] = Action({ to: address(users.bob.deleGator), value: 0, data: invokeDelegationCalldata_ });
        redemptionActions_[1] =
            Action({ to: address(bobDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute delegations_
        executeBatch_UserOp(users.bob, redemptionActions_);

        // Get final count
        uint256 finalValueAlice_ = aliceDeleGatorCounter.count();
        uint256 finalValueBob_ = bobDeleGatorCounter.count();

        // Validate that the counts were increased
        assertEq(finalValueAlice_, initialValueAlice_ + 1);
        assertEq(finalValueBob_, initialValueBob_ + 1);
    }

    ////////////////////////////// Invalid cases //////////////////////////////

    // should not allow a second Action to execute if the first Action fails
    function test_notAllow_multiActionUserOp() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValueAlice_ = aliceDeleGatorCounter.count();
        uint256 initialValueBob_ = bobDeleGatorCounter.count();

        // Create actions_, incorrectly incrementing Bob's Counter first
        Action[] memory actions_ = new Action[](2);
        actions_[0] =
            Action({ to: address(bobDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        actions_[1] =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute actions_
        executeBatch_UserOp(users.alice, actions_);

        // Get final count
        uint256 finalValueAlice_ = aliceDeleGatorCounter.count();
        uint256 finalValueBob_ = bobDeleGatorCounter.count();

        // Validate that the counts were not increased
        assertEq(finalValueAlice_, initialValueAlice_);
        assertEq(finalValueBob_, initialValueBob_);
    }

    // should revert without reason and catch it
    function test_executionRevertsWithoutReason() public {
        // Invalid action_, sending ETH to a contract that can't receive it.
        Action memory action_ = Action({ to: address(aliceDeleGatorCounter), value: 1, data: hex"" });

        vm.prank(address(delegationManager));

        vm.expectRevert(abi.encodeWithSelector(ExecutionLib.FailedExecutionWithoutReason.selector));

        users.alice.deleGator.executeDelegatedAction(action_);
    }

    // should NOT allow Carol to redeem a delegation to Bob through a UserOp (offchain)
    function test_notAllow_invokeOffchainDelegationToAnotherUser() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create Alice's delegation to Bob
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign Alice's delegation to Bob
        delegation_ = signDelegation(users.alice, delegation_);

        // Create Carol's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Carol's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.carol, delegations_, action_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has NOT increased by 1
        assertEq(finalValue_, initialValue_);
    }

    // should NOT allow a UserOp to be submitted to an invalid EntryPoint
    function test_notAllow_invalidEntryPoint() public {
        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Create a new EntryPoint
        EntryPoint newEntryPoint_ = new EntryPoint();

        // Create Alice's UserOp (with valid EntryPoint)
        bytes memory userOpCallData_ = abi.encodeWithSelector(IDelegationManager.enableDelegation.selector, delegation_);
        PackedUserOperation memory userOp_ = createAndSignUserOp(users.alice, address(users.alice.deleGator), userOpCallData_);

        PackedUserOperation[] memory userOps_ = new PackedUserOperation[](1);
        userOps_[0] = userOp_;

        // Submit the UserOp through the Bundler
        vm.prank(bundler);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEntryPoint.FailedOpWithRevert.selector,
                0,
                "AA23 reverted",
                abi.encodeWithSelector(IDeleGatorCoreFull.NotEntryPoint.selector)
            )
        );
        newEntryPoint_.handleOps(userOps_, bundler);

        // Create Alice's UserOp (with invalid EntryPoint)
        userOp_ = createUserOp(address(users.alice.deleGator), userOpCallData_);
        userOp_ = signUserOp(users.alice, userOp_, newEntryPoint_);

        // Submit the UserOp through the Bundler
        vm.prank(bundler);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEntryPoint.FailedOpWithRevert.selector,
                0,
                "AA23 reverted",
                abi.encodeWithSelector(IDeleGatorCoreFull.NotEntryPoint.selector)
            )
        );
        newEntryPoint_.handleOps(userOps_, bundler);
    }

    // should NOT allow a UserOp with an invalid signature
    function test_notAllow_invalidUserOpSignature() public {
        // Create action_
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Create Alice's UserOp
        bytes memory userOpCallData_ = abi.encodeWithSelector(IDeleGatorCoreFull.execute.selector, action_);
        PackedUserOperation memory userOp_ = createUserOp(address(users.alice.deleGator), userOpCallData_, hex"");

        // Bob signs UserOp
        userOp_ = signUserOp(users.bob, userOp_);

        // Submit the UserOp through the Bundler
        // the signature of the user operation.)
        // (AA24 signature error = The validateUserOp function of the smart account rejected
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        submitUserOp_Bundler(userOp_);
    }

    // should NOT allow a UserOp with a reused nonce
    function test_notAllow_nonceReuse() public {
        // Create action_
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Create and Sign Alice's UserOp
        PackedUserOperation memory userOp_ = createAndSignUserOp(
            users.alice, address(users.alice.deleGator), abi.encodeWithSelector(IDeleGatorCoreFull.execute.selector, action_)
        );

        // Submit the UserOp through the Bundler
        submitUserOp_Bundler(userOp_);

        // Submit the UserOp through the Bundler again
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA25 invalid account nonce"));
        submitUserOp_Bundler(userOp_);
    }

    ////////////////////////////// EVENTS Emission //////////////////////////////

    function test_event_Deposited() public {
        Action memory action_ = Action({
            to: address(users.alice.deleGator),
            value: 1 ether,
            data: abi.encodeWithSelector(IDeleGatorCoreFull.addDeposit.selector)
        });

        PackedUserOperation memory userOp_ = createAndSignUserOp(
            users.alice, address(users.alice.deleGator), abi.encodeWithSelector(IDeleGatorCoreFull.execute.selector, action_)
        );

        vm.expectEmit(true, false, false, true);
        emit Deposited(address(users.alice.deleGator), 1 ether);

        submitUserOp_Bundler(userOp_);
    }

    function test_allow_withdrawDeposit() public {
        Action memory action_ = Action({
            to: address(users.alice.deleGator),
            value: 1 ether,
            data: abi.encodeWithSelector(IDeleGatorCoreFull.addDeposit.selector)
        });

        PackedUserOperation memory userOp_ = createAndSignUserOp(
            users.alice, address(users.alice.deleGator), abi.encodeWithSelector(IDeleGatorCoreFull.execute.selector, action_)
        );

        submitUserOp_Bundler(userOp_);

        action_ = Action({
            to: address(users.alice.deleGator),
            value: 0 ether,
            data: abi.encodeWithSelector(IDeleGatorCoreFull.withdrawDeposit.selector, address(users.alice.addr), 0.5 ether)
        });

        userOp_ = createAndSignUserOp(
            users.alice, address(users.alice.deleGator), abi.encodeWithSelector(IDeleGatorCoreFull.execute.selector, action_)
        );

        vm.expectEmit(true, false, false, true);
        emit Withdrawn(address(users.alice.deleGator), address(users.alice.addr), 0.5 ether);

        submitUserOp_Bundler(userOp_);
    }

    // test Error

    // Should revert if Alice tries to delegate carol's delegation
    function test_error_InvalidDelegator() public {
        // carol create delegation for bob
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.carol.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        PackedUserOperation memory userOp_ = createAndSignUserOp(
            users.alice,
            address(users.alice.deleGator),
            abi.encodeWithSelector(IDelegationManager.enableDelegation.selector, delegation_)
        );

        PackedUserOperation[] memory userOps_ = new PackedUserOperation[](1);
        userOps_[0] = userOp_;
        vm.prank(bundler);

        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);
        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash_, address(users.alice.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidDelegator.selector)
        );

        entryPoint.handleOps(userOps_, bundler);
    }

    // Should revert if there is no valid root authority
    function test_error_InvalidRootAuthority() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: users.bob.addr,
            delegator: address(users.alice.deleGator),
            authority: 0x0,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation
        delegation_ = signDelegation(users.alice, delegation_);

        // Create Bob's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Redeem Bob's delegation
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        vm.prank(users.bob.addr);
        vm.expectRevert();
        delegationManager.redeemDelegation(abi.encode(delegations_), action_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has not increased by 1
        assertEq(finalValue_, initialValue_);
    }

    // Should revert if user tries to redeem a delegation without providing delegations_
    function test_error_NoDelegationsProvided() public {
        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        // Create Bob's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        Delegation[] memory delegations_ = new Delegation[](0);

        // creating userOpCallData_
        bytes memory userOpCallData_ =
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations_), action_);

        PackedUserOperation memory userOp_ = createAndSignUserOp(users.bob, address(users.bob.deleGator), userOpCallData_);

        PackedUserOperation[] memory userOps_ = new PackedUserOperation[](1);
        userOps_[0] = userOp_;

        // prank from bundler
        vm.prank(bundler);

        // get User Operation hash
        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);

        vm.expectEmit(true, true, false, true, address(entryPoint));
        // expected error
        emit UserOperationRevertReason(
            userOpHash_, address(users.bob.deleGator), 0, abi.encodeWithSelector(IDelegationManager.NoDelegationsProvided.selector)
        );
        entryPoint.handleOps(userOps_, bundler);
    }

    // Should revert if the caller is not the delegate
    function test_error_InvalidDelegate() public {
        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        // Create Bob's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // create user operation calldata for invokeDelegation
        bytes memory userOpCallData_ =
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations_), action_);

        PackedUserOperation memory userOp_ = createAndSignUserOp(users.carol, address(users.carol.deleGator), userOpCallData_);

        PackedUserOperation[] memory userOps_ = new PackedUserOperation[](1);
        userOps_[0] = userOp_;

        // prank from bundler
        vm.prank(bundler);

        // get UserOperation hash
        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);

        vm.expectEmit(true, true, false, true, address(entryPoint));
        // expect an event containing EmptySignature error
        emit UserOperationRevertReason(
            userOpHash_, address(users.carol.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidDelegate.selector)
        );

        entryPoint.handleOps(userOps_, bundler);
    }

    // Should revert if a UserOp signature is invalid
    function test_error_InvalidSignature() public {
        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign Alice's delegation with Carol's private key
        delegation_ = signDelegation(users.carol, delegation_);

        // Create Bob's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // signing the userOp_ from bob
        uint256[] memory signers_ = new uint256[](1);
        signers_[0] = users.bob.privateKey;

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        bytes memory userOpCallData_ =
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations_), action_);

        PackedUserOperation memory userOp_ = createAndSignUserOp(users.bob, address(users.bob.deleGator), userOpCallData_);

        PackedUserOperation[] memory userOps_ = new PackedUserOperation[](1);
        userOps_[0] = userOp_;

        // prank from bundler
        vm.prank(bundler);

        // get User Operation hash
        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);

        vm.expectEmit(true, true, false, true, address(entryPoint));
        // expect an event containing InvalidSignature error
        emit UserOperationRevertReason(
            userOpHash_, address(users.bob.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidSignature.selector)
        );

        entryPoint.handleOps(userOps_, bundler);
    }

    // Should revert if the delegation signature is from an invalid signer
    function test_error_InvalidSigner() public {
        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Carol signs the delegation using Alice's domain hash
        delegation_ = signDelegation(users.carol, delegation_);

        // Create Bob's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // create user operation calldata for invokeDelegation
        bytes memory userOpCallData_ =
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations_), action_);

        // create and sign user operation with Bob
        PackedUserOperation memory userOp_ = createAndSignUserOp(users.bob, address(users.bob.deleGator), userOpCallData_);

        PackedUserOperation[] memory userOps_ = new PackedUserOperation[](1);
        userOps_[0] = userOp_;
        vm.prank(bundler);

        // get User Operation hash
        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);

        vm.expectEmit(true, true, false, true, address(entryPoint));
        // expect an event containing InvalidDelegationSignature error
        emit UserOperationRevertReason(
            userOpHash_, address(users.bob.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidSignature.selector)
        );

        entryPoint.handleOps(userOps_, bundler);
    }

    // Should revert if executeDelegatedAction is called from an address other than the DelegationManager
    function test_notAllow_notDelegationManager() public {
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        vm.expectRevert(abi.encodeWithSelector(IDeleGatorCoreFull.NotDelegationManager.selector));
        users.alice.deleGator.executeDelegatedAction(action_);
    }

    // Should revert if execute is called from an address other than the EntryPoint
    function test_notAllow_notEntryPoint() public {
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        vm.expectRevert(abi.encodeWithSelector(IDeleGatorCoreFull.NotEntryPoint.selector));
        users.alice.deleGator.execute(action_);
    }

    // Should revert if the delegation chain contains invalid authority
    function test_error_InvalidAuthority() public {
        // Create Alice's delegation to Bob
        Delegation memory aliceDelegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign Alice's delegation to Bob
        aliceDelegation_ = signDelegation(users.alice, aliceDelegation_);

        //create invalid delegation
        Delegation memory invalidDelegation_ = Delegation({
            delegate: address(users.carol.addr),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Create Bob's delegation to Carol
        Delegation memory bobDelegation_ = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(invalidDelegation_),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        bobDelegation_ = signDelegation(users.bob, bobDelegation_);

        // Create Carol's action
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = bobDelegation_;
        delegations_[1] = aliceDelegation_;

        // create user operation calldata for invokeDelegation
        bytes memory userOpCallData_ =
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations_), action_);

        PackedUserOperation memory userOp_ = createAndSignUserOp(users.carol, address(users.carol.deleGator), userOpCallData_);

        PackedUserOperation[] memory userOps_ = new PackedUserOperation[](1);
        userOps_[0] = userOp_;
        vm.prank(bundler);

        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);

        vm.expectEmit(address(entryPoint));
        // expect an event containing InvalidAuthority error
        emit UserOperationRevertReason(
            userOpHash_, address(users.carol.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidAuthority.selector)
        );
        entryPoint.handleOps(userOps_, bundler);
    }
}

contract HybridDeleGator_TestSuite_P256_Test is DeleGatorTestSuite {
    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
    }
}

contract HybridDeleGator_TestSuite_EOA_Test is DeleGatorTestSuite {
    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.EOA;
    }
}

contract MultiSig_TestSuite_Test is DeleGatorTestSuite {
    constructor() {
        IMPLEMENTATION = Implementation.MultiSig;
        SIGNATURE_TYPE = SignatureType.MultiSig;
    }
}
