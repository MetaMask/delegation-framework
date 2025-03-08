// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IEntryPoint, EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { BytesLib } from "@bytes-utils/BytesLib.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { ERC1967Proxy as DeleGatorProxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { SigningUtilsLib } from "./utils/SigningUtilsLib.t.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { Execution, PackedUserOperation, Caveat, Delegation, ModeCode } from "../src/utils/Types.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { AccountSorterLib } from "./utils/AccountSorterLib.t.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { DeleGatorCore } from "../src/DeleGatorCore.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { Counter } from "./utils/Counter.t.sol";
import { UserOperationLib } from "./utils/UserOperationLib.t.sol";
import { SimpleFactory } from "../src/utils/SimpleFactory.sol";
import { ERC1271Lib } from "../src/libraries/ERC1271Lib.sol";
import { EIP7702DeleGatorCore } from "../src/EIP7702/EIP7702DeleGatorCore.sol";
import {
    CALLTYPE_SINGLE,
    CALLTYPE_DELEGATECALL,
    EXECTYPE_DEFAULT,
    MODE_DEFAULT,
    ModeLib,
    ExecType,
    ModeSelector,
    ModePayload
} from "@erc7579/lib/ModeLib.sol";

/**
 * @title EIP7702 Stateless DeleGator Implementation Test
 * @dev These tests are for the EIP7702Stateless functionality of the EIP7702StatelessDeleGator contract.
 * @dev NOTE: All Smart Account interactions flow through ERC4337 UserOps.
 */
contract EIP7702StatelessDeleGatorTest is BaseTest {
    using MessageHashUtils for bytes32;

    ////////////////////// Configure BaseTest //////////////////////

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    ////////////////////////////// State //////////////////////////////

    // uint256 public constant MAX_NUMBER_OF_SIGNERS = 30;
    EIP7702StatelessDeleGator public aliceDeleGator;
    EIP7702StatelessDeleGator public bobDeleGator;
    Counter public aliceDeleGatorCounter;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();

        // Set up typed DeleGators
        aliceDeleGator = EIP7702StatelessDeleGator(payable(address(users.alice.deleGator)));
        bobDeleGator = EIP7702StatelessDeleGator(payable(address(users.bob.deleGator)));

        aliceDeleGatorCounter = new Counter(address(users.alice.deleGator));
    }

    ////////////////////// Basic Functionality //////////////////////

    // should allow retrieval of the account name
    function test_allow_getName() public {
        assertEq(aliceDeleGator.NAME(), "EIP7702StatelessDeleGator");
    }

    // should allow retrieval of the version
    function test_allow_getVersion() public {
        assertEq(aliceDeleGator.VERSION(), "1.3.0");
    }

    // should allow retrieval of the account name
    function test_notAllow_toSetLongName() public {
        string memory longName_ = "EIP7702StatelessDeleGatorName123";
        vm.expectRevert(EIP7702DeleGatorCore.InvalidEIP712NameLength.selector);
        new EIP7702DeleGatorTestMock(longName_, "SomeVersion");
    }

    // should allow retrieval of the version
    function test_notAllow_toSetLongVersion() public {
        string memory longVersion_ = "V1111111111111111111111111111111";
        vm.expectRevert(EIP7702DeleGatorCore.InvalidEIP712VersionLength.selector);
        new EIP7702DeleGatorTestMock("SomeName", longVersion_);
    }

    function test_emitEvent_DelegationManagerSet() public {
        vm.expectEmit(true, true, true, true);
        emit EIP7702DeleGatorCore.SetDelegationManager(delegationManager);
        new EIP7702StatelessDeleGator(delegationManager, entryPoint);
    }

    function test_emitEvent_EntryPointSet() public {
        vm.expectEmit(true, true, true, true);
        emit EIP7702DeleGatorCore.SetEntryPoint(entryPoint);
        new EIP7702StatelessDeleGator(delegationManager, entryPoint);
    }

    ////////////////////// Redeeming delegations //////////////////////

    // should allow Bob to redeem a delegation from Alice DeleGator
    function test_allow_invokeOffchainDelegation() public {
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

        // Sign delegation
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 domainHash_ = delegationManager.getDomainHash();
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(domainHash_, delegationHash_);
        bytes memory signature_ = SigningUtilsLib.signHash_EOA(users.alice.privateKey, typedDataHash_);
        delegation_.signature = signature_;

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

    ////////////////////// Signing data //////////////////////

    // should allow to validate the signature from an EOA
    function test_allow_signatureFromEOA() public {
        // Get signature
        bytes32 hash_ = keccak256("hello world");

        bytes memory signature_ = SigningUtilsLib.signHash_EOA(users.alice.privateKey, hash_);
        assertEq(aliceDeleGator.isValidSignature(hash_, signature_), ERC1271Lib.EIP1271_MAGIC_VALUE);
    }

    // should fail to validate the signature from a different EOA
    function test_notAllow_invalidSignatureFromInvalidEOA() public {
        // Get signature
        bytes32 hash_ = keccak256("hello world");

        // Show that a short signature is invalid (SIG_VALIDATION_FAILED = 0xffffffff)
        bytes memory signature_ = SigningUtilsLib.signHash_EOA(users.bob.privateKey, hash_);
        assertEq(aliceDeleGator.isValidSignature(hash_, signature_), ERC1271Lib.SIG_VALIDATION_FAILED);
    }

    // should fail to validate a short signature
    function test_notAllow_invalidSignatureLength() public {
        // Get signature
        bytes32 hash_ = keccak256("hello world");

        bytes memory signature_ = hex"ffff";

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, signature_.length));
        aliceDeleGator.isValidSignature(hash_, signature_);
    }

    ////////////////////// General //////////////////////

    // Test for function:  execute(Execution calldata _execution)
    function test_execute_Execution_accessControl() public {
        // Prepare an example execution call
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // 1. Call from a random address -> Should revert (NotEntryPointOrSelf)
        address randomUser_ = address(0xabcdef);
        vm.deal(randomUser_, 1 ether);
        vm.prank(randomUser_);
        vm.expectRevert(EIP7702DeleGatorCore.NotEntryPointOrSelf.selector);
        aliceDeleGator.execute(execution_);

        // 2. Call from the entry point -> Should succeed
        uint256 initialCount_ = aliceDeleGatorCounter.count();
        vm.prank(address(entryPoint));
        aliceDeleGator.execute(execution_);
        uint256 finalCount_ = aliceDeleGatorCounter.count();
        assertEq(finalCount_, initialCount_ + 1, "Counter should have incremented after entryPoint call");

        // 3. Call from the contract itself -> Should succeed
        initialCount_ = aliceDeleGatorCounter.count();
        vm.prank(address(aliceDeleGator));
        aliceDeleGator.execute(execution_);
        finalCount_ = aliceDeleGatorCounter.count();
        assertEq(finalCount_, initialCount_ + 1, "Counter should have incremented after self-call");
    }

    // Test for function: execute(ModeCode _mode, bytes calldata _executionCalldata)
    function test_execute_ModeCode_accessControl() public {
        // The callData for a single call: (target, value, callData)
        // We'll encode it via ExecutionLib or by standard abi.encodePacked:
        bytes memory execCalldata_ =
            abi.encodePacked(address(aliceDeleGatorCounter), uint256(0), abi.encodeWithSelector(Counter.increment.selector));

        // 1. Call from a random address -> Should revert
        address randomUser_ = address(0x12345);
        vm.prank(randomUser_);
        vm.expectRevert(EIP7702DeleGatorCore.NotEntryPointOrSelf.selector);
        aliceDeleGator.execute(singleDefaultMode, execCalldata_);

        // 2. Call from the entry point -> Should succeed
        uint256 initialCount_ = aliceDeleGatorCounter.count();
        vm.prank(address(entryPoint));
        aliceDeleGator.execute(singleDefaultMode, execCalldata_);
        uint256 finalCount_ = aliceDeleGatorCounter.count();
        assertEq(finalCount_, initialCount_ + 1, "Counter should have incremented from entryPoint call");

        // 3. Call from the contract itself -> Should succeed
        initialCount_ = aliceDeleGatorCounter.count();
        vm.prank(address(aliceDeleGator));
        aliceDeleGator.execute(singleDefaultMode, execCalldata_);
        finalCount_ = aliceDeleGatorCounter.count();
        assertEq(finalCount_, initialCount_ + 1, "Counter should have incremented from self-call");
    }

    // Test supportsExecutionMode() for each of the 4 available modes,
    function test_supportsExecutionMode() public {
        ModePayload modePayloadDefault_ = ModePayload.wrap(bytes22(0x00));

        assertTrue(aliceDeleGator.supportsExecutionMode(singleDefaultMode), "should support single revert");
        assertTrue(aliceDeleGator.supportsExecutionMode(singleTryMode), "should support single try");
        assertTrue(aliceDeleGator.supportsExecutionMode(batchDefaultMode), "should support batch revert");
        assertTrue(aliceDeleGator.supportsExecutionMode(batchTryMode), "should support batch try");

        // Test a random/unsupported mode
        ModeCode unsupportedMode_ = ModeCode.wrap(bytes32(uint256(12345)));
        assertFalse(aliceDeleGator.supportsExecutionMode(unsupportedMode_), "should not support random mode");

        unsupportedMode_ = ModeLib.encode(CALLTYPE_DELEGATECALL, EXECTYPE_DEFAULT, MODE_DEFAULT, modePayloadDefault_);
        assertFalse(aliceDeleGator.supportsExecutionMode(unsupportedMode_), "should not suppot unsupported calltype");

        unsupportedMode_ = ModeLib.encode(CALLTYPE_SINGLE, ExecType.wrap(0x02), MODE_DEFAULT, modePayloadDefault_);
        assertFalse(aliceDeleGator.supportsExecutionMode(unsupportedMode_), "should not suppot unsupported exectype");

        unsupportedMode_ =
            ModeLib.encode(CALLTYPE_SINGLE, EXECTYPE_DEFAULT, ModeSelector.wrap(bytes4(0x00000001)), modePayloadDefault_);
        assertFalse(aliceDeleGator.supportsExecutionMode(unsupportedMode_), "should not suppot unsupported mode selector");
    }
}

// @dev Only used for testing the EIP712 constructor validations
contract EIP7702DeleGatorTestMock is EIP7702DeleGatorCore {
    constructor(
        string memory eip712Name_,
        string memory eip712Version_
    )
        EIP7702DeleGatorCore(IDelegationManager(address(0)), IEntryPoint(address(0)), eip712Name_, eip712Version_)
    { }

    // @dev Implemented to comply with the abstract interface
    function _isValidSignature(bytes32 _hash, bytes calldata _signature) internal view virtual override returns (bytes4) { }
}
