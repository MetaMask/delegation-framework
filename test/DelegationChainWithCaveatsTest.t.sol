// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { Execution, PackedUserOperation } from "../src/utils/Types.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { EXECUTE_SINGULAR_SIGNATURE } from "./utils/Constants.sol";
import { CounterWithReceive } from "./utils/CounterWithReceive.t.sol";
import { Caveat, Delegation } from "../src/utils/Types.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { ValueLteEnforcer } from "../src/enforcers/ValueLteEnforcer.sol";
import { TimestampEnforcer } from "../src/enforcers/TimestampEnforcer.sol";
import { AllowedTargetsEnforcer } from "../src/enforcers/AllowedTargetsEnforcer.sol";
import { AllowedMethodsEnforcer } from "../src/enforcers/AllowedMethodsEnforcer.sol";
import "forge-std/console.sol";

contract DelegationChainWithCaveatsTest is BaseTest {
    using MessageHashUtils for bytes32;

    CounterWithReceive public aliceDeleGatorCounter;
    ValueLteEnforcer public valueEnforcer;
    TimestampEnforcer public timestampEnforcer;
    AllowedMethodsEnforcer public methodsEnforcer;
    AllowedTargetsEnforcer public targetsEnforcer;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();

        aliceDeleGatorCounter = new CounterWithReceive(address(users.alice.deleGator));
        // can receive eth

        valueEnforcer = new ValueLteEnforcer();
        timestampEnforcer = new TimestampEnforcer();
        methodsEnforcer = new AllowedMethodsEnforcer();
        targetsEnforcer = new AllowedTargetsEnforcer();
    }

    function test_threeLevel_delegationChain_withCaveats() public {
        // Create delegation from Alice to Bob
        // Alice allows Bob to spend max 5 ETH and only call specific methods
        Caveat[] memory aliceCaveats = new Caveat[](2);
        aliceCaveats[0] = Caveat({ enforcer: address(valueEnforcer), terms: abi.encode(5 ether), args: "" });
        aliceCaveats[1] =
            Caveat({ enforcer: address(methodsEnforcer), terms: abi.encodePacked(CounterWithReceive.increment.selector), args: "" });

        Delegation memory aliceToBob = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: aliceCaveats,
            salt: 0,
            signature: ""
        });

        // Sign Alice's delegation
        aliceToBob = signDelegation(users.alice, aliceToBob);
        bytes32 aliceToBobHash = EncoderLib._getDelegationHash(aliceToBob);

        // Create delegation from Bob to Carol
        // Bob allows Carol to spend max 2 ETH and restricts targets
        Caveat[] memory bobCaveats = new Caveat[](2);
        bobCaveats[0] = Caveat({ enforcer: address(valueEnforcer), terms: abi.encode(2 ether), args: "" });
        bobCaveats[1] =
            Caveat({ enforcer: address(targetsEnforcer), terms: abi.encodePacked(address(aliceDeleGatorCounter)), args: "" });

        Delegation memory bobToCarol = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: aliceToBobHash,
            caveats: bobCaveats,
            salt: 0,
            signature: ""
        });

        // Sign Bob's delegation
        bobToCarol = signDelegation(users.bob, bobToCarol);
        bytes32 bobToCarolHash = EncoderLib._getDelegationHash(bobToCarol);

        // Create delegation from Carol to Dave
        // Carol allows Dave to spend max 1 ETH and restricts with a time window
        Caveat[] memory carolCaveats = new Caveat[](2);
        carolCaveats[0] = Caveat({ enforcer: address(valueEnforcer), terms: abi.encode(1 ether), args: "" });
        carolCaveats[1] = Caveat({
            enforcer: address(timestampEnforcer),
            terms: abi.encodePacked(uint128(block.timestamp), uint128(block.timestamp + 1 hours)),
            args: ""
        });

        Delegation memory carolToDave = Delegation({
            delegate: address(users.dave.deleGator),
            delegator: address(users.carol.deleGator),
            authority: bobToCarolHash,
            caveats: carolCaveats,
            salt: 0,
            signature: ""
        });

        // Sign Carol's delegation
        carolToDave = signDelegation(users.carol, carolToDave);

        // Now test execution through the complete chain
        // Dave attempting to execute on Alice's account
        Execution memory execution = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0.5 ether,
            callData: abi.encodeWithSelector(CounterWithReceive.increment.selector)
        });

        // Setup the delegation chain correctly
        Delegation[] memory delegations = new Delegation[](3);
        delegations[0] = carolToDave;
        delegations[1] = bobToCarol;
        delegations[2] = aliceToBob;

        vm.warp(block.timestamp + 1); // timestamp works only 1 sec after the start threshold

        invokeDelegation_UserOp(users.dave, delegations, execution);

        // Verify execution succeeded
        // eth balance in the alice counter should be 0.5
        assertEq(address(aliceDeleGatorCounter).balance, 0.5 ether, "Alice's counter balance should be 0.5");
        assertEq(aliceDeleGatorCounter.count(), 1, "Alice's counter should have been incremented");
    }

    function test_threeLevel_delegationChain_Fail_withCaveats() public {
        // Create delegation from Alice to Bob
        // Alice allows Bob to spend max 5 ETH and only call specific methods
        Caveat[] memory aliceCaveats = new Caveat[](2);
        aliceCaveats[0] = Caveat({ enforcer: address(valueEnforcer), terms: abi.encode(5 ether), args: "" });
        aliceCaveats[1] =
            Caveat({ enforcer: address(methodsEnforcer), terms: abi.encodePacked(CounterWithReceive.increment.selector), args: "" });

        Delegation memory aliceToBob = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: aliceCaveats,
            salt: 0,
            signature: ""
        });

        // Sign Alice's delegation
        aliceToBob = signDelegation(users.alice, aliceToBob);
        bytes32 aliceToBobHash = EncoderLib._getDelegationHash(aliceToBob);

        // Create delegation from Bob to Carol
        // Bob allows Carol to spend max 2 ETH and restricts targets
        Caveat[] memory bobCaveats = new Caveat[](2);
        bobCaveats[0] = Caveat({ enforcer: address(valueEnforcer), terms: abi.encode(2 ether), args: "" });
        bobCaveats[1] =
            Caveat({ enforcer: address(targetsEnforcer), terms: abi.encodePacked(address(aliceDeleGatorCounter)), args: "" });

        Delegation memory bobToCarol = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: aliceToBobHash,
            caveats: bobCaveats,
            salt: 0,
            signature: ""
        });

        // Sign Bob's delegation
        bobToCarol = signDelegation(users.bob, bobToCarol);
        bytes32 bobToCarolHash = EncoderLib._getDelegationHash(bobToCarol);

        // Create delegation from Carol to Dave
        // Carol allows Dave to spend max 1 ETH and restricts with a time window
        Caveat[] memory carolCaveats = new Caveat[](2);
        carolCaveats[0] = Caveat({ enforcer: address(valueEnforcer), terms: abi.encode(1 ether), args: "" });
        carolCaveats[1] = Caveat({
            enforcer: address(timestampEnforcer),
            terms: abi.encodePacked(uint128(block.timestamp), uint128(block.timestamp + 1 hours)),
            args: ""
        });

        Delegation memory carolToDave = Delegation({
            delegate: address(users.dave.deleGator),
            delegator: address(users.carol.deleGator),
            authority: bobToCarolHash,
            caveats: carolCaveats,
            salt: 0,
            signature: ""
        });

        // Sign Carol's delegation
        carolToDave = signDelegation(users.carol, carolToDave);

        // Now test execution through the complete chain
        Execution memory execution = Execution({
            // Dave attempting to execute on Alice's account
            target: address(aliceDeleGatorCounter),
            value: 1.5 ether,
            callData: abi.encodeWithSelector(CounterWithReceive.increment.selector)
        });

        //the above execution should fail because Carol has only given Dave ability to spend 1 ETH

        // Setup the delegation chain correctly
        Delegation[] memory delegations = new Delegation[](3);
        delegations[0] = carolToDave;
        delegations[1] = bobToCarol;
        delegations[2] = aliceToBob;

        vm.warp(block.timestamp + 1); // timestamp works only 1 sec after the start threshold

        invokeDelegation_UserOp(users.dave, delegations, execution);

        // These assertions should not run because the operation should revert
        // But if they do run, they should fail
        assertEq(address(aliceDeleGatorCounter).balance, 0, "Counter should not receive any ETH");
        assertEq(aliceDeleGatorCounter.count(), 0, "Counter should not be incremented");
    }
}
