// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Action } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { RedeemerEnforcer } from "../../src/enforcers/RedeemerEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract RedeemerEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    RedeemerEnforcer public redeemerEnforcer;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        redeemerEnforcer = new RedeemerEnforcer();
        vm.label(address(redeemerEnforcer), "Redeemer Enforcer");
    }

    ////////////////////// Valid cases //////////////////////

    // should SUCCEED to get terms info when passing valid terms
    function test_decodeTermsInfo() public {
        bytes memory terms_ = abi.encodePacked(address(users.alice.deleGator), address(users.bob.deleGator));
        address[] memory allowedRedeemers_ = redeemerEnforcer.getTermsInfo(terms_);
        assertEq(allowedRedeemers_[0], address(users.alice.deleGator));
        assertEq(allowedRedeemers_[1], address(users.bob.deleGator));
    }

    // should pass if called from a single valid redeemer
    function test_validSingleRedeemerCanExecute() public {
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        bytes memory terms_ = abi.encodePacked(address(users.bob.deleGator));
        vm.prank(address(delegationManager));
        redeemerEnforcer.beforeHook(terms_, hex"", action_, keccak256(""), address(0), address(users.bob.deleGator));
    }

    // should pass if called from multiple valid redeemers
    function test_validMultipleRedeemersCanExecute() public {
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        bytes memory terms_ = abi.encodePacked(address(users.alice.deleGator), address(users.bob.deleGator));
        vm.startPrank(address(delegationManager));
        redeemerEnforcer.beforeHook(terms_, hex"", action_, keccak256(""), address(0), address(users.alice.deleGator));
        redeemerEnforcer.beforeHook(terms_, hex"", action_, keccak256(""), address(0), address(users.bob.deleGator));
    }

    ////////////////////// Invalid cases //////////////////////

    // should FAIL to get terms info when passing an invalid terms length
    function test_getTermsInfoFailsForInvalidLength() public {
        vm.expectRevert("RedeemerEnforcer:invalid-terms-length");
        redeemerEnforcer.getTermsInfo(bytes("1"));
    }

    // should revert if called from an invalid redeemer
    function test_revertWithInvalidRedeemer() public {
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        bytes memory terms_ = abi.encodePacked(address(users.bob.deleGator));
        vm.prank(address(delegationManager));
        // Dave is not a valid redeemer
        vm.expectRevert("RedeemerEnforcer:unauthorized-redeemer");
        redeemerEnforcer.beforeHook(terms_, hex"", action_, keccak256(""), address(0), address(users.dave.deleGator));
    }

    // should revert with invalid terms length
    function test_revertWithInvalidTerms() public {
        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        bytes memory invalidTerms_ = abi.encodePacked(uint8(1));
        vm.prank(address(delegationManager));
        vm.expectRevert("RedeemerEnforcer:invalid-terms-length");
        redeemerEnforcer.beforeHook(invalidTerms_, hex"", action_, keccak256(""), address(0), address(users.bob.deleGator));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(redeemerEnforcer));
    }
}
