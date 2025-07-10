// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { Execution, PackedUserOperation, Caveat, Delegation } from "../src/utils/Types.sol";
import { Counter } from "./utils/Counter.t.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

/**
 * @title Revoke Delegation Mid Chain Test
 * @notice the test creates a delegation chain and revokes a delegation in the middle of the chain
 */
contract RevokeDelegationMidChainTest is BaseTest {
    using MessageHashUtils for bytes32;

    // Counter for Eve
    Counter eveCounterContract;

    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
    }

    function setUp() public override {
        super.setUp();

        // Create a Counter contract for Eve
        eveCounterContract = new Counter(address(users.eve.deleGator));
        vm.label(address(eveCounterContract), "Eve's Counter");

        // Deploy Carol's MultiSig delegator
        deployDeleGator_MultiSig(users.carol);

        // Deploy Dave's EIP7702 stateless delegator
        deployDeleGator_EIP7702Stateless(users.dave);

        // Bob, Alice and Eve have a hybrid delegator

        // Ensure wallets have sufficient funds
        vm.deal(address(users.eve.deleGator), 10 ether);
        vm.deal(address(users.dave.deleGator), 10 ether);
        vm.deal(address(users.carol.deleGator), 10 ether);
        vm.deal(address(users.bob.deleGator), 10 ether);
        vm.deal(address(users.alice.deleGator), 10 ether);

        // Fund the EntryPoint for each account
        vm.prank(address(users.eve.deleGator));
        entryPoint.depositTo{ value: 1 ether }(address(users.eve.deleGator));

        vm.prank(address(users.dave.deleGator));
        entryPoint.depositTo{ value: 1 ether }(address(users.dave.deleGator));

        vm.prank(address(users.carol.deleGator));
        entryPoint.depositTo{ value: 1 ether }(address(users.carol.deleGator));

        vm.prank(address(users.bob.deleGator));
        entryPoint.depositTo{ value: 1 ether }(address(users.bob.deleGator));

        vm.prank(address(users.alice.deleGator));
        entryPoint.depositTo{ value: 1 ether }(address(users.alice.deleGator));
    }

    function test_delegationChain_RevocationMidChain() public {
        // Create delegation chain:
        // Eve (EOA) -> Dave (EIP7702) -> Carol (MultiSig) -> Bob (Hybrid) -> Alice (Hybrid)

        // 1. Eve (EOA) delegates to Dave's EIP7702
        Delegation memory eveToDaveDelegation = Delegation({
            delegate: address(users.dave.deleGator),
            delegator: address(users.eve.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Eve signs with EOA
        bytes32 eveDelegationHash = EncoderLib._getDelegationHash(eveToDaveDelegation);
        bytes32 domainHash = delegationManager.getDomainHash();
        bytes32 eveTypedDataHash = MessageHashUtils.toTypedDataHash(domainHash, eveDelegationHash);
        eveToDaveDelegation.signature = signHash(SignatureType.EOA, users.eve, eveTypedDataHash);

        // 2. Dave (EIP7702) delegates to Carol's MultiSig
        Delegation memory daveToCarolDelegation = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.dave.deleGator),
            authority: eveDelegationHash,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Dave signs with EIP7702
        bytes32 daveDelegationHash = EncoderLib._getDelegationHash(daveToCarolDelegation);
        bytes32 daveTypedDataHash = MessageHashUtils.toTypedDataHash(domainHash, daveDelegationHash);
        daveToCarolDelegation.signature = signHash(SignatureType.EOA, users.dave, daveTypedDataHash);

        // 3. Carol's MultiSig delegates to Bob's Hybrid
        Delegation memory carolToBobDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.carol.deleGator),
            authority: daveDelegationHash,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Carol's MultiSig signs
        bytes32 carolDelegationHash = EncoderLib._getDelegationHash(carolToBobDelegation);
        bytes32 carolTypedDataHash = MessageHashUtils.toTypedDataHash(domainHash, carolDelegationHash);
        carolToBobDelegation.signature = signHash(SignatureType.MultiSig, users.carol, carolTypedDataHash);

        // 4. Bob's Hybrid delegates to Alice's Hybrid
        Delegation memory bobToAliceDelegation = Delegation({
            delegate: address(users.alice.deleGator),
            delegator: address(users.bob.deleGator),
            authority: carolDelegationHash,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Bob's Hybrid signs
        bytes32 bobDelegationHash = EncoderLib._getDelegationHash(bobToAliceDelegation);
        bytes32 bobTypedDataHash = MessageHashUtils.toTypedDataHash(domainHash, bobDelegationHash);
        bobToAliceDelegation.signature = signHash(SignatureType.RawP256, users.bob, bobTypedDataHash);

        // First, verify the full delegation chain works by having Alice increment the counter
        Delegation[] memory fullDelegationChain = new Delegation[](4);
        fullDelegationChain[0] = bobToAliceDelegation;
        fullDelegationChain[1] = carolToBobDelegation;
        fullDelegationChain[2] = daveToCarolDelegation;
        fullDelegationChain[3] = eveToDaveDelegation;

        invokeDelegation_UserOp(
            users.alice,
            fullDelegationChain,
            Execution({ target: address(eveCounterContract), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector) })
        );

        console.log("Eve's counter after full chain delegation: %d", eveCounterContract.count());
        assertEq(eveCounterContract.count(), 1, "Full delegation chain should work initially");

        // Now, have Carol disable her delegation to Bob, breaking the chain
        execute_UserOp(users.carol, abi.encodeWithSelector(IDelegationManager.disableDelegation.selector, carolToBobDelegation));

        // Verify Carol's delegation is now disabled
        bytes32 disabledDelegationHash = EncoderLib._getDelegationHash(carolToBobDelegation);
        assertTrue(delegationManager.disabledDelegations(disabledDelegationHash), "Carol's delegation should be disabled");

        // expecting revert  if the user operation is executed again
        // Instead of vm.expectEmit, record all events before the operation
        vm.recordLogs();

        // Execute the operation that should fail
        invokeDelegation_UserOp(
            users.alice,
            fullDelegationChain,
            Execution({ target: address(eveCounterContract), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector) })
        );

        // Get all emitted logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 userOpRevertReasonSig = keccak256("UserOperationRevertReason(bytes32,address,uint256,bytes)");
        // Look for the UserOperationRevertReason event with the expected error
        bool foundUserOpRevertEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            // Just check if UserOperationRevertReason event was emitted from entryPoint
            if (logs[i].topics.length > 0 && logs[i].topics[0] == userOpRevertReasonSig && logs[i].emitter == address(entryPoint)) {
                foundUserOpRevertEvent = true;
                break;
            }
        }

        assertTrue(foundUserOpRevertEvent, "Did not find expected CannotUseADisabledDelegation error");

        console.log("Eve's counter after full chain delegation: %d", eveCounterContract.count());
        assertEq(eveCounterContract.count(), 1, "Countrer should remain 1");
    }
}
