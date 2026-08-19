// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib, ModePayload } from "@erc7579/lib/ModeLib.sol";

import { CALLTYPE_BATCH, EXECTYPE_DEFAULT, MODE_DEFAULT } from "../../../src/utils/Constants.sol";
import { CaveatEnforcerBaseTest } from "../../enforcers/CaveatEnforcerBaseTest.t.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../../src/utils/Types.sol";
import {
    ExactExecutionBatchLimitedCallsProfileEnforcer
} from "../../../src/experiments/enforcers/ExactExecutionBatchLimitedCallsProfileEnforcer.sol";
import { EncoderLib } from "../../../src/libraries/EncoderLib.sol";
import { Counter } from "../../utils/Counter.t.sol";
import { ICaveatEnforcer } from "../../../src/interfaces/ICaveatEnforcer.sol";

/**
 * @notice Unit tests for versioned limit-order profile enforcer.
 * @dev Run: `forge test --match-contract ExactExecutionBatchLimitedCallsProfileEnforcerTest -vv`
 */
contract ExactExecutionBatchLimitedCallsProfileEnforcerTest is CaveatEnforcerBaseTest {
    ExactExecutionBatchLimitedCallsProfileEnforcer internal profileEnforcer;

    function setUp() public override {
        super.setUp();
        profileEnforcer = new ExactExecutionBatchLimitedCallsProfileEnforcer();
        vm.label(address(profileEnforcer), "Profile Enforcer");
    }

    function test_profileVersion_isOne() public {
        assertEq(profileEnforcer.PROFILE_VERSION(), 1);
    }

    function test_beforeHook_succeedsWithValidProfile() public {
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(_singleExecutionArray(execution_));
        ModeCode mode_ = batchDefaultMode;
        bytes memory terms_ = _encodeProfileTerms(1, 0, type(uint128).max, mode_, executionCallData_);
        bytes32 delegationHash_ = _sampleDelegationHash();

        vm.prank(address(delegationManager));
        profileEnforcer.beforeHook(terms_, hex"", mode_, executionCallData_, delegationHash_, address(0), address(0));

        assertEq(profileEnforcer.callCounts(address(delegationManager), delegationHash_), 1);
    }

    function test_beforeHook_revertsWhenTooEarly() public {
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(_singleExecutionArray(execution_));
        ModeCode mode_ = batchDefaultMode;
        uint128 validAfter_ = uint128(block.timestamp + 1 hours);
        bytes memory terms_ = _encodeProfileTerms(1, validAfter_, type(uint128).max, mode_, executionCallData_);

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactExecutionBatchLimitedCallsProfileEnforcer:too-early");
        profileEnforcer.beforeHook(terms_, hex"", mode_, executionCallData_, _sampleDelegationHash(), address(0), address(0));
    }

    function test_beforeHook_revertsWhenExpired() public {
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(_singleExecutionArray(execution_));
        ModeCode mode_ = batchDefaultMode;
        vm.warp(100);
        uint128 validUntil_ = 50;
        bytes memory terms_ = _encodeProfileTerms(1, 0, validUntil_, mode_, executionCallData_);

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactExecutionBatchLimitedCallsProfileEnforcer:expired");
        profileEnforcer.beforeHook(terms_, hex"", mode_, executionCallData_, _sampleDelegationHash(), address(0), address(0));
    }

    function test_beforeHook_revertsOnModeMismatch() public {
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(_singleExecutionArray(execution_));
        ModeCode expectedMode_ = batchDefaultMode;
        ModeCode actualMode_ = ModeLib.encode(CALLTYPE_BATCH, EXECTYPE_DEFAULT, MODE_DEFAULT, ModePayload.wrap(bytes22(uint176(1))));
        bytes memory terms_ = _encodeProfileTerms(1, 0, type(uint128).max, expectedMode_, executionCallData_);

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactExecutionBatchLimitedCallsProfileEnforcer:invalid-mode");
        profileEnforcer.beforeHook(terms_, hex"", actualMode_, executionCallData_, _sampleDelegationHash(), address(0), address(0));
    }

    function test_beforeHook_revertsOnExecutionMismatch() public {
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory expectedCallData_ = ExecutionLib.encodeBatch(_singleExecutionArray(execution_));
        bytes memory wrongCallData_ = ExecutionLib.encodeBatch(
            _singleExecutionArray(
                Execution({
                    target: address(aliceDeleGatorCounter),
                    value: 0,
                    callData: abi.encodeWithSelector(Counter.unsafeIncrement.selector)
                })
            )
        );
        ModeCode mode_ = batchDefaultMode;
        bytes memory terms_ = _encodeProfileTerms(1, 0, type(uint128).max, mode_, expectedCallData_);

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactExecutionBatchLimitedCallsProfileEnforcer:invalid-execution");
        profileEnforcer.beforeHook(terms_, hex"", mode_, wrongCallData_, _sampleDelegationHash(), address(0), address(0));
    }

    function test_getProfileTermsInfo_decodesHeader() public {
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(_singleExecutionArray(execution_));
        ModeCode mode_ = batchDefaultMode;
        uint128 validAfter_ = 100;
        uint128 validUntil_ = 200;
        bytes memory terms_ = _encodeProfileTerms(3, validAfter_, validUntil_, mode_, executionCallData_);

        (
            uint256 limit_,
            uint128 decodedValidAfter_,
            uint128 decodedValidUntil_,
            ModeCode decodedMode_,
            Execution[] memory executions_
        ) = profileEnforcer.getProfileTermsInfo(terms_);

        assertEq(limit_, 3);
        assertEq(decodedValidAfter_, validAfter_);
        assertEq(decodedValidUntil_, validUntil_);
        assertEq(ModeCode.unwrap(decodedMode_), ModeCode.unwrap(mode_));
        assertEq(executions_.length, 1);
        assertEq(executions_[0].target, execution_.target);
    }

    function _encodeProfileTerms(
        uint256 _limit,
        uint128 _validAfter,
        uint128 _validUntil,
        ModeCode _mode,
        bytes memory _executionCallData
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(_limit, _validAfter, _validUntil, ModeCode.unwrap(_mode), _executionCallData);
    }

    function _singleExecutionArray(Execution memory _execution) internal pure returns (Execution[] memory arr_) {
        arr_ = new Execution[](1);
        arr_[0] = _execution;
    }

    function _getEnforcer() internal override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(profileEnforcer));
    }

    function _sampleDelegationHash() internal view returns (bytes32) {
        return EncoderLib._getDelegationHash(
            Delegation({
                delegate: address(users.bob.deleGator),
                delegator: address(users.alice.deleGator),
                authority: ROOT_AUTHORITY,
                caveats: new Caveat[](0),
                salt: 0,
                signature: hex""
            })
        );
    }
}
