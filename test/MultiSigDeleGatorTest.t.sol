// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IEntryPoint, EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { BytesLib } from "@bytes-utils/BytesLib.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { ERC1967Proxy as DeleGatorProxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SigningUtilsLib } from "./utils/SigningUtilsLib.t.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { Execution, PackedUserOperation, Caveat, Delegation } from "../src/utils/Types.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { AccountSorterLib } from "./utils/AccountSorterLib.t.sol";
import { MultiSigDeleGator } from "../src/MultiSigDeleGator.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { DeleGatorCore } from "../src/DeleGatorCore.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { Counter } from "./utils/Counter.t.sol";
import { UserOperationLib } from "./utils/UserOperationLib.t.sol";
import { SimpleFactory } from "../src/utils/SimpleFactory.sol";

/**
 * @title Multi Signature DeleGator Implementation Test
 * @dev These tests are for the MultiSig functionality of the MultiSigDeleGator contract.
 * @dev DeleGator functionality is tested inside GenericDeleGatorUserOpTest.
 * @dev NOTE: All Smart Account interactions flow through ERC4337 UserOps.
 */
contract MultiSigDeleGatorTest is BaseTest {
    using MessageHashUtils for bytes32;

    ////////////////////// Configure BaseTest //////////////////////

    constructor() {
        IMPLEMENTATION = Implementation.MultiSig;
        SIGNATURE_TYPE = SignatureType.MultiSig;
    }

    ////////////////////////////// State //////////////////////////////

    uint256 public constant MAX_NUMBER_OF_SIGNERS = 30;
    MultiSigDeleGator public aliceDeleGator;
    MultiSigDeleGator public bobDeleGator;
    MultiSigDeleGator public sharedDeleGator;
    Counter sharedDeleGatorCounter;
    uint256[] public sharedDeleGatorPrivateKeys;
    address[] public sharedDeleGatorSigners;

    ////////////////////// Events //////////////////////

    event SetDelegationManager(IDelegationManager indexed newDelegationManager);
    event ReplacedSigner(address indexed oldSigner, address indexed newSigner);
    event AddedSigner(address indexed signer);
    event RemovedSigner(address indexed signer);
    event UpdatedThreshold(uint256 threshold);
    event Initialized(uint64 version);

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();

        // Set up typed DeleGators
        aliceDeleGator = MultiSigDeleGator(payable(address(users.alice.deleGator)));
        bobDeleGator = MultiSigDeleGator(payable(address(users.bob.deleGator)));

        // Set up multiple signer DeleGator
        // NOTE: signers are sorted
        sharedDeleGatorSigners = new address[](3);
        sharedDeleGatorSigners[0] = users.bob.addr;
        sharedDeleGatorSigners[1] = users.alice.addr;
        sharedDeleGatorSigners[2] = users.carol.addr;
        sharedDeleGatorPrivateKeys = new uint256[](3);
        sharedDeleGatorPrivateKeys[0] = users.bob.privateKey;
        sharedDeleGatorPrivateKeys[1] = users.alice.privateKey;
        sharedDeleGatorPrivateKeys[2] = users.carol.privateKey;
        sharedDeleGator = MultiSigDeleGator(payable(deployDeleGator_MultiSig(sharedDeleGatorSigners, 3)));
        vm.deal(address(sharedDeleGator), 100 ether);
        vm.label(address(sharedDeleGator), "DeleGator with 3 signers");

        // Create a Counter owned by the MultiSig
        sharedDeleGatorCounter = new Counter(address(sharedDeleGator));
    }

    ////////////////////// Basic Functionality //////////////////////

    // should allow retrieval of the maximum threshold
    function test_allow_getMaxSigners() public {
        uint256 threshold_ = aliceDeleGator.MAX_NUMBER_OF_SIGNERS();
        assertEq(threshold_, MAX_NUMBER_OF_SIGNERS);
    }

    // should return if an address is a valid signer
    function test_return_ifAnAddressIsAValidSigner() public {
        assertTrue(MultiSigDeleGator(payable(address(users.alice.deleGator))).isSigner(users.alice.addr));
        assertFalse(MultiSigDeleGator(payable(address(users.alice.deleGator))).isSigner(users.bob.addr));
    }

    // The implementation starts with the max threshold
    function test_ImplementationUsesMaxThreshold() public {
        assertEq(multiSigDeleGatorImpl.getThreshold(), type(uint256).max);
    }

    // should return the count of signers
    function test_allow_getSignersCount() public {
        assertEq(MultiSigDeleGator(payable(address(users.alice.deleGator))).getSignersCount(), 1);
    }

    // should allow a no-op for deploying SCA through initcode
    function test_allow_deploySCAWithInitCode() public {
        // Get predicted address and bytecode for a new MultiSigDeleGator
        address[] memory signers_ = new address[](1);
        signers_[0] = users.bob.addr;

        bytes32 salt = keccak256(abi.encode("salt"));

        bytes memory args_ =
            abi.encode(address(multiSigDeleGatorImpl), abi.encodeWithSignature("initialize(address[],uint256)", signers_, 1));

        bytes32 bytecodeHash_ = hashInitCode(type(DeleGatorProxy).creationCode, args_);
        address predictedAddr_ = vm.computeCreate2Address(salt, bytecodeHash_, address(simpleFactory));

        // Get initcode for a new MultiSigDeleGator
        bytes memory initcode_ = abi.encodePacked(
            address(simpleFactory),
            abi.encodeWithSelector(SimpleFactory.deploy.selector, abi.encodePacked(type(DeleGatorProxy).creationCode, args_), salt)
        );

        // Give the new MultiSigDeleGator some funds to pay for the execution
        vm.deal(predictedAddr_, 100);

        // Preload the EntryPoint with funds for the new MultiSigDeleGator
        vm.prank(users.alice.addr);
        entryPoint.depositTo{ value: 5 ether }(predictedAddr_);

        // Create and Sign UserOp with Bob's key
        PackedUserOperation memory userOperation_ = createUserOp(predictedAddr_, hex"", initcode_);
        userOperation_.signature = signHash(
            users.bob,
            UserOperationLib.getPackedUserOperationTypedDataHash(
                multiSigDeleGatorImpl.NAME(),
                multiSigDeleGatorImpl.DOMAIN_VERSION(),
                block.chainid,
                predictedAddr_,
                userOperation_,
                address(entryPoint)
            )
        );

        // Validate the contract hasn't been deployed yet
        assertEq(predictedAddr_.code, hex"");

        // Submit the UserOp through the Bundler
        submitUserOp_Bundler(userOperation_);
    }

    ////////////////////// Redeeming delegations //////////////////////

    // should allow Dave to redeem a Delegation through a UserOp when there are multiple signers (offchain)
    function test_allow_invokeOffchainDelegationWithMultipleSigners() public {
        // Get sharedDeleGator's Counter's initial count
        uint256 initialValue_ = sharedDeleGatorCounter.count();

        // Create delegation
        Delegation memory delegation_ = Delegation({
            delegate: address(users.dave.deleGator),
            delegator: address(sharedDeleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 domainHash_ = delegationManager.getDomainHash();
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(domainHash_, delegationHash_);
        bytes memory signature_ = SigningUtilsLib.signHash_MultiSig(sharedDeleGatorPrivateKeys, typedDataHash_);
        delegation_.signature = signature_;

        // Create Dave's execution
        Execution memory execution_ = Execution({
            target: address(sharedDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Execute Dave's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.dave, delegations_, execution_);

        // Get final count
        uint256 finalValue_ = sharedDeleGatorCounter.count();

        // Validate that the count has increased by 1
        assertEq(finalValue_, initialValue_ + 1);
    }

    ////////////////////// Signing data //////////////////////

    // should not allow a signature that is not a valid length
    function test_notAllow_invalidSignatureLength() public {
        // Configure signers
        vm.prank(address(aliceDeleGator));
        aliceDeleGator.updateMultiSigParameters(sharedDeleGatorSigners, 2, true);

        // Get signature
        bytes32 hash_ = keccak256("hello world");

        // Show that a short signature is invalid (SIG_VALIDATION_FAILED = 0xffffffff)
        bytes memory signature_ = SigningUtilsLib.signHash_EOA(users.alice.privateKey, hash_);
        bytes4 validationData_ = aliceDeleGator.isValidSignature(hash_, signature_);
        assertEq(validationData_, bytes4(0xffffffff));

        // Show that a long signature is invalid (SIG_VALIDATION_FAILED = 0xffffffff)
        signature_ = SigningUtilsLib.signHash_EOA(users.alice.privateKey, hash_);
        validationData_ =
            aliceDeleGator.isValidSignature(hash_, BytesLib.concat(signature_, BytesLib.concat(signature_, signature_)));
        assertEq(validationData_, bytes4(0xffffffff));
    }

    // Should revert when passing an empty array of signers to update
    function test_error_updateSigParametersInvalidThreshold() public {
        // Zero signers
        address[] memory signers_ = new address[](0);

        vm.prank(address(aliceDeleGator));
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidThreshold.selector));
        aliceDeleGator.updateMultiSigParameters(signers_, 2, false);
    }

    // Should revert if same addressess passed in signer
    function test_error_updateSigParamatersAlreadyASigner() public {
        (address addr_) = makeAddr("newUser");

        address[] memory signers_ = new address[](2);
        signers_[0] = addr_;
        signers_[1] = addr_;

        vm.prank(address(aliceDeleGator));
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.AlreadyASigner.selector));
        aliceDeleGator.updateMultiSigParameters(signers_, 2, false);
    }

    // Should revert if new signer is zero
    function test_error_updateSigParamatersZeroNewSigner() public {
        address[] memory signers_ = new address[](1);
        signers_[0] = address(0);

        vm.prank(address(aliceDeleGator));
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidSignerAddress.selector));
        aliceDeleGator.updateMultiSigParameters(signers_, 1, false);
    }

    // Should revert if new signer is a non-ERC1271 contract
    function test_error_updateSigParamatersContractNewSigner() public {
        // Deploy a non-ERC1271 contract
        NonERC1271TestContract nonERC1271 = new NonERC1271TestContract();
        
        address[] memory signers_ = new address[](1);
        signers_[0] = address(nonERC1271);

        vm.prank(address(aliceDeleGator));
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidSignerAddress.selector));
        aliceDeleGator.updateMultiSigParameters(signers_, 1, false);
    }
    // should not allow a signature that reuses signers

    function test_notAllow_signerReuse() public {
        // Configure signers
        vm.prank(address(aliceDeleGator));
        aliceDeleGator.updateMultiSigParameters(sharedDeleGatorSigners, 2, true);

        // Get signature
        bytes32 hash_ = keccak256("hello world");
        bytes memory signature_ = SigningUtilsLib.signHash_EOA(users.alice.privateKey, hash_);

        // Show that signature is invalid (SIG_VALIDATION_FAILED = 0xffffffff)
        bytes4 validationData_ = aliceDeleGator.isValidSignature(hash_, BytesLib.concat(signature_, signature_));
        assertEq(validationData_, bytes4(0xffffffff));
    }

    // should not allow a signature uses completely invalid signers
    function test_notAllow_invalidSigners() public {
        // Configure signers Alice and Bob
        vm.prank(address(aliceDeleGator));
        aliceDeleGator.updateMultiSigParameters(sharedDeleGatorSigners, 2, true);

        // Get signature from Carol
        bytes32 hash_ = keccak256("hello world");
        bytes memory carolSignature_ = SigningUtilsLib.signHash_EOA(users.carol.privateKey, hash_);
        bytes memory daveSignature_ = SigningUtilsLib.signHash_EOA(users.dave.privateKey, hash_);

        // Show that signature is invalid (SIG_VALIDATION_FAILED = 0xffffffff)
        bytes4 validationData_ = aliceDeleGator.isValidSignature(hash_, carolSignature_);
        assertEq(validationData_, bytes4(0xffffffff));

        // Update to a higher threshold
        vm.prank(address(aliceDeleGator));
        aliceDeleGator.updateThreshold(2);

        // Show that signature is still invalid (SIG_VALIDATION_FAILED = 0xffffffff)
        validationData_ = aliceDeleGator.isValidSignature(hash_, BytesLib.concat(carolSignature_, daveSignature_));
        assertEq(validationData_, bytes4(0xffffffff));
    }

    ////////////////////// Events //////////////////////

    function test_DelegationManagerSetEvent() public {
        vm.expectEmit(true, true, true, true);
        emit SetDelegationManager(delegationManager);
        new MultiSigDeleGator(delegationManager, entryPoint);
    }

    function test_InitializedSignersEvents() public {
        emit AddedSigner(sharedDeleGatorSigners[0]);
        vm.expectEmit(true, true, true, true);
        emit AddedSigner(sharedDeleGatorSigners[1]);
        vm.expectEmit(true, true, true, true);
        emit AddedSigner(sharedDeleGatorSigners[2]);
        emit UpdatedThreshold(1);
        vm.expectEmit(true, true, true, true);
        emit Initialized(1);
        new DeleGatorProxy(
            address(multiSigDeleGatorImpl), abi.encodeWithSignature("initialize(address[],uint256)", sharedDeleGatorSigners, 1)
        );
    }

    function test_InitializedImplementationEvent() public {
        vm.expectEmit(true, true, true, true);
        emit UpdatedThreshold(type(uint256).max);
        new MultiSigDeleGator(delegationManager, entryPoint);
    }

    function test_ReinitializedSignersEvents() public {
        address[] memory owners_ = new address[](2);
        owners_[0] = users.carol.addr;
        owners_[1] = users.dave.addr;

        // Replace the signers
        vm.startPrank(address(aliceDeleGator));
        emit AddedSigner(owners_[0]);
        vm.expectEmit(true, true, true, true);
        emit AddedSigner(owners_[1]);
        vm.expectEmit(true, true, true, true);
        emit UpdatedThreshold(2);
        vm.expectEmit(true, true, true, true);
        emit Initialized(2);
        aliceDeleGator.reinitialize(2, owners_, 2, false);
    }

    ////////////////////// Errors //////////////////////

    // should not allow a threshold greater than the number of signers
    function test_error_Init_thresholdGreaterThanSigners() public {
        // Configure delegator
        address[] memory signers_ = new address[](10);
        (signers_,) = _createMultipleSigners(10, false);
        uint256 threshold_ = signers_.length + 1;

        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidThreshold.selector));
        new DeleGatorProxy(
            address(multiSigDeleGatorImpl), abi.encodeWithSignature("initialize(address[],uint256)", signers_, threshold_)
        );
    }

    function test_error_Init_InvalidSignersLength() public {
        // Zero signers
        address[] memory signers_ = new address[](0);

        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidThreshold.selector));
        new DeleGatorProxy(address(multiSigDeleGatorImpl), abi.encodeWithSignature("initialize(address[],uint256)", signers_, 0));

        // More than max signers
        signers_ = new address[](MAX_NUMBER_OF_SIGNERS + 1);
        (signers_,) = _createMultipleSigners(MAX_NUMBER_OF_SIGNERS + 1, false);

        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.TooManySigners.selector));
        new DeleGatorProxy(
            address(multiSigDeleGatorImpl),
            abi.encodeWithSignature("initialize(address[],uint256)", signers_, MAX_NUMBER_OF_SIGNERS + 1)
        );
    }

    function test_error_Init_InvalidThreshold() public {
        // Creating 1 of 1 MultiSigDeleGator
        (address addr_) = makeAddr("newUser");
        address[] memory signers_ = new address[](1);
        signers_[0] = addr_;

        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidThreshold.selector));

        // should throw when Threshold is 0
        DeleGatorProxy proxy = new DeleGatorProxy(
            address(multiSigDeleGatorImpl), abi.encodeWithSignature("initialize(address[],uint256)", signers_, 0)
        );

        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidThreshold.selector));
        // should throw when Threshold greater than no. of signers
        proxy = new DeleGatorProxy(
            address(multiSigDeleGatorImpl), abi.encodeWithSignature("initialize(address[],uint256)", signers_, 2)
        );
    }

    // Should revert if Signer address is Zero Address
    function test_error_Init_InvalidSignerAddress() public {
        // 1 of 1 MultiSigDeleGator

        address[] memory signers_ = new address[](1);
        signers_[0] = address(0);

        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidSignerAddress.selector));

        // should throw when Threshold is 0
        new DeleGatorProxy(address(multiSigDeleGatorImpl), abi.encodeWithSignature("initialize(address[],uint256)", signers_, 1));
    }

    // Should revert if same addressess passed in signer
    function test_error_Init_AlreadyASigner() public {
        // 1 of 1 MultiSigDeleGator

        (address addr_) = makeAddr("newUser");

        address[] memory signers_ = new address[](2);
        signers_[0] = addr_;
        signers_[1] = addr_;

        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.AlreadyASigner.selector));

        // should throw when Threshold is 0
        new DeleGatorProxy(address(multiSigDeleGatorImpl), abi.encodeWithSignature("initialize(address[],uint256)", signers_, 1));
    }

    ////////////////////// Updating MultiSig Parameters //////////////////////

    // should allow Alice to clear and add new signers
    function test_reinitialize_clearsAndSetSigners() public {
        address[] memory oldSigners_ = aliceDeleGator.getSigners();
        assertEq(oldSigners_[0], users.alice.addr);
        assertEq(oldSigners_.length, 1);

        address[] memory owners_ = new address[](2);
        owners_[0] = users.carol.addr;
        owners_[1] = users.dave.addr;

        // Replace the signers
        vm.startPrank(address(aliceDeleGator));
        aliceDeleGator.reinitialize(2, owners_, 2, true);

        address[] memory newSigners_ = aliceDeleGator.getSigners();
        assertEq(newSigners_[0], users.carol.addr);
        assertEq(newSigners_[1], users.dave.addr);
        assertEq(newSigners_.length, 2);
    }

    // should allow Alice to keep and add new signers
    function test_reinitialize_keepAndSetSigners() public {
        address[] memory oldSigners_ = aliceDeleGator.getSigners();
        assertEq(oldSigners_[0], users.alice.addr);
        assertEq(oldSigners_.length, 1);

        address[] memory owners_ = new address[](2);
        owners_[0] = users.carol.addr;
        owners_[1] = users.dave.addr;

        // Adds the new signers
        vm.startPrank(address(aliceDeleGator));
        aliceDeleGator.reinitialize(2, owners_, 2, false);

        address[] memory newSigners_ = aliceDeleGator.getSigners();
        assertEq(newSigners_[0], users.alice.addr);
        assertEq(newSigners_[1], users.carol.addr);
        assertEq(newSigners_[2], users.dave.addr);
        assertEq(newSigners_.length, 3);
    }

    // should allow Alice to replace a signer
    function test_allow_replaceSigner() public {
        address[] memory preSigners_ = aliceDeleGator.getSigners();

        assertEq(preSigners_[0], users.alice.addr);

        vm.startPrank(address(aliceDeleGator));

        // Replace the only signer
        vm.expectEmit(true, true, true, true, address(aliceDeleGator));
        emit ReplacedSigner(users.alice.addr, users.bob.addr);
        aliceDeleGator.replaceSigner(users.alice.addr, users.bob.addr);
        address[] memory postSigners_ = aliceDeleGator.getSigners();
        assertEq(postSigners_[0], users.bob.addr);
        assertFalse(preSigners_[0] == postSigners_[0]);

        // Add a few signers so we can test more cases
        aliceDeleGator.addSigner(users.alice.addr);
        aliceDeleGator.addSigner(users.carol.addr);

        // Replace first signer
        vm.expectEmit(true, true, true, true, address(aliceDeleGator));
        emit ReplacedSigner(users.bob.addr, users.dave.addr);
        aliceDeleGator.replaceSigner(users.bob.addr, users.dave.addr);
        postSigners_ = aliceDeleGator.getSigners();
        assertEq(postSigners_[0], users.dave.addr);
        assertEq(postSigners_[1], users.alice.addr);
        assertEq(postSigners_[2], users.carol.addr);
        assertEq(postSigners_.length, 3);

        // Replace middle signer
        vm.expectEmit(true, true, true, true, address(aliceDeleGator));
        emit ReplacedSigner(users.alice.addr, users.eve.addr);
        aliceDeleGator.replaceSigner(users.alice.addr, users.eve.addr);
        postSigners_ = aliceDeleGator.getSigners();
        assertEq(postSigners_[0], users.dave.addr);
        assertEq(postSigners_[1], users.eve.addr);
        assertEq(postSigners_[2], users.carol.addr);
        assertEq(postSigners_.length, 3);

        // Replace last signer
        vm.expectEmit(true, true, true, true, address(aliceDeleGator));
        emit ReplacedSigner(users.carol.addr, users.frank.addr);
        aliceDeleGator.replaceSigner(users.carol.addr, users.frank.addr);
        postSigners_ = aliceDeleGator.getSigners();
        assertEq(postSigners_[0], users.dave.addr);
        assertEq(postSigners_[1], users.eve.addr);
        assertEq(postSigners_[2], users.frank.addr);
        assertEq(postSigners_.length, 3);
    }

    function test_notAllow_replaceSigner() public {
        address[] memory preSigners_ = aliceDeleGator.getSigners();

        assertEq(preSigners_[0], users.alice.addr);

        // Don't allow someone else to replace Alice's MultiSigDeleGator's signers
        // replaceSigner call must come from the MultiSigDeleGator itself
        vm.prank(address(users.alice.addr));
        vm.expectRevert(abi.encodeWithSelector(DeleGatorCore.NotEntryPointOrSelf.selector));
        aliceDeleGator.replaceSigner(users.alice.addr, users.bob.addr);

        // Mock calls from the MultiSigDeleGator itself
        vm.startPrank(address(aliceDeleGator));

        // Don't allow replacing a non-signer
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.NotASigner.selector));
        aliceDeleGator.replaceSigner(users.bob.addr, users.bob.addr);

        // Don't allow replacing with an existing signer
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.AlreadyASigner.selector));
        aliceDeleGator.replaceSigner(users.alice.addr, users.alice.addr);

        // Don't allow replacing with the zero address
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidSignerAddress.selector));
        aliceDeleGator.replaceSigner(users.alice.addr, address(0));

        // Don't allow replacing with a non-ERC1271 contract signer
        NonERC1271TestContract nonERC1271 = new NonERC1271TestContract();
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidSignerAddress.selector));
        aliceDeleGator.replaceSigner(users.alice.addr, address(nonERC1271));

        // Don't allow replacing with the address of the DeleGator
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidSignerAddress.selector));
        aliceDeleGator.replaceSigner(users.alice.addr, address(aliceDeleGator));
    }

    // should allow Alice to add a signer
    function test_allow_addSigner() public {
        address[] memory preSigners_ = aliceDeleGator.getSigners();

        assertEq(preSigners_[0], users.alice.addr);
        assertEq(preSigners_.length, 1);

        vm.prank(address(aliceDeleGator));
        vm.expectEmit(true, true, true, true, address(aliceDeleGator));
        emit AddedSigner(users.bob.addr);
        aliceDeleGator.addSigner(users.bob.addr);

        address[] memory postSigners_ = aliceDeleGator.getSigners();

        assertEq(postSigners_[0], users.alice.addr);
        assertEq(postSigners_[1], users.bob.addr);
        assertEq(postSigners_.length, 2);
    }

    function test_notAllow_addSigner() public {
        address[] memory preSigners_ = aliceDeleGator.getSigners();

        assertEq(preSigners_[0], users.alice.addr);

        // Don't allow someone else to remove signers.
        // Call must come from the MultiSigDeleGator itself.
        vm.prank(address(users.alice.addr));
        vm.expectRevert(abi.encodeWithSelector(DeleGatorCore.NotEntryPointOrSelf.selector));
        aliceDeleGator.addSigner(users.bob.addr);

        // Mock calls from the MultiSigDeleGator itself
        vm.startPrank(address(aliceDeleGator));

        // Don't allow adding with the zero address
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidSignerAddress.selector));
        aliceDeleGator.addSigner(address(0));

        // Don't allow adding a non-ERC1271 contract signer
        NonERC1271TestContract nonERC1271 = new NonERC1271TestContract();
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidSignerAddress.selector));
        aliceDeleGator.addSigner(address(nonERC1271));

        // Don't allow adding with the address of the DeleGator
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidSignerAddress.selector));
        aliceDeleGator.addSigner(address(aliceDeleGator));

        // Don't allow adding an existing signer
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.AlreadyASigner.selector));
        aliceDeleGator.addSigner(users.alice.addr);

        // Don't allow adding too many signers
        for (uint256 i = 0; i < MAX_NUMBER_OF_SIGNERS; ++i) {
            if (i == MAX_NUMBER_OF_SIGNERS - 1) {
                vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.TooManySigners.selector));
            }
            aliceDeleGator.addSigner(makeAddr(Strings.toString(i)));
        }
    }

    // should allow Alice to remove a signer
    function test_allow_removeSigner() public {
        vm.startPrank(address(aliceDeleGator));

        // Adding signers so there's some to remove.
        aliceDeleGator.addSigner(users.bob.addr);
        aliceDeleGator.addSigner(users.carol.addr);
        aliceDeleGator.addSigner(users.dave.addr);
        aliceDeleGator.addSigner(users.eve.addr);

        address[] memory preSigners_ = aliceDeleGator.getSigners();
        assertEq(preSigners_[0], users.alice.addr);
        assertEq(preSigners_[1], users.bob.addr);
        assertEq(preSigners_[2], users.carol.addr);
        assertEq(preSigners_[3], users.dave.addr);
        assertEq(preSigners_[4], users.eve.addr);
        assertEq(preSigners_.length, 5);

        // Remove the first signer in storage
        vm.expectEmit(true, true, true, true, address(aliceDeleGator));
        emit RemovedSigner(users.alice.addr);
        aliceDeleGator.removeSigner(users.alice.addr);
        address[] memory postSigners_ = aliceDeleGator.getSigners();
        assertEq(postSigners_[0], users.eve.addr);
        assertEq(postSigners_[1], users.bob.addr);
        assertEq(postSigners_[2], users.carol.addr);
        assertEq(postSigners_[3], users.dave.addr);
        assertEq(postSigners_.length, 4);

        // Remove the last signer in storage
        vm.expectEmit(true, true, true, true, address(aliceDeleGator));
        emit RemovedSigner(users.dave.addr);
        aliceDeleGator.removeSigner(users.dave.addr);
        postSigners_ = aliceDeleGator.getSigners();
        assertEq(postSigners_[0], users.eve.addr);
        assertEq(postSigners_[1], users.bob.addr);
        assertEq(postSigners_[2], users.carol.addr);
        assertEq(postSigners_.length, 3);

        // Remove a middle signer
        vm.expectEmit(true, true, true, true, address(aliceDeleGator));
        emit RemovedSigner(users.bob.addr);
        aliceDeleGator.removeSigner(users.bob.addr);
        postSigners_ = aliceDeleGator.getSigners();
        assertEq(postSigners_[0], users.eve.addr);
        assertEq(postSigners_[1], users.carol.addr);
        assertEq(postSigners_.length, 2);
    }

    function test_notAllow_removeSigner() public {
        // Don't allow someone else to remove signers.
        // Call must come from the MultiSigDeleGator itself.
        vm.prank(address(users.alice.addr));
        vm.expectRevert(abi.encodeWithSelector(DeleGatorCore.NotEntryPointOrSelf.selector));
        aliceDeleGator.removeSigner(users.alice.addr);

        // Mock calls from the MultiSigDeleGator itself
        vm.startPrank(address(aliceDeleGator));

        // Don't allow removing the last signer
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InsufficientSigners.selector));
        aliceDeleGator.removeSigner(users.alice.addr);

        // Don't allow removing non signers
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.NotASigner.selector));
        aliceDeleGator.removeSigner(users.bob.addr);

        // Don't allow less signers than the threshold
        aliceDeleGator.addSigner(users.bob.addr);
        aliceDeleGator.updateThreshold(2);
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InsufficientSigners.selector));
        aliceDeleGator.removeSigner(users.bob.addr);
    }

    function test_allow_updatingThreshold() public {
        uint256 preThreshold_ = aliceDeleGator.getThreshold();
        assertEq(preThreshold_, 1);

        // Mock calls from the MultiSigDeleGator itself
        vm.startPrank(address(aliceDeleGator));

        // Add a signer so we can increase the threshold
        aliceDeleGator.addSigner(users.bob.addr);

        // Increase the threshold
        vm.expectEmit(true, true, true, true, address(aliceDeleGator));
        emit UpdatedThreshold(2);
        aliceDeleGator.updateThreshold(2);

        uint256 postThreshold_ = aliceDeleGator.getThreshold();
        assertEq(postThreshold_, 2);
    }

    function test_notAllow_updatingThreshold() public {
        // Don't allow someone else to remove signers.
        // Call must come from the MultiSigDeleGator itself.
        vm.prank(address(users.alice.addr));
        vm.expectRevert(abi.encodeWithSelector(DeleGatorCore.NotEntryPointOrSelf.selector));
        aliceDeleGator.updateThreshold(1);

        uint256 preThreshold_ = aliceDeleGator.getThreshold();
        assertEq(preThreshold_, 1);

        // Mock calls from the MultiSigDeleGator itself
        vm.startPrank(address(aliceDeleGator));

        // Add a signer so we can increase the threshold
        aliceDeleGator.addSigner(users.bob.addr);

        // Don't allow a threshold of 0
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidThreshold.selector));
        aliceDeleGator.updateThreshold(0);

        // Don't allow a threshold greater than number of signers
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidThreshold.selector));
        aliceDeleGator.updateThreshold(3);
    }

    // should only allow Alice's MultiSigDeleGator to call updateMultiSigParameters
    function test_notAllow_updateMultiSigParameters_access() public {
        address[] memory signers_ = new address[](2);
        signers_[0] = users.alice.addr;
        signers_[1] = users.bob.addr;

        // Don't allow Alice to update Alice's MultiSigDeleGator's signers
        vm.prank(address(users.alice.addr));
        vm.expectRevert(abi.encodeWithSelector(DeleGatorCore.NotEntryPointOrSelf.selector));
        aliceDeleGator.updateMultiSigParameters(signers_, 1, false);

        // Don't allow Bob to update Alice's MultiSigDeleGator's signers
        vm.prank(address(users.bob.addr));
        vm.expectRevert(abi.encodeWithSelector(DeleGatorCore.NotEntryPointOrSelf.selector));
        aliceDeleGator.updateMultiSigParameters(signers_, 1, false);

        // Don't allow Bob's MultiSigDeleGator to update Alice's MultiSigDeleGator's signers
        vm.prank(address(bobDeleGator));
        vm.expectRevert(abi.encodeWithSelector(DeleGatorCore.NotEntryPointOrSelf.selector));
        aliceDeleGator.updateMultiSigParameters(signers_, 1, false);
    }

    // should not allow Alice's MultiSigDeleGator to update with an invalid threshold
    function test_notAllow_updateMultiSigParameters_threshold() public {
        address[] memory signers_ = new address[](2);
        signers_[0] = users.alice.addr;
        signers_[1] = users.bob.addr;

        // Don't allow a threshold of 0
        vm.prank(address(aliceDeleGator));
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidThreshold.selector));
        aliceDeleGator.updateMultiSigParameters(signers_, 0, true);

        // Don't allow a threshold greater than the number of existing signers + new signers
        vm.prank(address(aliceDeleGator));
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidThreshold.selector));
        aliceDeleGator.updateMultiSigParameters(signers_, signers_.length + 1, true);
    }

    // should not allow Alice's MultiSigDeleGator to update with an invalid threshold while keeping the signers
    function test_notAllow_updateMultiSigParameters_thresholdKeepingSigners() public {
        address[] memory signers_ = new address[](2);
        signers_[0] = users.alice.addr;
        signers_[1] = users.bob.addr;

        uint256 amountOfSigners_ = aliceDeleGator.getSigners().length;
        // Don't allow a threshold greater than the number of signers
        vm.prank(address(aliceDeleGator));
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.InvalidThreshold.selector));
        aliceDeleGator.updateMultiSigParameters(signers_, amountOfSigners_ + signers_.length + 1, false);
    }

    // should not allow Alice's MultiSigDeleGator to update with a max number of signers
    function test_notAllow_updateMultiSigParameters_maxNumberOfSigners() public {
        uint256 maxNumberOfSigners_ = aliceDeleGator.MAX_NUMBER_OF_SIGNERS();
        address[] memory signers_ = new address[](maxNumberOfSigners_);

        // Don't allow more signers than the max number of signers, keeping the signers
        vm.prank(address(aliceDeleGator));
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.TooManySigners.selector));
        aliceDeleGator.updateMultiSigParameters(signers_, 1, false);

        // Don't allow more signers than the max number of signers, deleting the signers
        signers_ = new address[](maxNumberOfSigners_ + 1);
        vm.prank(address(aliceDeleGator));
        vm.expectRevert(abi.encodeWithSelector(MultiSigDeleGator.TooManySigners.selector));
        aliceDeleGator.updateMultiSigParameters(signers_, 1, true);
    }

    // should allow the creation of a MultiSig with 3 signers and updating the signers & threshold
    function test_allow_updateMultiSigParameters_base() public {
        // create a multiSig with 3 signers and threshold of 2
        MultiSigDeleGator deleGator_ = MultiSigDeleGator(payable(deployDeleGator_MultiSig(sharedDeleGatorSigners, 2)));
        vm.deal(address(deleGator_), 100 ether);

        address[] memory obtainedSigners_ = deleGator_.getSigners();

        assertEq(sharedDeleGatorSigners[0], obtainedSigners_[0]);
        assertEq(sharedDeleGatorSigners[1], obtainedSigners_[1]);
        assertEq(sharedDeleGatorSigners[2], obtainedSigners_[2]);

        // updating carol's address to Dave's address
        sharedDeleGatorSigners[2] = users.dave.addr;

        // Update Signers and threshold
        bytes memory userOpCallData_ =
            abi.encodeWithSelector(MultiSigDeleGator.updateMultiSigParameters.selector, sharedDeleGatorSigners, 3, true);
        PackedUserOperation memory userOp_ = createUserOp(address(deleGator_), userOpCallData_);

        // Create a subset of private keys to ensure signature length is accurate
        uint256[] memory privateKeysSubset_ = new uint256[](2);
        privateKeysSubset_[0] = sharedDeleGatorPrivateKeys[0];
        privateKeysSubset_[1] = sharedDeleGatorPrivateKeys[1];
        userOp_.signature =
            SigningUtilsLib.signHash_MultiSig(privateKeysSubset_, deleGator_.getPackedUserOperationTypedDataHash(userOp_));

        PackedUserOperation[] memory userOps_ = new PackedUserOperation[](1);
        userOps_[0] = userOp_;
        vm.prank(bundler);

        vm.expectEmit(false, false, false, true, address(deleGator_));
        emit RemovedSigner(sharedDeleGatorSigners[0]);
        vm.expectEmit(false, false, false, true, address(deleGator_));
        emit RemovedSigner(sharedDeleGatorSigners[1]);
        vm.expectEmit(false, false, false, true, address(deleGator_));
        emit RemovedSigner(sharedDeleGatorSigners[2]);
        vm.expectEmit(false, false, false, true, address(deleGator_));
        emit AddedSigner(sharedDeleGatorSigners[0]);
        vm.expectEmit(false, false, false, true, address(deleGator_));
        emit AddedSigner(sharedDeleGatorSigners[1]);
        vm.expectEmit(false, false, false, true, address(deleGator_));
        emit AddedSigner(sharedDeleGatorSigners[2]);

        entryPoint.handleOps(userOps_, bundler);

        obtainedSigners_ = deleGator_.getSigners();

        assertEq(sharedDeleGatorSigners[0], obtainedSigners_[0]);
        assertEq(sharedDeleGatorSigners[1], obtainedSigners_[1]);
        assertEq(sharedDeleGatorSigners[2], obtainedSigners_[2]);

        uint256 threshold_ = deleGator_.getThreshold();
        assertEq(threshold_, 3);
    }

    // should NOT be able to reinitialize someone elses MultiSigDeleGator
    function test_unauthorizedReinitializeCall() public {
        // Load DeleGator to manipulate
        address payable delegator_ = payable(address(aliceDeleGator));

        uint64 version_ = DeleGatorCore(delegator_).getInitializedVersion() + 1;
        address[] memory newSigners_ = new address[](1);
        newSigners_[0] = users.bob.addr;

        vm.prank(users.bob.addr);
        vm.expectRevert(abi.encodeWithSelector(DeleGatorCore.NotEntryPointOrSelf.selector));
        MultiSigDeleGator(delegator_).reinitialize(version_, newSigners_, 1, false);
    }

    ////////////////////// ERC-1271 Contract Signer Tests //////////////////////

    // should allow adding an ERC-1271 contract as a signer
    function test_allow_addContractSigner() public {
        // Deploy a contract signer (another MultiSigDeleGator)
        address[] memory contractSigners_ = new address[](1);
        contractSigners_[0] = users.carol.addr;
        MultiSigDeleGator contractSigner_ = MultiSigDeleGator(payable(deployDeleGator_MultiSig(contractSigners_, 1)));

        vm.prank(address(aliceDeleGator));
        vm.expectEmit(true, true, true, true, address(aliceDeleGator));
        emit AddedSigner(address(contractSigner_));
        aliceDeleGator.addSigner(address(contractSigner_));

        address[] memory signers_ = aliceDeleGator.getSigners();
        assertEq(signers_.length, 2);
        assertEq(signers_[1], address(contractSigner_));
        assertTrue(aliceDeleGator.isERC1271Signer(address(contractSigner_)));
    }

    // should allow replacing EOA with ERC-1271 contract signer
    function test_allow_replaceWithContractSigner() public {
        // Deploy a contract signer
        address[] memory contractSigners_ = new address[](1);
        contractSigners_[0] = users.bob.addr;
        MultiSigDeleGator contractSigner_ = MultiSigDeleGator(payable(deployDeleGator_MultiSig(contractSigners_, 1)));

        vm.prank(address(aliceDeleGator));
        vm.expectEmit(true, true, true, true, address(aliceDeleGator));
        emit ReplacedSigner(users.alice.addr, address(contractSigner_));
        aliceDeleGator.replaceSigner(users.alice.addr, address(contractSigner_));

        address[] memory signers_ = aliceDeleGator.getSigners();
        assertEq(signers_.length, 1);
        assertEq(signers_[0], address(contractSigner_));
        assertTrue(aliceDeleGator.isERC1271Signer(address(contractSigner_)));
    }

    // should validate mixed EOA and contract signatures
    function test_allow_mixedSignatureValidation() public {
        // Setup: Create a multisig with 2 EOAs and 1 contract signer (3-of-3)
        address[] memory subSigners_ = new address[](1);
        subSigners_[0] = users.carol.addr;
        MultiSigDeleGator subMultiSig_ = MultiSigDeleGator(payable(deployDeleGator_MultiSig(subSigners_, 1)));

        address[] memory mixedSigners_ = new address[](3);
        mixedSigners_[0] = users.alice.addr;
        mixedSigners_[1] = users.bob.addr;
        mixedSigners_[2] = address(subMultiSig_);
        
        MultiSigDeleGator mixedDeleGator_ = MultiSigDeleGator(payable(deployDeleGator_MultiSig(mixedSigners_, 3)));

        bytes32 hash_ = keccak256("test message");

        // Create all signatures
        bytes memory aliceSig_ = SigningUtilsLib.signHash_EOA(users.alice.privateKey, hash_);
        bytes memory bobSig_ = SigningUtilsLib.signHash_EOA(users.bob.privateKey, hash_);
        bytes memory carolSig_ = SigningUtilsLib.signHash_EOA(users.carol.privateKey, hash_);
        
        bytes memory contractSig_ = abi.encodePacked(
            address(subMultiSig_),
            uint16(carolSig_.length),
            carolSig_
        );

        // Build combined signature in sorted order (all 3 signers for 3-of-3 threshold)
        address[] memory signers_ = new address[](3);
        bytes[] memory sigs_ = new bytes[](3);
        signers_[0] = users.alice.addr;
        signers_[1] = users.bob.addr;
        signers_[2] = address(subMultiSig_);
        sigs_[0] = aliceSig_;
        sigs_[1] = bobSig_;
        sigs_[2] = contractSig_;
        bytes memory combinedSig_ = _sortSignatures(signers_, sigs_);

        bytes4 result_ = mixedDeleGator_.isValidSignature(hash_, combinedSig_);
        assertEq(result_, bytes4(0x1626ba7e), "Mixed signature validation failed");
    }

    // should validate nested contract signatures (2 levels)
    function test_allow_nestedContractSignatures() public {
        // Level 2: SubMultiSig with Alice and Bob (2-of-2)
        address[] memory subSigners_ = new address[](2);
        subSigners_[0] = users.alice.addr;
        subSigners_[1] = users.bob.addr;
        MultiSigDeleGator subMultiSig_ = MultiSigDeleGator(payable(deployDeleGator_MultiSig(subSigners_, 2)));

        // Level 1: RootMultiSig with Carol and SubMultiSig (2-of-2)
        address[] memory rootSigners_ = new address[](2);
        rootSigners_[0] = users.carol.addr;
        rootSigners_[1] = address(subMultiSig_);
        MultiSigDeleGator rootMultiSig_ = MultiSigDeleGator(payable(deployDeleGator_MultiSig(rootSigners_, 2)));

        bytes32 hash_ = keccak256("nested test");

        // Create signatures for SubMultiSig (Alice + Bob) - sorted
        bytes memory aliceSig_ = SigningUtilsLib.signHash_EOA(users.alice.privateKey, hash_);
        bytes memory bobSig_ = SigningUtilsLib.signHash_EOA(users.bob.privateKey, hash_);
        
        address[] memory subSigSigners_ = new address[](2);
        bytes[] memory subSigs_ = new bytes[](2);
        subSigSigners_[0] = users.alice.addr;
        subSigSigners_[1] = users.bob.addr;
        subSigs_[0] = aliceSig_;
        subSigs_[1] = bobSig_;
        bytes memory subMultiSigSig_ = _sortSignatures(subSigSigners_, subSigs_);

        // Create Carol's signature
        bytes memory carolSig_ = SigningUtilsLib.signHash_EOA(users.carol.privateKey, hash_);

        // Encode contract signature for SubMultiSig
        bytes memory contractSig_ = abi.encodePacked(
            address(subMultiSig_),
            uint16(subMultiSigSig_.length),
            subMultiSigSig_
        );

        // Sort root signatures
        address[] memory rootSigSigners_ = new address[](2);
        bytes[] memory rootSigs_ = new bytes[](2);
        rootSigSigners_[0] = users.carol.addr;
        rootSigSigners_[1] = address(subMultiSig_);
        rootSigs_[0] = carolSig_;
        rootSigs_[1] = contractSig_;
        bytes memory combinedSig_ = _sortSignatures(rootSigSigners_, rootSigs_);

        // Validate
        bytes4 result_ = rootMultiSig_.isValidSignature(hash_, combinedSig_);
        assertEq(result_, bytes4(0x1626ba7e), "Nested signature validation failed");
    }

    // should reject if contract signature is invalid
    function test_notAllow_invalidContractSignature() public {
        // Setup: multisig with 1 EOA and 1 contract signer
        address[] memory subSigners_ = new address[](1);
        subSigners_[0] = users.bob.addr;
        MultiSigDeleGator subMultiSig_ = MultiSigDeleGator(payable(deployDeleGator_MultiSig(subSigners_, 1)));

        address[] memory mixedSigners_ = new address[](2);
        mixedSigners_[0] = users.alice.addr;
        mixedSigners_[1] = address(subMultiSig_);
        MultiSigDeleGator mixedDeleGator_ = MultiSigDeleGator(payable(deployDeleGator_MultiSig(mixedSigners_, 2)));

        bytes32 hash_ = keccak256("test");

        // Create valid Alice signature
        bytes memory aliceSig_ = SigningUtilsLib.signHash_EOA(users.alice.privateKey, hash_);
        
        // Create INVALID signature for contract (wrong private key)
        bytes memory wrongSig_ = SigningUtilsLib.signHash_EOA(users.carol.privateKey, hash_);
        
        bytes memory contractSig_ = abi.encodePacked(
            address(subMultiSig_),
            uint16(wrongSig_.length),
            wrongSig_
        );

        bytes memory combinedSig_ = abi.encodePacked(aliceSig_, contractSig_);

        // Should fail validation
        bytes4 result_ = mixedDeleGator_.isValidSignature(hash_, combinedSig_);
        assertEq(result_, bytes4(0xffffffff), "Should reject invalid contract signature");
    }

    // should return correct isERC1271Signer status
    function test_return_isERC1271Signer() public {
        // Deploy contract signer
        address[] memory contractSigners_ = new address[](1);
        contractSigners_[0] = users.bob.addr;
        MultiSigDeleGator contractSigner_ = MultiSigDeleGator(payable(deployDeleGator_MultiSig(contractSigners_, 1)));

        // Add contract signer
        vm.prank(address(aliceDeleGator));
        aliceDeleGator.addSigner(address(contractSigner_));

        // Alice should be EOA (not ERC1271)
        assertFalse(aliceDeleGator.isERC1271Signer(users.alice.addr));
        
        // Contract signer should be ERC1271
        assertTrue(aliceDeleGator.isERC1271Signer(address(contractSigner_)));
    }

    // should handle threshold with mixed signers
    function test_allow_thresholdWithMixedSigners() public {
        // Setup: 2 EOAs + 1 contract, threshold 2-of-3
        address[] memory subSigners_ = new address[](1);
        subSigners_[0] = users.carol.addr;
        MultiSigDeleGator subMultiSig_ = MultiSigDeleGator(payable(deployDeleGator_MultiSig(subSigners_, 1)));

        address[] memory mixedSigners_ = new address[](3);
        mixedSigners_[0] = users.alice.addr;
        mixedSigners_[1] = users.bob.addr;
        mixedSigners_[2] = address(subMultiSig_);
        
        MultiSigDeleGator mixedDeleGator_ = MultiSigDeleGator(payable(deployDeleGator_MultiSig(mixedSigners_, 2)));

        bytes32 hash_ = keccak256("threshold test");

        // Test 1: Alice + Bob (2 EOAs)
        bytes memory aliceSig_ = SigningUtilsLib.signHash_EOA(users.alice.privateKey, hash_);
        bytes memory bobSig_ = SigningUtilsLib.signHash_EOA(users.bob.privateKey, hash_);
        
        address[] memory signers1_ = new address[](2);
        bytes[] memory sigs1_ = new bytes[](2);
        signers1_[0] = users.alice.addr;
        signers1_[1] = users.bob.addr;
        sigs1_[0] = aliceSig_;
        sigs1_[1] = bobSig_;
        bytes memory sig1_ = _sortSignatures(signers1_, sigs1_);
        
        bytes4 result1_ = mixedDeleGator_.isValidSignature(hash_, sig1_);
        assertEq(result1_, bytes4(0x1626ba7e), "EOA-only threshold should work");

        // Test 2: Alice + SubMultiSig (1 EOA + 1 contract)
        bytes memory carolSig_ = SigningUtilsLib.signHash_EOA(users.carol.privateKey, hash_);
        bytes memory contractSig_ = abi.encodePacked(
            address(subMultiSig_),
            uint16(carolSig_.length),
            carolSig_
        );
        address[] memory signers2_ = new address[](2);
        bytes[] memory sigs2_ = new bytes[](2);
        signers2_[0] = users.alice.addr;
        signers2_[1] = address(subMultiSig_);
        sigs2_[0] = aliceSig_;
        sigs2_[1] = contractSig_;
        bytes memory sig2_ = _sortSignatures(signers2_, sigs2_);
        
        bytes4 result2_ = mixedDeleGator_.isValidSignature(hash_, sig2_);
        assertEq(result2_, bytes4(0x1626ba7e), "Mixed threshold should work");
    }

    // should maintain signature ordering with contract signers
    function test_notAllow_unsortedMixedSignatures() public {
        // Setup with sorted addresses: alice < contractSigner
        address[] memory subSigners_ = new address[](1);
        subSigners_[0] = users.bob.addr;
        MultiSigDeleGator subMultiSig_ = MultiSigDeleGator(payable(deployDeleGator_MultiSig(subSigners_, 1)));

        // Ensure alice's address is less than contract address for testing
        address[] memory mixedSigners_ = new address[](2);
        if (users.alice.addr < address(subMultiSig_)) {
            mixedSigners_[0] = users.alice.addr;
            mixedSigners_[1] = address(subMultiSig_);
        } else {
            mixedSigners_[0] = address(subMultiSig_);
            mixedSigners_[1] = users.alice.addr;
        }
        
        MultiSigDeleGator mixedDeleGator_ = MultiSigDeleGator(payable(deployDeleGator_MultiSig(mixedSigners_, 2)));

        bytes32 hash_ = keccak256("ordering test");

        bytes memory aliceSig_ = SigningUtilsLib.signHash_EOA(users.alice.privateKey, hash_);
        bytes memory bobSig_ = SigningUtilsLib.signHash_EOA(users.bob.privateKey, hash_);
        bytes memory contractSig_ = abi.encodePacked(
            address(subMultiSig_),
            uint16(bobSig_.length),
            bobSig_
        );

        // Provide signatures in WRONG order (should fail)
        bytes memory wrongOrderSig_;
        if (users.alice.addr < address(subMultiSig_)) {
            // Correct order is alice, contract - so reverse it
            wrongOrderSig_ = abi.encodePacked(contractSig_, aliceSig_);
        } else {
            wrongOrderSig_ = abi.encodePacked(aliceSig_, contractSig_);
        }

        bytes4 result_ = mixedDeleGator_.isValidSignature(hash_, wrongOrderSig_);
        assertEq(result_, bytes4(0xffffffff), "Unsorted signatures should fail");
    }

    ////////////////////// Helpers //////////////////////

    function _createMultipleSigners(uint256 _numOfSigners, bool _sort) internal returns (address[] memory, uint256[] memory) {
        address[] memory signers_ = new address[](_numOfSigners);
        uint256[] memory privateKeys_ = new uint256[](_numOfSigners);

        for (uint256 i = 0; i < _numOfSigners; ++i) {
            (address addr_, uint256 privateKey_) = makeAddrAndKey(Strings.toString(i));
            signers_[i] = addr_;
            privateKeys_[i] = privateKey_;
        }
        if (!_sort) return (signers_, privateKeys_);

        (signers_, privateKeys_) = AccountSorterLib.sortAddressesWithPrivateKeys(signers_, privateKeys_);
        return (signers_, privateKeys_);
    }

    // Helper to build sorted signatures using address-signature pairs
    // Similar approach to AccountSorterLib but for signatures instead of private keys
    function _sortSignatures(
        address[] memory signers,
        bytes[] memory signatures
    ) internal pure returns (bytes memory) {
        require(signers.length == signatures.length, "Length mismatch");
        
        // Use insertion sort (efficient for small arrays)
        for (uint256 i = 1; i < signers.length; i++) {
            address keyAddr = signers[i];
            bytes memory keySig = signatures[i];
            uint256 j = i;
            
            while (j > 0 && signers[j - 1] > keyAddr) {
                signers[j] = signers[j - 1];
                signatures[j] = signatures[j - 1];
                j--;
            }
            
            signers[j] = keyAddr;
            signatures[j] = keySig;
        }
        
        // Concatenate sorted signatures
        bytes memory result;
        for (uint256 i = 0; i < signatures.length; i++) {
            result = abi.encodePacked(result, signatures[i]);
        }
        
        return result;
    }
}

// Mock non-ERC1271 contract for testing rejection of invalid contract signers
contract NonERC1271TestContract {
    // This contract intentionally does not implement isValidSignature
    function someFunction() external pure returns (uint256) {
        return 42;
    }
}
