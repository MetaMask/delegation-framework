// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { Execution } from "../src/utils/Types.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { CounterWithReceive } from "./utils/CounterWithReceive.t.sol";
import { Caveat, Delegation } from "../src/utils/Types.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { ValueLteEnforcer } from "../src/enforcers/ValueLteEnforcer.sol";
import { TimestampEnforcer } from "../src/enforcers/TimestampEnforcer.sol";
import { AllowedTargetsEnforcer } from "../src/enforcers/AllowedTargetsEnforcer.sol";
import { AllowedMethodsEnforcer } from "../src/enforcers/AllowedMethodsEnforcer.sol";

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
        Caveat[] memory aliceCaveats_ = new Caveat[](2);
        aliceCaveats_[0] = Caveat({ enforcer: address(valueEnforcer), terms: abi.encode(5 ether), args: "" });
        aliceCaveats_[1] =
            Caveat({ enforcer: address(methodsEnforcer), terms: abi.encodePacked(CounterWithReceive.increment.selector), args: "" });

        Delegation memory aliceToBob_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: aliceCaveats_,
            salt: 0,
            signature: ""
        });

        // Sign Alice's delegation
        aliceToBob_ = signDelegation(users.alice, aliceToBob_);
        bytes32 aliceToBobHash_ = EncoderLib._getDelegationHash(aliceToBob_);

        // Create delegation from Bob to Carol
        // Bob allows Carol to spend max 2 ETH and restricts targets
        Caveat[] memory bobCaveats_ = new Caveat[](2);
        bobCaveats_[0] = Caveat({ enforcer: address(valueEnforcer), terms: abi.encode(2 ether), args: "" });
        bobCaveats_[1] =
            Caveat({ enforcer: address(targetsEnforcer), terms: abi.encodePacked(address(aliceDeleGatorCounter)), args: "" });

        Delegation memory bobToCarol_ = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: aliceToBobHash_,
            caveats: bobCaveats_,
            salt: 0,
            signature: ""
        });

        // Sign Bob's delegation
        bobToCarol_ = signDelegation(users.bob, bobToCarol_);
        bytes32 bobToCarolHash_ = EncoderLib._getDelegationHash(bobToCarol_);

        // Create delegation from Carol to Dave
        // Carol allows Dave to spend max 1 ETH and restricts with a time window
        Caveat[] memory carolCaveats_ = new Caveat[](2);
        carolCaveats_[0] = Caveat({ enforcer: address(valueEnforcer), terms: abi.encode(1 ether), args: "" });
        carolCaveats_[1] = Caveat({
            enforcer: address(timestampEnforcer),
            terms: abi.encodePacked(uint128(block.timestamp), uint128(block.timestamp + 1 hours)),
            args: ""
        });

        Delegation memory carolToDave_ = Delegation({
            delegate: address(users.dave.deleGator),
            delegator: address(users.carol.deleGator),
            authority: bobToCarolHash_,
            caveats: carolCaveats_,
            salt: 0,
            signature: ""
        });

        // Sign Carol's delegation
        carolToDave_ = signDelegation(users.carol, carolToDave_);

        // Now test execution through the complete chain
        // Dave attempting to execute on Alice's account
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0.5 ether,
            callData: abi.encodeWithSelector(CounterWithReceive.increment.selector)
        });

        // Setup the delegation chain correctly
        Delegation[] memory delegations = new Delegation[](3);
        delegations[0] = carolToDave_;
        delegations[1] = bobToCarol_;
        delegations[2] = aliceToBob_;

        vm.warp(block.timestamp + 1); // timestamp works only 1 sec after the start threshold

        invokeDelegation_UserOp(users.dave, delegations, execution_);

        // Verify execution succeeded
        // eth balance in the alice counter should be 0.5
        assertEq(address(aliceDeleGatorCounter).balance, 0.5 ether, "Alice's counter balance should be 0.5");
        assertEq(aliceDeleGatorCounter.count(), 1, "Alice's counter should have been incremented");
    }

    function test_threeLevel_delegationChain_Fail_withCaveats() public {
        // Create delegation from Alice to Bob
        // Alice allows Bob to spend max 5 ETH and only call specific methods
        Caveat[] memory aliceCaveats_ = new Caveat[](2);
        aliceCaveats_[0] = Caveat({ enforcer: address(valueEnforcer), terms: abi.encode(5 ether), args: "" });
        aliceCaveats_[1] =
            Caveat({ enforcer: address(methodsEnforcer), terms: abi.encodePacked(CounterWithReceive.increment.selector), args: "" });

        Delegation memory aliceToBob_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: aliceCaveats_,
            salt: 0,
            signature: ""
        });

        // Sign Alice's delegation
        aliceToBob_ = signDelegation(users.alice, aliceToBob_);
        bytes32 aliceToBobHash_ = EncoderLib._getDelegationHash(aliceToBob_);

        // Create delegation from Bob to Carol
        // Bob allows Carol to spend max 2 ETH and restricts targets
        Caveat[] memory bobCaveats_ = new Caveat[](2);
        bobCaveats_[0] = Caveat({ enforcer: address(valueEnforcer), terms: abi.encode(2 ether), args: "" });
        bobCaveats_[1] =
            Caveat({ enforcer: address(targetsEnforcer), terms: abi.encodePacked(address(aliceDeleGatorCounter)), args: "" });

        Delegation memory bobToCarol_ = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: aliceToBobHash_,
            caveats: bobCaveats_,
            salt: 0,
            signature: ""
        });

        // Sign Bob's delegation
        bobToCarol_ = signDelegation(users.bob, bobToCarol_);
        bytes32 bobToCarolHash_ = EncoderLib._getDelegationHash(bobToCarol_);

        // Create delegation from Carol to Dave
        // Carol allows Dave to spend max 1 ETH and restricts with a time window
        Caveat[] memory carolCaveats_ = new Caveat[](2);
        carolCaveats_[0] = Caveat({ enforcer: address(valueEnforcer), terms: abi.encode(1 ether), args: "" });
        carolCaveats_[1] = Caveat({
            enforcer: address(timestampEnforcer),
            terms: abi.encodePacked(uint128(block.timestamp), uint128(block.timestamp + 1 hours)),
            args: ""
        });

        Delegation memory carolToDave_ = Delegation({
            delegate: address(users.dave.deleGator),
            delegator: address(users.carol.deleGator),
            authority: bobToCarolHash_,
            caveats: carolCaveats_,
            salt: 0,
            signature: ""
        });

        // Sign Carol's delegation
        carolToDave_ = signDelegation(users.carol, carolToDave_);

        // Now test execution through the complete chain
        Execution memory execution_ = Execution({
            // Dave attempting to execute on Alice's account
            target: address(aliceDeleGatorCounter),
            value: 1.5 ether,
            callData: abi.encodeWithSelector(CounterWithReceive.increment.selector)
        });

        // the above execution should fail because Carol has only given Dave ability to spend 1 ETH

        // Setup the delegation chain
        Delegation[] memory delegations = new Delegation[](3);
        delegations[0] = carolToDave_;
        delegations[1] = bobToCarol_;
        delegations[2] = aliceToBob_;

        vm.warp(block.timestamp + 1); // timestamp works only 1 sec after the start threshold

        invokeDelegation_UserOp(users.dave, delegations, execution_);

        // These assertions should not run because the operation should revert
        // But if they do run, they should fail
        assertEq(address(aliceDeleGatorCounter).balance, 0, "Counter should not receive any ETH");
        assertEq(aliceDeleGatorCounter.count(), 0, "Counter should not be incremented");
    }
}
