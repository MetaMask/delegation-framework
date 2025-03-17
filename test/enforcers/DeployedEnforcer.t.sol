// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { DeployedEnforcer } from "../../src/enforcers/DeployedEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract DeployedEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////

    DeployedEnforcer public deployedEnforcer;
    bytes32 public salt;

    ////////////////////////////// Events //////////////////////////////

    event DeployedContract(address contractAddress);
    event Deployed(address indexed addr);

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        deployedEnforcer = new DeployedEnforcer();
        vm.label(address(deployedEnforcer), "Deployed Enforcer");
        salt = keccak256(abi.encode("salt"));
    }

    ////////////////////// Valid cases //////////////////////

    // should accurately compute the predicted create2 address
    function test_computesAPredictedAddress() public {
        bytes32 bytecodeHash_ = hashInitCode(type(Counter).creationCode);
        address predictedAddr_ = vm.computeCreate2Address(salt, bytecodeHash_, address(deployedEnforcer));
        address factoryPredictedAddr_ = deployedEnforcer.computeAddress(bytecodeHash_, salt);
        assertEq(factoryPredictedAddr_, predictedAddr_);
    }

    // should deploy if the contract hasn't been deployed yet and terms are properly formatted
    function test_deploysIfNonExistent() public {
        // Compute predicted address
        bytes32 bytecodeHash_ = hashInitCode(type(Counter).creationCode);
        address predictedAddr_ = vm.computeCreate2Address(salt, bytecodeHash_, address(deployedEnforcer));

        // NOTE: Execution isn't very relevant for this test.
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Check that the contract hasn't been deployed yet
        bytes memory initialCode_ = predictedAddr_.code;
        assertEq(initialCode_, bytes(""));

        // beforeHook, mimicking the behavior of Alice's DeleGator
        vm.prank(address(delegationManager));

        // should emit an event when contract is deployed in the factory
        vm.expectEmit(true, true, true, true, address(deployedEnforcer));
        emit DeployedContract(predictedAddr_);
        deployedEnforcer.beforeHook(
            abi.encodePacked(predictedAddr_, salt, abi.encodePacked(type(Counter).creationCode)),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // Check that the contract has been deployed properly
        bytes memory finalCode_ = predictedAddr_.code;
        assertEq(finalCode_, type(Counter).runtimeCode);
    }

    // should NOT deploy if the contract already has been deployed
    function test_doesNotDeployIfExistent() public {
        // Compute predicted address
        bytes memory bytecode_ = type(Counter).creationCode;
        bytes32 bytecodeHash_ = hashInitCode(bytecode_);
        address predictedAddr_ = vm.computeCreate2Address(salt, bytecodeHash_, address(deployedEnforcer));

        // NOTE: Execution isn't very relevant for this test.
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Deploy the contract
        vm.prank(address(delegationManager));
        deployedEnforcer.beforeHook(
            abi.encodePacked(predictedAddr_, salt, bytecode_),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );

        // beforeHook, mimicking the behavior of Alice's DeleGator
        vm.prank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(deployedEnforcer));
        emit DeployedEnforcer.SkippedDeployment(predictedAddr_);

        // Use enforcer when contract is already deployed
        deployedEnforcer.beforeHook(
            abi.encodePacked(predictedAddr_, salt, bytecode_),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    // should revert if the predicted address doesn't match the deployed address
    function test_revertIfPredictedAddressDoesNotMatch() public {
        // NOTE: Execution isn't very relevant for this test.
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // beforeHook, mimicking the behavior of Alice's DeleGator
        vm.prank(address(delegationManager));
        vm.expectRevert("DeployedEnforcer:deployed-address-mismatch");
        deployedEnforcer.beforeHook(
            abi.encodePacked(users.alice.addr, salt, abi.encodePacked(type(Counter).creationCode)),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    // should revert if the length of the terms is not sufficient
    function test_revertIfTermsLengthIsInvalid() public {
        // NOTE: Execution isn't very relevant for this test.
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.startPrank(address(delegationManager));

        // 0 bytes
        vm.expectRevert("DeployedEnforcer:invalid-terms-length");
        deployedEnforcer.beforeHook(hex"", hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0));

        // 20 bytes
        vm.expectRevert("DeployedEnforcer:invalid-terms-length");
        deployedEnforcer.beforeHook(
            abi.encodePacked(users.alice.addr), hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );

        // 52 bytes
        vm.expectRevert("DeployedEnforcer:invalid-terms-length");
        deployedEnforcer.beforeHook(
            abi.encodePacked(users.alice.addr, bytes32(hex"")),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    // should revert if deployed contract is empty
    function test_revertIfContractIsEmpty() public {
        // This is the bytecode for an empty contract
        bytes memory bytecode_ = hex"60006000";

        bytes32 bytecodeHash_ = hashInitCode(bytecode_);
        address predictedAddr_ = vm.computeCreate2Address(salt, bytecodeHash_, address(deployedEnforcer));

        // // NOTE: Execution isn't very relevant for this test.
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // beforeHook, mimicking the behavior of Alice's DeleGator
        vm.prank(address(delegationManager));
        vm.expectRevert(abi.encodeWithSelector(DeployedEnforcer.DeployedEmptyContract.selector, predictedAddr_));
        deployedEnforcer.beforeHook(
            abi.encodePacked(predictedAddr_, salt, bytecode_),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    // should fail if there is no contract deployed
    function test_revertsIfBytecodeDoesntExist() public {
        // NOTE: deployedEnforcer ensures that a contract gets deployed

        // Compute predicted address
        bytes32 bytecodeHash_ = hashInitCode(hex"");
        address predictedAddr_ = vm.computeCreate2Address(salt, bytecodeHash_, address(deployedEnforcer));

        // NOTE: Execution isn't very relevant for this test.
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        // Check that the contract hasn't been deployed yet
        bytes memory initialCode_ = predictedAddr_.code;
        assertEq(initialCode_, bytes(""));

        // beforeHook, mimicking the behavior of Alice's DeleGator
        vm.prank(address(delegationManager));
        vm.expectRevert();
        deployedEnforcer.beforeHook(
            abi.encodePacked(predictedAddr_, salt, abi.encodePacked(type(Counter).creationCode)),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        deployedEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// Integration //////////////////////

    // should deploy if the contract hasn't been deployed yet and terms are properly formatted, and allows to use it
    function test_deploysIfNonExistentAndAllowsToUseItIntegration() public {
        // Compute predicted address
        bytes32 bytecodeHash_ = hashInitCode(type(Counter).creationCode);
        address predictedAddr_ = vm.computeCreate2Address(salt, bytecodeHash_, address(deployedEnforcer));

        // NOTE: Execution isn't very relevant for this test.
        Execution memory execution_ =
            Execution({ target: predictedAddr_, value: 0, callData: abi.encodeWithSelector(Counter.setCount.selector, 1) });

        // Check that the contract hasn't been deployed yet
        bytes memory initialCode_ = predictedAddr_.code;
        assertEq(initialCode_, bytes(""));

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            args: hex"",
            enforcer: address(deployedEnforcer),
            terms: abi.encodePacked(predictedAddr_, salt, abi.encodePacked(type(Counter).creationCode))
        });
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation = signDelegation(users.alice, delegation);

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation;

        // Enforcer allows the delegation
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Check that the contract has been deployed properly
        bytes memory finalCode_ = predictedAddr_.code;
        assertEq(finalCode_, type(Counter).runtimeCode);

        assertEq(Counter(predictedAddr_).count(), 1);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(deployedEnforcer));
    }
}

contract Counter {
    uint256 public count = 0;

    function setCount(uint256 _newCount) public {
        count = _newCount;
    }

    function increment() public {
        count++;
    }
}
