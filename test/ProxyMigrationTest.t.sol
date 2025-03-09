// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { BytesLib } from "@bytes-utils/BytesLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { SigningUtilsLib } from "./utils/SigningUtilsLib.t.sol";
import { StorageUtilsLib } from "./utils/StorageUtilsLib.t.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { Execution, PackedUserOperation, Caveat, Delegation } from "../src/utils/Types.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { HybridDeleGator } from "../src/HybridDeleGator.sol";
import { MultiSigDeleGator } from "../src/MultiSigDeleGator.sol";
import { DeleGatorCore } from "../src/DeleGatorCore.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { EXECUTE_SINGULAR_SIGNATURE } from "./utils/Constants.sol";

contract HybridDeleGator_Test is BaseTest {
    using MessageHashUtils for bytes32;

    event ClearedStorage();

    ////////////////////// Configure BaseTest //////////////////////

    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
    }

    ////////////////////////////// Tests //////////////////////////////

    // should accurately switch between implementations several times
    function test_upgradeMultipleTimes() public {
        // Load storage locations
        bytes32 INITIALIZABLE_STORAGE_LOCATION = StorageUtilsLib.getStorageLocation("openzeppelin.storage.Initializable");

        // Create a MultiSigDeleGator to manipulate
        address payable deleGator_ = payable(address(deployDeleGator_MultiSig(users.alice)));
        vm.label(deleGator_, "DeleGator");
        vm.deal(deleGator_, 100 ether);

        // Assert DeleGator is MultiSig
        assertEq(address(DeleGatorCore(deleGator_).getImplementation()), address(multiSigDeleGatorImpl));

        // Upgrade to Hybrid
        Execution memory execution_ = Execution({
            target: address(deleGator_),
            value: 0,
            callData: abi.encodeWithSelector(
                DeleGatorCore.upgradeToAndCall.selector,
                address(hybridDeleGatorImpl),
                abi.encodeWithSelector(
                    HybridDeleGator.reinitialize.selector,
                    DeleGatorCore(deleGator_).getInitializedVersion() + 1,
                    users.alice.addr,
                    new string[](0),
                    new uint256[](0),
                    new uint256[](0),
                    false
                )
            )
        });
        bytes memory userOpCallData_ = abi.encodeWithSignature(EXECUTE_SINGULAR_SIGNATURE, execution_);
        PackedUserOperation memory userOp_ = createUserOp(address(deleGator_), userOpCallData_);
        bytes32 userOpHash_ = entryPoint.getUserOpHash(userOp_);
        userOp_.signature = signHash(
            SignatureType.MultiSig, users.alice, MultiSigDeleGator(deleGator_).getPackedUserOperationTypedDataHash(userOp_)
        );

        vm.expectEmit();
        emit ClearedStorage();

        submitUserOp_Bundler(userOp_);

        // Assert DeleGator is Hybrid
        assertEq(address(DeleGatorCore(deleGator_).getImplementation()), address(hybridDeleGatorImpl));

        // Assert MultiSig storage was cleared
        bytes32 DEFAULT_MULTISIG_DELEGATOR_STORAGE_LOCATION = StorageUtilsLib.getStorageLocation("DeleGator.MultiSigDeleGator");
        address[] memory owners_ =
            StorageUtilsLib.loadFullArray(deleGator_, uint256(DEFAULT_MULTISIG_DELEGATOR_STORAGE_LOCATION) + 1);
        assertEq(owners_.length, 0);
        assertEq(vm.load(deleGator_, bytes32(uint256(DEFAULT_MULTISIG_DELEGATOR_STORAGE_LOCATION) + 1)), 0);

        // Initializable version should have increased by 1
        bytes memory initializableStorage_ = abi.encode(vm.load(deleGator_, INITIALIZABLE_STORAGE_LOCATION));
        assertEq(2, BytesLib.toUint64(initializableStorage_, 24));
        assertEq(false, StorageUtilsLib.toBool(initializableStorage_, 23));

        // Assert Hybrid storage was configured properly
        address hybridOwner_ = HybridDeleGator(deleGator_).owner();
        assertEq(users.alice.addr, hybridOwner_);

        // Upgrade to MultiSig
        owners_ = new address[](1);
        owners_[0] = users.alice.addr;
        execution_ = Execution({
            target: address(deleGator_),
            value: 0,
            callData: abi.encodeWithSelector(
                DeleGatorCore.upgradeToAndCall.selector,
                address(multiSigDeleGatorImpl),
                abi.encodeWithSelector(
                    MultiSigDeleGator.reinitialize.selector, DeleGatorCore(deleGator_).getInitializedVersion() + 1, owners_, 1, false
                )
            )
        });
        userOpCallData_ = abi.encodeWithSignature(EXECUTE_SINGULAR_SIGNATURE, execution_);
        userOp_ = createUserOp(address(deleGator_), userOpCallData_);
        userOpHash_ = entryPoint.getUserOpHash(userOp_);
        userOp_.signature =
            signHash(SignatureType.EOA, users.alice, MultiSigDeleGator(deleGator_).getPackedUserOperationTypedDataHash(userOp_));

        vm.expectEmit();
        emit ClearedStorage();

        submitUserOp_Bundler(userOp_);

        // Assert DeleGator is MultiSig
        assertEq(address(DeleGatorCore(deleGator_).getImplementation()), address(multiSigDeleGatorImpl));

        // Assert Hybrid storage was cleared
        bytes32 DEFAULT_HYBRID_DELEGATOR_STORAGE_LOCATION = StorageUtilsLib.getStorageLocation("DeleGator.HybridDeleGator");
        bytes32 hybridMemoryAfter_ = vm.load(deleGator_, DEFAULT_HYBRID_DELEGATOR_STORAGE_LOCATION);
        assertEq(0, hybridMemoryAfter_);

        // Initializable version should have increased by 1
        initializableStorage_ = abi.encode(vm.load(deleGator_, INITIALIZABLE_STORAGE_LOCATION));
        assertEq(3, BytesLib.toUint64(initializableStorage_, 24));
        assertEq(false, StorageUtilsLib.toBool(initializableStorage_, 23));

        // Assert MultiSig storage was configured properly
        assertEq(users.alice.addr, MultiSigDeleGator(deleGator_).getSigners()[0]);
        assertEq(1, MultiSigDeleGator(deleGator_).getThreshold());
    }

    function test_upgradeWithoutStorageCleanup() public {
        // Load storage locations
        bytes32 INITIALIZABLE_STORAGE_LOCATION = StorageUtilsLib.getStorageLocation("openzeppelin.storage.Initializable");

        // Create a MultiSigDeleGator to manipulate
        address payable deleGator_ = payable(address(deployDeleGator_MultiSig(users.alice)));
        vm.label(deleGator_, "DeleGator");
        vm.deal(deleGator_, 100 ether);

        // Assert DeleGator is MultiSig
        assertEq(address(DeleGatorCore(deleGator_).getImplementation()), address(multiSigDeleGatorImpl));

        // Upgrade to Hybrid
        Execution memory execution_ = Execution({
            target: address(deleGator_),
            value: 0,
            callData: abi.encodeWithSelector(
                DeleGatorCore.upgradeToAndCallAndRetainStorage.selector,
                address(hybridDeleGatorImpl),
                abi.encodeWithSelector(
                    HybridDeleGator.reinitialize.selector,
                    DeleGatorCore(deleGator_).getInitializedVersion() + 1,
                    users.alice.addr,
                    new string[](0),
                    new uint256[](0),
                    new uint256[](0),
                    false
                )
            )
        });
        bytes memory userOpCallData_ = abi.encodeWithSignature(EXECUTE_SINGULAR_SIGNATURE, execution_);
        PackedUserOperation memory userOp_ = createUserOp(address(deleGator_), userOpCallData_);
        userOp_.signature = signHash(
            SignatureType.MultiSig, users.alice, MultiSigDeleGator(deleGator_).getPackedUserOperationTypedDataHash(userOp_)
        );

        submitUserOp_Bundler(userOp_);

        // Assert DeleGator is Hybrid
        assertEq(address(DeleGatorCore(deleGator_).getImplementation()), address(hybridDeleGatorImpl));

        // Assert MultiSig storage was not cleared
        bytes32 DEFAULT_MULTISIG_DELEGATOR_STORAGE_LOCATION = StorageUtilsLib.getStorageLocation("DeleGator.MultiSigDeleGator");
        address[] memory owners_ =
            StorageUtilsLib.loadFullArray(deleGator_, uint256(DEFAULT_MULTISIG_DELEGATOR_STORAGE_LOCATION) + 1);
        assertEq(owners_.length, 1);

        // Initializable version should have increased by 1
        bytes memory initializableStorage_ = abi.encode(vm.load(deleGator_, INITIALIZABLE_STORAGE_LOCATION));
        assertEq(2, BytesLib.toUint64(initializableStorage_, 24));
        assertEq(false, StorageUtilsLib.toBool(initializableStorage_, 23));
    }
}
