// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import "../../src/utils/Types.sol";
import { Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { NonceEnforcer } from "../../src/enforcers/NonceEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Caveats } from "../../src/libraries/Caveats.sol";

contract NonceEnforcerTest is CaveatEnforcerBaseTest {
    using ModeLib for ModeCode;

    ////////////////////////////// State //////////////////////////////
    NonceEnforcer public enforcer;
    Execution execution = Execution({ target: address(0), value: 0, callData: hex"" });
    bytes executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);
    address delegator = address(users.alice.deleGator);
    address dm = address(delegationManager);
    ModeCode mode = ModeLib.encodeSimpleSingle();

    ////////////////////////////// Events //////////////////////////////

    event UsedNonce(address indexed delegationManager, address indexed delegator, uint256 nonce);

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        enforcer = new NonceEnforcer();
        vm.label(address(enforcer), "Nonce Enforcer");
    }

    ////////////////////// Basic Functionality //////////////////////

    // Validates the terms get decoded correctly
    function test_decodedTheTerms() public {
        // 0
        uint256 nonce_ = 0;
        Caveat memory caveat = Caveats.createNonceCaveat(address(enforcer), nonce_);
        assertEq(enforcer.getTermsInfo(caveat.terms), nonce_);

        // boring integer
        nonce_ = 100;
        caveat = Caveats.createNonceCaveat(address(enforcer), nonce_);
        assertEq(enforcer.getTermsInfo(caveat.terms), nonce_);

        // uint256 max
        nonce_ = type(uint256).max;
        caveat = Caveats.createNonceCaveat(address(enforcer), nonce_);
        assertEq(enforcer.getTermsInfo(caveat.terms), nonce_);
    }

    // Validates that the delegator can increment the ID
    function test_allow_incrementingId() public {
        assertEq(enforcer.currentNonce(dm, delegator), 0);
        vm.prank(delegator);
        vm.expectEmit(true, true, true, true);
        emit UsedNonce(dm, delegator, 0);
        enforcer.incrementNonce(dm);
        assertEq(enforcer.currentNonce(dm, delegator), 1);
    }

    // Validates that a valid ID doesn't revert
    function test_allow_validId() public {
        uint256 nonce_ = enforcer.currentNonce(dm, delegator);
        Caveat memory caveat = Caveats.createNonceCaveat(address(enforcer), nonce_);

        vm.startPrank(dm);

        // Should not revert
        enforcer.beforeHook(caveat.terms, hex"", mode, executionCallData, bytes32(0), delegator, address(0));
    }

    ////////////////////// Errors //////////////////////

    // Validates the terms are enforced
    function test_invalid_decodedTheTerms() public {
        bytes memory terms_ = hex"";

        // Too small
        vm.expectRevert(bytes("NonceEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large
        uint256 nonce_ = 100;
        terms_ = abi.encode(nonce_, nonce_);
        vm.expectRevert(bytes("NonceEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Validates that an invalid ID reverts
    function test_notAllow_invalidId() public {
        // Higher ID should revert
        uint256 nonce_ = enforcer.currentNonce(dm, delegator);
        Caveat memory caveat = Caveats.createNonceCaveat(address(enforcer), nonce_ + 1);
        vm.startPrank(dm);
        vm.expectRevert(bytes("NonceEnforcer:invalid-nonce"));
        enforcer.beforeHook(caveat.terms, hex"", mode, executionCallData, bytes32(0), delegator, address(0));

        // Increment ID so the current ID is high enough to check a lower ID
        vm.startPrank(dm);
        enforcer.incrementNonce(dm);
        nonce_ = enforcer.currentNonce(dm, delegator);

        // Lower ID should also revert
        caveat = Caveats.createNonceCaveat(address(enforcer), nonce_ - 1);
        vm.startPrank(dm);
        vm.expectRevert(bytes("NonceEnforcer:invalid-nonce"));
        enforcer.beforeHook(caveat.terms, hex"", mode, executionCallData, bytes32(0), delegator, address(0));
    }

    //////////////////////  Integration  //////////////////////

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
