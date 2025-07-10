// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { OwnershipTransferEnforcer } from "../../src/enforcers/OwnershipTransferEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract OwnershipTransferEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    OwnershipTransferEnforcer public enforcer;
    address public mockContract;
    address delegator;
    address delegate;
    address dm;
    Execution transferOwnershipExecution;
    bytes transferOwnershipExecutionCallData;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        delegate = address(users.bob.deleGator);
        dm = address(delegationManager);
        enforcer = new OwnershipTransferEnforcer();
        vm.label(address(enforcer), "Ownership Transfer Enforcer");
        mockContract = address(0x1234);
        vm.label(mockContract, "Mock ERC173 Contract");
    }

    ////////////////////// Basic Functionality //////////////////////

    // Validates the terms get decoded correctly
    function test_decodedTheTerms() public {
        bytes memory terms_ = abi.encodePacked(mockContract);
        address decodedContract = enforcer.getTermsInfo(terms_);
        assertEq(decodedContract, mockContract);
    }

    // Validates that a valid ownership transfer is allowed
    function test_allow_validOwnershipTransfer() public {
        address newOwner = delegate;
        bytes memory terms_ = abi.encodePacked(mockContract);
        transferOwnershipExecution = Execution({
            target: mockContract,
            value: 0,
            callData: abi.encodeWithSelector(bytes4(keccak256("transferOwnership(address)")), newOwner)
        });
        transferOwnershipExecutionCallData = ExecutionLib.encodeSingle(
            transferOwnershipExecution.target, transferOwnershipExecution.value, transferOwnershipExecution.callData
        );

        vm.startPrank(dm);

        vm.expectEmit(true, true, true, true, address(enforcer));
        emit OwnershipTransferEnforcer.OwnershipTransferEnforced(dm, delegate, bytes32(0), newOwner);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, transferOwnershipExecutionCallData, bytes32(0), delegator, delegate);
    }

    ////////////////////// Errors //////////////////////

    // Reverts if the terms length is invalid
    function test_invalid_termsLength() public {
        bytes memory invalidTerms = abi.encodePacked(mockContract, uint256(1)); // Too long
        vm.expectRevert("OwnershipTransferEnforcer:invalid-terms-length");
        enforcer.getTermsInfo(invalidTerms);
    }

    // Reverts if the target contract doesn't match the terms
    function test_notAllow_invalidTargetContract() public {
        address newOwner = address(0x5678);
        bytes memory terms_ = abi.encodePacked(mockContract);
        transferOwnershipExecution = Execution({
            target: address(0x9999), // Different from mockContract
            value: 0,
            callData: abi.encodeWithSelector(bytes4(keccak256("transferOwnership(address)")), newOwner)
        });
        transferOwnershipExecutionCallData = ExecutionLib.encodeSingle(
            transferOwnershipExecution.target, transferOwnershipExecution.value, transferOwnershipExecution.callData
        );

        vm.prank(dm);
        vm.expectRevert("OwnershipTransferEnforcer:invalid-contract");
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, transferOwnershipExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if the method called is not transferOwnership
    function test_notAllow_invalidMethod() public {
        bytes memory terms_ = abi.encodePacked(mockContract);
        transferOwnershipExecution = Execution({
            target: mockContract,
            value: 0,
            callData: abi.encodeWithSelector(bytes4(keccak256("someOtherMethod(address)")), address(0))
        });
        transferOwnershipExecutionCallData = ExecutionLib.encodeSingle(
            transferOwnershipExecution.target, transferOwnershipExecution.value, transferOwnershipExecution.callData
        );

        vm.prank(dm);
        vm.expectRevert("OwnershipTransferEnforcer:invalid-method");
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, transferOwnershipExecutionCallData, bytes32(0), delegator, delegate);
    }

    // Reverts if the execution call data length is invalid
    function test_notAllow_invalidExecutionLength() public {
        bytes memory terms_ = abi.encodePacked(mockContract);
        transferOwnershipExecution = Execution({
            target: mockContract,
            value: 0,
            callData: abi.encodeWithSelector(bytes4(keccak256("transferOwnership(address)"))) // Missing the address parameter
         });
        transferOwnershipExecutionCallData = ExecutionLib.encodeSingle(
            transferOwnershipExecution.target, transferOwnershipExecution.value, transferOwnershipExecution.callData
        );

        vm.prank(dm);
        vm.expectRevert("OwnershipTransferEnforcer:invalid-execution-length");
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, transferOwnershipExecutionCallData, bytes32(0), delegator, delegate);
    }

    // should fail with invalid call type mode (batch instead of single mode)
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));

        vm.expectRevert("CaveatEnforcer:invalid-call-type");

        enforcer.beforeHook(hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
