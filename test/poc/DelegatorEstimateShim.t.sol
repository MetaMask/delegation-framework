// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { DelegationManager } from "../../src/DelegationManager.sol";
import { DelegatorEstimateShim } from "../../src/poc/DelegatorEstimateShim.sol";
import { Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
contract DelegatorEstimateShimTest is Test {
    DelegationManager internal delegationManager;
    bytes32 internal constant ROOT_AUTHORITY =
        0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    DelegatorEstimateShim internal shimImpl;
    address internal delegator;
    address internal redeemer;

    ModeCode internal singleDefaultMode = ModeLib.encodeSimpleSingle();

    function setUp() public {
        delegationManager = new DelegationManager(address(this));
        shimImpl = new DelegatorEstimateShim(address(delegationManager));
        delegator = makeAddr("delegator");
        redeemer = makeAddr("redeemer");
        vm.etch(delegator, address(shimImpl).code);
    }

    function test_bogusSignaturePassesWithShimBytecode() public {
        Delegation memory delegation_ = Delegation({
            delegate: redeemer,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 1,
            signature: hex"00"
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

    function _toDelegationArray(Delegation memory d) internal pure returns (Delegation[] memory arr) {
        arr = new Delegation[](1);
        arr[0] = d;
    }
}
