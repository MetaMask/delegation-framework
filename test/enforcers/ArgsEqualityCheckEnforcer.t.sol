// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ArgsEqualityCheckEnforcer } from "../../src/enforcers/ArgsEqualityCheckEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Caveats } from "../../src/libraries/Caveats.sol";

contract ArgsEqualityCheckEnforcerTest is CaveatEnforcerBaseTest {
    using ModeLib for ModeCode;

    ////////////////////// State //////////////////////

    ArgsEqualityCheckEnforcer public argsEqualityCheckEnforcer;
    ModeCode public mode = ModeLib.encodeSimpleSingle();

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        argsEqualityCheckEnforcer = new ArgsEqualityCheckEnforcer();
        vm.label(address(argsEqualityCheckEnforcer), "Args Equality Enforcer");
    }

    ////////////////////// Valid cases //////////////////////

    // should SUCCEED to pass enforcer if terms equals args
    function test_passEnforcerWhenTermsEqualsArgs() public {
        bytes memory expectedArgs = bytes("This is an example");
        Caveat memory caveat = Caveats.createArgsEqualityCheckCaveat(address(argsEqualityCheckEnforcer), expectedArgs);
        argsEqualityCheckEnforcer.beforeHook(
            caveat.terms, expectedArgs, mode, abi.encode(new Execution[](1)[0]), bytes32(0), address(0), address(0)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    // should FAIL to pass enforcer if terms and args are different
    function test_failToPasEnforcerWhenTermsAndArgsAreDifferent() public {
        bytes memory expectedArgs = bytes("This is an example1");
        bytes memory actualArgs = bytes("This is an example2");
        Caveat memory caveat = Caveats.createArgsEqualityCheckCaveat(address(argsEqualityCheckEnforcer), expectedArgs);
        address redeemer_ = address(99999);
        vm.startPrank(address(delegationManager));
        vm.expectRevert("ArgsEqualityCheckEnforcer:different-args-and-terms");
        vm.expectEmit(true, true, true, true, address(argsEqualityCheckEnforcer));
        emit ArgsEqualityCheckEnforcer.DifferentArgsAndTerms(address(delegationManager), redeemer_, bytes32(0), caveat.terms, actualArgs);
        argsEqualityCheckEnforcer.beforeHook(
            caveat.terms, actualArgs, mode, abi.encode(new Execution[](1)[0]), bytes32(0), address(0), redeemer_
        );
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(argsEqualityCheckEnforcer));
    }
}
