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
    event Delegated(bytes32 indexed delegationHash, address indexed delegator, address indexed delegate, Delegation delegation);
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
        uint256 balanceBefore = address(users.alice.deleGator).balance;
        (bool success,) = address(users.alice.deleGator).call{ value: 1 ether }("");
        assertTrue(success);
        assertEq(address(users.alice.deleGator).balance, balanceBefore + 1 ether);
    }

    // should allow retrieval of the nonce
    function test_allow_getNonce() public {
        // Get Alice's nonce
        uint256 nonce = users.alice.deleGator.getNonce();
        assertEq(nonce, 0);
    }

    // should allow retrieval of the nonce
    function test_allow_getNonceWithKey() public {
        // Get Alice's nonce
        uint256 nonce = users.alice.deleGator.getNonce(uint192(100));
        assertEq(nonce, 1844674407370955161600);
    }

    // should allow retrieval of the deposit in the entry point
    function test_allow_getDeposit() public {
        // Get Alice's deposit
        uint256 deposit = users.alice.deleGator.getDeposit();
        assertEq(deposit, 0);
    }

    // should allow retrieval of the entry point
    function test_allow_getEntryPoint() public {
        // Get entry point address
        address entryPoint_ = address(users.alice.deleGator.entryPoint());
        assertEq(entryPoint_, address(entryPoint));
    }

    // should allow Alice to store a Delegation onchain through a UserOp
    function test_allow_storeOnchainDelegation() public {
        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Submit Alice's UserOp
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Get delegation hash
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);

        // Get stored delegation
        bool isOnchain = users.alice.deleGator.isDelegationOnchain(delegationHash);

        // Validate that the delegation is correct
        assertTrue(isOnchain);
    }

    // should allow Alice to enable/disable an offchain Delegation with a Delegation struct
    function test_allow_updatingOffchainDelegationDisabledStateWithStruct() public {
        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Get delegation hash
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);

        PackedUserOperation memory disableUserOp = createAndSignUserOp(
            users.alice,
            address(users.alice.deleGator),
            abi.encodeWithSignature(
                "disableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation
            )
        );
        PackedUserOperation memory enableUserOp = createAndSignUserOp(
            users.alice,
            address(users.alice.deleGator),
            abi.encodeWithSignature("enableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation)
        );

        // check before revoking
        bool isDisabled = users.alice.deleGator.isDelegationDisabled(delegationHash);
        assertEq(isDisabled, false);

        // Disable delegation
        vm.expectEmit(true, true, true, true);
        emit DisabledDelegation(delegationHash, address(users.alice.deleGator), users.bob.addr, delegation);
        submitUserOp_Bundler(disableUserOp);
        isDisabled = users.alice.deleGator.isDelegationDisabled(delegationHash);
        assertEq(isDisabled, true);

        // Enable delegation
        vm.expectEmit(true, true, true, true);
        emit EnabledDelegation(delegationHash, address(users.alice.deleGator), users.bob.addr, delegation);
        submitUserOp_Bundler(enableUserOp);
        isDisabled = users.alice.deleGator.isDelegationDisabled(delegationHash);
        assertEq(isDisabled, false);
    }

    // should allow Alice to enable/disable an onchain Delegation with a Delegation struct
    function test_allow_updatingOnchainDelegationDisabledStateWithStruct() public {
        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Submit Alice's UserOp
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Get delegation hash
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);

        PackedUserOperation memory disableUserOp = createAndSignUserOp(
            users.alice,
            address(users.alice.deleGator),
            abi.encodeWithSignature(
                "disableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation
            )
        );
        PackedUserOperation memory enableUserOp = createAndSignUserOp(
            users.alice,
            address(users.alice.deleGator),
            abi.encodeWithSignature("enableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation)
        );

        // check before revoking
        bool isDisabled = users.alice.deleGator.isDelegationDisabled(delegationHash);
        assertEq(isDisabled, false);

        // Disable delegation
        vm.expectEmit(true, true, true, true);
        emit DisabledDelegation(delegationHash, address(users.alice.deleGator), users.bob.addr, delegation);
        submitUserOp_Bundler(disableUserOp);
        isDisabled = users.alice.deleGator.isDelegationDisabled(delegationHash);
        assertEq(isDisabled, true);

        // Enable delegation
        vm.expectEmit(true, true, true, true);
        emit EnabledDelegation(delegationHash, address(users.alice.deleGator), users.bob.addr, delegation);
        submitUserOp_Bundler(enableUserOp);
        isDisabled = users.alice.deleGator.isDelegationDisabled(delegationHash);
        assertEq(isDisabled, false);
    }

    // should not allow Alice to delegate if she is not the delegator
    function test_notAllow_delegatingForAnotherDelegator() public {
        // Creating an invalid delegation where Alice is not the delegator.
        Delegation memory delegation = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        // Create UserOp
        bytes memory userOpCallData =
            abi.encodeWithSignature("enableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation);

        PackedUserOperation memory userOp = createAndSignUserOp(users.alice, address(users.alice.deleGator), userOpCallData);
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        // Expect a revert event
        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash, address(users.alice.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidDelegator.selector)
        );

        // Submit the UserOp
        submitUserOp_Bundler(userOp);
    }

    // should not allow Alice to disable an invalid delegation
    function test_notAllow_disablingInvalidDelegation() public {
        Delegation memory delegation = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        // Create UserOp
        bytes memory userOpCallData = abi.encodeWithSignature(
            "disableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation
        );

        PackedUserOperation memory userOp = createAndSignUserOp(users.alice, address(users.alice.deleGator), userOpCallData);
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        // Expect a revert event
        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash, address(users.alice.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidDelegator.selector)
        );

        // Submit the UserOp
        submitUserOp_Bundler(userOp);
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

        vm.expectRevert(abi.encodeWithSelector(IDelegationManager.InvalidDelegation.selector));

        vm.prank(address(users.bob.deleGator));
        users.bob.deleGator.redeemDelegation(abi.encode(delegations_), action_);
    }

    // should not allow to delegate already existing delegation
    function test_notAllow_alreadyExistingDelegation() public {
        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Submit Alice's UserOp to delegate
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Create Alice's UserOp (with valid EntryPoint)
        bytes memory userOpCallData = abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation);
        PackedUserOperation memory userOp = createAndSignUserOp(users.alice, address(users.alice.deleGator), userOpCallData);
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        // Expect a revert event
        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash, address(users.alice.deleGator), 1, abi.encodeWithSelector(IDelegationManager.AlreadyExists.selector)
        );

        // Submit the UserOp
        submitUserOp_Bundler(userOp);
    }

    // should not allow to enable already enabled delegation
    function test_notAllow_enableAlreadyEnabledDelegation() public {
        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Submit Alice's UserOp to delegate
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Create UserOp
        bytes memory userOpCallData =
            abi.encodeWithSignature("enableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation);

        PackedUserOperation memory userOp = createAndSignUserOp(users.alice, address(users.alice.deleGator), userOpCallData);
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        // Expect a revert event
        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash, address(users.alice.deleGator), 1, abi.encodeWithSelector(IDelegationManager.AlreadyEnabled.selector)
        );

        // Submit the UserOp
        submitUserOp_Bundler(userOp);
    }

    function test_notAllow_disableAlreadyDisabledDelegation() public {
        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Submit Alice's UserOp to delegate
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Get delegation hash
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);

        // Get stored delegation disabled state
        bool isDisabled = users.alice.deleGator.isDelegationDisabled(delegationHash);
        assertFalse(isDisabled);

        // Disable delegation
        execute_UserOp(
            users.alice,
            abi.encodeWithSignature(
                "disableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation
            )
        );
        isDisabled = users.alice.deleGator.isDelegationDisabled(delegationHash);
        assertTrue(isDisabled);

        // Create UserOp
        PackedUserOperation memory disableUserOp = createAndSignUserOp(
            users.alice,
            address(users.alice.deleGator),
            abi.encodeWithSignature(
                "disableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation
            )
        );
        bytes32 userOpHash = entryPoint.getUserOpHash(disableUserOp);

        // Expect a revert event
        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash, address(users.alice.deleGator), 2, abi.encodeWithSelector(IDelegationManager.AlreadyDisabled.selector)
        );

        // Submit the UserOp
        submitUserOp_Bundler(disableUserOp);
    }

    // should allow Alice to disable an offchain Delegation
    function test_allow_disableOffchainDelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        delegation = signDelegation(users.alice, delegation);

        // Create Bob's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Bob's UserOp
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        invokeDelegation_UserOp(users.bob, delegations, action);

        // Get intermediate count
        uint256 intermediateValue = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(intermediateValue, initialValue + 1);

        execute_UserOp(
            users.alice,
            abi.encodeWithSignature(
                "disableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation
            )
        );

        bytes memory userOpCallData =
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations), action);

        uint256[] memory signers_ = new uint256[](1);
        signers_[0] = users.bob.privateKey;

        PackedUserOperation memory userOp = createAndSignUserOp(users.bob, address(users.bob.deleGator), userOpCallData);

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;
        vm.prank(bundler);

        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash,
            address(users.bob.deleGator),
            1,
            abi.encodeWithSelector(IDelegationManager.CannotUseADisabledDelegation.selector)
        );

        entryPoint.handleOps(userOps, bundler);

        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has not increased
        assertEq(finalValue, intermediateValue);
    }

    // should allow Alice to reset a disabled onchain delegation
    function test_allow_resetDisabledDelegation() public {
        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Submit Alice's UserOp to delegate
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Get delegation hash
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);

        // Get stored delegation disabled state
        bool isDisabled = users.alice.deleGator.isDelegationDisabled(delegationHash);
        assertFalse(isDisabled);

        // Disable delegation
        execute_UserOp(
            users.alice,
            abi.encodeWithSignature(
                "disableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation
            )
        );
        isDisabled = users.alice.deleGator.isDelegationDisabled(delegationHash);
        assertTrue(isDisabled);

        // Enable delegation
        execute_UserOp(
            users.alice,
            abi.encodeWithSignature("enableDelegation((address,address,bytes32,(address,bytes,bytes)[],uint256,bytes))", delegation)
        );
        isDisabled = users.alice.deleGator.isDelegationDisabled(delegationHash);
        assertFalse(isDisabled);
    }

    // should allow anyone to redeem an open Delegation (onchain)
    function test_allow_onchainOpenDelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();
        uint256 updatedValue;

        // Create delegation
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({
            args: hex"",
            enforcer: address(allowedTargetsEnforcer),
            terms: abi.encodePacked(address(aliceDeleGatorCounter))
        });
        Delegation memory delegation = Delegation({
            delegate: ANY_DELEGATE,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        // Store delegation
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Bob's Delegator redeems the delegation
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;
        invokeDelegation_UserOp(users.bob, delegations, action);

        // Validate that the count has increased by 1
        updatedValue = aliceDeleGatorCounter.count();
        assertEq(updatedValue, initialValue + 1);
        initialValue = updatedValue;

        bytes32[] memory delegationHashes = new bytes32[](1);
        delegationHashes[0] = EncoderLib._getDelegationHash(delegation);
        // Bob redeems the delegation
        vm.prank(users.bob.addr);
        vm.expectEmit(true, true, true, true, address(delegationManager));
        emit RedeemedDelegation(delegation.delegator, users.bob.addr, delegation);
        delegationManager.redeemDelegation(abi.encode(delegations), action);

        // Validate that the count has increased by 1
        updatedValue = aliceDeleGatorCounter.count();
        assertEq(updatedValue, initialValue + 1);
    }

    // should emit an event when the action is executed
    function test_emit_executedActionEvent() public {
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Bob's Delegator redeems the delegation
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Creating a valid action
        vm.prank(address(entryPoint));
        vm.expectEmit(true, true, true, true, address(users.alice.deleGator));
        emit ExecutedAction(action.to, action.value, true, hex"");
        users.alice.deleGator.execute(action);

        // Validate that the count has increased by 1
        uint256 updatedValue = aliceDeleGatorCounter.count();
        assertEq(updatedValue, initialValue + 1);

        // Creating a invalid action
        action.value = 1;
        vm.prank(address(entryPoint));
        // Expect it to emit a reverted event
        vm.expectEmit(true, true, true, true, address(users.alice.deleGator));
        vm.expectRevert(abi.encodeWithSelector(ExecutionLib.FailedExecutionWithoutReason.selector));
        emit ExecutedAction(action.to, action.value, false, hex"");
        users.alice.deleGator.execute(action);
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
        uint256 initialValue = aliceDeleGatorCounter.count();
        uint256 updatedValue;

        // Create delegation
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({
            args: hex"",
            enforcer: address(allowedTargetsEnforcer),
            terms: abi.encodePacked(address(aliceDeleGatorCounter))
        });
        Delegation memory delegation = Delegation({
            delegate: ANY_DELEGATE,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        delegation = signDelegation(users.alice, delegation);

        // Bob's Delegator redeems the delegation
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        invokeDelegation_UserOp(users.bob, delegations, action);

        // Validate that the count has increased by 1
        updatedValue = aliceDeleGatorCounter.count();
        assertEq(updatedValue, initialValue + 1);
        initialValue = updatedValue;

        // Bob redeems the delegation
        vm.prank(users.bob.addr);
        delegationManager.redeemDelegation(abi.encode(delegations), action);

        // Validate that the count has increased by 1
        updatedValue = aliceDeleGatorCounter.count();
        assertEq(updatedValue, initialValue + 1);
    }

    // should allow anyone to redelegate an open Delegation (onchain)
    function test_allow_onchainOpenDelegationRedelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();
        uint256 updatedValue;

        // Create & store Alice's delegation
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({
            args: hex"",
            enforcer: address(allowedTargetsEnforcer),
            terms: abi.encodePacked(address(aliceDeleGatorCounter))
        });
        Delegation memory aliceDelegation = Delegation({
            delegate: ANY_DELEGATE,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });
        bytes32 aliceDelegationHash = EncoderLib._getDelegationHash(aliceDelegation);
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, aliceDelegation));

        // Create & store Bob's delegation
        Delegation memory bobDelegation = Delegation({
            delegate: users.carol.addr,
            delegator: address(users.bob.deleGator),
            authority: aliceDelegationHash,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        execute_UserOp(users.bob, abi.encodeWithSelector(IDelegationManager.delegate.selector, bobDelegation));

        // Carol redeems the delegation
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        Delegation[] memory delegations = new Delegation[](2);
        delegations[0] = bobDelegation;
        delegations[1] = aliceDelegation;

        vm.prank(users.carol.addr);
        vm.expectEmit(true, true, true, true, address(delegationManager));
        emit RedeemedDelegation(aliceDelegation.delegator, users.carol.addr, bobDelegation);
        vm.expectEmit(true, true, true, true, address(delegationManager));
        emit RedeemedDelegation(aliceDelegation.delegator, users.carol.addr, aliceDelegation);
        delegationManager.redeemDelegation(abi.encode(delegations), action);

        // Validate that the count has increased by 1
        updatedValue = aliceDeleGatorCounter.count();
        assertEq(updatedValue, initialValue + 1);
    }

    // should allow anyone to redelegate an open Delegation (offchain)
    function test_allow_offchainOpenDelegationRedelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();
        uint256 updatedValue;

        // Create Alice's open delegation
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({
            args: hex"",
            enforcer: address(allowedTargetsEnforcer),
            terms: abi.encodePacked(address(aliceDeleGatorCounter))
        });
        Delegation memory aliceDelegation = Delegation({
            delegate: ANY_DELEGATE,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });
        bytes32 aliceDelegationHash = EncoderLib._getDelegationHash(aliceDelegation);
        aliceDelegation = signDelegation(users.alice, aliceDelegation);

        // Bob's DeleGator redelegates the open delegation
        Delegation memory bobDelegation = Delegation({
            delegate: users.carol.addr,
            delegator: address(users.bob.deleGator),
            authority: aliceDelegationHash,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        bobDelegation = signDelegation(users.bob, bobDelegation);

        // Carol redeems the delegation
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        Delegation[] memory delegations = new Delegation[](2);
        delegations[0] = bobDelegation;
        delegations[1] = aliceDelegation;

        // Carol redeems the delegation
        vm.prank(users.carol.addr);
        delegationManager.redeemDelegation(abi.encode(delegations), action);

        // Validate that the count has increased by 1
        updatedValue = aliceDeleGatorCounter.count();
        assertEq(updatedValue, initialValue + 1);
    }

    // should allow Bob's DeleGator to redeem a Delegation through a UserOp (onchain)
    function test_allow_deleGatorInvokeOnchainDelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Create Bob's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Bob's UserOp
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        invokeDelegation_UserOp(users.bob, delegations, action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue, initialValue + 1);
    }

    // should allow Bob to redeem a Delegation with Caveats through a UserOp (onchain)
    function test_allow_invokeOnchainDelegationWithCaveats() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create Caveats
        Caveat[] memory caveats = new Caveat[](2);
        caveats[0] = Caveat({
            args: hex"",
            enforcer: address(allowedTargetsEnforcer),
            terms: abi.encodePacked(address(aliceDeleGatorCounter))
        });
        caveats[1] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(Counter.increment.selector) });

        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        // Store delegation
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Create Bob's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Bob's UserOp
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        invokeDelegation_UserOp(users.bob, delegations, action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue, initialValue + 1);
    }

    // should NOT allow Bob to redeem a delegation with poorly formed data
    function test_notAllow_invalidRedeemDelegationData() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: users.bob.addr,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Create Bob's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        vm.prank(users.bob.addr);
        vm.expectRevert();
        delegationManager.redeemDelegation(abi.encode("quack"), action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has not increased
        assertEq(finalValue, initialValue);
    }

    // should not allow call to Implementation's validateUserOp
    function test_notAllow_callFromNonProxyAddress_ValidateUserOp() public {
        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Create Alice's UserOp
        bytes memory userOpCallData = abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation);
        PackedUserOperation memory userOp = createAndSignUserOp(users.alice, address(users.alice.deleGator), userOpCallData);
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        vm.prank(address(entryPoint));
        hybridDeleGatorImpl.validateUserOp(userOp, userOpHash, 0);
    }

    // should not allow call to Implementation's IsValidSignature
    function test_notAllow_callFromNonProxyAddress_IsValidSignature() public {
        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Create Alice's UserOp
        bytes memory userOpCallData = abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation);
        PackedUserOperation memory userOp = createAndSignUserOp(users.alice, address(users.alice.deleGator), userOpCallData);
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        vm.prank(address(entryPoint));
        hybridDeleGatorImpl.isValidSignature(userOpHash, userOp.signature);
    }

    // should allow Bob to redeem a Delegation through a UserOp (onchain)
    function test_allow_eoaInvokeOnchainDelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: users.bob.addr,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Create Bob's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Redeem Bob's delegation
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        vm.prank(users.bob.addr);
        delegationManager.redeemDelegation(abi.encode(delegations), action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue, initialValue + 1);
    }

    // should allow Bob's DeleGator to redeem a Delegation through a UserOp (offchain)
    function test_allow_deleGatorInvokeOffchainDelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        delegation = signDelegation(users.alice, delegation);

        // Create Bob's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Bob's UserOp
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        invokeDelegation_UserOp(users.bob, delegations, action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue, initialValue + 1);
    }

    // should allow Bob to redeem a Delegation through a UserOp (offchain)
    function test_allow_eoaInvokeOffchainDelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: users.bob.addr,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        delegation = signDelegation(users.alice, delegation);

        // Create Bob's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Redeem Bob's delegation
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        vm.prank(users.bob.addr);
        delegationManager.redeemDelegation(abi.encode(delegations), action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue, initialValue + 1);
    }

    // should allow Bob (EOA) to redelegate a Delegation (offchain)
    function test_allow_eoaRedelegateOffchainDelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create Alice's delegation to Bob
        Delegation memory delegation1 = Delegation({
            delegate: users.bob.addr,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        delegation1 = signDelegation(users.alice, delegation1);
        bytes32 delegationHash1 = EncoderLib._getDelegationHash(delegation1);

        // Create Bob's Delegation to Carol
        Delegation memory delegation2 = Delegation({
            delegate: users.carol.addr,
            delegator: users.bob.addr,
            authority: delegationHash1,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash2 = EncoderLib._getDelegationHash(delegation2);
        bytes32 domainHash = delegationManager.getDomainHash();
        bytes32 typedDataHash = MessageHashUtils.toTypedDataHash(domainHash, delegationHash2);
        delegation2.signature = SigningUtilsLib.signHash_EOA(users.bob.privateKey, typedDataHash);

        // Create Carol's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Redeem Carol's delegation
        Delegation[] memory delegations = new Delegation[](2);
        delegations[0] = delegation2;
        delegations[1] = delegation1;

        vm.prank(users.carol.addr);
        delegationManager.redeemDelegation(abi.encode(delegations), action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue, initialValue + 1);
    }

    // should not allow Carol to claim a delegation when EOA signature doesn't match the delegator
    function test_notAllow_eoaRedelegateOffchainDelegation() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create Alice's delegation to Bob
        Delegation memory delegation1 = Delegation({
            delegate: users.bob.addr,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        delegation1 = signDelegation(users.alice, delegation1);
        bytes32 delegationHash1 = EncoderLib._getDelegationHash(delegation1);

        // Create Bob's Delegation to Carol (signed by Dave)
        Delegation memory delegation2 = Delegation({
            delegate: users.carol.addr,
            delegator: users.bob.addr,
            authority: delegationHash1,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash2 = EncoderLib._getDelegationHash(delegation2);
        bytes32 domainHash = delegationManager.getDomainHash();
        bytes32 typedDataHash = MessageHashUtils.toTypedDataHash(domainHash, delegationHash2);
        delegation2.signature = SigningUtilsLib.signHash_EOA(users.dave.privateKey, typedDataHash);

        // Create Carol's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Redeem Carol's delegation
        Delegation[] memory delegations = new Delegation[](2);
        delegations[0] = delegation2;
        delegations[1] = delegation1;

        vm.prank(users.carol.addr);
        vm.expectRevert(abi.encodeWithSelector(IDelegationManager.InvalidSignature.selector));
        delegationManager.redeemDelegation(abi.encode(delegations), action);

        // Get final count
        // Validate that the count has increased by 1
        uint256 finalValue = aliceDeleGatorCounter.count();
        assertEq(finalValue, initialValue);
    }

    // should allow Bob to redeem a Delegation with Caveats through a UserOp (offchain)
    function test_allow_invokeOffchainDelegationWithCaveats() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create Caveats
        Caveat[] memory caveats = new Caveat[](2);
        caveats[0] = Caveat({
            args: hex"",
            enforcer: address(allowedTargetsEnforcer),
            terms: abi.encodePacked(address(aliceDeleGatorCounter))
        });
        caveats[1] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(Counter.increment.selector) });

        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        delegation = signDelegation(users.alice, delegation);

        // Create Bob's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Bob's UserOp
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        invokeDelegation_UserOp(users.bob, delegations, action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue, initialValue + 1);
    }

    // should allow Carol to redeem a Delegation through a UserOp (onchain & offchain)
    function test_allow_invokeCombinedDelegationChain() public {
        //  Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create Alice's delegation to Bob
        Delegation memory aliceDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation onchain
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, aliceDelegation));

        // Create Bob's delegation to Carol
        Delegation memory bobDelegation = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(aliceDelegation),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign Bob's delegation
        Delegation memory signedBobDelegation = signDelegation(users.bob, bobDelegation);

        // Create Carol's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Carol's UserOp
        Delegation[] memory delegations = new Delegation[](2);
        delegations[0] = signedBobDelegation;
        delegations[1] = aliceDelegation;

        invokeDelegation_UserOp(users.carol, delegations, action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue, initialValue + 1);
    }

    // should allow Carol's DeleGator to claim an onchain redelegation from Bob
    function test_allow_chainOfOnchainDelegationToDeleGators() public {
        //  Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create Alice's delegation to Bob
        Delegation memory aliceDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation onchain
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, aliceDelegation));

        // Create Bob's delegation to Carol
        Delegation memory bobDelegation = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(aliceDelegation),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation onchain
        execute_UserOp(users.bob, abi.encodeWithSelector(IDelegationManager.delegate.selector, bobDelegation));

        // Create Carol's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        Delegation[] memory delegations = new Delegation[](2);
        delegations[0] = bobDelegation;
        delegations[1] = aliceDelegation;

        invokeDelegation_UserOp(users.carol, delegations, action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue, initialValue + 1);
    }

    // should allow Carol's DeleGator to claim an offchain redelegation from Bob
    function test_allow_chainOfOffchainDelegationToDeleGators() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory aliceDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        aliceDelegation = signDelegation(users.alice, aliceDelegation);

        // Create Bob's delegation to Carol
        Delegation memory bobDelegation = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(aliceDelegation),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign Bob's delegation
        bobDelegation = signDelegation(users.bob, bobDelegation);

        // Create Carol's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Carol's UserOp
        Delegation[] memory delegations = new Delegation[](2);
        delegations[0] = bobDelegation;
        delegations[1] = aliceDelegation;

        invokeDelegation_UserOp(users.carol, delegations, action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue, initialValue + 1);
    }

    // should not allow Carol to redelegate a delegation to Bob
    function test_notAllow_chainOfOffchainDelegationToDeleGators() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create delegation from Alice to Bob
        Delegation memory aliceDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        aliceDelegation = signDelegation(users.alice, aliceDelegation);

        // Create Carol's delegation to Dave
        Delegation memory carolDelegation = Delegation({
            delegate: address(users.dave.deleGator),
            delegator: address(users.carol.deleGator),
            authority: EncoderLib._getDelegationHash(aliceDelegation),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign Carol's delegation
        carolDelegation = signDelegation(users.carol, carolDelegation);

        // Create Dave's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Dave's UserOp
        Delegation[] memory delegations = new Delegation[](2);
        delegations[0] = carolDelegation;
        delegations[1] = aliceDelegation;

        PackedUserOperation memory userOp = createAndSignUserOp(
            users.dave,
            address(users.dave.deleGator),
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations), action)
        );

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;
        vm.prank(bundler);

        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        // Expect it to emit a reverted event
        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash, address(users.dave.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidDelegate.selector)
        );

        entryPoint.handleOps(userOps, bundler);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has not increased
        assertEq(finalValue, initialValue);
    }

    // should shortcircuit Carol's DeleGator's delegation redemption to increase Alice's DeleGator's Counter
    function test_executesFirstRootAuthorityFound() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory aliceDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        aliceDelegation = signDelegation(users.alice, aliceDelegation);

        // Create Bob's delegation to Carol
        Delegation memory bobDelegation = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign Bob's delegation
        bobDelegation = signDelegation(users.bob, bobDelegation);

        // Create Carol's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Carol's UserOp
        Delegation[] memory delegations = new Delegation[](2);
        delegations[0] = bobDelegation;
        delegations[1] = aliceDelegation;

        invokeDelegation_UserOp(users.carol, delegations, action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has not increased by 1
        assertEq(finalValue, initialValue);
    }

    // should allow Carol to claim an onchain redelegation from Bob
    function test_allow_chainOfOnchainDelegationToEoa() public {
        //  Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create Alice's delegation to Bob
        Delegation memory aliceDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation onchain
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, aliceDelegation));

        // Create Bob's delegation to Carol
        Delegation memory bobDelegation = Delegation({
            delegate: users.carol.addr,
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(aliceDelegation),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation onchain
        execute_UserOp(users.bob, abi.encodeWithSelector(IDelegationManager.delegate.selector, bobDelegation));

        // Create Carol's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        Delegation[] memory delegations = new Delegation[](2);
        delegations[0] = bobDelegation;
        delegations[1] = aliceDelegation;

        vm.prank(users.carol.addr);
        delegationManager.redeemDelegation(abi.encode(delegations), action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue, initialValue + 1);
    }

    // should allow Carol to claim an offchain redelegation from Bob
    function test_allow_chainOfOffchainDelegationToEoa() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory aliceDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Alice signs delegation
        aliceDelegation = signDelegation(users.alice, aliceDelegation);

        // Create Bob's delegation to Carol
        Delegation memory bobDelegation = Delegation({
            delegate: users.carol.addr,
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(aliceDelegation),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign Bob's delegation
        bobDelegation = signDelegation(users.bob, bobDelegation);

        // Create Carol's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Carol's UserOp
        Delegation[] memory delegations = new Delegation[](2);
        delegations[0] = bobDelegation;
        delegations[1] = aliceDelegation;

        vm.prank(users.carol.addr);
        delegationManager.redeemDelegation(abi.encode(delegations), action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue, initialValue + 1);
    }

    // should allow Alice to execute multiple actions in a single UserOp
    function test_allow_multiAction_UserOp() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create actions
        Action[] memory actions = new Action[](2);
        actions[0] =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        actions[1] =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Actions
        executeBatch_UserOp(users.alice, actions);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the delegations were stored
        assertEq(finalValue, initialValue + 2);
    }

    // should not allow to execute empty Actions
    function test_notAllow_emptyAction_UserOp() public {
        //Create Actions
        Action[] memory actions = new Action[](0);

        bytes memory userOpCallData_ = abi.encodeWithSelector(IDeleGatorCoreFull.executeBatch.selector, actions);
        PackedUserOperation memory userOp_ = createUserOp(address(users.alice.deleGator), userOpCallData_);
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

    // should allow Bob to execute multiple actions that redeem delegations in a single UserOp
    function test_allow_multiActionDelegationClaim_Onchain_UserOp() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create Alice's delegation to Bob
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation onchain
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Create onchain action Action
        Action memory incrementAction =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Invoke delegation calldata
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        bytes memory invokeDelegationCalldata =
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations), incrementAction);

        // Create invoke delegation Actions
        Action[] memory redemptionActions = new Action[](2);
        redemptionActions[0] = Action({ to: address(users.bob.deleGator), value: 0, data: invokeDelegationCalldata });
        redemptionActions[1] = Action({ to: address(users.bob.deleGator), value: 0, data: invokeDelegationCalldata });

        // Execute delegations
        executeBatch_UserOp(users.bob, redemptionActions);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the counts were increased
        assertEq(finalValue, initialValue + 2);
    }

    // should allow Bob to execute multiple actions that redeem delegations in a single UserOp
    function test_allow_multiActionDelegationClaim_Offchain_UserOp() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

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

        // Create onchain action Action
        Action memory incrementAction =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Invoke delegation calldata
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        bytes memory invokeDelegationCalldata =
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations), incrementAction);

        // Create invoke delegation Actions
        Action[] memory redemptionActions = new Action[](2);
        redemptionActions[0] = Action({ to: address(users.bob.deleGator), value: 0, data: invokeDelegationCalldata });
        redemptionActions[1] = Action({ to: address(users.bob.deleGator), value: 0, data: invokeDelegationCalldata });

        // Execute delegations
        executeBatch_UserOp(users.bob, redemptionActions);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the counts were increased
        assertEq(finalValue, initialValue + 2);
    }

    // should allow Alice to execute a combination of actions through a single UserOp
    function test_allow_multiActionCombination_UserOp() public {
        // Get DeleGator's Counter's initial count
        uint256 initialValueAlice = aliceDeleGatorCounter.count();
        uint256 initialValueBob = bobDeleGatorCounter.count();

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
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        bytes memory invokeDelegationCalldata = abi.encodeWithSelector(
            IDeleGatorCoreFull.redeemDelegation.selector,
            abi.encode(delegations),
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) })
        );

        // Create invoke delegation Actions
        Action[] memory redemptionActions = new Action[](2);
        redemptionActions[0] = Action({ to: address(users.bob.deleGator), value: 0, data: invokeDelegationCalldata });
        redemptionActions[1] =
            Action({ to: address(bobDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute delegations
        executeBatch_UserOp(users.bob, redemptionActions);

        // Get final count
        uint256 finalValueAlice = aliceDeleGatorCounter.count();
        uint256 finalValueBob = bobDeleGatorCounter.count();

        // Validate that the counts were increased
        assertEq(finalValueAlice, initialValueAlice + 1);
        assertEq(finalValueBob, initialValueBob + 1);
    }

    ////////////////////////////// Invalid cases //////////////////////////////

    // should not allow a second Action to execute if the first Action fails
    function test_notAllow_multiActionUserOp() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValueAlice = aliceDeleGatorCounter.count();
        uint256 initialValueBob = bobDeleGatorCounter.count();

        // Create actions, incorrectly incrementing Bob's Counter first
        Action[] memory actions = new Action[](2);
        actions[0] =
            Action({ to: address(bobDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        actions[1] =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute actions
        executeBatch_UserOp(users.alice, actions);

        // Get final count
        uint256 finalValueAlice = aliceDeleGatorCounter.count();
        uint256 finalValueBob = bobDeleGatorCounter.count();

        // Validate that the counts were not increased
        assertEq(finalValueAlice, initialValueAlice);
        assertEq(finalValueBob, initialValueBob);
    }

    // should revert without reason and catch it
    function test_executionRevertsWithoutReason() public {
        // Invalid action, sending ETH to a contract that can't receive it.
        Action memory action_ = Action({ to: address(aliceDeleGatorCounter), value: 1, data: hex"" });

        vm.prank(address(delegationManager));

        vm.expectRevert(abi.encodeWithSelector(ExecutionLib.FailedExecutionWithoutReason.selector));

        users.alice.deleGator.executeDelegatedAction(action_);
    }

    // should NOT allow Carol to redeem a delegation to Bob through a UserOp (onchain)
    function test_notAllow_invokeOnchainDelegationToAnotherUser() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create Alice's delegation to Bob
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation onchain
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Create Carol's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Carol's UserOp
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        invokeDelegation_UserOp(users.carol, delegations, action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has NOT increased by 1
        assertEq(finalValue, initialValue);
    }

    // should NOT allow Carol to redeem a delegation to Bob through a UserOp (offchain)
    function test_notAllow_invokeOffchainDelegationToAnotherUser() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create Alice's delegation to Bob
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign Alice's delegation to Bob
        delegation = signDelegation(users.alice, delegation);

        // Create Carol's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Execute Carol's UserOp
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        invokeDelegation_UserOp(users.carol, delegations, action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has NOT increased by 1
        assertEq(finalValue, initialValue);
    }

    // should NOT allow a UserOp to be submitted to an invalid EntryPoint
    function test_notAllow_invalidEntryPoint() public {
        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Create a new EntryPoint
        EntryPoint newEntryPoint = new EntryPoint();

        // Create Alice's UserOp (with valid EntryPoint)
        bytes memory userOpCallData = abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation);
        PackedUserOperation memory userOp = createAndSignUserOp(users.alice, address(users.alice.deleGator), userOpCallData);

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

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
        newEntryPoint.handleOps(userOps, bundler);

        // Create Alice's UserOp (with invalid EntryPoint)
        userOp = createUserOp(address(users.alice.deleGator), userOpCallData);
        userOp = signUserOp(users.alice, userOp, newEntryPoint);

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
        newEntryPoint.handleOps(userOps, bundler);
    }

    // should NOT allow a UserOp with an invalid signature
    function test_notAllow_invalidUserOpSignature() public {
        // Create action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Create Alice's UserOp
        bytes memory userOpCallData = abi.encodeWithSelector(IDeleGatorCoreFull.execute.selector, action);
        PackedUserOperation memory userOp = createUserOp(address(users.alice.deleGator), userOpCallData, hex"");

        // Bob signs UserOp
        userOp = signUserOp(users.bob, userOp);

        // Submit the UserOp through the Bundler
        // the signature of the user operation.)
        // (AA24 signature error = The validateUserOp function of the smart account rejected
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        submitUserOp_Bundler(userOp);
    }

    // should NOT allow a UserOp with a reused nonce
    function test_notAllow_nonceReuse() public {
        // Create action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Create and Sign Alice's UserOp
        PackedUserOperation memory userOp = createAndSignUserOp(
            users.alice, address(users.alice.deleGator), abi.encodeWithSelector(IDeleGatorCoreFull.execute.selector, action)
        );

        // Submit the UserOp through the Bundler
        submitUserOp_Bundler(userOp);

        // Submit the UserOp through the Bundler again
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA25 invalid account nonce"));
        submitUserOp_Bundler(userOp);
    }

    ////////////////////////////// EVENTS Emission //////////////////////////////

    // should not allow an invalid delegator to delegate
    function test_event_storeDelegation() public {
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);

        PackedUserOperation memory userOp = createAndSignUserOp(
            users.alice, address(users.alice.deleGator), abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation)
        );

        vm.expectEmit(true, false, false, true);
        emit Delegated(delegationHash, address(users.alice.deleGator), address(users.bob.addr), delegation);

        submitUserOp_Bundler(userOp);
    }

    function test_event_Deposited() public {
        Action memory action = Action({
            to: address(users.alice.deleGator),
            value: 1 ether,
            data: abi.encodeWithSelector(IDeleGatorCoreFull.addDeposit.selector)
        });

        PackedUserOperation memory userOp = createAndSignUserOp(
            users.alice, address(users.alice.deleGator), abi.encodeWithSelector(IDeleGatorCoreFull.execute.selector, action)
        );

        vm.expectEmit(true, false, false, true);
        emit Deposited(address(users.alice.deleGator), 1 ether);

        submitUserOp_Bundler(userOp);
    }

    function test_allow_withdrawDeposit() public {
        Action memory action = Action({
            to: address(users.alice.deleGator),
            value: 1 ether,
            data: abi.encodeWithSelector(IDeleGatorCoreFull.addDeposit.selector)
        });

        PackedUserOperation memory userOp = createAndSignUserOp(
            users.alice, address(users.alice.deleGator), abi.encodeWithSelector(IDeleGatorCoreFull.execute.selector, action)
        );

        submitUserOp_Bundler(userOp);

        action = Action({
            to: address(users.alice.deleGator),
            value: 0 ether,
            data: abi.encodeWithSelector(IDeleGatorCoreFull.withdrawDeposit.selector, address(users.alice.addr), 0.5 ether)
        });

        userOp = createAndSignUserOp(
            users.alice, address(users.alice.deleGator), abi.encodeWithSelector(IDeleGatorCoreFull.execute.selector, action)
        );

        vm.expectEmit(true, false, false, true);
        emit Withdrawn(address(users.alice.deleGator), address(users.alice.addr), 0.5 ether);

        submitUserOp_Bundler(userOp);
    }

    // test Error

    // Should revert if Alice tries to delegate carol's delegation
    function test_error_InvalidDelegator() public {
        // carol create delegation for bob
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.carol.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // bob's action
        PackedUserOperation memory userOp = createAndSignUserOp(
            users.alice, address(users.alice.deleGator), abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation)
        );

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;
        vm.prank(bundler);

        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit UserOperationRevertReason(
            userOpHash, address(users.alice.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidDelegator.selector)
        );

        entryPoint.handleOps(userOps, bundler);
    }

    // Should revert if there is no valid root authority
    function test_error_InvalidRootAuthority() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue = aliceDeleGatorCounter.count();

        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: users.bob.addr,
            delegator: address(users.alice.deleGator),
            authority: 0x0,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Create Bob's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // Redeem Bob's delegation
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        vm.prank(users.bob.addr);
        vm.expectRevert();
        delegationManager.redeemDelegation(abi.encode(delegations), action);

        // Get final count
        uint256 finalValue = aliceDeleGatorCounter.count();

        // Validate that the count has not increased by 1
        assertEq(finalValue, initialValue);
    }

    // Should revert if user tries to redeem a delegation without providing delegations
    function test_error_NoDelegationsProvided() public {
        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Create Bob's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        Delegation[] memory delegations = new Delegation[](0);

        // creating UserOpCallData
        bytes memory userOpCallData =
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations), action);

        PackedUserOperation memory userOp = createAndSignUserOp(users.bob, address(users.bob.deleGator), userOpCallData);

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        // prank from bundler
        vm.prank(bundler);

        // get User Operation hash
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        vm.expectEmit(true, true, false, true, address(entryPoint));
        // expected error
        emit UserOperationRevertReason(
            userOpHash, address(users.bob.deleGator), 0, abi.encodeWithSelector(IDelegationManager.NoDelegationsProvided.selector)
        );
        entryPoint.handleOps(userOps, bundler);
    }

    // Should revert if the caller is not the delegate
    function test_error_InvalidDelegate() public {
        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, delegation));

        // Create Bob's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        // create user operation calldata for invokeDelegation
        bytes memory userOpCallData =
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations), action);

        PackedUserOperation memory userOp = createAndSignUserOp(users.carol, address(users.carol.deleGator), userOpCallData);

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        // prank from bundler
        vm.prank(bundler);

        // get UserOperation hash
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        vm.expectEmit(true, true, false, true, address(entryPoint));
        // expect an event containing InvalidDelegation error
        emit UserOperationRevertReason(
            userOpHash, address(users.carol.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidDelegate.selector)
        );

        entryPoint.handleOps(userOps, bundler);
    }

    // Should revert if a UserOp signature is invalid
    function test_error_InvalidSignature() public {
        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign Alice's delegation with Carol's private key
        delegation = signDelegation(users.carol, delegation);

        // Create Bob's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        // signing the userOp from bob
        uint256[] memory signers_ = new uint256[](1);
        signers_[0] = users.bob.privateKey;

        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        bytes memory userOpCallData =
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations), action);

        PackedUserOperation memory userOp = createAndSignUserOp(users.bob, address(users.bob.deleGator), userOpCallData);

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        // prank from bundler
        vm.prank(bundler);

        // get User Operation hash
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        vm.expectEmit(true, true, false, true, address(entryPoint));
        // expect an event containing InvalidSignature error
        emit UserOperationRevertReason(
            userOpHash, address(users.bob.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidSignature.selector)
        );

        entryPoint.handleOps(userOps, bundler);
    }

    // Should revert if the delegation signature is from an invalid signer
    function test_error_InvalidSigner() public {
        // Create delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Carol signs the delegation using Alice's domain hash
        delegation = signDelegation(users.carol, delegation);

        // Create Bob's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        // create user operation calldata for invokeDelegation
        bytes memory userOpCallData =
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations), action);

        // create and sign user operation with Bob
        PackedUserOperation memory userOp = createAndSignUserOp(users.bob, address(users.bob.deleGator), userOpCallData);

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;
        vm.prank(bundler);

        // get User Operation hash
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        vm.expectEmit(true, true, false, true, address(entryPoint));
        // expect an event containing InvalidDelegationSignature error
        emit UserOperationRevertReason(
            userOpHash, address(users.bob.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidSignature.selector)
        );

        entryPoint.handleOps(userOps, bundler);
    }

    // Should revert if executeDelegatedAction is called from an address other than the DelegationManager
    function test_notAllow_notDelegationManager() public {
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        vm.expectRevert(abi.encodeWithSelector(IDeleGatorCoreFull.NotDelegationManager.selector));
        users.alice.deleGator.executeDelegatedAction(action);
    }

    // Should revert if execute is called from an address other than the EntryPoint
    function test_notAllow_notEntryPoint() public {
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        vm.expectRevert(abi.encodeWithSelector(IDeleGatorCoreFull.NotEntryPoint.selector));
        users.alice.deleGator.execute(action);
    }

    // Should revert if the delegation chain contains invalid authority
    function test_error_InvalidAuthority() public {
        // Create Alice's delegation to Bob
        Delegation memory aliceDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation onchain
        execute_UserOp(users.alice, abi.encodeWithSelector(IDelegationManager.delegate.selector, aliceDelegation));

        //create invalid delegation
        Delegation memory invalidDelegation = Delegation({
            delegate: address(users.carol.addr),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Create Bob's delegation to Carol
        Delegation memory bobDelegation = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(invalidDelegation),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Store delegation onchain
        execute_UserOp(users.bob, abi.encodeWithSelector(IDelegationManager.delegate.selector, bobDelegation));

        // Create Carol's action
        Action memory action =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        Delegation[] memory delegations = new Delegation[](2);
        delegations[0] = bobDelegation;
        delegations[1] = aliceDelegation;

        // create user operation calldata for invokeDelegation
        bytes memory userOpCallData =
            abi.encodeWithSelector(IDeleGatorCoreFull.redeemDelegation.selector, abi.encode(delegations), action);

        PackedUserOperation memory userOp = createAndSignUserOp(users.carol, address(users.carol.deleGator), userOpCallData);

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;
        vm.prank(bundler);

        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);

        vm.expectEmit(address(entryPoint));
        // expect an event containing InvalidAuthority error
        emit UserOperationRevertReason(
            userOpHash, address(users.carol.deleGator), 0, abi.encodeWithSelector(IDelegationManager.InvalidAuthority.selector)
        );
        entryPoint.handleOps(userOps, bundler);
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
