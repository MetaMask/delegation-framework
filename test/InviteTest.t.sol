// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { BaseTest } from "./utils/BaseTest.t.sol";
import { Delegation, Execution, PackedUserOperation, Caveat, ModeCode } from "../src/utils/Types.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { Counter } from "./utils/Counter.t.sol";
import { MultiSigDeleGator } from "../src/MultiSigDeleGator.sol";
import { DeleGatorCore } from "../src/DeleGatorCore.sol";
import { SimpleFactory } from "../src/utils/SimpleFactory.sol";
import { AllowedTargetsEnforcer } from "../src/enforcers/AllowedTargetsEnforcer.sol";
import { AllowedMethodsEnforcer } from "../src/enforcers/AllowedMethodsEnforcer.sol";
import { EXECUTE_SINGULAR_SIGNATURE } from "./utils/Constants.sol";
import { UserOperationLib } from "./utils/UserOperationLib.t.sol";

contract InviteTest is BaseTest {
    using MessageHashUtils for bytes32;

    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    ////////////////////////////// State ///////////////////////////////

    bytes32 public salt;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    Counter public aliceDeleGatorCounter;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        salt = keccak256(abi.encode("salt"));
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        vm.label(address(allowedTargetsEnforcer), "Allowed Targets Enforcer");
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        vm.label(address(allowedMethodsEnforcer), "Allowed Methods Enforcer");
        aliceDeleGatorCounter = new Counter(address(users.alice.deleGator));
    }

    ////////////////////////////// External Methods //////////////////////////////

    // should allow Bob to create a new MultiSigDeleGator and prepare a transaction prior to contract deployment
    function test_createADeleGatorForBobAndSend() public {
        // Get predicted address and bytecode for a new MultiSigDeleGator
        address[] memory signers_ = new address[](1);
        signers_[0] = users.bob.addr;

        bytes memory args_ =
            abi.encode(address(multiSigDeleGatorImpl), abi.encodeWithSignature("initialize(address[],uint256)", signers_, 1));
        bytes32 bytecodeHash_ = hashInitCode(type(ERC1967Proxy).creationCode, args_);
        address predictedAddr_ = vm.computeCreate2Address(salt, bytecodeHash_, address(simpleFactory));
        vm.label(predictedAddr_, "Expected Address");
        address factoryPredictedAddr_ = simpleFactory.computeAddress(bytecodeHash_, salt);
        assertEq(factoryPredictedAddr_, predictedAddr_);

        // Get initcode for a new MultiSigDeleGator
        bytes memory initcode_ = abi.encodePacked(
            address(simpleFactory),
            abi.encodeWithSelector(SimpleFactory.deploy.selector, abi.encodePacked(type(ERC1967Proxy).creationCode, args_), salt)
        );

        // Create execution to send ETH to Bob
        Execution memory execution_ = Execution({ target: address(users.bob.addr), value: 1, callData: hex"" });

        // Give the new MultiSigDeleGator some funds to pay for the execution
        vm.deal(predictedAddr_, 100);

        // Preload the EntryPoint with funds for the new MultiSigDeleGator
        vm.prank(users.alice.addr);
        entryPoint.depositTo{ value: 5 ether }(predictedAddr_);

        // Fetch balance before execution executes
        uint256 balanceBefore_ = users.bob.addr.balance;

        // Create and Sign UserOp with Bob's key
        PackedUserOperation memory userOp_ =
            createUserOp(predictedAddr_, abi.encodeWithSignature(EXECUTE_SINGULAR_SIGNATURE, execution_), initcode_);
        userOp_.signature = signHash(users.bob, getPackedUserOperationTypedDataHash(predictedAddr_, userOp_, address(entryPoint)));

        // Validate the contract hasn't been deployed yet
        assertEq(predictedAddr_.code, hex"");

        // Submit the UserOp through the Bundler
        submitUserOp_Bundler(userOp_);

        // Fetch balance after execution executes
        uint256 balanceAfter_ = users.bob.addr.balance;
        assertEq(balanceAfter_, balanceBefore_ + 1);

        // Check that the contract has been deployed properly
        // NOTE: "runtimeCode" is not available for contracts containing immutable variables.
        // Need to generate that code. OR cheat and see if it matches Bob's existing MultiSigDeleGator.
        // assertEq(predictedAddr_.code, address(users.users.bob.deleGator).code);
    }

    // should allow Bob to create a new MultiSigDeleGator and prepare a transaction that executes a delegation from Alice prior to
    // contract deployment
    function test_createADeleGatorForBobAndDelegate() public {
        // Get predicted address and bytecode for a new MultiSigDeleGator
        address[] memory signers_ = new address[](1);
        signers_[0] = users.bob.addr;
        bytes memory args_ =
            abi.encode(address(multiSigDeleGatorImpl), abi.encodeWithSignature("initialize(address[],uint256)", signers_, 1));
        bytes32 bytecodeHash_ = hashInitCode(type(ERC1967Proxy).creationCode, args_);
        address predictedAddr_ = vm.computeCreate2Address(salt, bytecodeHash_, address(simpleFactory));
        vm.label(predictedAddr_, "Expected Address");

        // Create initcode_
        bytes memory initcode_ = abi.encodePacked(
            address(simpleFactory),
            abi.encodeWithSelector(SimpleFactory.deploy.selector, abi.encodePacked(type(ERC1967Proxy).creationCode, args_), salt)
        );

        vm.label(predictedAddr_, "Expected Address");

        // Validate the contract hasn't been deployed yet
        assertEq(predictedAddr_.code, hex"");

        Delegation memory delegation_;
        {
            // Create Caveats for only calling increment
            Caveat[] memory caveats_ = new Caveat[](2);
            caveats_[0] = Caveat({
                args: hex"",
                enforcer: address(allowedTargetsEnforcer),
                terms: abi.encodePacked(address(aliceDeleGatorCounter))
            });
            caveats_[1] = Caveat({
                args: hex"",
                enforcer: address(allowedMethodsEnforcer),
                terms: abi.encodePacked(Counter.increment.selector)
            });

            // Create Alice's delegation to Bob
            delegation_ = Delegation({
                delegate: predictedAddr_,
                delegator: address(users.alice.deleGator),
                authority: ROOT_AUTHORITY,
                caveats: caveats_,
                salt: 0,
                signature: hex""
            });

            // Sign delegation
            delegation_ = signDelegation(users.alice, delegation_);
        }

        // Give the new MultiSigDeleGator some funds to pay for the execution
        vm.deal(predictedAddr_, 100);

        // Preload the EntryPoint with funds for the new MultiSigDeleGator
        vm.prank(users.alice.addr);
        entryPoint.depositTo{ value: 5 ether }(predictedAddr_);

        // Fetch initial count
        uint256[] memory counts_ = new uint256[](2);
        counts_[0] = aliceDeleGatorCounter.count();

        // Create execution to deploy a new MultiSigDeleGator and execute Bob's UserOp
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = singleDefaultMode;

        bytes memory userOpCallData_ =
            abi.encodeWithSelector(DeleGatorCore.redeemDelegations.selector, permissionContexts_, modes_, executionCallDatas_);

        PackedUserOperation memory userOp_ = createUserOp(predictedAddr_, userOpCallData_, initcode_);

        userOp_.signature = signHash(users.bob, getPackedUserOperationTypedDataHash(predictedAddr_, userOp_, address(entryPoint)));

        submitUserOp_Bundler(userOp_);

        // Fetch final count
        counts_[1] = aliceDeleGatorCounter.count();
        assertEq(counts_[1], counts_[0] + 1);

        // Check that the contract has been deployed properly
        // NOTE: "runtimeCode" is not available for contracts containing immutable variables.
        // Need to generate that code. OR cheat and see if it matches Bob's existing MultiSigDeleGator.
        // assertEq(predictedAddr_.code, address(users.users.bob.deleGator).code);
    }

    ////////////////////////////// Helper Methods //////////////////////////////

    function getPackedUserOperationTypedDataHash(
        address _contract,
        PackedUserOperation memory userOp_,
        address _entryPoint
    )
        internal
        view
        returns (bytes32)
    {
        return UserOperationLib.getPackedUserOperationTypedDataHash(
            multiSigDeleGatorImpl.NAME(), multiSigDeleGatorImpl.DOMAIN_VERSION(), block.chainid, _contract, userOp_, _entryPoint
        );
    }
}
