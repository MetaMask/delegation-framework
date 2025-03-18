// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { Execution, PackedUserOperation, Caveat, Delegation } from "../src/utils/Types.sol";
import { Counter } from "./utils/Counter.t.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";
/**
 * @title Mixed authority delegation
 * @notice Use a mix of 7702, Hybrid, MultiSig in a delegation chain
 */

contract MixedAuthorityDelegationTest is BaseTest {
    using MessageHashUtils for bytes32;

    Counter public aliceCounterContract; // Owned by Hybrid
    Counter public bobCounterContract; // Owned by MultiSig
    Counter public carolCounterContract; // Owned by EOA
    Counter public daveCounterContract; // Owned by EIP7702Stateless

    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
    }

    function setUp() public override {
        super.setUp();

        // Deploy Counter contracts owned by different authorities
        aliceCounterContract = new Counter(address(users.alice.deleGator)); // Hybrid
        bobCounterContract = new Counter(address(users.bob.deleGator)); // MultiSig
        carolCounterContract = new Counter(users.carol.addr); // EOA
        daveCounterContract = new Counter(users.dave.addr); // EIP7702

        // Deploy Carol's EIP7702 stateless delegator
        deployDeleGator_EIP7702Stateless(users.carol);

        // Deploy Dave's EIP7702 stateless delegator
        deployDeleGator_EIP7702Stateless(users.dave);
    }

    function test_SingleDelegation_MixedAuthorityDelegationTest() public {
        // Carol (EOA) -> Dave (EIP7702)

        // Carol (EOA) delegates to Dave's EIP7702
        Delegation memory carolToDaveDelegation = Delegation({
            delegate: address(users.dave.deleGator),
            delegator: users.carol.addr,
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Carol signs with EOA
        bytes32 carolDelegationHash = EncoderLib._getDelegationHash(carolToDaveDelegation);
        bytes32 domainHash = delegationManager.getDomainHash();
        bytes32 carolTypedDataHash = MessageHashUtils.toTypedDataHash(domainHash, carolDelegationHash);
        carolToDaveDelegation.signature = signHash(SignatureType.EOA, users.carol, carolTypedDataHash);

        // Dave can increment Carol's counter using Carol's delegation
        Delegation[] memory carolToDaveDelegations = new Delegation[](1);
        carolToDaveDelegations[0] = carolToDaveDelegation;

        invokeDelegation_UserOp(
            users.dave,
            carolToDaveDelegations,
            Execution({
                target: address(carolCounterContract),
                value: 0,
                callData: abi.encodeWithSelector(Counter.increment.selector)
            })
        ); // Increment Carol's counter

        console.log(" Carol's counter: %d", carolCounterContract.count());
        assertEq(carolCounterContract.count(), 1);
    }

    function test_delegationChain_MixedAuthorityDelegationTest() public {
        // Create delegation chain:
        // Carol (EOA) -> Dave (EIP7702) -> Bob (MultiSig) -> Alice (Hybrid)

        // 1. Carol (EOA) delegates to Dave's EIP7702
        Delegation memory carolToDaveDelegation = Delegation({
            delegate: address(users.dave.deleGator),
            delegator: users.carol.addr,
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Carol signs with EOA
        bytes32 carolDelegationHash = EncoderLib._getDelegationHash(carolToDaveDelegation);
        bytes32 domainHash = delegationManager.getDomainHash();
        bytes32 carolTypedDataHash = MessageHashUtils.toTypedDataHash(domainHash, carolDelegationHash);
        carolToDaveDelegation.signature = signHash(SignatureType.EOA, users.carol, carolTypedDataHash);

        // 2. Dave (EIP7702) delegates to Bob's MultiSig
        Delegation memory daveToBobDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.dave.deleGator),
            authority: carolDelegationHash,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Dave signs with EIP7702
        bytes32 daveDelegationHash = EncoderLib._getDelegationHash(daveToBobDelegation);
        bytes32 daveTypedDataHash = MessageHashUtils.toTypedDataHash(domainHash, daveDelegationHash);
        daveToBobDelegation.signature = signHash(SignatureType.EOA, users.dave, daveTypedDataHash);

        // 3. Bob's MultiSig delegates to Alice's Hybrid
        Delegation memory bobToAliceDelegation = Delegation({
            delegate: address(users.alice.deleGator),
            delegator: address(users.bob.deleGator),
            authority: daveDelegationHash,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Bob's MultiSig signs
        bytes32 bobDelegationHash = EncoderLib._getDelegationHash(bobToAliceDelegation);
        bytes32 bobTypedDataHash = MessageHashUtils.toTypedDataHash(domainHash, bobDelegationHash);
        bobToAliceDelegation.signature = signHash(SignatureType.MultiSig, users.bob, bobTypedDataHash);

        // Dave can increment Carol's counter using Carol's delegation
        Delegation[] memory carolToDaveDelegations = new Delegation[](1);
        carolToDaveDelegations[0] = carolToDaveDelegation;

        invokeDelegation_UserOp(
            users.dave,
            carolToDaveDelegations,
            Execution({
                target: address(carolCounterContract),
                value: 0,
                callData: abi.encodeWithSelector(Counter.increment.selector)
            })
        ); // Increment Carol's counter

        console.log(" Carol's counter: %d", carolCounterContract.count());
        assertEq(carolCounterContract.count(), 1);

        // Bob can increment Carol's counter using Dave's delegation
        Delegation[] memory daveToBobDelegations = new Delegation[](2);
        daveToBobDelegations[0] = daveToBobDelegation;
        daveToBobDelegations[1] = carolToDaveDelegation;
        invokeDelegation_UserOp(
            users.bob,
            daveToBobDelegations,
            Execution({
                target: address(carolCounterContract),
                value: 0,
                callData: abi.encodeWithSelector(Counter.increment.selector)
            })
        ); // Increment Dave's counter
        console.log("Carol's counter: %d", carolCounterContract.count());
        assertEq(carolCounterContract.count(), 2);

        // Alice can increment Carol's counter using Bob's delegation
        Delegation[] memory bobToAliceDelegations = new Delegation[](3);
        bobToAliceDelegations[0] = bobToAliceDelegation;
        bobToAliceDelegations[1] = daveToBobDelegation;
        bobToAliceDelegations[2] = carolToDaveDelegation;
        invokeDelegation_UserOp(
            users.alice,
            bobToAliceDelegations,
            Execution({
                target: address(carolCounterContract),
                value: 0,
                callData: abi.encodeWithSelector(Counter.increment.selector)
            })
        ); // Increment Bob's counter
        console.log(" Carol's counter: %d", carolCounterContract.count());
        assertEq(carolCounterContract.count(), 3);
    }
}
