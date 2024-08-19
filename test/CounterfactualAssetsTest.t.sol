// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { BaseTest } from "./utils/BaseTest.t.sol";
import { Delegation, Caveat, Execution } from "../src/utils/Types.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { BasicCF721 } from "./utils/BasicCF721.t.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { DeployedEnforcer } from "../src/enforcers/DeployedEnforcer.sol";
import { AllowedTargetsEnforcer } from "../src/enforcers/AllowedTargetsEnforcer.sol";
import { AllowedMethodsEnforcer } from "../src/enforcers/AllowedMethodsEnforcer.sol";

contract CounterfactualAssetsTest is BaseTest {
    constructor() {
        IMPLEMENTATION = Implementation.MultiSig;
        SIGNATURE_TYPE = SignatureType.MultiSig;
    }

    ////////////////////////////// State ///////////////////////////////
    DeployedEnforcer public deployedEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    address public basicCf721;
    bytes public basicCf721Args;
    bytes public basicCf721Bytecode;
    bytes32 public basicCf721BytecodeHash;
    bytes32 public basicCf721Salt;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        basicCf721Args = abi.encode(address(users.alice.deleGator), "MyCF721", "CF721", "ipfs://");
        basicCf721Salt = keccak256(abi.encode("salt"));
        deployedEnforcer = new DeployedEnforcer();
        vm.label(address(deployedEnforcer), "Deployed Enforcer");
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        vm.label(address(allowedTargetsEnforcer), "Allowed Targets Enforcer");
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        vm.label(address(allowedMethodsEnforcer), "Allowed Methods Enforcer");
    }

    // should allow Alice to create NFT specifics and give delegations
    function test_allow_createNftAndDelegate_offchain() public {
        // Alice creates the NFT details, Name, Symbol, BaseURI and gets the deterministic address
        // The Alice then uses the deterministic address of her CF721 NFT contract to create delegations to mint
        // The delegation will have the DeployedEnforcer caveat to make sure the CF721 contract is deployed

        // Calculate data needed for deploy Caveat terms
        bytes32 bytecodeHash_ = hashInitCode(type(BasicCF721).creationCode, basicCf721Args);
        address predictedAddr_ = vm.computeCreate2Address(basicCf721Salt, bytecodeHash_, address(deployedEnforcer));
        address factoryPredictedAddr_ = deployedEnforcer.computeAddress(bytecodeHash_, basicCf721Salt);
        assertEq(factoryPredictedAddr_, predictedAddr_);

        // Get initial state
        bytes memory initialCode_ = predictedAddr_.code;
        assertEq(initialCode_, bytes(""));

        // Create deploy terms and Caveat for deploying BasicCF721
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            args: hex"",
            enforcer: address(deployedEnforcer),
            terms: abi.encodePacked(
                predictedAddr_,
                basicCf721Salt,
                abi.encodePacked(
                    type(BasicCF721).creationCode, abi.encode(address(users.alice.deleGator), "MyCF721", "CF721", "ipfs://")
                )
            )
        });

        // Create Delegation to deploy BasicCF721
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        // Alice signs Delegation to deploy BasicCF721
        delegation_ = signDelegation(users.alice, delegation_);

        // Create Bob's execution_ to mint an NFT
        Execution memory execution_ = Execution({
            target: predictedAddr_,
            value: 0,
            callData: abi.encodeWithSelector(BasicCF721.mint.selector, [address(users.bob.deleGator)])
        });

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Get final state
        bytes memory finalCode_ = predictedAddr_.code;
        // Assert that the CF721 contract is deployed correctly
        assertEq(finalCode_, type(BasicCF721).runtimeCode);
        // Assert that an NFT was minted
        assertEq(BasicCF721(predictedAddr_).balanceOf(address(users.bob.deleGator)), 1);
        assertEq(BasicCF721(predictedAddr_).ownerOf(0), address(users.bob.deleGator));
    }

    // should allow Alice to create NFT specifics and give delegations with strict caveats
    // NOTE: This is really just testing Caveats
    function test_allow_createNftAndDelegateWithCaveats_offchain() public {
        // Alice creates the NFT details, Name, Symbol, BaseURI and gets the deterministic address
        // Alice then uses the deterministic address of her CF721 NFT contract to create delegations to mint
        // The first delegation will have the DeployedEnforcer caveat to make sure the CF721 contract is deployed
        // It will also have a AllowedTargetEnforcer and AllowedMethodsEnforcer to make sure the mint function is called

        // Calculate data needed for deploy Caveat terms
        bytes32 bytecodeHash_ = hashInitCode(type(BasicCF721).creationCode, basicCf721Args);
        address predictedAddr_ = vm.computeCreate2Address(basicCf721Salt, bytecodeHash_, address(deployedEnforcer));

        // Get initial state
        bytes memory initialCode_ = predictedAddr_.code;
        assertEq(initialCode_, bytes(""));

        // Create deploy terms and Caveat for deploying BasicCF721
        Caveat[] memory caveats_ = new Caveat[](3);
        // DeployedEnforcer
        caveats_[0] = Caveat({
            args: hex"",
            enforcer: address(deployedEnforcer),
            terms: abi.encodePacked(
                predictedAddr_,
                basicCf721Salt,
                abi.encodePacked(
                    type(BasicCF721).creationCode, abi.encode(address(users.alice.deleGator), "MyCF721", "CF721", "ipfs://")
                )
            )
        });
        // AllowedTargetEnforcer
        caveats_[1] = Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(predictedAddr_) });
        // AllowedMethodsEnforcer
        caveats_[2] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(BasicCF721.mint.selector) });

        // Create Delegation to deploy BasicCF721
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        // Alice signs Delegation to deploy BasicCF721
        delegation_ = signDelegation(users.alice, delegation_);

        // Create Bob's execution_ to mint an NFT
        Execution memory execution_ = Execution({
            target: predictedAddr_,
            value: 0,
            callData: abi.encodeWithSelector(BasicCF721.mint.selector, [address(users.bob.deleGator)])
        });

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Get final state
        bytes memory finalCode_ = predictedAddr_.code;
        // Assert that the CF721 contract is deployed correctly
        assertEq(finalCode_, type(BasicCF721).runtimeCode);
        // Assert that an NFT was minted
        assertEq(BasicCF721(predictedAddr_).balanceOf(address(users.bob.deleGator)), 1);
        assertEq(BasicCF721(predictedAddr_).ownerOf(0), address(users.bob.deleGator));
    }

    // should allow Alice to create NFT specifics and give delegations with strict caveats and allow user to redelegate
    // NOTE: This is really just testing Caveats and redelegation
    function test_allow_createNftAndDelegateWithCaveatsAndRedelegate_offchain() public {
        // Alice creates the NFT details, Name, Symbol, BaseURI and gets the deterministic address
        // Alice then uses the deterministic address of her CF721 NFT contract to create delegations to mint
        // The first delegation will have the DeployedEnforcer caveat to make sure the CF721 contract is deployed
        // It will also have a AllowedTargetEnforcer and AllowedMethodsEnforcer to make sure the mint function is called
        // Bob then redelegates all of the permissions to Carol

        // Calculate data needed for deploy Caveat terms
        bytes32 bytecodeHash_ = hashInitCode(type(BasicCF721).creationCode, basicCf721Args);
        address predictedAddr_ = vm.computeCreate2Address(basicCf721Salt, bytecodeHash_, address(deployedEnforcer));

        // Get initial state
        bytes memory initialCode_ = predictedAddr_.code;
        assertEq(initialCode_, bytes(""));

        // Create deploy terms and Caveat for deploying BasicCF721
        Caveat[] memory caveats_ = new Caveat[](3);
        // DeployedEnforcer
        caveats_[0] = Caveat({
            args: hex"",
            enforcer: address(deployedEnforcer),
            terms: abi.encodePacked(
                predictedAddr_,
                basicCf721Salt,
                abi.encodePacked(
                    type(BasicCF721).creationCode, abi.encode(address(users.alice.deleGator), "MyCF721", "CF721", "ipfs://")
                )
            )
        });
        // AllowedTargetEnforcer
        caveats_[1] = Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(predictedAddr_) });
        // AllowedMethodsEnforcer
        caveats_[2] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(BasicCF721.mint.selector) });

        // Create Alice's Delegation to Bob to deploy BasicCF721 and mint
        Delegation memory aliceDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        // Alice signs Delegation to Bob
        Delegation memory aliceDelegation_ = signDelegation(users.alice, aliceDelegation);

        // Create Bob's Delegation to Carol
        Delegation memory bobDelegation_ = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(aliceDelegation),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Bob signs Delegation to Carol
        bobDelegation_ = signDelegation(users.bob, bobDelegation_);

        // Create Carols's execution_ to mint an NFT
        Execution memory execution_ = Execution({
            target: predictedAddr_,
            value: 0,
            callData: abi.encodeWithSelector(BasicCF721.mint.selector, [address(users.carol.deleGator)])
        });

        // Execute Carol's UserOp
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = bobDelegation_;
        delegations_[1] = aliceDelegation_;
        invokeDelegation_UserOp(users.carol, delegations_, execution_);

        // Get final state
        bytes memory finalCode_ = predictedAddr_.code;
        // Assert that the CF721 contract is deployed correctly
        assertEq(finalCode_, type(BasicCF721).runtimeCode);
        // Assert that an NFT was minted
        assertEq(BasicCF721(predictedAddr_).balanceOf(address(users.carol.deleGator)), 1);
        assertEq(BasicCF721(predictedAddr_).ownerOf(0), address(users.carol.deleGator));
    }
}
