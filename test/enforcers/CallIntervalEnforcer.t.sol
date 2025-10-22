// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { CallIntervalEnforcer } from "../../src/enforcers/CallIntervalEnforcer.sol";
import { ModeCode } from "../../src/utils/Types.sol";

contract CallIntervalEnforcerTest is Test {
    CallIntervalEnforcer public enforcer;
    address public delegationManager = address(0x1234);
    bytes32 public delegationHash = keccak256("test-delegation");
    uint256 public interval = 1 hours;
    bytes public terms;

    ModeCode public defaultMode = ModeCode.wrap(bytes32(0));

    function setUp() public {
        vm.warp(10000);
        enforcer = new CallIntervalEnforcer();
        terms = abi.encodePacked(interval);
    }

    function testRevertOnInvalidTermsLength() public {
        bytes memory invalidTerms = new bytes(31);
        vm.expectRevert("CallIntervalEnforcer:invalid-terms-length");
        enforcer.getTermsInfo(invalidTerms);
    }

    function testFirstCallSucceeds() public {
        vm.prank(delegationManager);
        enforcer.beforeHook(terms, "", defaultMode, "", delegationHash, address(0), address(0));
        uint256 lastCall = enforcer.lastCallExecution(delegationManager, delegationHash);
        assertEq(lastCall, block.timestamp);
    }

    function testRevertIfIntervalNotElapsed() public {
        // First call
        vm.prank(delegationManager);
        enforcer.beforeHook(terms, "", defaultMode, "", delegationHash, address(0), address(0));
        // Second call immediately
        vm.prank(delegationManager);
        vm.expectRevert("CallIntervalEnforcer:early-delegation");
        enforcer.beforeHook(terms, "", defaultMode, "", delegationHash, address(0), address(0));
    }

    function testCallSucceedsAfterInterval() public {
        // First call
        vm.prank(delegationManager);
        enforcer.beforeHook(terms, "", defaultMode, "", delegationHash, address(0), address(0));
        // Warp time forward by interval + 1
        vm.warp(block.timestamp + interval + 1);
        // Second call
        vm.prank(delegationManager);
        enforcer.beforeHook(terms, "", defaultMode, "", delegationHash, address(0), address(0));
        uint256 lastCall = enforcer.lastCallExecution(delegationManager, delegationHash);
        assertEq(lastCall, block.timestamp);
    }

    function testZeroIntervalAllowsImmediateCalls() public {
        bytes memory zeroTerms = abi.encodePacked(uint256(0));
        // First call
        vm.prank(delegationManager);
        enforcer.beforeHook(zeroTerms, "", defaultMode, "", delegationHash, address(0), address(0));
        // Second call immediately
        vm.prank(delegationManager);
        enforcer.beforeHook(zeroTerms, "", defaultMode, "", delegationHash, address(0), address(0));
        // Should not revert
    }

    function testDifferentDelegationHashesTrackedIndependently() public {
        bytes32 hash1 = keccak256("hash1");
        bytes32 hash2 = keccak256("hash2");
        vm.prank(delegationManager);
        enforcer.beforeHook(terms, "", defaultMode, "", hash1, address(0), address(0));
        vm.prank(delegationManager);
        enforcer.beforeHook(terms, "", defaultMode, "", hash2, address(0), address(0));
        assertEq(enforcer.lastCallExecution(delegationManager, hash1), block.timestamp);
        assertEq(enforcer.lastCallExecution(delegationManager, hash2), block.timestamp);
    }

    function testDifferentManagersTrackedIndependently() public {
        address manager1 = address(0x1111);
        address manager2 = address(0x2222);
        vm.prank(manager1);
        enforcer.beforeHook(terms, "", defaultMode, "", delegationHash, address(0), address(0));
        vm.prank(manager2);
        enforcer.beforeHook(terms, "", defaultMode, "", delegationHash, address(0), address(0));
        assertEq(enforcer.lastCallExecution(manager1, delegationHash), block.timestamp);
        assertEq(enforcer.lastCallExecution(manager2, delegationHash), block.timestamp);
    }
}
