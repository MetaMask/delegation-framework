// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { Execution, PackedUserOperation } from "../src/utils/Types.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { EXECUTE_SINGULAR_SIGNATURE } from "./utils/Constants.sol";
import "forge-std/console.sol";

/**
 * @title test to demonstrate replay attack if the entry point is changed
 * @notice this test was passing before the fix - fixed in commit 1f91637e7f61d03e012b7c9d7fc5ee4dc86ce3f3
 * @dev https://github.com/MetaMask/delegation-framework/commit/1f91637e7f61d03e012b7c9d7fc5ee4dc86ce3f3
 */
contract EIP7702EntryPointReplayAttackTest is BaseTest {
    using MessageHashUtils for bytes32;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    // New EntryPoint to upgrade to
    EntryPoint newEntryPoint;
    // Implementation with the new EntryPoint
    EIP7702StatelessDeleGator newImpl;

    function setUp() public override {
        super.setUp();

        // Deploy a second EntryPoint
        newEntryPoint = new EntryPoint();
        vm.label(address(newEntryPoint), "New EntryPoint");

        // Deploy a new implementation connected to the new EntryPoint
        newImpl = new EIP7702StatelessDeleGator(delegationManager, newEntryPoint);
        vm.label(address(newImpl), "New EIP7702 StatelessDeleGator Impl");
    }

    function test_replayAttackAcrossEntryPoints() public {
        // 1. Create a UserOp that will be valid with the original EntryPoint
        address aliceDeleGatorAddr = address(users.alice.deleGator);

        // A simple operation to transfer ETH to Bob
        Execution memory execution = Execution({ target: users.bob.addr, value: 1 ether, callData: hex"" });

        // Create the UserOp with current EntryPoint
        bytes memory userOpCallData = abi.encodeWithSignature(EXECUTE_SINGULAR_SIGNATURE, execution);
        PackedUserOperation memory userOp = createUserOp(aliceDeleGatorAddr, userOpCallData);

        // Alice signs it with the current EntryPoint's context
        userOp.signature = signHash(users.alice, getPackedUserOperationTypedDataHash(userOp));

        // Bob's initial balance for verification
        uint256 bobInitialBalance = users.bob.addr.balance;

        // Execute the original UserOp through the first EntryPoint
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;
        vm.prank(bundler);
        entryPoint.handleOps(userOps, bundler);

        // Verify first execution worked
        uint256 bobBalanceAfterExecution = users.bob.addr.balance;
        assertEq(bobBalanceAfterExecution, bobInitialBalance + 1 ether);

        // 2. Modify code storage
        // The code will be: 0xef0100 || address of new implementation
        vm.etch(aliceDeleGatorAddr, bytes.concat(hex"ef0100", abi.encodePacked(newImpl)));

        // Verify the implementation was updated
        assertEq(address(users.alice.deleGator.entryPoint()), address(newEntryPoint));

        // // 3. Attempt to replay the original UserOp through the new EntryPoint
        // vm.prank(bundler);
        // newEntryPoint.handleOps(userOps, bundler);

        // // 4. Verify if the attack succeeded - check if Bob received ETH again
        // assertEq(users.bob.addr.balance, bobBalanceAfterExecution + 1 ether);

        // 3. Attempt to replay the original UserOp through the new EntryPoint
        vm.expectRevert(); // this will fail because the entry point has changed
        vm.prank(bundler);
        newEntryPoint.handleOps(userOps, bundler);

        // 4. Verify if the attack succeeded - check if Bob received ETH again
        assertEq(users.bob.addr.balance, bobBalanceAfterExecution);

        console.log("Bob's initial balance was: %d", bobInitialBalance / 1 ether);
        console.log("Bob's balance after execution on old entry point was: %d", bobBalanceAfterExecution / 1 ether);
        console.log("Bob's balance after replaying user op on new entry point: %d", users.bob.addr.balance / 1 ether);
    }
}
