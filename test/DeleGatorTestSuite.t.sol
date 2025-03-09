// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { IEntryPoint, EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ExecutionHelper } from "@erc7579/core/ExecutionHelper.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { IERC7821 } from "../src/interfaces/IERC7821.sol";
import { EIP7702DeleGatorCore } from "../src/EIP7702/EIP7702DeleGatorCore.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import {
    Delegation,
    Caveat,
    PackedUserOperation,
    Delegation,
    Execution,
    ModeCode,
    ModePayload,
    ExecType,
    CallType
} from "../src/utils/Types.sol";
import { CALLTYPE_SINGLE, CALLTYPE_BATCH, EXECTYPE_DEFAULT, EXECTYPE_TRY, MODE_DEFAULT } from "../src/utils/Constants.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { Counter } from "./utils/Counter.t.sol";
import { StorageUtilsLib } from "./utils/StorageUtilsLib.t.sol";
import { SigningUtilsLib } from "./utils/SigningUtilsLib.t.sol";
import { EXECUTE_SIGNATURE, EXECUTE_SINGULAR_SIGNATURE } from "./utils/Constants.sol";
import { IDeleGatorCore } from "../src/interfaces/IDeleGatorCore.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { DeleGatorCore } from "../src/DeleGatorCore.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { AllowedMethodsEnforcer } from "../src/enforcers/AllowedMethodsEnforcer.sol";
import { AllowedTargetsEnforcer } from "../src/enforcers/AllowedTargetsEnforcer.sol";
import { HybridDeleGator } from "../src/HybridDeleGator.sol";
import { MultiSigDeleGator } from "../src/MultiSigDeleGator.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";

abstract contract DeleGatorTestSuite is BaseTest {
    using MessageHashUtils for bytes32;

    ////////////////////////////// Setup //////////////////////

    Counter aliceDeleGatorCounter;
    Counter bobDeleGatorCounter;
    ModeCode[] oneSingularMode;

    function setUp() public virtual override {
        super.setUp();

        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        vm.label(address(allowedMethodsEnforcer), "Allowed Methods Enforcer");
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        vm.label(address(allowedTargetsEnforcer), "Allowed Targets Enforcer");

        aliceDeleGatorCounter = new Counter(address(users.alice.deleGator));
        bobDeleGatorCounter = new Counter(address(users.bob.deleGator));

        oneSingularMode = new ModeCode[](1);
        oneSingularMode[0] = singleDefaultMode;
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
    event SentPrefund(address indexed sender, uint256 amount, bool success);
    event RedeemedDelegation(address indexed rootDelegator, address indexed redeemer, Delegation delegation);

    /// Hook: Expect an invalid empty signature revert.
    function encodeInvalidEmptySignatureRevertReason() internal virtual returns (bytes memory);

    /// Hook: Expect an invalid signature revert.
    function encodeInvalidSignatureRevertReason() internal virtual returns (bytes memory);

    /// Hook: Expect the revert that occurs when not called from the EntryPoint.
    function encodeNotEntryPointRevertReason() internal virtual returns (bytes memory);

    ////////////////////////////// Core Functionality //////////////////////////////

    function test_erc165_supportsInterface() public {
        // should support the following interfaces
        assertTrue(users.alice.deleGator.supportsInterface(type(IERC165).interfaceId));
        assertTrue(users.alice.deleGator.supportsInterface(type(IERC1271).interfaceId));
        assertTrue(users.alice.deleGator.supportsInterface(type(IERC1155Receiver).interfaceId));
        assertTrue(users.alice.deleGator.supportsInterface(type(IERC721Receiver).interfaceId));
        assertTrue(users.alice.deleGator.supportsInterface(type(IDeleGatorCore).interfaceId));

        if (IMPLEMENTATION == Implementation.EIP7702Stateless) {
            assertTrue(users.alice.deleGator.supportsInterface(type(IERC7821).interfaceId));
        }
    }

    // should allow retrieval of the delegation manager
    function test_allow_getDelegationManager() public {
        assertEq(address(users.alice.deleGator.delegationManager()), address(delegationManager));
    }

    // should allow the delegator account to receive native tokens
    function test_allow_receiveNativeToken() public {
        uint256 balanceBefore_ = address(users.alice.deleGator).balance;
        (bool success_,) = address(users.alice.deleGator).call{ value: 1 ether }("");
        assertTrue(success_);
        assertEq(address(users.alice.deleGator).balance, balanceBefore_ + 1 ether);
    }

    // should allow retrieval of the domain values
    function test_allow_getDomainValues() public {
        (,, string memory version_, uint256 chainId_, address verifyingContract,,) = users.alice.deleGator.eip712Domain();

        assertEq(version_, "1");
        assertEq(chainId_, block.chainid);
        assertEq(verifyingContract, address(users.alice.deleGator));
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

    // should not allow using a delegation without a contract signature
    function test_notAllow_delegationWithoutContactSignature() public {
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory revertReason_ = encodeInvalidEmptySignatureRevertReason();
        vm.expectRevert(revertReason_);

        vm.prank(address(users.bob.deleGator));
        users.bob.deleGator.redeemDelegations(permissionContexts_, oneSingularMode, executionCallDatas_);
    }

    // should not allow using a delegation without an EOA signature
    function test_notAllow_delegationWithoutEOASignature() public {
        (address someEOAUser_) = makeAddr("SomeEOAUser");

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: someEOAUser_,
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        Execution memory execution_;
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, uint256(0)));

        vm.prank(address(users.bob.deleGator));
        users.bob.deleGator.redeemDelegations(permissionContexts_, oneSingularMode, executionCallDatas_);
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

        // Create Bob's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        invokeDelegation_UserOp(users.bob, delegations_, execution_);

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

        bytes memory userOpCallData_ = abi.encodeWithSelector(
            DeleGatorCore.redeemDelegations.selector, permissionContexts_, oneSingularMode, executionCallDatas_
        );

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

    // should emit an event when paying the prefund
    function test_emit_sentPrefund() public {
        PackedUserOperation memory userOp_ = createAndSignUserOp(users.alice, address(users.alice.deleGator), hex"");

        vm.startPrank(address(entryPoint));

        vm.expectEmit(true, true, true, true, address(users.alice.deleGator));
        emit SentPrefund(address(entryPoint), 1, true);
        users.alice.deleGator.validateUserOp(userOp_, bytes32(0), 1);

        vm.expectEmit(true, true, true, true, address(users.alice.deleGator));
        emit SentPrefund(address(entryPoint), type(uint256).max, false);
        users.alice.deleGator.validateUserOp(userOp_, bytes32(0), type(uint256).max);
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
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Validate that the count has increased by 1
        updatedValue_ = aliceDeleGatorCounter.count();
        assertEq(updatedValue_, initialValue_ + 1);
        initialValue_ = updatedValue_;

        // Bob redeems the delegation
        vm.prank(users.bob.addr);

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        delegationManager.redeemDelegations(permissionContexts_, oneSingularMode, executionCallDatas_);

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
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = bobDelegation_;
        delegations_[1] = aliceDelegation_;

        // Carol redeems the delegation
        vm.prank(users.carol.addr);
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        delegationManager.redeemDelegations(permissionContexts_, oneSingularMode, executionCallDatas_);

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

        // Create Bob's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        vm.prank(users.bob.addr);
        vm.expectRevert();

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode("quack");

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        delegationManager.redeemDelegations(permissionContexts_, oneSingularMode, executionCallDatas_);

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

        // Create Bob's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);

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

        // Create Bob's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Redeem Bob's delegation
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        vm.prank(users.bob.addr);

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        delegationManager.redeemDelegations(permissionContexts_, oneSingularMode, executionCallDatas_);

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

        // Create Carol's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Redeem Carol's delegation
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = delegation2_;
        delegations_[1] = delegation1_;

        vm.prank(users.carol.addr);

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        delegationManager.redeemDelegations(permissionContexts_, oneSingularMode, executionCallDatas_);

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

        // Create Carol's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Redeem Carol's delegation
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = delegation2_;
        delegations_[1] = delegation1_;

        vm.prank(users.carol.addr);
        bytes memory revertReason_ = encodeInvalidSignatureRevertReason();
        vm.expectRevert(revertReason_);

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        delegationManager.redeemDelegations(permissionContexts_, oneSingularMode, executionCallDatas_);

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

        // Create Bob's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);

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

        // Create Carol's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Execute Carol's UserOp
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = bobDelegation_;
        delegations_[1] = aliceDelegation_;

        invokeDelegation_UserOp(users.carol, delegations_, execution_);

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

        // Create Dave's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Execute Dave's UserOp
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = carolDelegation_;
        delegations_[1] = aliceDelegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        PackedUserOperation memory userOp_ = createAndSignUserOp(
            users.dave,
            address(users.dave.deleGator),
            abi.encodeWithSelector(
                DeleGatorCore.redeemDelegations.selector, permissionContexts_, oneSingularMode, executionCallDatas_
            )
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

        // Create Carol's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Execute Carol's UserOp
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = bobDelegation_;
        delegations_[1] = aliceDelegation_;

        invokeDelegation_UserOp(users.carol, delegations_, execution_);

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

        // Create Carol's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Execute Carol's UserOp
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = bobDelegation_;
        delegations_[1] = aliceDelegation_;

        vm.prank(users.carol.addr);

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        delegationManager.redeemDelegations(permissionContexts_, oneSingularMode, executionCallDatas_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue_, initialValue_ + 1);
    }

    // should allow Alice to execute a single execution with a single UserOp
    function test_allow_singleExecution_UserOp() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Execute Executions
        bytes memory userOpCallData_ = abi.encodeWithSignature(
            EXECUTE_SIGNATURE,
            singleDefaultMode,
            ExecutionLib.encodeSingle(address(aliceDeleGatorCounter), 0, abi.encodeWithSelector(Counter.increment.selector))
        );
        PackedUserOperation memory userOp_ = createUserOp(address(users.alice.deleGator), userOpCallData_);
        bytes32 userOpHash_ = getPackedUserOperationTypedDataHash(userOp_);
        userOp_.signature = signHash(users.alice, userOpHash_);

        submitUserOp_Bundler(userOp_, false);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the delegations_ were worked
        assertEq(finalValue_, initialValue_ + 1);
    }

    // should allow Alice to execute multiple Executions in a single UserOp
    function test_allow_multiExecution_UserOp() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create Executions
        Execution[] memory executionCallDatas_ = new Execution[](2);
        executionCallDatas_[0] = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        executionCallDatas_[1] = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Execute Executions
        bytes memory userOpCallData_ = abi.encodeWithSignature(EXECUTE_SIGNATURE, batchDefaultMode, abi.encode(executionCallDatas_));
        PackedUserOperation memory userOp_ = createUserOp(address(users.alice.deleGator), userOpCallData_);
        bytes32 userOpHash_ = getPackedUserOperationTypedDataHash(userOp_);
        userOp_.signature = signHash(users.alice, userOpHash_);
        submitUserOp_Bundler(userOp_, false);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the delegations_ were worked
        assertEq(finalValue_, initialValue_ + 2);
    }

    // should allow Alice to execute a single Execution in a single UserOp that catches reverts
    function test_allow_trySingleExecution_UserOp() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Execute Executions
        bytes memory userOpCallData_ = abi.encodeWithSignature(
            EXECUTE_SIGNATURE,
            singleTryMode,
            ExecutionLib.encodeSingle(address(aliceDeleGatorCounter), 0, abi.encodeWithSelector(Counter.increment.selector))
        );
        PackedUserOperation memory userOp_ = createUserOp(address(users.alice.deleGator), userOpCallData_);
        bytes32 userOpHash_ = getPackedUserOperationTypedDataHash(userOp_);
        userOp_.signature = signHash(users.alice, userOpHash_);
        submitUserOp_Bundler(userOp_, false);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the delegations_ were worked
        assertEq(finalValue_, initialValue_ + 1);
    }

    // should allow Alice to execute multiple Executions in a single UserOp that catches reverts
    function test_allow_tryMultiExecution_UserOp() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Create Executions
        Execution[] memory executionCallDatas_ = new Execution[](2);
        executionCallDatas_[0] = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        executionCallDatas_[1] = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Execute Executions
        bytes memory userOpCallData_ = abi.encodeWithSignature(EXECUTE_SIGNATURE, batchTryMode, abi.encode(executionCallDatas_));
        PackedUserOperation memory userOp_ = createUserOp(address(users.alice.deleGator), userOpCallData_);
        bytes32 userOpHash_ = getPackedUserOperationTypedDataHash(userOp_);
        userOp_.signature = signHash(users.alice, userOpHash_);
        submitUserOp_Bundler(userOp_, false);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the delegations_ were worked
        assertEq(finalValue_, initialValue_ + 2);
    }

    // should not allow an unsupported callType
    function test_notAllow_unsupportedCallType_UserOp() public {
        ModeCode mode_ = ModeLib.encode(CallType.wrap(0x02), EXECTYPE_DEFAULT, MODE_DEFAULT, ModePayload.wrap(0x00));
        // Execute Executions
        bytes memory userOpCallData_ = abi.encodeWithSignature(
            EXECUTE_SIGNATURE,
            mode_,
            ExecutionLib.encodeSingle(address(aliceDeleGatorCounter), 0, abi.encodeWithSelector(Counter.increment.selector))
        );
        PackedUserOperation memory userOp_ = createUserOp(address(users.alice.deleGator), userOpCallData_);
        bytes32 userOpHash_ = getPackedUserOperationTypedDataHash(userOp_);
        userOp_.signature = signHash(users.alice, userOpHash_);

        bytes memory revertReason_ = abi.encodeWithSelector(DeleGatorCore.UnsupportedCallType.selector, CallType.wrap(0x02));
        // Expect a revert event
        vm.expectEmit(false, false, false, true, address(entryPoint));
        emit UserOperationRevertReason(userOpHash_, address(users.alice.deleGator), 0, revertReason_);

        submitUserOp_Bundler(userOp_, false);
    }

    // should not allow an unsupported execType
    function test_notAllow_singleUnsupportedExecType_UserOp() public {
        ModeCode mode_ = ModeLib.encode(CALLTYPE_SINGLE, ExecType.wrap(0x02), MODE_DEFAULT, ModePayload.wrap(0x00));
        // Execute Executions
        bytes memory userOpCallData_ = abi.encodeWithSignature(
            EXECUTE_SIGNATURE,
            mode_,
            ExecutionLib.encodeSingle(address(aliceDeleGatorCounter), 0, abi.encodeWithSelector(Counter.increment.selector))
        );
        PackedUserOperation memory userOp_ = createUserOp(address(users.alice.deleGator), userOpCallData_);
        bytes32 userOpHash_ = getPackedUserOperationTypedDataHash(userOp_);
        userOp_.signature = signHash(users.alice, userOpHash_);

        bytes memory revertReason_ = abi.encodeWithSelector(DeleGatorCore.UnsupportedExecType.selector, ExecType.wrap(0x02));
        // Expect a revert event
        vm.expectEmit(false, false, false, true, address(entryPoint));
        emit UserOperationRevertReason(userOpHash_, address(users.alice.deleGator), 0, revertReason_);
        submitUserOp_Bundler(userOp_, false);
    }

    // should not allow an unsupported execType in a batch
    function test_notAllow_multiUnsupportedExecType_UserOp() public {
        ModeCode mode_ = ModeLib.encode(CALLTYPE_BATCH, ExecType.wrap(0x02), MODE_DEFAULT, ModePayload.wrap(0x00));
        // Create Executions
        Execution[] memory executionCallDatas_ = new Execution[](2);
        executionCallDatas_[0] = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        executionCallDatas_[1] = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Execute Executions
        bytes memory userOpCallData_ = abi.encodeWithSignature(EXECUTE_SIGNATURE, mode_, abi.encode(executionCallDatas_));
        PackedUserOperation memory userOp_ = createUserOp(address(users.alice.deleGator), userOpCallData_);
        bytes32 userOpHash_ = getPackedUserOperationTypedDataHash(userOp_);
        userOp_.signature = signHash(users.alice, userOpHash_);

        bytes memory revertReason_ = abi.encodeWithSelector(DeleGatorCore.UnsupportedExecType.selector, ExecType.wrap(0x02));
        // Expect a revert event
        vm.expectEmit(false, false, false, true, address(entryPoint));
        emit UserOperationRevertReason(userOpHash_, address(users.alice.deleGator), 0, revertReason_);
        submitUserOp_Bundler(userOp_, false);
    }

    // should allow Bob to execute multiple Executions that redeem delegations_ in a single UserOp (offchain)
    function test_allow_multiExecutionDelegationClaim_Offchain_UserOp() public {
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

        // Create Execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Invoke delegation calldata
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        bytes memory invokeDelegationCalldata_ = abi.encodeWithSelector(
            DeleGatorCore.redeemDelegations.selector, permissionContexts_, oneSingularMode, executionCallDatas_
        );

        // Create invoke delegation Executions
        Execution[] memory redemptionExecutions_ = new Execution[](2);
        redemptionExecutions_[0] =
            Execution({ target: address(users.bob.deleGator), value: 0, callData: invokeDelegationCalldata_ });
        redemptionExecutions_[1] =
            Execution({ target: address(users.bob.deleGator), value: 0, callData: invokeDelegationCalldata_ });

        // Execute delegations_
        executeBatch_UserOp(users.bob, redemptionExecutions_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the counts were increased
        assertEq(finalValue_, initialValue_ + 2);
    }

    // should allow Alice to execute a combination of Executions through a single UserOp
    function test_allow_multiExecutionCombination_UserOp() public {
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
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] =
            ExecutionLib.encodeSingle(address(aliceDeleGatorCounter), 0, abi.encodeWithSelector(Counter.increment.selector));

        bytes memory invokeDelegationCalldata_ = abi.encodeWithSelector(
            DeleGatorCore.redeemDelegations.selector, permissionContexts_, oneSingularMode, executionCallDatas_
        );

        // Create invoke delegation Executions
        Execution[] memory redemptionExecutions_ = new Execution[](2);
        redemptionExecutions_[0] =
            Execution({ target: address(users.bob.deleGator), value: 0, callData: invokeDelegationCalldata_ });
        redemptionExecutions_[1] = Execution({
            target: address(bobDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Execute delegations_
        executeBatch_UserOp(users.bob, redemptionExecutions_);

        // Get final count
        uint256 finalValueAlice_ = aliceDeleGatorCounter.count();
        uint256 finalValueBob_ = bobDeleGatorCounter.count();

        // Validate that the counts were increased
        assertEq(finalValueAlice_, initialValueAlice_ + 1);
        assertEq(finalValueBob_, initialValueBob_ + 1);
    }

    // should allow Alice to execute a single Executions in a single UserOp
    function test_allow_executeFromExecutor() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Execute Execution
        vm.prank(address(delegationManager));
        users.alice.deleGator.executeFromExecutor(
            singleDefaultMode,
            ExecutionLib.encodeSingle(address(aliceDeleGatorCounter), 0, abi.encodeWithSelector(Counter.increment.selector))
        );

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the delegations_ were worked
        assertEq(finalValue_, initialValue_ + 1);
    }

    // should allow Alice to execute a single Executions in a single UserOp
    function test_allow_executeFromExecutor_batch() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Execute Execution
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        executions_[1] = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        vm.prank(address(delegationManager));
        users.alice.deleGator.executeFromExecutor(batchDefaultMode, ExecutionLib.encodeBatch(executions_));

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the delegations_ were worked
        assertEq(finalValue_, initialValue_ + 2);
    }

    // should allow Alice to execute a single Executions in a single UserOp
    function test_allow_tryExecuteFromExecutor() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Execute Execution
        vm.prank(address(delegationManager));
        users.alice.deleGator.executeFromExecutor(
            singleTryMode,
            ExecutionLib.encodeSingle(address(aliceDeleGatorCounter), 0, abi.encodeWithSelector(Counter.increment.selector))
        );

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the delegations_ were worked
        assertEq(finalValue_, initialValue_ + 1);
    }

    // should allow Alice to execute a single Executions in a single UserOp
    function test_allow_tryExecuteFromExecutor_batch() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValue_ = aliceDeleGatorCounter.count();

        // Execute Execution
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        executions_[1] = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        vm.prank(address(delegationManager));
        users.alice.deleGator.executeFromExecutor(batchTryMode, ExecutionLib.encodeBatch(executions_));

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the delegations_ were worked
        assertEq(finalValue_, initialValue_ + 2);
    }

    // should allow Alice to execute a single Executions in a single UserOp
    function test_allow_executeFromExecutorUnsupportedExecType() public {
        ModeCode mode_ = ModeLib.encode(CALLTYPE_SINGLE, ExecType.wrap(0x02), MODE_DEFAULT, ModePayload.wrap(0x00));

        bytes memory revertReason_ = abi.encodeWithSelector(DeleGatorCore.UnsupportedExecType.selector, ExecType.wrap(0x02));
        vm.expectRevert(revertReason_);

        // Execute Execution
        vm.prank(address(delegationManager));
        users.alice.deleGator.executeFromExecutor(
            mode_, ExecutionLib.encodeSingle(address(aliceDeleGatorCounter), 0, abi.encodeWithSelector(Counter.increment.selector))
        );
    }

    // should allow Alice to execute a single Executions in a single UserOp
    function test_notAllow_executeFromExecutorUnsupportedExecType_batch() public {
        ModeCode mode_ = ModeLib.encode(CALLTYPE_BATCH, ExecType.wrap(0x02), MODE_DEFAULT, ModePayload.wrap(0x00));
        // Execute Execution
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        executions_[1] = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        bytes memory revertReason_ = abi.encodeWithSelector(DeleGatorCore.UnsupportedExecType.selector, ExecType.wrap(0x02));
        vm.expectRevert(revertReason_);

        vm.prank(address(delegationManager));
        users.alice.deleGator.executeFromExecutor(mode_, ExecutionLib.encodeBatch(executions_));
    }

    // should allow Alice to execute a single Executions in a single UserOp
    function test_notAllow_executeFromExecutorUnsupportedCallType() public {
        ModeCode mode_ = ModeLib.encode(CallType.wrap(0x02), EXECTYPE_TRY, MODE_DEFAULT, ModePayload.wrap(0x00));

        bytes memory revertReason_ = abi.encodeWithSelector(DeleGatorCore.UnsupportedCallType.selector, CallType.wrap(0x02));
        vm.expectRevert(revertReason_);

        // Execute Execution
        vm.prank(address(delegationManager));
        users.alice.deleGator.executeFromExecutor(
            mode_, ExecutionLib.encodeSingle(address(aliceDeleGatorCounter), 0, abi.encodeWithSelector(Counter.increment.selector))
        );
    }

    ////////////////////////////// Invalid cases //////////////////////////////

    // should not allow a second Execution to execute if the first Execution fails
    function test_notAllow_multiExecutionUserOp() public {
        // Get Alice's DeleGator's Counter's initial count
        uint256 initialValueAlice_ = aliceDeleGatorCounter.count();
        uint256 initialValueBob_ = bobDeleGatorCounter.count();

        // Create Executions, incorrectly incrementing Bob's Counter first
        Execution[] memory executionCallDatas_ = new Execution[](2);
        executionCallDatas_[0] = Execution({
            target: address(bobDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        executionCallDatas_[1] = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Execute Executions
        executeBatch_UserOp(users.alice, executionCallDatas_);

        // Get final count
        uint256 finalValueAlice_ = aliceDeleGatorCounter.count();
        uint256 finalValueBob_ = bobDeleGatorCounter.count();

        // Validate that the counts were not increased
        assertEq(finalValueAlice_, initialValueAlice_);
        assertEq(finalValueBob_, initialValueBob_);
    }

    // should revert without reason and catch it
    function test_executionRevertsWithoutReason() public {
        // Invalid execution_, sending ETH to a contract that can't receive it.
        Execution memory execution_ = Execution({ target: address(aliceDeleGatorCounter), value: 1, callData: hex"" });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        // Expect it to emit a bubbled up reverted event
        vm.expectRevert();
        users.alice.deleGator.executeFromExecutor(singleDefaultMode, executionCallData_);
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

        // Create Carol's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Execute Carol's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.carol, delegations_, execution_);

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
                abi.encodeWithSelector(DeleGatorCore.NotEntryPoint.selector)
            )
        );
        newEntryPoint_.handleOps(userOps_, bundler);

        // Create Alice's UserOp (with invalid EntryPoint)
        userOp_ = createUserOp(address(users.alice.deleGator), userOpCallData_);
        userOp_ = signUserOp(users.alice, userOp_);

        // Submit the UserOp through the Bundler
        vm.prank(bundler);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEntryPoint.FailedOpWithRevert.selector,
                0,
                "AA23 reverted",
                abi.encodeWithSelector(DeleGatorCore.NotEntryPoint.selector)
            )
        );
        newEntryPoint_.handleOps(userOps_, bundler);
    }

    // should NOT allow a UserOp with an invalid signature
    function test_notAllow_invalidUserOpSignature() public {
        // Create execution_
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Create Alice's UserOp
        bytes memory userOpCallData_ = abi.encodeWithSignature(EXECUTE_SINGULAR_SIGNATURE, execution_);
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
        // Create execution_
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Create and Sign Alice's UserOp
        PackedUserOperation memory userOp_ = createAndSignUserOp(
            users.alice, address(users.alice.deleGator), abi.encodeWithSignature(EXECUTE_SINGULAR_SIGNATURE, execution_)
        );

        // Submit the UserOp through the Bundler
        submitUserOp_Bundler(userOp_);

        // Submit the UserOp through the Bundler again
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA25 invalid account nonce"));
        submitUserOp_Bundler(userOp_);
    }

    ////////////////////////////// EVENTS Emission //////////////////////////////

    function test_event_Deposited() public {
        Execution memory execution_ = Execution({
            target: address(users.alice.deleGator),
            value: 1 ether,
            callData: abi.encodeWithSelector(DeleGatorCore.addDeposit.selector)
        });

        PackedUserOperation memory userOp_ = createAndSignUserOp(
            users.alice, address(users.alice.deleGator), abi.encodeWithSignature(EXECUTE_SINGULAR_SIGNATURE, execution_)
        );

        vm.expectEmit(true, false, false, true);
        emit Deposited(address(users.alice.deleGator), 1 ether);

        submitUserOp_Bundler(userOp_);
    }

    function test_allow_withdrawDeposit() public {
        Execution memory execution_ = Execution({
            target: address(users.alice.deleGator),
            value: 1 ether,
            callData: abi.encodeWithSelector(DeleGatorCore.addDeposit.selector)
        });

        PackedUserOperation memory userOp_ = createAndSignUserOp(
            users.alice, address(users.alice.deleGator), abi.encodeWithSignature(EXECUTE_SINGULAR_SIGNATURE, execution_)
        );

        submitUserOp_Bundler(userOp_);

        execution_ = Execution({
            target: address(users.alice.deleGator),
            value: 0 ether,
            callData: abi.encodeWithSelector(DeleGatorCore.withdrawDeposit.selector, address(users.alice.addr), 0.5 ether)
        });

        userOp_ = createAndSignUserOp(
            users.alice, address(users.alice.deleGator), abi.encodeWithSignature(EXECUTE_SINGULAR_SIGNATURE, execution_)
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

        // Create Bob's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Redeem Bob's delegation
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(users.bob.addr);
        vm.expectRevert();
        delegationManager.redeemDelegations(permissionContexts_, oneSingularMode, executionCallDatas_);

        // Get final count
        uint256 finalValue_ = aliceDeleGatorCounter.count();

        // Validate that the count has not increased by 1
        assertEq(finalValue_, initialValue_);
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

        // Create Bob's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        // create user operation calldata for invokeDelegation
        bytes memory userOpCallData_ = abi.encodeWithSelector(
            DeleGatorCore.redeemDelegations.selector, permissionContexts_, oneSingularMode, executionCallDatas_
        );

        PackedUserOperation memory userOp_ = createAndSignUserOp(users.carol, address(users.carol.deleGator), userOpCallData_);

        PackedUserOperation[] memory userOps_ = new PackedUserOperation[](1);
        userOps_[0] = userOp_;

        // prank from bundler
        vm.prank(bundler);

        // get UserOperation hash
        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);

        vm.expectEmit(true, true, false, true, address(entryPoint));
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

        // Create Bob's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // signing the userOp_ from bob
        uint256[] memory signers_ = new uint256[](1);
        signers_[0] = users.bob.privateKey;

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        bytes memory userOpCallData_ = abi.encodeWithSelector(
            DeleGatorCore.redeemDelegations.selector, permissionContexts_, oneSingularMode, executionCallDatas_
        );

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
            userOpHash_,
            address(users.bob.deleGator),
            0,
            abi.encodeWithSelector(IDelegationManager.InvalidERC1271Signature.selector)
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

        // Create Bob's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        // create user operation calldata for invokeDelegation
        bytes memory userOpCallData_ = abi.encodeWithSelector(
            DeleGatorCore.redeemDelegations.selector, permissionContexts_, oneSingularMode, executionCallDatas_
        );

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
            userOpHash_,
            address(users.bob.deleGator),
            0,
            abi.encodeWithSelector(IDelegationManager.InvalidERC1271Signature.selector)
        );

        entryPoint.handleOps(userOps_, bundler);
    }

    // Should revert if executeFromExecutor is called from an address other than the DelegationManager
    function test_notAllow_notDelegationManager() public {
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.expectRevert(abi.encodeWithSelector(DeleGatorCore.NotDelegationManager.selector));
        users.alice.deleGator.executeFromExecutor(singleDefaultMode, executionCallData_);
    }

    // Should revert if execute is called from an address other than the EntryPoint
    function test_notAllow_notEntryPoint() public {
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory revertReason_ = encodeNotEntryPointRevertReason();
        vm.expectRevert(revertReason_);
        users.alice.deleGator.execute(execution_);
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

        // Create Carol's execution
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = bobDelegation_;
        delegations_[1] = aliceDelegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // create user operation calldata for invokeDelegation
        bytes memory userOpCallData_ = abi.encodeWithSelector(
            DeleGatorCore.redeemDelegations.selector, permissionContexts_, oneSingularMode, executionCallDatas_
        );

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

    function test_replayAttackAcrossEntryPoints() public {
        // Deploy a second EntryPoint
        EntryPoint newEntryPoint_ = new EntryPoint();
        vm.label(address(newEntryPoint_), "New EntryPoint");

        // 1. Create a UserOp that will be valid with the original EntryPoint
        address aliceDeleGatorAddr_ = address(users.alice.deleGator);

        // A simple operation to transfer ETH to Bob
        Execution memory execution_ = Execution({ target: users.bob.addr, value: 1 ether, callData: hex"" });

        // Create the UserOp with current EntryPoint
        bytes memory userOpCallData_ = abi.encodeWithSignature(EXECUTE_SINGULAR_SIGNATURE, execution_);
        PackedUserOperation memory userOp_ = createUserOp(aliceDeleGatorAddr_, userOpCallData_);

        // Alice signs it with the current EntryPoint's context
        userOp_.signature = signHash(users.alice, getPackedUserOperationTypedDataHash(userOp_));

        // Bob's initial balance for verification
        uint256 bobInitialBalance = users.bob.addr.balance;

        // 1. Execute the original UserOp through the first EntryPoint
        PackedUserOperation[] memory userOps_ = new PackedUserOperation[](1);
        userOps_[0] = userOp_;
        vm.prank(bundler);
        entryPoint.handleOps(userOps_, bundler);

        // Verify first execution worked
        uint256 bobBalanceAfterExecution_ = users.bob.addr.balance;
        assertEq(bobBalanceAfterExecution_, bobInitialBalance + 1 ether);

        // 2. Upgrade the code implementation
        vm.startPrank(address(entryPoint));

        // Upgrade to a new implementation and validate that the signers remain the same.
        if (IMPLEMENTATION == Implementation.Hybrid) {
            address newImpl_ = address(new HybridDeleGator(delegationManager, newEntryPoint_));
            users.alice.deleGator.upgradeToAndCallAndRetainStorage(newImpl_, hex"");
            HybridDeleGator hybridDeleGator_ = HybridDeleGator(payable(aliceDeleGatorAddr_));
            assertEq(hybridDeleGator_.owner(), users.alice.addr);
            (uint256 x_, uint256 y_) = hybridDeleGator_.getKey(users.alice.name);
            assertEq(x_, users.alice.x);
            assertEq(y_, users.alice.y);
        } else if (IMPLEMENTATION == Implementation.MultiSig) {
            address newImpl_ = address(new MultiSigDeleGator(delegationManager, newEntryPoint_));
            users.alice.deleGator.upgradeToAndCallAndRetainStorage(newImpl_, hex"");
            MultiSigDeleGator multiSigDeleGator_ = MultiSigDeleGator(payable(aliceDeleGatorAddr_));
            assertTrue(multiSigDeleGator_.isSigner(users.alice.addr));
        } else if (IMPLEMENTATION == Implementation.EIP7702Stateless) {
            address newImpl_ = address(new EIP7702StatelessDeleGator(delegationManager, newEntryPoint_));
            vm.etch(aliceDeleGatorAddr_, bytes.concat(hex"ef0100", abi.encodePacked(newImpl_)));
        } else {
            revert("Invalid Implementation");
        }
        vm.stopPrank();

        // Verify the implementation was updated
        assertEq(address(users.alice.deleGator.entryPoint()), address(newEntryPoint_));

        // 3. Attempt to replay the original UserOp through the new EntryPoint
        vm.prank(bundler);

        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        newEntryPoint_.handleOps(userOps_, bundler);

        // 4. Verify if the attack did not succeed - check if Bob received ETH again
        assertEq(users.bob.addr.balance, bobBalanceAfterExecution_);
    }
}

abstract contract UUPSDeleGatorTest is DeleGatorTestSuite {
    function encodeInvalidEmptySignatureRevertReason() internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(IDelegationManager.InvalidERC1271Signature.selector);
    }

    function encodeInvalidSignatureRevertReason() internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(IDelegationManager.InvalidEOASignature.selector);
    }

    function encodeNotEntryPointRevertReason() internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(DeleGatorCore.NotEntryPoint.selector);
    }
}

abstract contract EIP7702DeleGatorTest is DeleGatorTestSuite {
    function encodeInvalidEmptySignatureRevertReason() internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, uint256(0));
    }

    function encodeInvalidSignatureRevertReason() internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(IDelegationManager.InvalidERC1271Signature.selector);
    }

    function encodeNotEntryPointRevertReason() internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(DeleGatorCore.NotEntryPointOrSelf.selector);
    }
}

contract HybridDeleGator_TestSuite_P256_Test is UUPSDeleGatorTest {
    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
    }
}

contract HybridDeleGator_TestSuite_EOA_Test is UUPSDeleGatorTest {
    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.EOA;
    }
}

contract MultiSig_TestSuite_Test is UUPSDeleGatorTest {
    constructor() {
        IMPLEMENTATION = Implementation.MultiSig;
        SIGNATURE_TYPE = SignatureType.MultiSig;
    }
}

contract EIP7702Staless_TestSuite_Test is EIP7702DeleGatorTest {
    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }
}
