// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { Execution, Caveat, Delegation } from "../src/utils/Types.sol";
import { Counter } from "./utils/Counter.t.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { DeleGatorCore } from "../src/DeleGatorCore.sol";
import { HybridDeleGator } from "../src/HybridDeleGator.sol";

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

        users.bob.deleGator = DeleGatorCore(payable(deployDeleGator_MultiSig(users.bob)));
        vm.deal(address(users.bob.deleGator), 10 ether);

        deployDeleGator_EIP7702Stateless(users.carol);
        deployDeleGator_EIP7702Stateless(users.dave);

        // Deploy Counter contracts owned by different authorities
        aliceCounterContract = new Counter(address(users.alice.deleGator)); // Hybrid
        bobCounterContract = new Counter(address(users.bob.deleGator)); // MultiSig
        carolCounterContract = new Counter(users.carol.addr); // EOA
        daveCounterContract = new Counter(users.dave.addr); // EIP7702
    }

    // Carol (EOA EIP7702) -> Dave (Hybrid)
    function test_SingleDelegation_MixedAuthorityDelegationTest() public {
        address delegate_ = address(users.dave.deleGator);
        address delegator_ = users.carol.addr;

        // Verify delegate is hybrid and delegator is EIP7702 stateless
        assertEq(HybridDeleGator(payable(delegate_)).NAME(), "HybridDeleGator");
        assertEq(EIP7702StatelessDeleGator(payable(delegator_)).NAME(), "EIP7702StatelessDeleGator");

        // Carol (EOA EIP7702) delegates to Dave's EIP7702
        Delegation memory carolToDaveDelegation_ = Delegation({
            delegate: delegate_,
            delegator: delegator_,
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Carol signs with EOA
        bytes32 carolDelegationHash_ = EncoderLib._getDelegationHash(carolToDaveDelegation_);
        bytes32 domainHash_ = delegationManager.getDomainHash();
        bytes32 carolTypedDataHash_ = MessageHashUtils.toTypedDataHash(domainHash_, carolDelegationHash_);
        carolToDaveDelegation_.signature = signHash(SignatureType.EOA, users.carol, carolTypedDataHash_);

        // Dave can increment Carol's counter using Carol's delegation
        Delegation[] memory carolToDaveDelegations__ = new Delegation[](1);
        carolToDaveDelegations__[0] = carolToDaveDelegation_;

        // Increment Carol's counter
        invokeDelegation_UserOp(
            users.dave,
            carolToDaveDelegations__,
            Execution({
                target: address(carolCounterContract),
                value: 0,
                callData: abi.encodeWithSelector(Counter.increment.selector)
            })
        );

        assertEq(carolCounterContract.count(), 1, "The counter should have been incremented");
    }

    // Create delegation chain:
    // Carol (EIP7702) -> Dave (EIP7702) -> Bob (MultiSig) -> Alice (Hybrid)
    function test_delegationChain_MixedAuthorityDelegationTest() public {
        address delegate_ = address(users.dave.deleGator);
        address delegator_ = users.carol.addr;

        // Verify delegate is hybrid and delegator is EIP7702 stateless
        assertEq(HybridDeleGator(payable(delegate_)).NAME(), "HybridDeleGator");
        assertEq(EIP7702StatelessDeleGator(payable(delegator_)).NAME(), "EIP7702StatelessDeleGator");

        // 1. Carol (EOA) delegates to Dave's EIP7702
        Delegation memory carolToDaveDelegation = Delegation({
            delegate: delegate_,
            delegator: delegator_,
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

        delegate_ = address(users.bob.deleGator);
        delegator_ = address(users.dave.deleGator);

        // Verify delegate is multisig and delegator is hybrid
        assertEq(HybridDeleGator(payable(delegate_)).NAME(), "MultiSigDeleGator", "1");
        assertEq(EIP7702StatelessDeleGator(payable(delegator_)).NAME(), "HybridDeleGator");

        //  Dave (EIP7702) delegates to Bob's MultiSig
        Delegation memory daveToBobDelegation = Delegation({
            delegate: delegate_,
            delegator: delegator_,
            authority: carolDelegationHash,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Dave signs with EIP7702
        bytes32 daveDelegationHash_ = EncoderLib._getDelegationHash(daveToBobDelegation);
        bytes32 daveTypedDataHash_ = MessageHashUtils.toTypedDataHash(domainHash, daveDelegationHash_);
        daveToBobDelegation.signature = signHash(SignatureType.EOA, users.dave, daveTypedDataHash_);

        delegate_ = address(users.alice.deleGator);
        delegator_ = address(users.bob.deleGator);

        // Verify delegate is multisig and delegator is hybrid
        assertEq(HybridDeleGator(payable(delegate_)).NAME(), "HybridDeleGator");
        assertEq(EIP7702StatelessDeleGator(payable(delegator_)).NAME(), "MultiSigDeleGator", "2");

        // Bob's MultiSig delegates to Alice's Hybrid
        Delegation memory bobToAliceDelegation_ = Delegation({
            delegate: delegate_,
            delegator: delegator_,
            authority: daveDelegationHash_,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Bob's MultiSig signs
        bytes32 bobDelegationHash_ = EncoderLib._getDelegationHash(bobToAliceDelegation_);
        bytes32 bobTypedDataHash_ = MessageHashUtils.toTypedDataHash(domainHash, bobDelegationHash_);
        bobToAliceDelegation_.signature = signHash(SignatureType.MultiSig, users.bob, bobTypedDataHash_);

        // Dave can increment Carol's counter using Carol's delegation
        Delegation[] memory carolToDaveDelegations_ = new Delegation[](1);
        carolToDaveDelegations_[0] = carolToDaveDelegation;

        Execution memory execution_ = Execution({
            target: address(carolCounterContract),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        invokeDelegation_UserOp(users.dave, carolToDaveDelegations_, execution_); // Increment Carol's counter

        assertEq(carolCounterContract.count(), 1);

        // Bob can increment Carol's counter using Dave's delegation
        Delegation[] memory daveToBobDelegations_ = new Delegation[](2);
        daveToBobDelegations_[0] = daveToBobDelegation;
        daveToBobDelegations_[1] = carolToDaveDelegation;

        IMPLEMENTATION = Implementation.MultiSig;
        SIGNATURE_TYPE = SignatureType.EOA;
        invokeDelegation_UserOp(users.bob, daveToBobDelegations_, execution_); // Increment Dave's counter
        assertEq(carolCounterContract.count(), 2);

        // Alice can increment Carol's counter using Bob's delegation
        Delegation[] memory completeDelegationChain_ = new Delegation[](3);
        completeDelegationChain_[0] = bobToAliceDelegation_;
        completeDelegationChain_[1] = daveToBobDelegation;
        completeDelegationChain_[2] = carolToDaveDelegation;
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
        invokeDelegation_UserOp(users.alice, completeDelegationChain_, execution_); // Increment Bob's counter
        assertEq(carolCounterContract.count(), 3);
    }
}
