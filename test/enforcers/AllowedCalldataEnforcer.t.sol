// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { BytesLib } from "@bytes-utils/BytesLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Counter } from "../utils/Counter.t.sol";
import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { AllowedCalldataEnforcer } from "../../src/enforcers/AllowedCalldataEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";
import { BasicCF721 } from "../utils/BasicCF721.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract DummyContract {
    function stringFn(uint256[] calldata _str) public { }
    function arrayFn(string calldata _str) public { }
}

contract AllowedCalldataEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    AllowedCalldataEnforcer public allowedCalldataEnforcer;
    BasicERC20 public basicCF20;
    BasicCF721 public basicCF721;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        allowedCalldataEnforcer = new AllowedCalldataEnforcer();
        vm.label(address(allowedCalldataEnforcer), "Equal Parameters Enforcer");
        basicCF20 = new BasicERC20(address(users.alice.deleGator), "TestToken1", "TestToken1", 100 ether);
        basicCF721 = new BasicCF721(address(users.alice.deleGator), "TestNFT", "TestNFT", "");
    }

    ////////////////////// Valid cases //////////////////////

    // should allow a single method to be called when a single function parameter is equal
    function test_singleMethodCanBeCalledWithEqualParam() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(100))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // beforeHook, mimicking the behavior of Alice's DeleGator
        uint256 paramStart_ = abi.encodeWithSelector(BasicERC20.mint.selector, address(0)).length;
        uint256 paramValue_ = 100;
        bytes memory inputTerms_ = abi.encodePacked(paramStart_, paramValue_);

        vm.prank(address(delegationManager));
        allowedCalldataEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should allow a method to be called when a single function parameter that is a dynamic array
    function test_singleMethodCanBeCalledWithEqualDynamicArrayParam() public {
        uint256[] memory param = new uint256[](2);
        param[0] = 1;
        param[1] = 2;

        // Create the execution that would be executed
        Execution memory execution_ =
            Execution({ target: address(0), value: 0, callData: abi.encodeWithSelector(DummyContract.arrayFn.selector, param) });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // The subset of the calldata that includes the index of the calldata where the dynamic array starts
        bytes memory offsetTerms_ = abi.encodePacked(uint256(4), uint256(32));
        // The subset of the calldata that includes the number of elements in the array
        bytes memory lengthTerms_ = abi.encodePacked(uint256(36), uint256(2));
        // The subset of the calldata that includes data in the array
        bytes memory parameterTerms_ = abi.encodePacked(uint256(68), BytesLib.slice(execution_.callData, uint256(68), uint256(64)));

        vm.prank(address(delegationManager));
        allowedCalldataEnforcer.beforeHook(
            offsetTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
        allowedCalldataEnforcer.beforeHook(
            lengthTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
        allowedCalldataEnforcer.beforeHook(
            parameterTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should allow a single method to be called when a single function parameter that is dynamic is equal
    function test_singleMethodCanBeCalledWithEqualDynamicStringParam() public {
        string memory param = "Test string";

        // Create the execution that would be executed
        Execution memory execution_ =
            Execution({ target: address(0), value: 0, callData: abi.encodeWithSelector(DummyContract.arrayFn.selector, param) });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // The offset of the string in the calldata
        bytes memory offsetTerms_ = abi.encodePacked(uint256(4), uint256(32));
        // The length of the string
        bytes memory lengthTerms_ = abi.encodePacked(uint256(36), uint256(11));
        // The string itself
        bytes memory parameterTerms_ = abi.encodePacked(uint256(68), BytesLib.slice(execution_.callData, uint256(68), uint256(32)));

        vm.prank(address(delegationManager));
        allowedCalldataEnforcer.beforeHook(
            offsetTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
        allowedCalldataEnforcer.beforeHook(
            lengthTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
        allowedCalldataEnforcer.beforeHook(
            parameterTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should allow Artist to create NFT specific delegations with metadata caveat
    function test_methodCanBeCalledWithSpecificMetadata() public {
        string memory metadataUrl_ = "ipfs://bafybeigxsy55qgbdqw44y5yrs2jhhk2kdn7vbt6y4myvhcwdjak6cwj464/3762";

        // The Execution with the mint calldata that would be executed
        bytes memory encodedData_ =
            abi.encodeWithSelector(BasicCF721.mintWithMetadata.selector, address(users.bob.deleGator), metadataUrl_);
        Execution memory execution_ = Execution({ target: address(basicCF721), value: 0, callData: encodedData_ });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Calculate the start and length of the metadata bytes within the calldata
        bytes memory encodedMetadataString_ = abi.encode(metadataUrl_);
        bytes32 start_ = bytes32(abi.encodeWithSelector(BasicCF721.mintWithMetadata.selector, address(users.bob.deleGator)).length);
        bytes32 length_ = bytes32(encodedMetadataString_.length);

        vm.prank(address(delegationManager));
        // NOTE: Using encodedData_ not  encodedMetadataString_ to ensure the value for the offset is correct
        bytes memory allowedCalldata_ = abi.encodePacked(start_, BytesLib.slice(encodedData_, uint256(start_), uint256(length_)));
        allowedCalldataEnforcer.beforeHook(
            allowedCalldata_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    // should NOT allow a method to be called when a single function parameter is not equal
    function test_singleMethodCanNotCalledWithNonEqualParam() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(200))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // beforeHook, mimicking the behavior of Alice's DeleGator
        uint256 paramStart_ = abi.encodeWithSelector(BasicERC20.mint.selector, address(0)).length;
        uint256 paramValue_ = 100;
        bytes memory inputTerms_ = abi.encodePacked(paramStart_, paramValue_);

        vm.prank(address(delegationManager));
        vm.expectRevert("AllowedCalldataEnforcer:invalid-calldata");
        allowedCalldataEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should NOT allow to pass an invalid calldata length (invalid terms)
    function test_failsWithInvalidTermsLength() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(200))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // beforeHook, mimicking the behavior of Alice's DeleGator
        uint256 paramStart_ = abi.encodeWithSelector(BasicERC20.mint.selector, address(0)).length;
        uint256[3] memory paramValue_ = [uint256(100), 100, 100];
        bytes memory inputTerms_ = abi.encodePacked(paramStart_, paramValue_);

        vm.prank(address(delegationManager));
        vm.expectRevert("AllowedCalldataEnforcer:invalid-calldata-length");
        allowedCalldataEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should NOT allow a method to be called when a terms size is invalid
    function test_singleMethodCanNotCalledWithInvalidTermsSize() public {
        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(200))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // beforeHook, mimicking the behavior of Alice's DeleGator
        uint256 paramStart_ = abi.encodeWithSelector(BasicERC20.mint.selector, address(0)).length;
        bytes memory inputTerms_ = abi.encodePacked(paramStart_);

        vm.prank(address(delegationManager));
        vm.expectRevert("AllowedCalldataEnforcer:invalid-terms-size");
        allowedCalldataEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should fail with invalid call type mode (batch instead of single mode)
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));

        vm.expectRevert("CaveatEnforcer:invalid-call-type");

        allowedCalldataEnforcer.beforeHook(hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        allowedCalldataEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// Integration //////////////////////

    // should allow a single method to be called when a single function parameter is equal Integration
    function test_singleMethodCanBeCalledWithEqualParamIntegration() public {
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), 0);

        // Create the execution that would be executed on Alice for transferring a ft tokens
        Execution memory execution1_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(1))
        });

        // create terms for the enforcer
        uint256 paramStart_ = abi.encodeWithSelector(IERC20.transfer.selector, address(0)).length;
        uint256 paramValue_ = 1;
        bytes memory inputTerms_ = abi.encodePacked(paramStart_, paramValue_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(allowedCalldataEnforcer), terms: inputTerms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Enforcer allows the delegation
        invokeDelegation_UserOp(users.bob, delegations_, execution1_);

        // Validate that the balance have increased
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), uint256(1));

        // Enforcer allows to reuse the delegation
        invokeDelegation_UserOp(users.bob, delegations_, execution1_);

        // Validate that the balance has increased again
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), uint256(2));
    }

    // should NOT allow a single method to be called when a single function parameter is not equal Integration
    function test_singleMethodCanNotBeCalledWithNonEqualParamIntegration() public {
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), 0);

        // Create the execution that would be executed on Alice for transferring a ft tokens
        Execution memory execution1_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(2))
        });

        // create terms for the enforcer
        uint256 paramStart_ = abi.encodeWithSelector(IERC20.transfer.selector, address(0)).length;
        uint256 paramValue_ = 1;
        bytes memory inputTerms_ = abi.encodePacked(paramStart_, paramValue_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(allowedCalldataEnforcer), terms: inputTerms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Enforcer allows the delegation
        invokeDelegation_UserOp(users.bob, delegations_, execution1_);

        // Validate that the balance have not increased
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), uint256(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(allowedCalldataEnforcer));
    }
}
