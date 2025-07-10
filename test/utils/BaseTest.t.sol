// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { StdCheatsSafe } from "forge-std/StdCheats.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { FCL_ecdsa_utils } from "@FCL/FCL_ecdsa_utils.sol";
import { ecGenMulmuladdB4W } from "@SCL/elliptic/SCL_mulmuladdX_fullgenW.sol";
import { a, b, p, gx, gy, n } from "@SCL/fields/SCL_secp256r1.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IEntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { P256SCLVerifierLib } from "../../src/libraries/P256SCLVerifierLib.sol";
import { SCL_Wrapper } from "./SCLWrapperLib.sol";

import { CALLTYPE_SINGLE, CALLTYPE_BATCH, EXECTYPE_TRY, MODE_DEFAULT } from "../../src/utils/Constants.sol";
import { EXECUTE_SIGNATURE } from "./Constants.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { TestUser, TestUsers, Implementation, SignatureType } from "./Types.t.sol";
import { SigningUtilsLib } from "./SigningUtilsLib.t.sol";
import { StorageUtilsLib } from "./StorageUtilsLib.t.sol";
import { UserOperationLib } from "./UserOperationLib.t.sol";
import { Execution, PackedUserOperation, Delegation, ModeCode, ModePayload } from "../../src/utils/Types.sol";
import { SimpleFactory } from "../../src/utils/SimpleFactory.sol";
import { DelegationManager } from "../../src/DelegationManager.sol";
import { DeleGatorCore } from "../../src/DeleGatorCore.sol";
import { HybridDeleGator } from "../../src/HybridDeleGator.sol";
import { MultiSigDeleGator } from "../../src/MultiSigDeleGator.sol";
import { EIP7702StatelessDeleGator } from "../../src/EIP7702/EIP7702StatelessDeleGator.sol";
import "forge-std/Test.sol";

abstract contract BaseTest is Test {
    using ModeLib for ModeCode;
    using MessageHashUtils for bytes32;

    SignatureType public SIGNATURE_TYPE;
    Implementation public IMPLEMENTATION;

    ////////////////////////////// State //////////////////////////////

    // Constants
    bytes32 public ROOT_AUTHORITY;
    address public ANY_DELEGATE;

    // ERC4337
    EntryPoint public entryPoint;

    // Simple Factory
    SimpleFactory public simpleFactory;

    // Delegation Manager
    DelegationManager public delegationManager;

    // DeleGator Implementations
    HybridDeleGator public hybridDeleGatorImpl;
    MultiSigDeleGator public multiSigDeleGatorImpl;
    EIP7702StatelessDeleGator public eip7702StatelessDeleGatorImpl;

    // Users
    TestUsers internal users;
    address payable bundler;

    // Tracks the user's nonce
    mapping(address entryPoint => mapping(address user => uint256 nonce)) public senderNonce;
    // mapping(address user => uint256 nonce) public senderNonce;

    // Execution modes
    ModeCode public singleDefaultMode = ModeLib.encodeSimpleSingle();
    ModeCode public batchDefaultMode = ModeLib.encodeSimpleBatch();
    ModeCode public singleTryMode = ModeLib.encode(CALLTYPE_SINGLE, EXECTYPE_TRY, MODE_DEFAULT, ModePayload.wrap(0x00));
    ModeCode public batchTryMode = ModeLib.encode(CALLTYPE_BATCH, EXECTYPE_TRY, MODE_DEFAULT, ModePayload.wrap(0x00));

    ////////////////////////////// Set Up //////////////////////////////

    function setUp() public virtual {
        // Create 4337 EntryPoint
        entryPoint = new EntryPoint();
        vm.label(address(entryPoint), "EntryPoint");

        // Create Simple Factory
        simpleFactory = new SimpleFactory();
        vm.label(address(simpleFactory), "Simple Factory");

        // DelegationManager
        delegationManager = new DelegationManager(makeAddr("DelegationManager Owner"));
        vm.label(address(delegationManager), "Delegation Manager");

        // Set constant values for easy access
        ROOT_AUTHORITY = delegationManager.ROOT_AUTHORITY();
        ANY_DELEGATE = delegationManager.ANY_DELEGATE();

        // Create P256 Verifier Contract
        vm.etch(P256SCLVerifierLib.VERIFIER, type(SCL_Wrapper).runtimeCode);
        vm.label(P256SCLVerifierLib.VERIFIER, "P256 Verifier");

        // Deploy the implementations
        hybridDeleGatorImpl = new HybridDeleGator(delegationManager, entryPoint);
        vm.label(address(hybridDeleGatorImpl), "Hybrid DeleGator");

        multiSigDeleGatorImpl = new MultiSigDeleGator(delegationManager, entryPoint);
        vm.label(address(multiSigDeleGatorImpl), "MultiSig DeleGator");

        eip7702StatelessDeleGatorImpl = new EIP7702StatelessDeleGator(delegationManager, entryPoint);
        vm.label(address(eip7702StatelessDeleGatorImpl), "EIP7702Stateless DeleGator");

        // Create users
        users = _createUsers();

        // Create the bundler
        bundler = payable(makeAddr("Bundler"));
        vm.deal(bundler, 100 ether);
    }

    ////////////////////////////// Public //////////////////////////////

    function signHash(TestUser memory _user, bytes32 _hash) public view returns (bytes memory) {
        return signHash(SIGNATURE_TYPE, _user, _hash);
    }

    function signHash(SignatureType _signatureType, TestUser memory _user, bytes32 _hash) public pure returns (bytes memory) {
        if (_signatureType == SignatureType.EOA) {
            return SigningUtilsLib.signHash_EOA(_user.privateKey, _hash);
        } else if (_signatureType == SignatureType.MultiSig) {
            uint256[] memory privateKeys_ = new uint256[](1);
            privateKeys_[0] = _user.privateKey;
            return SigningUtilsLib.signHash_MultiSig(privateKeys_, _hash);
        } else if (_signatureType == SignatureType.RawP256) {
            return SigningUtilsLib.signHash_P256(_user.name, _user.privateKey, _hash);
        } else {
            revert("Invalid Signature Type");
        }
    }

    /// @notice Uses the private key to sign a delegation.
    /// @dev NOTE: Assumes MultiSigDeleGator has a single signer with a threshold of 1.
    function signDelegation(
        TestUser memory _user,
        Delegation memory _delegation
    )
        public
        view
        returns (Delegation memory delegation_)
    {
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(_delegation);
        bytes32 domainHash_ = delegationManager.getDomainHash();
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(domainHash_, delegationHash_);
        delegation_ = Delegation({
            delegate: _delegation.delegate,
            delegator: _delegation.delegator,
            authority: _delegation.authority,
            caveats: _delegation.caveats,
            salt: _delegation.salt,
            signature: signHash(_user, typedDataHash_)
        });
    }

    /// @notice Creates an unsigned UserOperation with the nonce prefilled.
    function createUserOp(
        address _sender,
        bytes memory _callData,
        bytes memory _initCode,
        bytes32 _accountGasLimits,
        uint256 _preVerificationGas,
        bytes32 _gasFees,
        bytes memory _paymasterAndData,
        bytes memory _signature,
        address _entryPoint
    )
        public
        returns (PackedUserOperation memory userOperation_)
    {
        vm.txGasPrice(2);

        return PackedUserOperation({
            sender: _sender,
            nonce: senderNonce[_entryPoint][_sender]++,
            initCode: _initCode,
            callData: _callData,
            accountGasLimits: _accountGasLimits,
            preVerificationGas: _preVerificationGas,
            gasFees: _gasFees,
            paymasterAndData: _paymasterAndData,
            signature: _signature
        });
    }

    /// @notice Creates an unsigned UserOperation with the nonce prefilled.
    function createUserOp(
        address _sender,
        bytes memory _callData,
        bytes memory _initCode,
        bytes32 _accountGasLimits,
        uint256 _preVerificationGas,
        bytes32 _gasFees,
        bytes memory _paymasterAndData,
        bytes memory _signature
    )
        public
        returns (PackedUserOperation memory userOperation_)
    {
        return createUserOp(
            _sender,
            _callData,
            _initCode,
            _accountGasLimits,
            _preVerificationGas,
            _gasFees,
            _paymasterAndData,
            _signature,
            address(entryPoint)
        );
    }

    /// @notice Creates an unsigned UserOperation with paymaster with default values.
    function createUserOp(
        address _sender,
        bytes memory _callData
    )
        public
        returns (PackedUserOperation memory PackedUserOperation_)
    {
        return createUserOp(_sender, _callData, hex"", hex"");
    }

    /// @notice Creates an unsigned UserOperation with paymaster with default values.
    function createUserOp(
        address _sender,
        bytes memory _callData,
        address _entryPoint
    )
        public
        returns (PackedUserOperation memory PackedUserOperation_)
    {
        return createUserOp(_sender, _callData, hex"", hex"", _entryPoint);
    }

    /// @notice Creates an unsigned UserOperation with paymaster with default values.
    function createUserOp(
        address _sender,
        bytes memory _callData,
        bytes memory _initCode
    )
        public
        returns (PackedUserOperation memory userOperation_)
    {
        return createUserOp(_sender, _callData, _initCode, hex"");
    }

    /// @notice Creates an unsigned UserOperation with paymaster with default values.
    function createUserOp(
        address _sender,
        bytes memory _callData,
        bytes memory _initCode,
        bytes memory _paymasterAndData,
        address _entryPoint
    )
        public
        returns (PackedUserOperation memory userOperation_)
    {
        uint128 verificationGasLimit_ = 30000000;
        uint128 callGasLimit_ = 30000000;
        bytes32 accountGasLimits_ = bytes32(abi.encodePacked(verificationGasLimit_, callGasLimit_));

        // maxPriorityFeePerGas = 1, maxFeePerGas_ = 1;
        bytes32 gasFees_ = bytes32(abi.encodePacked(uint128(1), uint128(1)));

        return createUserOp(
            _sender, _callData, _initCode, accountGasLimits_, 30000000, gasFees_, _paymasterAndData, hex"", _entryPoint
        );
    }

    /// @notice Creates an unsigned UserOperation with paymaster with default values.
    function createUserOp(
        address _sender,
        bytes memory _callData,
        bytes memory _initCode,
        bytes memory _paymasterAndData
    )
        public
        returns (PackedUserOperation memory userOperation_)
    {
        return createUserOp(_sender, _callData, _initCode, _paymasterAndData, address(entryPoint));
    }

    // NOTE: This is a big assumption about how signatures for DeleGators are made. The hash to sign could come in many forms
    // depending on the implementation.
    function getPackedUserOperationTypedDataHash(PackedUserOperation memory _userOp) public view returns (bytes32) {
        return DeleGatorCore(payable(_userOp.sender)).getPackedUserOperationTypedDataHash(_userOp);
    }

    // NOTE: This method assumes the signature is an EIP712 signature of the UserOperation with a domain provided by the Signer. It
    // expects the hash to be signed to be returned by the method `getPackedUserOperationTypedDataHash`.
    function signUserOp(
        TestUser memory _user,
        PackedUserOperation memory _userOp
    )
        public
        view
        returns (PackedUserOperation memory)
    {
        _userOp.signature = signHash(_user, getPackedUserOperationTypedDataHash(_userOp));
        return _userOp;
    }

    function createAndSignUserOp(
        TestUser memory _user,
        address _sender,
        bytes memory _callData,
        bytes memory _initCode
    )
        public
        returns (PackedUserOperation memory userOperation_)
    {
        userOperation_ = createUserOp(_sender, _callData, _initCode);
        userOperation_ = signUserOp(_user, userOperation_);
    }

    function createAndSignUserOp(
        TestUser memory _user,
        address _sender,
        bytes memory _callData,
        bytes memory _initCode,
        bytes memory _paymasterAndData
    )
        public
        returns (PackedUserOperation memory userOperation_)
    {
        userOperation_ = createUserOp(_sender, _callData, _initCode, _paymasterAndData);
        userOperation_ = signUserOp(_user, userOperation_);
    }

    function createAndSignUserOp(
        TestUser memory _user,
        address _sender,
        bytes memory _callData
    )
        public
        returns (PackedUserOperation memory userOperation_)
    {
        userOperation_ = createAndSignUserOp(_user, _sender, _callData, hex"");
    }

    function execute_UserOp(TestUser memory _user, Execution memory _execution) public {
        execute_UserOp(_user, _execution, hex"", false);
    }

    function execute_UserOp(TestUser memory _user, Execution memory _execution, bool _shouldFail) public {
        execute_UserOp(_user, _execution, hex"", _shouldFail);
    }

    function execute_UserOp(
        TestUser memory _user,
        Execution memory _execution,
        bytes memory _paymasterAndData,
        bool _shouldFail
    )
        public
    {
        bytes memory userOpCallData_ = abi.encodeWithSignature(
            EXECUTE_SIGNATURE,
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(_execution.target, _execution.value, _execution.callData)
        );
        PackedUserOperation memory userOp_ = createUserOp(address(_user.deleGator), userOpCallData_, hex"", _paymasterAndData);
        userOp_.signature = signHash(_user, getPackedUserOperationTypedDataHash(userOp_));
        submitUserOp_Bundler(userOp_, _shouldFail);
    }

    /**
     * @dev Executes the calldata on self.
     */
    function execute_UserOp(TestUser memory _user, bytes memory _callData) public {
        Execution memory execution_ = Execution({ target: address(_user.deleGator), value: 0, callData: _callData });
        execute_UserOp(_user, execution_);
    }

    function executeBatch_UserOp(TestUser memory _user, Execution[] memory _executions) public {
        bytes memory userOpCallData_ =
            abi.encodeWithSignature(EXECUTE_SIGNATURE, ModeLib.encodeSimpleBatch(), abi.encode(_executions));
        PackedUserOperation memory userOp_ = createUserOp(address(_user.deleGator), userOpCallData_);
        userOp_.signature = signHash(_user, getPackedUserOperationTypedDataHash(userOp_));
        submitUserOp_Bundler(userOp_, false);
    }

    function invokeDelegation_UserOp(TestUser memory _user, Delegation[] memory _delegations, Execution memory _execution) public {
        return invokeDelegation_UserOp(_user, _delegations, _execution, hex"");
    }

    function invokeDelegation_UserOp(
        TestUser memory _user,
        Delegation[] memory _delegations,
        Execution memory _execution,
        bytes memory _initCode
    )
        public
    {
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(_execution.target, _execution.value, _execution.callData);

        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleSingle();

        bytes memory userOpCallData_ =
            abi.encodeWithSelector(DeleGatorCore.redeemDelegations.selector, permissionContexts_, modes_, executionCallDatas_);
        PackedUserOperation memory userOp_ = createUserOp(address(_user.deleGator), userOpCallData_, _initCode);
        userOp_.signature = signHash(_user, getPackedUserOperationTypedDataHash(userOp_));
        submitUserOp_Bundler(userOp_, false);
    }

    function submitUserOp_Bundler(PackedUserOperation memory _userOp) public {
        submitUserOp_Bundler(_userOp, false);
    }

    function submitUserOp_Bundler(PackedUserOperation memory _userOp, bool _shouldFail) public {
        PackedUserOperation[] memory userOps_ = new PackedUserOperation[](1);
        userOps_[0] = _userOp;
        vm.prank(bundler);
        if (_shouldFail) vm.expectRevert();
        entryPoint.handleOps(userOps_, payable(bundler));
    }

    function deployDeleGator(TestUser memory _user) public returns (address) {
        return deployDeleGator(IMPLEMENTATION, _user);
    }

    function deployDeleGator(Implementation _implementation, TestUser memory _user) public returns (address) {
        if (_implementation == Implementation.Hybrid) {
            return deployDeleGator_Hybrid(_user);
        } else if (_implementation == Implementation.MultiSig) {
            return deployDeleGator_MultiSig(_user);
        } else if (_implementation == Implementation.EIP7702Stateless) {
            return deployDeleGator_EIP7702Stateless(_user);
        } else {
            revert("Invalid Implementation");
        }
    }

    function deployDeleGator_MultiSig(TestUser memory _user) public returns (address) {
        address[] memory owners_ = new address[](1);
        owners_[0] = _user.addr;
        return deployDeleGator_MultiSig(owners_, 1);
    }

    function deployDeleGator_MultiSig(address[] memory _owners, uint256 _threshold) public returns (address) {
        return address(
            new ERC1967Proxy(
                address(multiSigDeleGatorImpl), abi.encodeWithSignature("initialize(address[],uint256)", _owners, _threshold)
            )
        );
    }

    function deployDeleGator_Hybrid(TestUser memory _user) public returns (address) {
        string[] memory keyIds_ = new string[](1);
        uint256[] memory xValues_ = new uint256[](1);
        uint256[] memory yValues_ = new uint256[](1);
        keyIds_[0] = _user.name;
        xValues_[0] = _user.x;
        yValues_[0] = _user.y;
        return deployDeleGator_Hybrid(_user.addr, keyIds_, xValues_, yValues_);
    }

    function deployDeleGator_Hybrid(
        address _owner,
        string[] memory _keyIds,
        uint256[] memory _xValues,
        uint256[] memory _yValues
    )
        public
        returns (address)
    {
        return address(
            new ERC1967Proxy(
                address(hybridDeleGatorImpl),
                abi.encodeWithSignature("initialize(address,string[],uint256[],uint256[])", _owner, _keyIds, _xValues, _yValues)
            )
        );
    }

    function deployDeleGator_EIP7702Stateless(TestUser memory _user) public returns (address) {
        return deployDeleGator_EIP7702Stateless(_user.addr);
    }

    function deployDeleGator_EIP7702Stateless(address _eoaAddress) public returns (address) {
        vm.etch(_eoaAddress, bytes.concat(hex"ef0100", abi.encodePacked(eip7702StatelessDeleGatorImpl)));
        return _eoaAddress;
    }

    // Name is the seed used to generate the address, private key, and DeleGator.
    function createUser(string memory _name) public returns (TestUser memory user_) {
        (address addr_, uint256 privateKey_) = makeAddrAndKey(_name);
        vm.deal(addr_, 100 ether);
        vm.label(addr_, _name);

        user_.name = _name;
        user_.addr = payable(addr_);
        user_.privateKey = privateKey_;
        (user_.x, user_.y) = FCL_ecdsa_utils.ecdsa_derivKpub(user_.privateKey);
        user_.deleGator = DeleGatorCore(payable(deployDeleGator(user_)));

        vm.deal(address(user_.deleGator), 100 ether);
        vm.label(address(user_.deleGator), string.concat(_name, " DeleGator"));
    }

    ////////////////////////////// Internal //////////////////////////////

    function _createUsers() internal returns (TestUsers memory users_) {
        users_.alice = createUser("Alice");
        users_.bob = createUser("Bob");
        users_.carol = createUser("Carol");
        users_.dave = createUser("Dave");
        users_.eve = createUser("Eve");
        users_.frank = createUser("Frank");
    }
}
