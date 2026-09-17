// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { DelegationManager } from "../../src/DelegationManager.sol";
import { DelegatorEstimateShim } from "../../src/poc/DelegatorEstimateShim.sol";
import { CallType, Caveat, Delegation, Execution, ModeCode } from "../../src/utils/Types.sol";

contract RevertingTarget {
    fallback() external payable {
        revert("target-revert");
    }
}

contract DelegatorEstimateShimTest is Test {
    DelegationManager internal delegationManager;
    bytes32 internal constant ROOT_AUTHORITY =
        0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    DelegatorEstimateShim internal shimImpl;
    address internal delegator;
    address internal redeemer;

    ModeCode internal singleDefaultMode = ModeLib.encodeSimpleSingle();
    ModeCode internal batchDefaultMode = ModeLib.encodeSimpleBatch();

    /// 65-byte zero signature (valid ECDSA length; content irrelevant once the
    /// shim accepts ERC-1271 unconditionally after paying recover gas).
    bytes internal constant BOGUS_SIGNATURE_65 =
        hex"0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    RevertingTarget internal revertingTarget;

    function setUp() public {
        delegationManager = new DelegationManager(address(this));
        shimImpl = new DelegatorEstimateShim(address(delegationManager));
        delegator = makeAddr("delegator");
        redeemer = makeAddr("redeemer");
        revertingTarget = new RevertingTarget();
        vm.etch(delegator, address(shimImpl).code);
    }

    function test_bogusSignaturePassesWithShimBytecode() public {
        Delegation memory delegation_ = Delegation({
            delegate: redeemer,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 1,
            signature: BOGUS_SIGNATURE_65
        });

        bytes[] memory contexts_ = new bytes[](1);
        contexts_[0] = abi.encode(_toDelegationArray(delegation_));

        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = singleDefaultMode;

        bytes[] memory executions_ = new bytes[](1);
        executions_[0] = ExecutionLib.encodeSingle(redeemer, 0, hex"");

        vm.prank(redeemer);
        delegationManager.redeemDelegations(contexts_, modes_, executions_);
    }

    function test_revertsOnUnsupportedMode() public {
        Delegation memory delegation_ = _leafDelegation();

        bytes[] memory contexts_ = new bytes[](1);
        contexts_[0] = abi.encode(_toDelegationArray(delegation_));

        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = batchDefaultMode; // CALLTYPE_BATCH — not supported by shim

        bytes[] memory executions_ = new bytes[](1);
        // Batch execution calldata shape (encoded as a batch of one).
        Execution[] memory batch_ = new Execution[](1);
        batch_[0] = Execution({ target: redeemer, value: 0, callData: hex"" });
        executions_[0] = ExecutionLib.encodeBatch(batch_);

        vm.prank(redeemer);
        {
            (CallType callType_,,,) = ModeLib.decode(batchDefaultMode);
            vm.expectRevert(
                abi.encodeWithSelector(
                    DelegatorEstimateShim.UnsupportedCallType.selector,
                    callType_
                )
            );
        }
        delegationManager.redeemDelegations(contexts_, modes_, executions_);
    }

    function test_bubblesTargetRevert() public {
        Delegation memory delegation_ = _leafDelegation();

        bytes[] memory contexts_ = new bytes[](1);
        contexts_[0] = abi.encode(_toDelegationArray(delegation_));

        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = singleDefaultMode;

        bytes[] memory executions_ = new bytes[](1);
        executions_[0] = ExecutionLib.encodeSingle(
            address(revertingTarget),
            0,
            abi.encodeWithSignature("anything()")
        );

        vm.prank(redeemer);
        vm.expectRevert(bytes("target-revert"));
        delegationManager.redeemDelegations(contexts_, modes_, executions_);
    }

    function _leafDelegation() internal view returns (Delegation memory) {
        return Delegation({
            delegate: redeemer,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 1,
            signature: BOGUS_SIGNATURE_65
        });
    }

    function _toDelegationArray(Delegation memory d)
        internal
        pure
        returns (Delegation[] memory arr)
    {
        arr = new Delegation[](1);
        arr[0] = d;
    }
}
