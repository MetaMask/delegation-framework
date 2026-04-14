// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { AllowedCalldataAnyOfEnforcer } from "../../src/enforcers/AllowedCalldataAnyOfEnforcer.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract AllowedCalldataAnyOfEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    AllowedCalldataAnyOfEnforcer public allowedCalldataAnyOfEnforcer;
    BasicERC20 public basicCF20;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        allowedCalldataAnyOfEnforcer = new AllowedCalldataAnyOfEnforcer();
        vm.label(address(allowedCalldataAnyOfEnforcer), "Allowed Calldata Any-Of Enforcer");
        basicCF20 = new BasicERC20(address(users.alice.deleGator), "TestToken1", "TestToken1", 100 ether);
    }

    function _packTerms(uint256 dataStart_, bytes[] memory values_) internal pure returns (bytes memory) {
        return bytes.concat(abi.encodePacked(dataStart_), abi.encode(values_));
    }

    ////////////////////// Valid cases //////////////////////

    // should allow when the calldata matches the first allowed slice at dataStart
    function test_allowsWhenFirstCandidateMatches() public {
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(100))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint256 paramStart_ = abi.encodeWithSelector(BasicERC20.mint.selector, address(0)).length;
        bytes[] memory values_ = new bytes[](2);
        values_[0] = abi.encodePacked(uint256(100));
        values_[1] = abi.encodePacked(uint256(200));
        bytes memory inputTerms_ = _packTerms(paramStart_, values_);

        vm.prank(address(delegationManager));
        allowedCalldataAnyOfEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should allow when the calldata matches a later candidate at dataStart
    function test_allowsWhenSecondCandidateMatches() public {
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(200))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint256 paramStart_ = abi.encodeWithSelector(BasicERC20.mint.selector, address(0)).length;
        bytes[] memory values_ = new bytes[](2);
        values_[0] = abi.encodePacked(uint256(100));
        values_[1] = abi.encodePacked(uint256(200));
        bytes memory inputTerms_ = _packTerms(paramStart_, values_);

        vm.prank(address(delegationManager));
        allowedCalldataAnyOfEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should allow when candidates have different lengths and the longer one matches
    function test_allowsWhenVariableLengthCandidateMatches() public {
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(0xabcd))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint256 paramStart_ = abi.encodeWithSelector(BasicERC20.mint.selector, address(0)).length;
        bytes[] memory values_ = new bytes[](2);
        values_[0] = hex"ab";
        values_[1] = abi.encodePacked(uint256(0xabcd));
        bytes memory inputTerms_ = _packTerms(paramStart_, values_);

        vm.prank(address(delegationManager));
        allowedCalldataAnyOfEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    // should NOT allow when no candidate matches at dataStart
    function test_revertsWhenNoCandidateMatches() public {
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(300))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint256 paramStart_ = abi.encodeWithSelector(BasicERC20.mint.selector, address(0)).length;
        bytes[] memory values_ = new bytes[](2);
        values_[0] = abi.encodePacked(uint256(100));
        values_[1] = abi.encodePacked(uint256(200));
        bytes memory inputTerms_ = _packTerms(paramStart_, values_);

        vm.prank(address(delegationManager));
        vm.expectRevert("AllowedCalldataAnyOfEnforcer:invalid-calldata");
        allowedCalldataAnyOfEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should NOT allow when calldata is too short for every candidate
    function test_revertsWhenCalldataTooShortForAllCandidates() public {
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(100))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint256 paramStart_ = abi.encodeWithSelector(BasicERC20.mint.selector, address(0)).length;
        bytes[] memory values_ = new bytes[](1);
        values_[0] = new bytes(execution_.callData.length - paramStart_ + 1);
        for (uint256 i = 0; i < values_[0].length; ++i) {
            values_[0][i] = 0xff;
        }
        bytes memory inputTerms_ = _packTerms(paramStart_, values_);

        vm.prank(address(delegationManager));
        vm.expectRevert("AllowedCalldataAnyOfEnforcer:invalid-calldata");
        allowedCalldataAnyOfEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should FAIL getTermsInfo when terms are shorter than 32 bytes
    function test_getTermsInfoFailsForShortTerms() public {
        vm.expectRevert("AllowedCalldataAnyOfEnforcer:invalid-terms-size");
        allowedCalldataAnyOfEnforcer.getTermsInfo(hex"010203");
    }

    // should FAIL getTermsInfo when the decoded array is empty
    function test_getTermsInfoFailsForEmptyCandidatesArray() public {
        bytes[] memory values_ = new bytes[](0);
        bytes memory terms_ = _packTerms(0, values_);
        vm.expectRevert("AllowedCalldataAnyOfEnforcer:no-allowed-values");
        allowedCalldataAnyOfEnforcer.getTermsInfo(terms_);
    }

    // should FAIL getTermsInfo when a candidate is zero-length
    function test_getTermsInfoFailsForZeroLengthCandidate() public {
        bytes[] memory values_ = new bytes[](2);
        values_[0] = hex"aa";
        values_[1] = hex"";
        bytes memory terms_ = _packTerms(4, values_);
        vm.expectRevert("AllowedCalldataAnyOfEnforcer:invalid-value-length");
        allowedCalldataAnyOfEnforcer.getTermsInfo(terms_);
    }

    // should fail with invalid call type mode (batch instead of single mode)
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));

        vm.expectRevert("CaveatEnforcer:invalid-call-type");

        allowedCalldataAnyOfEnforcer.beforeHook(
            hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0)
        );
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        allowedCalldataAnyOfEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// Integration //////////////////////

    // should allow execution when the amount matches one of the allowed encodings Integration
    function test_integrationAllowsMatchingAmount() public {
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), 0);

        Execution memory execution1_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(2))
        });

        uint256 paramStart_ = abi.encodeWithSelector(IERC20.transfer.selector, address(0)).length;
        bytes[] memory values_ = new bytes[](2);
        values_[0] = abi.encodePacked(uint256(1));
        values_[1] = abi.encodePacked(uint256(2));
        bytes memory inputTerms_ = _packTerms(paramStart_, values_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(allowedCalldataAnyOfEnforcer), terms: inputTerms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution1_);

        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), uint256(2));
    }

    // should NOT allow execution when the amount matches none of the allowed encodings Integration
    function test_integrationRejectsNonMatchingAmount() public {
        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), 0);

        Execution memory execution1_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(3))
        });

        uint256 paramStart_ = abi.encodeWithSelector(IERC20.transfer.selector, address(0)).length;
        bytes[] memory values_ = new bytes[](2);
        values_[0] = abi.encodePacked(uint256(1));
        values_[1] = abi.encodePacked(uint256(2));
        bytes memory inputTerms_ = _packTerms(paramStart_, values_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(allowedCalldataAnyOfEnforcer), terms: inputTerms_ });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution1_);

        assertEq(basicCF20.balanceOf(address(users.bob.deleGator)), uint256(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(allowedCalldataAnyOfEnforcer));
    }
}
