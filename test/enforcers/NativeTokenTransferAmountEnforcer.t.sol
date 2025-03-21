// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { NativeTokenTransferAmountEnforcer } from "../../src/enforcers/NativeTokenTransferAmountEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract NativeTokenTransferAmountEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////// Set up //////////////////////
    NativeTokenTransferAmountEnforcer public nativeTokenTransferAmountEnforcer;

    function setUp() public override {
        super.setUp();
        nativeTokenTransferAmountEnforcer = new NativeTokenTransferAmountEnforcer();
        vm.label(address(nativeTokenTransferAmountEnforcer), "Native Allowance Enforcer");
    }

    //////////////////// Valid cases //////////////////////

    // Should decode the terms
    function test_decodesTheTerms() public {
        uint256 obtainedAllowance_ = nativeTokenTransferAmountEnforcer.getTermsInfo(abi.encode(1 ether));
        assertEq(obtainedAllowance_, 1 ether);
    }

    // should SUCCEED to INVOKE transfer ETH BELOW enforcer allowance
    function test_transferSucceedsIfCalledBelowAllowance() public {
        uint256 allowance_ = 1 ether;

        // Create the execution that would be executed
        Execution memory execution_ = Execution({ target: address(users.bob.deleGator), value: 1 ether, callData: hex"" });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory inputTerms_ = abi.encode(allowance_);

        bytes32 delegationHash_ = _getExampleDelegation(inputTerms_);

        assertEq(nativeTokenTransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
        vm.prank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(nativeTokenTransferAmountEnforcer));
        emit NativeTokenTransferAmountEnforcer.IncreasedSpentMap(
            address(delegationManager), address(0), delegationHash_, allowance_, 1 ether
        );
        nativeTokenTransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );

        assertEq(nativeTokenTransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), allowance_);
    }

    // should SUCCEED to INVOKE transfer ETH BELOW enforcer allowance
    function test_transferSucceedsIfCalledBelowAllowanceMultipleCalls() public {
        uint256 allowance_ = 3 ether;

        // Create the execution that would be executed
        Execution memory execution_ = Execution({ target: address(users.bob.deleGator), value: 1 ether, callData: hex"" });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory inputTerms_ = abi.encode(allowance_);

        bytes32 delegationHash_ = _getExampleDelegation(inputTerms_);
        assertEq(nativeTokenTransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
        vm.startPrank(address(delegationManager));

        // Fist use
        vm.expectEmit(true, true, true, true, address(nativeTokenTransferAmountEnforcer));
        emit NativeTokenTransferAmountEnforcer.IncreasedSpentMap(
            address(delegationManager), address(0), delegationHash_, allowance_, 1 ether
        );
        nativeTokenTransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
        assertEq(nativeTokenTransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 1 ether);

        // Second use
        vm.expectEmit(true, true, true, true, address(nativeTokenTransferAmountEnforcer));
        emit NativeTokenTransferAmountEnforcer.IncreasedSpentMap(
            address(delegationManager), address(0), delegationHash_, allowance_, 2 ether
        );
        nativeTokenTransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
        assertEq(nativeTokenTransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 2 ether);

        // Third use, maximum allowance used
        vm.expectEmit(true, true, true, true, address(nativeTokenTransferAmountEnforcer));
        emit NativeTokenTransferAmountEnforcer.IncreasedSpentMap(
            address(delegationManager), address(0), delegationHash_, allowance_, allowance_
        );
        nativeTokenTransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
        assertEq(nativeTokenTransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), allowance_);
    }

    ////////////////////// Invalid cases //////////////////////

    // should FAIL if allowance is exceeded
    function test_transferFailsIfAllowanceExceeded() public {
        uint256 allowance_ = 1 ether;

        // Create the execution that would be executed
        // The value is higher than the allowance
        Execution memory execution_ = Execution({ target: address(users.bob.deleGator), value: allowance_ + 1, callData: hex"" });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory inputTerms_ = abi.encode(allowance_);

        bytes32 delegationHash_ = _getExampleDelegation(inputTerms_);

        assertEq(nativeTokenTransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
        vm.prank(address(delegationManager));
        vm.expectRevert("NativeTokenTransferAmountEnforcer:allowance-exceeded");
        nativeTokenTransferAmountEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );

        // The allowance does not change
        assertEq(nativeTokenTransferAmountEnforcer.spentMap(address(delegationManager), delegationHash_), 0);
    }

    // should fail with invalid call type mode (batch instead of single mode)
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));

        vm.expectRevert("CaveatEnforcer:invalid-call-type");

        nativeTokenTransferAmountEnforcer.beforeHook(
            hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0)
        );
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        nativeTokenTransferAmountEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    function _getExampleDelegation(bytes memory inputTerms_) internal view returns (bytes32 delegationHash_) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(nativeTokenTransferAmountEnforcer), terms: inputTerms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        return EncoderLib._getDelegationHash(delegation_);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(nativeTokenTransferAmountEnforcer));
    }
}
