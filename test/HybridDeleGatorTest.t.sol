// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { FCL_ecdsa_utils } from "@FCL/FCL_ecdsa_utils.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { BytesLib } from "@bytes-utils/BytesLib.sol";

import { SigningUtilsLib } from "./utils/SigningUtilsLib.t.sol";
import { StorageUtilsLib } from "./utils/StorageUtilsLib.t.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { Execution, PackedUserOperation, Caveat, Delegation } from "../src/utils/Types.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { HybridDeleGator } from "../src/HybridDeleGator.sol";
import { IDeleGatorCore } from "../src/interfaces/IDeleGatorCore.sol";
import { DeleGatorCore } from "../src/DeleGatorCore.sol";
import { IERC173 } from "../src/interfaces/IERC173.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { SCL_Wrapper } from "./utils/SCLWrapperLib.sol";
import { P256SCLVerifierLib } from "../src/libraries/P256SCLVerifierLib.sol";
import { ERC1271Lib } from "../src/libraries/ERC1271Lib.sol";
import { EXECUTE_SINGULAR_SIGNATURE } from "./utils/Constants.sol";

contract HybridDeleGator_Test is BaseTest {
    using MessageHashUtils for bytes32;

    ////////////////////// Configure BaseTest //////////////////////

    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
    }

    ////////////////////////////// State //////////////////////////////

    // Default test user
    string keyId = "test";
    bytes32 keyIdHash = keccak256(abi.encodePacked(keyId));
    HybridDeleGator public aliceDeleGator;
    HybridDeleGator public bobDeleGator;
    HybridDeleGator public onlyEoaHybridDeleGator;

    bytes32 private DELEGATOR_CORE_STORAGE_LOCATION = StorageUtilsLib.getStorageLocation("DeleGator.Core");
    bytes32 private INITIALIZABLE_STORAGE_LOCATION = StorageUtilsLib.getStorageLocation("openzeppelin.storage.Initializable");

    ////////////////////////////// Events //////////////////////////////
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event AddedP256Key(bytes32 indexed keyIdHash, string keyId, uint256 x, uint256 y);
    event RemovedP256Key(bytes32 indexed keyIdHash, uint256 x, uint256 y);

    ////////////////////////////// Errors //////////////////////////////

    error InvalidKey();
    error KeyDoesNotExist(bytes32 keyIdHash);
    error CannotRemoveLastKey();
    error InvalidEmptyKey();

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();

        // Create a hybrid owned by an EOA only
        onlyEoaHybridDeleGator =
            HybridDeleGator(payable(deployDeleGator_Hybrid(users.alice.addr, new string[](0), new uint256[](0), new uint256[](0))));
        vm.deal(address(onlyEoaHybridDeleGator), 100 ether);

        // Set up typed DeleGators
        aliceDeleGator = HybridDeleGator(payable(address(users.alice.deleGator)));
        bobDeleGator = HybridDeleGator(payable(address(users.bob.deleGator)));
    }

    ////////////////////// Hybrid DeleGator Specific Tests //////////////////////

    ////////////////////// Events //////////////////////

    // Should emit AddedP256Key in initialize
    function test_keyAdded_initialize() public {
        string[] memory keyIds_ = new string[](1);
        uint256[] memory xValues_ = new uint256[](1);
        uint256[] memory yValues_ = new uint256[](1);
        keyIds_[0] = keyId;
        xValues_[0] = users.alice.x;
        yValues_[0] = users.alice.y;

        vm.expectEmit(true, true, true, true);
        emit AddedP256Key(keyIdHash, keyId, users.alice.x, users.alice.y);

        new ERC1967Proxy(
            address(hybridDeleGatorImpl),
            abi.encodeWithSignature(
                "initialize(address,string[],uint256[],uint256[])", users.alice.addr, keyIds_, xValues_, yValues_
            )
        );
    }

    // Should emit AddedP256Key in addKey
    function test_keyAdded_addKey() public {
        // Create and Sign UserOp
        bytes memory userOpCallData_ = abi.encodeWithSignature(
            EXECUTE_SINGULAR_SIGNATURE,
            Execution({
                target: address(aliceDeleGator),
                value: 0,
                callData: abi.encodeWithSelector(HybridDeleGator.addKey.selector, keyId, users.alice.x, users.alice.y)
            })
        );
        PackedUserOperation memory userOp_ = createAndSignUserOp(users.alice, address(aliceDeleGator), userOpCallData_);

        vm.expectEmit(true, true, true, true);
        emit AddedP256Key(keyIdHash, keyId, users.alice.x, users.alice.y);

        // Submit UserOp through Bundler
        submitUserOp_Bundler(userOp_);
    }

    // Should emit RemovedP256Key in removeKey
    function test_keyRemoved_removeKey() public {
        execute_UserOp(users.alice, abi.encodeWithSelector(HybridDeleGator.addKey.selector, keyId, users.alice.x, users.alice.y));

        // Create and Sign UserOp
        bytes memory userOpCallData_ = abi.encodeWithSignature(
            EXECUTE_SINGULAR_SIGNATURE,
            Execution({
                target: address(aliceDeleGator),
                value: 0,
                callData: abi.encodeWithSelector(HybridDeleGator.removeKey.selector, keyId)
            })
        );
        PackedUserOperation memory userOp_ = createAndSignUserOp(users.alice, address(aliceDeleGator), userOpCallData_);

        vm.expectEmit(true, true, true, true);
        emit RemovedP256Key(keyIdHash, users.alice.x, users.alice.y);

        // Submit UserOp through Bundler
        submitUserOp_Bundler(userOp_);
    }

    // Should emit RemovedP256Key, AddedP256Key, TransferredOwnership in replace signers
    function test_events_replacedSigners() public {
        vm.startPrank(address(aliceDeleGator));

        // Compute Bob's P256 keys
        string[] memory keyIds_ = new string[](1);
        uint256[] memory xValues_ = new uint256[](1);
        uint256[] memory yValues_ = new uint256[](1);
        keyIds_[0] = users.bob.name;
        xValues_[0] = users.bob.x;
        yValues_[0] = users.bob.y;

        (uint256 obtainedX_, uint256 obtainedY_) = HybridDeleGator(aliceDeleGator).getKey(users.alice.name);

        bytes32 aliceKeyIdHash_ = keccak256(abi.encodePacked(users.alice.name));
        bytes32 bobKeyIdHash_ = keccak256(abi.encodePacked(users.bob.name));

        vm.expectEmit(true, true, true, true);
        emit RemovedP256Key(aliceKeyIdHash_, obtainedX_, obtainedY_);

        vm.expectEmit(true, true, true, true);
        emit AddedP256Key(bobKeyIdHash_, users.bob.name, xValues_[0], yValues_[0]);

        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(users.alice.addr, users.bob.addr);
        aliceDeleGator.updateSigners(users.bob.addr, keyIds_, xValues_, yValues_);

        // Bob is the EOA owner now
        (uint256 x__, uint256 y__) = aliceDeleGator.getKey(users.bob.name);
        assertEq(users.bob.x, x__);
        assertEq(users.bob.y, y__);
    }

    // Should move the stored key ID hash from the last index to the removed index
    function test_removeP256KeyAndRearrangeStoredKeyIdHashes() public {
        vm.startPrank(address(aliceDeleGator));

        // Add 2 more keys
        aliceDeleGator.addKey(users.bob.name, users.bob.x, users.bob.y);
        aliceDeleGator.addKey(users.carol.name, users.carol.x, users.carol.y);
        bytes32[] memory initialKeyIdHashes_ = aliceDeleGator.getKeyIdHashes();

        // Update signers to only Bob
        // Compute Bob's P256 keys
        aliceDeleGator.removeKey(users.alice.name);

        bytes32[] memory finalKeyIdHashes_ = aliceDeleGator.getKeyIdHashes();
        assertEq(finalKeyIdHashes_[0], initialKeyIdHashes_[2]);
    }

    // Should fail when the inputs length are different in updateSigners
    function test_error_replacedSignersInputsMismatch() public {
        vm.startPrank(address(aliceDeleGator));

        string[] memory keyIds_ = new string[](2);
        uint256[] memory xValues_ = new uint256[](1);
        uint256[] memory yValues_ = new uint256[](1);

        vm.expectRevert(
            abi.encodeWithSelector(HybridDeleGator.InputLengthsMismatch.selector, keyIds_.length, xValues_.length, yValues_.length)
        );
        aliceDeleGator.updateSigners(users.bob.addr, keyIds_, xValues_, yValues_);

        keyIds_ = new string[](1);
        xValues_ = new uint256[](2);
        yValues_ = new uint256[](1);

        vm.expectRevert(
            abi.encodeWithSelector(HybridDeleGator.InputLengthsMismatch.selector, keyIds_.length, xValues_.length, yValues_.length)
        );
        aliceDeleGator.updateSigners(users.bob.addr, keyIds_, xValues_, yValues_);

        keyIds_ = new string[](1);
        xValues_ = new uint256[](1);
        yValues_ = new uint256[](2);
        vm.expectRevert(
            abi.encodeWithSelector(HybridDeleGator.InputLengthsMismatch.selector, keyIds_.length, xValues_.length, yValues_.length)
        );
        aliceDeleGator.updateSigners(users.bob.addr, keyIds_, xValues_, yValues_);
    }

    // Should fail when the new signers are empty
    function test_error_replacedSignersToEmpty() public {
        vm.startPrank(address(aliceDeleGator));

        string[] memory keyIds_ = new string[](0);
        uint256[] memory xValues_ = new uint256[](0);
        uint256[] memory yValues_ = new uint256[](0);

        vm.expectRevert(abi.encodeWithSelector(HybridDeleGator.SignersCannotBeEmpty.selector));
        aliceDeleGator.updateSigners(address(0), keyIds_, xValues_, yValues_);
    }

    ////////////////////// Initialization //////////////////////

    // Should allow to initialize with 0 p256 owners, 1 EOA owner
    function test_initialize_zeroP256OneEOA() public {
        HybridDeleGator hybridDeleGator_ = HybridDeleGator(
            payable(
                address(
                    new ERC1967Proxy(
                        address(hybridDeleGatorImpl),
                        abi.encodeWithSignature(
                            "initialize(address,string[],uint256[],uint256[])",
                            users.alice.addr,
                            new string[](0),
                            new uint256[](0),
                            new uint256[](0)
                        )
                    )
                )
            )
        );

        assertEq(users.alice.addr, hybridDeleGator_.owner());
    }

    // Should allow to initialize with 1+ p256 owners, 0 EOA owners
    function test_initialize_multipleP256ZeroEOA() public {
        (uint256 x_, uint256 y_) = FCL_ecdsa_utils.ecdsa_derivKpub(users.carol.privateKey);
        string[] memory keyIds_ = new string[](2);
        uint256[] memory xValues_ = new uint256[](2);
        uint256[] memory yValues_ = new uint256[](2);
        keyIds_[0] = keyId;
        xValues_[0] = users.alice.x;
        yValues_[0] = users.alice.y;
        keyIds_[1] = users.carol.name;
        xValues_[1] = x_;
        yValues_[1] = y_;

        HybridDeleGator hybridDeleGator_ = HybridDeleGator(
            payable(
                address(
                    new ERC1967Proxy(
                        address(hybridDeleGatorImpl),
                        abi.encodeWithSignature(
                            "initialize(address,string[],uint256[],uint256[])", address(0), keyIds_, xValues_, yValues_
                        )
                    )
                )
            )
        );
        assertEq(hybridDeleGator_.owner(), address(0));
        assertEq(hybridDeleGator_.getKeyIdHashesCount(), 2);
    }

    // Should allow to initialize with 1+ p256 owners, 1 EOA owners
    function test_initialize_multipleP256OneEOA() public {
        // Set up a default key
        (uint256 x_, uint256 y_) = FCL_ecdsa_utils.ecdsa_derivKpub(users.carol.privateKey);

        string[] memory keyIds_ = new string[](2);
        uint256[] memory xValues_ = new uint256[](2);
        uint256[] memory yValues_ = new uint256[](2);
        keyIds_[0] = keyId;
        xValues_[0] = users.alice.x;
        yValues_[0] = users.alice.y;
        keyIds_[1] = users.carol.name;
        xValues_[1] = x_;
        yValues_[1] = y_;

        HybridDeleGator hybridDeleGator_ = HybridDeleGator(
            payable(
                address(
                    new ERC1967Proxy(
                        address(hybridDeleGatorImpl),
                        abi.encodeWithSignature(
                            "initialize(address,string[],uint256[],uint256[])", users.alice.addr, keyIds_, xValues_, yValues_
                        )
                    )
                )
            )
        );
        assertEq(hybridDeleGator_.owner(), users.alice.addr);
        assertEq(hybridDeleGator_.getKeyIdHashesCount(), 2);
    }

    // should allow Alice to clear and add new signers
    function test_reinitialize_clearsAndSetSigners() public {
        uint256 oldSignersCount_ = aliceDeleGator.getKeyIdHashesCount();
        assertEq(oldSignersCount_, 1);

        string[] memory keyIds_ = new string[](2);
        uint256[] memory xValues_ = new uint256[](2);
        uint256[] memory yValues_ = new uint256[](2);
        keyIds_[0] = users.carol.name;
        xValues_[0] = users.carol.x;
        yValues_[0] = users.carol.y;
        keyIds_[1] = users.dave.name;
        xValues_[1] = users.dave.x;
        yValues_[1] = users.dave.y;
        bytes32 keyHashCarol_ = keccak256(abi.encodePacked(keyIds_[0]));
        bytes32 keyHashDave_ = keccak256(abi.encodePacked(keyIds_[1]));

        // Replace the signers
        vm.startPrank(address(aliceDeleGator));
        aliceDeleGator.reinitialize(
            uint8(DeleGatorCore(payable(address(aliceDeleGator))).getInitializedVersion() + 1),
            users.bob.addr,
            keyIds_,
            xValues_,
            yValues_,
            true
        );

        bytes32[] memory keyIdHashes_ = aliceDeleGator.getKeyIdHashes();
        assertEq(keyIdHashes_[0], keyHashCarol_);
        assertEq(keyIdHashes_[1], keyHashDave_);
        assertEq(keyIdHashes_.length, 2);
    }

    // should allow Alice to clear and add new signers
    function test_reinitialize_keepAndSetSigners() public {
        uint256 oldSignersCount_ = aliceDeleGator.getKeyIdHashesCount();
        assertEq(oldSignersCount_, 1);

        string[] memory keyIds_ = new string[](2);
        uint256[] memory xValues_ = new uint256[](2);
        uint256[] memory yValues_ = new uint256[](2);
        keyIds_[0] = users.carol.name;
        xValues_[0] = users.carol.x;
        yValues_[0] = users.carol.y;
        keyIds_[1] = users.dave.name;
        xValues_[1] = users.dave.x;
        yValues_[1] = users.dave.y;
        bytes32 keyHashAlice_ = keccak256(abi.encodePacked(users.alice.name));
        bytes32 keyHashCarol_ = keccak256(abi.encodePacked(keyIds_[0]));
        bytes32 keyHashDave_ = keccak256(abi.encodePacked(keyIds_[1]));

        // Replace the signers
        vm.startPrank(address(aliceDeleGator));
        aliceDeleGator.reinitialize(
            uint8(DeleGatorCore(payable(address(aliceDeleGator))).getInitializedVersion() + 1),
            users.bob.addr,
            keyIds_,
            xValues_,
            yValues_,
            false
        );

        bytes32[] memory keyIdHashes_ = aliceDeleGator.getKeyIdHashes();
        assertEq(keyIdHashes_[0], keyHashAlice_);
        assertEq(keyIdHashes_[1], keyHashCarol_);
        assertEq(keyIdHashes_[2], keyHashDave_);
        assertEq(keyIdHashes_.length, 3);
    }

    ////////////////////// UUPS //////////////////////

    // Should allow upgrading to a HybridDeleGator
    function test_allow_upgradingHybridDeleGator() public {
        // Load DeleGator to manipulate
        address payable deleGator_ = payable(address(aliceDeleGator));

        // Load initial storage values
        bytes32 delegatorCoreStoragePre_ = vm.load(deleGator_, DELEGATOR_CORE_STORAGE_LOCATION);

        // Compute Bob's P256 keys
        string[] memory keyIds_ = new string[](1);
        uint256[] memory xValues_ = new uint256[](1);
        uint256[] memory yValues_ = new uint256[](1);
        keyIds_[0] = users.bob.name;
        xValues_[0] = users.bob.x;
        yValues_[0] = users.bob.y;

        // Update DeleGator to Hybrid owned by Bob
        address[] memory signers_ = new address[](1);
        signers_[0] = users.alice.addr;
        execute_UserOp(
            users.alice,
            abi.encodeWithSelector(
                DeleGatorCore.upgradeToAndCall.selector,
                address(hybridDeleGatorImpl),
                abi.encodeWithSelector(
                    HybridDeleGator.reinitialize.selector,
                    DeleGatorCore(deleGator_).getInitializedVersion() + 1,
                    users.bob.addr,
                    keyIds_,
                    xValues_,
                    yValues_,
                    false
                ),
                false
            )
        );

        // Assert DeleGator is Hybrid
        assertEq(address(DeleGatorCore(deleGator_).getImplementation()), address(hybridDeleGatorImpl));

        // ERC4337 should be the same
        assertEq(delegatorCoreStoragePre_, vm.load(deleGator_, DELEGATOR_CORE_STORAGE_LOCATION));

        // Initializable version should have increased by 1
        bytes memory initializableStorage_ = abi.encode(vm.load(deleGator_, INITIALIZABLE_STORAGE_LOCATION));
        assertEq(2, BytesLib.toUint64(initializableStorage_, 24));
        assertEq(false, StorageUtilsLib.toBool(initializableStorage_, 23));

        // Assert Hybrid storage was configured properly
        (uint256 x__, uint256 y__) = HybridDeleGator(deleGator_).getKey(users.bob.name);
        assertEq(users.bob.x, x__);
        assertEq(users.bob.y, y__);

        address hybridOwner_ = HybridDeleGator(deleGator_).owner();
        assertEq(users.bob.addr, hybridOwner_);
    }

    ////////////////////// Key Management //////////////////////

    // Should allow adding a new key
    function test_allow_addKey() public {
        uint256 count_ = aliceDeleGator.getKeyIdHashesCount();
        assertEq(count_, 1);

        execute_UserOp(users.alice, abi.encodeWithSelector(HybridDeleGator.addKey.selector, keyId, users.alice.x, users.alice.y));

        (uint256 x_, uint256 y_) = aliceDeleGator.getKey(keyId);
        assertEq(x_, users.alice.x);
        assertEq(y_, users.alice.y);

        count_ = aliceDeleGator.getKeyIdHashesCount();
        assertEq(count_, 2);
    }

    // Should allow removing a key
    function test_allow_removeKey() public {
        execute_UserOp(users.alice, abi.encodeWithSelector(HybridDeleGator.addKey.selector, keyId, users.alice.x, users.alice.y));

        uint256 count_ = aliceDeleGator.getKeyIdHashesCount();
        assertEq(count_, 2);

        execute_UserOp(users.alice, abi.encodeWithSelector(HybridDeleGator.removeKey.selector, keyId));

        (uint256 x_, uint256 y_) = aliceDeleGator.getKey(keyId);
        assertEq(x_, 0);
        assertEq(y_, 0);

        count_ = aliceDeleGator.getKeyIdHashesCount();
        assertEq(count_, 1);
    }

    // Should return the stored key id hashes
    function test_return_KeyIdHashes() public {
        execute_UserOp(users.alice, abi.encodeWithSelector(HybridDeleGator.addKey.selector, keyId, users.alice.x, users.alice.y));

        bytes32[] memory keyIdHashes_ = aliceDeleGator.getKeyIdHashes();
        uint256 count_ = aliceDeleGator.getKeyIdHashesCount();

        assertEq(keyIdHashes_.length, count_);
        assertEq(keyIdHashes_.length, 2);
        bytes32 keyIdHash0_ = keccak256(abi.encodePacked("Alice"));
        bytes32 keyIdHash1_ = keccak256(abi.encodePacked(keyId));

        assertEq(keyIdHashes_[0], keyIdHash0_);
        assertEq(keyIdHashes_[1], keyIdHash1_);
    }

    // should NOT allow Alice to transfer ownership directly
    function test_notAllow_transferOwnership_directOwner() public {
        // Submit Alice's tx
        vm.prank(users.alice.addr);
        vm.expectRevert(abi.encodeWithSelector(DeleGatorCore.NotEntryPointOrSelf.selector));
        aliceDeleGator.transferOwnership(users.bob.addr);
    }

    // should NOT allow Bob to transfer Alice's ownership directly
    function test_notAllow_transferOwnership_directNonOwner() public {
        // Submit Bob's tx
        vm.prank(users.bob.addr);
        vm.expectRevert(abi.encodeWithSelector(DeleGatorCore.NotEntryPointOrSelf.selector));
        aliceDeleGator.transferOwnership(users.bob.addr);
    }

    // should NOT allow Alice to renounce ownership directly like OZ Ownable
    function test_notAllow_renounceOwnership_Direct() public {
        assertEq(aliceDeleGator.owner(), users.alice.addr);

        // Submit Alice's tx
        vm.prank(users.alice.addr);
        vm.expectRevert();
        aliceDeleGator.renounceOwnership();
    }

    // should support IERC173 and parent interfaces for ERC165
    function test_allow_erc173InterfaceId() public {
        assertTrue(aliceDeleGator.supportsInterface(type(IERC173).interfaceId));
        assertTrue(aliceDeleGator.supportsInterface(type(IDeleGatorCore).interfaceId));
    }

    // Should allow a single secure EOA to replace an insecure EOA
    function test_allow_replaceEOAWithEOA() public {
        // Alice is the EOA owner
        assertEq(users.alice.addr, onlyEoaHybridDeleGator.owner());

        // Create and Sign UserOp
        bytes memory userOpCallData_ = abi.encodeWithSignature(
            EXECUTE_SINGULAR_SIGNATURE,
            Execution({
                target: address(onlyEoaHybridDeleGator),
                value: 0,
                callData: abi.encodeWithSelector(
                    HybridDeleGator.updateSigners.selector, users.bob.addr, new string[](0), new uint256[](0), new uint256[](0)
                )
            })
        );
        PackedUserOperation memory userOp_ = createUserOp(address(onlyEoaHybridDeleGator), userOpCallData_);

        bytes32 userOpHash_ = onlyEoaHybridDeleGator.getPackedUserOperationHash(userOp_);

        // Need to sign the hash from typed data.
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(onlyEoaHybridDeleGator.getDomainHash(), userOpHash_);

        userOp_.signature = SigningUtilsLib.signHash_EOA(users.alice.privateKey, typedDataHash_);

        // Submit UserOp through Bundler
        submitUserOp_Bundler(userOp_);

        // Bob is the EOA owner now
        assertEq(users.bob.addr, onlyEoaHybridDeleGator.owner());
    }

    // Should allow a single secure P256 key to replace an insecure EOA
    function test_allow_replaceEOAWithP256() public {
        // Alice is the EOA owner
        assertEq(users.alice.addr, onlyEoaHybridDeleGator.owner());

        // Compute Bob's P256 keys
        string[] memory keyIds_ = new string[](1);
        uint256[] memory xValues_ = new uint256[](1);
        uint256[] memory yValues_ = new uint256[](1);
        keyIds_[0] = users.bob.name;
        xValues_[0] = users.bob.x;
        yValues_[0] = users.bob.y;

        // Create and Sign UserOp
        bytes memory userOpCallData_ = abi.encodeWithSignature(
            EXECUTE_SINGULAR_SIGNATURE,
            Execution({
                target: address(onlyEoaHybridDeleGator),
                value: 0,
                callData: abi.encodeWithSelector(HybridDeleGator.updateSigners.selector, address(0), keyIds_, xValues_, yValues_)
            })
        );
        PackedUserOperation memory userOp_ = createUserOp(address(onlyEoaHybridDeleGator), userOpCallData_);

        bytes32 userOpHash_ = onlyEoaHybridDeleGator.getPackedUserOperationHash(userOp_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(onlyEoaHybridDeleGator.getDomainHash(), userOpHash_);
        userOp_.signature = SigningUtilsLib.signHash_EOA(users.alice.privateKey, typedDataHash_);

        // Submit UserOp through Bundler
        submitUserOp_Bundler(userOp_);

        // Bob is the EOA owner now
        (uint256 x__, uint256 y__) = onlyEoaHybridDeleGator.getKey(users.bob.name);
        assertEq(users.bob.x, x__);
        assertEq(users.bob.y, y__);
    }

    // Should allow a secure EOA and P256 keys to replace an insecure EOA
    function test_allow_replaceEOAWithEOAAndP256() public {
        // Alice is the EOA owner
        assertEq(users.alice.addr, onlyEoaHybridDeleGator.owner());

        // Compute Bob's P256 keys
        string[] memory keyIds_ = new string[](1);
        uint256[] memory xValues_ = new uint256[](1);
        uint256[] memory yValues_ = new uint256[](1);
        keyIds_[0] = users.bob.name;
        xValues_[0] = users.bob.x;
        yValues_[0] = users.bob.y;

        // Create and Sign UserOp
        bytes memory userOpCallData_ = abi.encodeWithSignature(
            EXECUTE_SINGULAR_SIGNATURE,
            Execution({
                target: address(onlyEoaHybridDeleGator),
                value: 0,
                callData: abi.encodeWithSelector(HybridDeleGator.updateSigners.selector, users.bob.addr, keyIds_, xValues_, yValues_)
            })
        );
        PackedUserOperation memory userOp_ = createUserOp(address(onlyEoaHybridDeleGator), userOpCallData_);

        bytes32 userOpHash_ = onlyEoaHybridDeleGator.getPackedUserOperationHash(userOp_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(onlyEoaHybridDeleGator.getDomainHash(), userOpHash_);
        userOp_.signature = SigningUtilsLib.signHash_EOA(users.alice.privateKey, typedDataHash_);

        // Submit UserOp through Bundler
        submitUserOp_Bundler(userOp_);

        // Bob is the EOA owner now
        (uint256 x__, uint256 y__) = onlyEoaHybridDeleGator.getKey(users.bob.name);
        assertEq(users.bob.x, x__);
        assertEq(users.bob.y, y__);

        // Bob is the EOA owner
        assertEq(users.bob.addr, onlyEoaHybridDeleGator.owner());
    }

    // A delegate replacing ALL of the existing keys (passkeys and EOA) in a single transaction offchain
    function test_allow_replaceEOAWithEOAAndP256WithOffchainDelegation() public {
        // Alice is the EOA owner
        assertEq(users.alice.addr, aliceDeleGator.owner());

        // Compute Bob's P256 keys
        string[] memory keyIds_ = new string[](1);
        uint256[] memory xValues_ = new uint256[](1);
        uint256[] memory yValues_ = new uint256[](1);
        keyIds_[0] = users.bob.name;
        xValues_[0] = users.bob.x;
        yValues_[0] = users.bob.y;

        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(aliceDeleGator),
            value: 0,
            callData: abi.encodeWithSelector(HybridDeleGator.updateSigners.selector, users.bob.addr, keyIds_, xValues_, yValues_)
        });

        Caveat[] memory caveats_ = new Caveat[](0);
        Delegation memory delegation_ = Delegation({
            delegate: address(bobDeleGator),
            delegator: address(aliceDeleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        // Signing the delegation
        delegation_ = signDelegation(users.alice, delegation_);

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Bob is the EOA owner now
        (uint256 x__, uint256 y__) = aliceDeleGator.getKey(users.bob.name);
        assertEq(users.bob.x, x__);
        assertEq(users.bob.y, y__);

        // Bob is the EOA owner
        assertEq(users.bob.addr, aliceDeleGator.owner());
    }

    ////////////////////// Signature Validation //////////////////////

    // Test the flow using a signature created with WebAuthn and an invalid type
    function test_fails_signingWithWebAuthnWithInvalidType() public {
        // Alice is the EOA owner
        assertEq(users.alice.addr, aliceDeleGator.owner());

        // Hardcoded values in these test were generated with WebAuthn
        // https://github.com/MetaMask/Passkeys-Demo-App
        string memory webAuthnKeyId_ = "WebAuthnUser";
        uint256 xWebAuthn_ = 0x5ab7b640f322014c397264bb85cbf404500feb04833ae699f41978495b655163;
        uint256 yWebAuthn_ = 0x1ee739189ede53846bd7d38bfae016919bf7d88f7ccd60aad8277af4793d1fd7;
        bytes32 keyIdHash_ = keccak256(abi.encodePacked(webAuthnKeyId_));

        // Adding the key as signer
        vm.prank(address(entryPoint));
        aliceDeleGator.addKey(webAuthnKeyId_, xWebAuthn_, yWebAuthn_);

        // Create the execution that would be executed
        bytes memory userOpCallData_ = abi.encodeWithSignature(
            EXECUTE_SINGULAR_SIGNATURE,
            Execution({
                target: address(aliceDeleGator),
                value: 0,
                callData: abi.encodeWithSelector(Ownable.transferOwnership.selector, address(1))
            })
        );
        PackedUserOperation memory userOp_ = createUserOp(address(aliceDeleGator), userOpCallData_);

        // WebAuthn Signature values
        uint256 r_ = 0x83e76b9afa53953f7971d4cdc8e2859f8786ba70423de061d0e15367d41b44fa;
        uint256 s_ = 0x7c25bacc7ef162d395533639cc164b02592585d0ab382efe3790393a07ee7f56;

        bytes memory authenticatorData_ = hex"49960de5880e8c687434170f6476605b8fe4aeb9a28632c7995cf3ba831d97630500000000";
        bool requireUserVerification_ = true;

        // Using an invalid type here it should be '{"type":"webauthn.get","challenge":"';
        string memory clientDataJSONPrefix_ = '{"type":"web.get","challenge":"';
        string memory clientDataJSONSuffix_ = '","origin":"http://localhost:3000","crossOrigin":false}';

        // Index of the type in clientDataJSON string
        uint256 responseTypeLocation_ = 1;

        userOp_.signature = abi.encode(
            keyIdHash_,
            r_,
            s_,
            authenticatorData_,
            requireUserVerification_,
            clientDataJSONPrefix_,
            clientDataJSONSuffix_,
            responseTypeLocation_
        );

        // Submit UserOp through Bundler, it will fail
        submitUserOp_Bundler(userOp_, true);

        // The owner was not transferred
        assertEq(aliceDeleGator.owner(), users.alice.addr);
    }

    // A signature should be valid if generated with EOA
    function test_allow_signatureWithEOA() public {
        Delegation memory delegation_ = Delegation({
            delegate: users.bob.addr,
            delegator: address(aliceDeleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(delegationManager.getDomainHash(), delegationHash_);
        delegation_.signature = SigningUtilsLib.signHash_EOA(users.alice.privateKey, typedDataHash_);

        // Show that signature is valid
        bytes4 resultEOA_ = aliceDeleGator.isValidSignature(typedDataHash_, delegation_.signature);
        assertEq(resultEOA_, bytes4(0x1626ba7e));
    }

    // A signature should be valid if generated with a raw P256
    function test_allow_signatureWithP256() public {
        Delegation memory delegation_ = Delegation({
            delegate: users.bob.addr,
            delegator: address(aliceDeleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(delegationManager.getDomainHash(), delegationHash_);
        bytes memory signature_ = SigningUtilsLib.signHash_P256(users.alice.name, users.alice.privateKey, typedDataHash_);
        delegation_.signature = signature_;

        // Show that signature is valid
        bytes4 resultP256_ = aliceDeleGator.isValidSignature(typedDataHash_, delegation_.signature);
        assertEq(resultP256_, bytes4(0x1626ba7e));
    }

    ////////////////////// Errors //////////////////////

    // Should NOT allow adding an existing key. Emits AlreadyExists in addKey
    function test_notAllow_addingExistingKey() public {
        vm.startPrank(address(aliceDeleGator));

        // Don't allow overwriting an existing key
        vm.expectRevert(
            abi.encodeWithSelector(HybridDeleGator.KeyAlreadyExists.selector, keccak256(abi.encodePacked(users.alice.name)))
        );
        aliceDeleGator.addKey(users.alice.name, users.alice.x, users.alice.y);
    }

    // Should NOT allow adding a key that is not on the curve.
    function test_notAllow_addKeyNotOnCurve() public {
        vm.prank(address(aliceDeleGator));
        vm.expectRevert(abi.encodeWithSelector(HybridDeleGator.KeyNotOnCurve.selector, 0, 0));
        aliceDeleGator.addKey(keyId, 0, 0);
    }

    // Should NOT allow adding an invalid key. Emits InvalidKey on deploy
    function test_notAllow_invalidKeyOnDeploy() public {
        string[] memory keyIds_ = new string[](1);
        keyIds_[0] = keyId;

        uint256[] memory xValues_ = new uint256[](1);
        uint256[] memory yValues_ = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(HybridDeleGator.KeyNotOnCurve.selector, 0, 0));
        new ERC1967Proxy(
            address(hybridDeleGatorImpl),
            abi.encodeWithSignature(
                "initialize(address,string[],uint256[],uint256[])", users.alice.addr, keyIds_, xValues_, yValues_
            )
        );
    }

    // Should NOT allow removing a non-existant key. Emits KeyDoesNotExist in removeKey
    function test_notAllow_removingNonExistantKey() public {
        vm.expectRevert(abi.encodeWithSelector(HybridDeleGator.KeyDoesNotExist.selector, keccak256(abi.encodePacked(keyId))));
        vm.prank(address(aliceDeleGator));
        aliceDeleGator.removeKey(keyId);
    }

    // Should NOT allow to add an empty key
    function test_notAllow_addingAnEmptyKey() public {
        uint256 xWebAuthn_ = 0xfe238ff5854d1d5cf1c7fc8576f82220c0f1dd9e5805f177ca1f5ef2359f5d64;
        uint256 yWebAuthn_ = 0x82184d10af7245c2ae25b72983269f073ddbf8de32bb94a5798ca635555ebcfc;
        vm.expectRevert(abi.encodeWithSelector(HybridDeleGator.InvalidEmptyKey.selector));
        vm.prank(address(aliceDeleGator));
        aliceDeleGator.addKey("", xWebAuthn_, yWebAuthn_);
    }

    // Should NOT allow removing the last key via P256. Emits CannotRemoveLastSigner in removeKey
    function test_notAllow_removingLastKeyViaP256() public {
        // Delete the EOA leaving only P256 key
        vm.startPrank(address(aliceDeleGator));
        aliceDeleGator.renounceOwnership();

        vm.expectRevert(abi.encodeWithSelector(HybridDeleGator.CannotRemoveLastSigner.selector));
        aliceDeleGator.removeKey(users.alice.name);
    }

    // Should NOT allow removing the last key via EOA. Emits CannotRemoveLastSigner in removeKey
    function test_notAllow_removingLastKeyViaEOA() public {
        // Delete the P256 key leaving only EOA
        vm.startPrank(address(aliceDeleGator));
        aliceDeleGator.removeKey(users.alice.name);

        vm.expectRevert(abi.encodeWithSelector(HybridDeleGator.CannotRemoveLastSigner.selector));
        aliceDeleGator.renounceOwnership();
    }

    // A signature should be valid if generated with a raw P256
    function test_notAllow_invalidSignatureLength() public {
        Delegation memory delegation_ = Delegation({
            delegate: users.bob.addr,
            delegator: address(aliceDeleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(delegationManager.getDomainHash(), delegationHash_);
        delegation_.signature = hex"ffffffffffffffffffff";

        // Show that signature is valid
        bytes4 resultP256_ = aliceDeleGator.isValidSignature(typedDataHash_, delegation_.signature);
        assertEq(resultP256_, bytes4(0xffffffff));
    }
}
