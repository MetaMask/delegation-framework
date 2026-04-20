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

    /// @dev Header: `uint128 startIndex` (high) | `uint128 valueLength` (low), then `candidateCount * valueLength` bytes.
    function _packTerms(uint128 startIndex_, uint128 valueLength_, bytes memory concatenatedValues_) internal pure returns (bytes memory) {
        require(
            concatenatedValues_.length > 0 && concatenatedValues_.length % uint256(valueLength_) == 0,
            "test: bad concatenatedValues length"
        );
        uint256 metadataWord_ = (uint256(uint128(startIndex_)) << 128) | uint256(uint128(valueLength_));
        return bytes.concat(bytes32(metadataWord_), concatenatedValues_);
    }

    ////////////////////// Valid cases //////////////////////

    // should allow when the calldata matches the first allowed slice at startIndex
    function test_allowsWhenFirstCandidateMatches() public {
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(100))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 startIndex_ = uint128(abi.encodeWithSelector(BasicERC20.mint.selector, address(0)).length);
        uint128 valueLength_ = 32;
        bytes memory concatenatedValues_ = bytes.concat(abi.encodePacked(uint256(100)), abi.encodePacked(uint256(200)));
        bytes memory terms_ = _packTerms(startIndex_, valueLength_, concatenatedValues_);

        vm.prank(address(delegationManager));
        allowedCalldataAnyOfEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should allow when the calldata matches a later candidate at startIndex
    function test_allowsWhenSecondCandidateMatches() public {
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(200))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 startIndex_ = uint128(abi.encodeWithSelector(BasicERC20.mint.selector, address(0)).length);
        uint128 valueLength_ = 32;
        bytes memory concatenatedValues_ = bytes.concat(abi.encodePacked(uint256(100)), abi.encodePacked(uint256(200)));
        bytes memory terms_ = _packTerms(startIndex_, valueLength_, concatenatedValues_);

        vm.prank(address(delegationManager));
        allowedCalldataAnyOfEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should allow when several equal-length candidates include the executed uint256
    function test_allowsWhenOneOfSeveralUint256CandidatesMatches() public {
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(0xabcd))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 startIndex_ = uint128(abi.encodeWithSelector(BasicERC20.mint.selector, address(0)).length);
        uint128 valueLength_ = 32;
        bytes memory concatenatedValues_ =
            bytes.concat(abi.encodePacked(uint256(1)), abi.encodePacked(uint256(0xabcd)), abi.encodePacked(uint256(2)));
        bytes memory terms_ = _packTerms(startIndex_, valueLength_, concatenatedValues_);

        vm.prank(address(delegationManager));
        allowedCalldataAnyOfEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    // should NOT allow when no candidate matches at startIndex
    function test_revertsWhenNoCandidateMatches() public {
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(300))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 startIndex_ = uint128(abi.encodeWithSelector(BasicERC20.mint.selector, address(0)).length);
        uint128 valueLength_ = 32;
        bytes memory concatenatedValues_ = bytes.concat(abi.encodePacked(uint256(100)), abi.encodePacked(uint256(200)));
        bytes memory terms_ = _packTerms(startIndex_, valueLength_, concatenatedValues_);

        vm.prank(address(delegationManager));
        vm.expectRevert("AllowedCalldataAnyOfEnforcer:invalid-calldata");
        allowedCalldataAnyOfEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should NOT allow when the execution window is shorter than valueLength
    function test_revertsWhenCalldataTooShortForSlice() public {
        Execution memory execution_ = Execution({
            target: address(basicCF20),
            value: 0,
            callData: abi.encodeWithSelector(BasicERC20.mint.selector, address(users.alice.deleGator), uint256(100))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        uint128 startIndex_ = uint128(abi.encodeWithSelector(BasicERC20.mint.selector, address(0)).length);
        uint128 valueLength_ = uint128(execution_.callData.length - uint256(startIndex_) + 1);
        bytes memory concatenatedValues_ = new bytes(uint256(valueLength_));
        for (uint256 i = 0; i < concatenatedValues_.length; ++i) {
            concatenatedValues_[i] = 0xff;
        }
        bytes memory terms_ = _packTerms(startIndex_, valueLength_, concatenatedValues_);

        vm.prank(address(delegationManager));
        vm.expectRevert("AllowedCalldataAnyOfEnforcer:invalid-calldata-length");
        allowedCalldataAnyOfEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    // should FAIL getTermsInfo when terms are shorter than 32 bytes
    function test_getTermsInfoFailsForShortTerms() public {
        vm.expectRevert("AllowedCalldataAnyOfEnforcer:invalid-terms-size");
        allowedCalldataAnyOfEnforcer.getTermsInfo(hex"010203");
    }

    // should FAIL getTermsInfo when there is no candidate tail
    function test_getTermsInfoFailsForEmptyCandidatesTail() public {
        uint256 metadataWord_ = (uint256(uint128(0)) << 128) | uint256(uint128(32));
        bytes memory terms_ = abi.encodePacked(bytes32(metadataWord_));
        vm.expectRevert("AllowedCalldataAnyOfEnforcer:no-allowed-values");
        allowedCalldataAnyOfEnforcer.getTermsInfo(terms_);
    }

    // should FAIL getTermsInfo when valueLength is zero
    function test_getTermsInfoFailsForZeroValueLength() public {
        uint256 metadataWord_ = (uint256(uint128(4)) << 128) | uint256(uint128(0));
        bytes memory terms_ = bytes.concat(bytes32(metadataWord_), hex"aabb");
        vm.expectRevert("AllowedCalldataAnyOfEnforcer:invalid-value-length");
        allowedCalldataAnyOfEnforcer.getTermsInfo(terms_);
    }

    // should FAIL getTermsInfo when tail is not a multiple of valueLength
    function test_getTermsInfoFailsForInvalidValuesPadding() public {
        uint256 metadataWord_ = (uint256(uint128(0)) << 128) | uint256(uint128(32));
        bytes memory terms_ = bytes.concat(bytes32(metadataWord_), new bytes(33));
        vm.expectRevert("AllowedCalldataAnyOfEnforcer:invalid-values-padding");
        allowedCalldataAnyOfEnforcer.getTermsInfo(terms_);
    }

    // should decode header via getTermsInfo
    function test_getTermsInfoDecodesHeaderAndCount() public view {
        uint128 expectedStartIndex_ = 40;
        uint128 expectedValueLength_ = 32;
        bytes memory concatenatedValues_ = bytes.concat(abi.encodePacked(uint256(1)), abi.encodePacked(uint256(2)));
        bytes memory terms_ = _packTerms(expectedStartIndex_, expectedValueLength_, concatenatedValues_);
        (uint128 startIndex_, uint128 valueLength_, uint256 candidateCount_) =
            allowedCalldataAnyOfEnforcer.getTermsInfo(terms_);
        assertEq(startIndex_, expectedStartIndex_);
        assertEq(valueLength_, expectedValueLength_);
        assertEq(candidateCount_, 2);
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

        uint128 startIndex_ = uint128(abi.encodeWithSelector(IERC20.transfer.selector, address(0)).length);
        uint128 valueLength_ = 32;
        bytes memory concatenatedValues_ = bytes.concat(abi.encodePacked(uint256(1)), abi.encodePacked(uint256(2)));
        bytes memory terms_ = _packTerms(startIndex_, valueLength_, concatenatedValues_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(allowedCalldataAnyOfEnforcer), terms: terms_ });
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

        uint128 startIndex_ = uint128(abi.encodeWithSelector(IERC20.transfer.selector, address(0)).length);
        uint128 valueLength_ = 32;
        bytes memory concatenatedValues_ = bytes.concat(abi.encodePacked(uint256(1)), abi.encodePacked(uint256(2)));
        bytes memory terms_ = _packTerms(startIndex_, valueLength_, concatenatedValues_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(allowedCalldataAnyOfEnforcer), terms: terms_ });
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
