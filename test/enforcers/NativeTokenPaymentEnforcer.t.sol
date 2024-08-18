// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Action, Caveat, Delegation } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { NativeTokenPaymentEnforcer } from "../../src/enforcers/NativeTokenPaymentEnforcer.sol";
import { NativeTokenTransferAmountEnforcer } from "../../src/enforcers/NativeTokenTransferAmountEnforcer.sol";
import { ArgsEqualityCheckEnforcer } from "../../src/enforcers/ArgsEqualityCheckEnforcer.sol";
import { LimitedCallsEnforcer } from "../../src/enforcers/LimitedCallsEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Counter } from "../utils/Counter.t.sol";

contract NativeTokenPaymentEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////// Set up //////////////////////
    NativeTokenPaymentEnforcer public nativeTokenPaymentEnforcer;
    NativeTokenTransferAmountEnforcer public nativeTokenTransferAmountEnforcer;
    LimitedCallsEnforcer public limitedCallsEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    ArgsEqualityCheckEnforcer public argsEqualityCheckEnforcer;

    function setUp() public override {
        super.setUp();
        nativeTokenTransferAmountEnforcer = new NativeTokenTransferAmountEnforcer();
        vm.label(address(nativeTokenTransferAmountEnforcer), "Native Token Transfer Amount Enforcer");
        argsEqualityCheckEnforcer = new ArgsEqualityCheckEnforcer();
        vm.label(address(argsEqualityCheckEnforcer), "Args Equality Check Enforcer");
        nativeTokenPaymentEnforcer =
            new NativeTokenPaymentEnforcer(IDelegationManager(address(delegationManager)), address(argsEqualityCheckEnforcer));
        vm.label(address(nativeTokenPaymentEnforcer), "Native Payment Enforcer");
        limitedCallsEnforcer = new LimitedCallsEnforcer();
        vm.label(address(limitedCallsEnforcer), "Limited Calls Enforcer");
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        vm.label(address(allowedTargetsEnforcer), "Allowed Targets Enforcer");
    }

    //////////////////// Valid cases //////////////////////

    // Should decode the terms
    function test_decodesTheTerms() public {
        address recipient_ = address(users.alice.deleGator);
        uint256 amount_ = 1 ether;
        bytes memory terms_ = abi.encodePacked(recipient_, amount_);

        (address obtainedRecipient_, uint256 obtainedAmount_) = nativeTokenPaymentEnforcer.getTermsInfo(terms_);
        assertEq(obtainedRecipient_, recipient_);
        assertEq(obtainedAmount_, amount_);
    }

    // Should SUCCEED if the payment is valid
    function test_validationPassWithValidPayment() public {
        Delegation[] memory paymentDelegations_ = new Delegation[](1);
        paymentDelegations_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        paymentDelegations_[0] = signDelegation(users.bob, paymentDelegations_[0]);

        bytes memory args_ = abi.encode(paymentDelegations_);

        address recipient_ = address(users.alice.deleGator);
        bytes memory terms_ = abi.encodePacked(recipient_, uint256(1 ether));

        (bytes32 delegationHash_,) = _getExampleDelegation(terms_, hex"");

        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        vm.startPrank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(nativeTokenPaymentEnforcer));
        emit NativeTokenPaymentEnforcer.ValidatedPayment(
            address(delegationManager), delegationHash_, recipient_, address(users.alice.deleGator), address(0), 1 ether
        );

        nativeTokenPaymentEnforcer.afterHook(terms_, args_, action_, delegationHash_, address(users.alice.deleGator), address(0));
    }

    // Should SUCCEED to make the payment with a redelegation
    function test_validationPassWithValidRedelegationPayment() public {
        Delegation[] memory paymentDelegations_ = new Delegation[](2);
        paymentDelegations_[1] = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.carol.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        paymentDelegations_[1] = signDelegation(users.carol, paymentDelegations_[1]);

        paymentDelegations_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(paymentDelegations_[1]),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        paymentDelegations_[0] = signDelegation(users.bob, paymentDelegations_[0]);

        bytes memory args_ = abi.encode(paymentDelegations_);

        address recipient_ = address(users.alice.deleGator);
        bytes memory terms_ = abi.encodePacked(recipient_, uint256(1 ether));

        (bytes32 delegationHash_,) = _getExampleDelegation(terms_, hex"");

        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        vm.startPrank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(nativeTokenPaymentEnforcer));
        emit NativeTokenPaymentEnforcer.ValidatedPayment(
            address(delegationManager), delegationHash_, recipient_, address(users.alice.deleGator), address(0), 1 ether
        );

        nativeTokenPaymentEnforcer.afterHook(terms_, args_, action_, delegationHash_, address(users.alice.deleGator), address(0));
    }

    // Should only overwrite the args of the args equality enforcer
    function test_onlyOverwriteAllowanceEnforcerArgs() public {
        // The terms indicate to send 1 ether to Alice.
        address recipient_ = address(users.alice.deleGator);
        bytes memory paymentTerms_ = abi.encodePacked(recipient_, uint256(1 ether));
        (bytes32 delegationHash_, Delegation memory paidDelegation_) = _getExampleDelegation(paymentTerms_, hex"");

        Delegation[] memory paidDelegations_ = new Delegation[](1);
        paidDelegations_[0] = paidDelegation_;

        // Create the Allowance enforcer
        uint256 allowance_ = 1 ether;
        bytes memory allowanceTerms_ = abi.encode(allowance_);
        bytes memory argsTerms_ = abi.encode(delegationHash_);

        // The args of the nativeTokenTransferAmountEnforcer will ovewriten
        // The limitedCallsEnforcer and allowedTargetsEnforcer should stay the same
        Caveat[] memory paymentCaveats_ = new Caveat[](4);
        paymentCaveats_[0] = Caveat({ args: hex"", enforcer: address(nativeTokenTransferAmountEnforcer), terms: allowanceTerms_ });
        paymentCaveats_[1] = Caveat({ args: hex"", enforcer: address(limitedCallsEnforcer), terms: abi.encodePacked(uint256(10)) });
        paymentCaveats_[2] = Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(recipient_) });
        paymentCaveats_[3] = Caveat({ args: hex"", enforcer: address(argsEqualityCheckEnforcer), terms: argsTerms_ });

        // Create payment delegation from Bob to NativeTokenPaymentEnforcer
        Delegation[] memory paymentDelegations_ = new Delegation[](1);
        paymentDelegations_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: paymentCaveats_,
            salt: 0,
            signature: hex""
        });

        paymentDelegations_[0] = signDelegation(users.bob, paymentDelegations_[0]);

        // The args contain the payment delegation to redeem
        bytes memory args_ = abi.encode(paymentDelegations_);

        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        vm.startPrank(address(delegationManager));

        // Expect this to be overwritten in the event
        paymentDelegations_[0].caveats[3].args = abi.encodePacked(delegationHash_);

        // Checks the args of the caveats in the DelegationManager event
        vm.expectEmit(true, true, true, true, address(delegationManager));
        emit IDelegationManager.RedeemedDelegation(
            paymentDelegations_[0].delegator, address(nativeTokenPaymentEnforcer), paymentDelegations_[0]
        );
        nativeTokenPaymentEnforcer.afterHook(
            paymentTerms_, args_, action_, delegationHash_, address(users.alice.deleGator), address(0)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    // should FAIL to get terms info when passing an invalid terms length
    function test_getTermsInfoFailsForInvalidLength() public {
        vm.expectRevert("NativeTokenPaymentEnforcer:invalid-terms-length");
        nativeTokenPaymentEnforcer.getTermsInfo(bytes("1"));
    }

    // Should FAIL if the payment is insufficient
    function test_validationFailWithInsufficientPayment() public {
        address mockDelegationManager_ = address(new MockDelegationManager());
        // Overriding the delegation manager for testing purposes
        nativeTokenPaymentEnforcer =
            new NativeTokenPaymentEnforcer(IDelegationManager(mockDelegationManager_), address(nativeTokenTransferAmountEnforcer));
        vm.label(address(nativeTokenPaymentEnforcer), "Native Paid Enforcer");

        Delegation[] memory paymentDelegations_ = new Delegation[](1);
        paymentDelegations_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        paymentDelegations_[0] = signDelegation(users.bob, paymentDelegations_[0]);

        // Using a mock delegation manager
        bytes memory args_ = abi.encode(paymentDelegations_);

        address recipient_ = address(users.alice.deleGator);
        bytes memory terms_ = abi.encodePacked(recipient_, uint256(1 ether));

        (bytes32 delegationHash_,) = _getExampleDelegation(terms_, hex"");

        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        vm.startPrank(mockDelegationManager_);
        vm.expectRevert("NativeTokenPaymentEnforcer:payment-not-received");
        nativeTokenPaymentEnforcer.afterHook(terms_, args_, action_, delegationHash_, address(0), address(0));
    }

    // Should FAIL if the sender is different from the delegation manager.
    function test_validationFailWhenInvalidSender() public {
        // Using an invalid sender, it must be the delegation manager
        vm.startPrank(address(users.bob.deleGator));
        vm.expectRevert("NativeTokenPaymentEnforcer:only-delegation-manager");
        nativeTokenPaymentEnforcer.afterHook(hex"", hex"", new Action[](1)[0], bytes32(0), address(0), address(0));
    }

    function test_chargePaymentFromAllowance() public {
        // The terms indicate to send 1 ether to Alice.
        address recipient_ = address(users.alice.deleGator);
        bytes memory paymentTerms_ = abi.encodePacked(recipient_, uint256(1 ether));
        (bytes32 delegationHash_, Delegation memory paidDelegation_) = _getExampleDelegation(paymentTerms_, hex"");

        Delegation[] memory paidDelegations_ = new Delegation[](1);
        paidDelegations_[0] = paidDelegation_;

        // Create the Allowance enforcer
        uint256 allowance_ = 1 ether;
        bytes memory allowanceTerms_ = abi.encode(allowance_);
        bytes memory argsTerms_ = abi.encode(delegationHash_);

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(nativeTokenTransferAmountEnforcer), terms: allowanceTerms_ });
        caveats_[1] = Caveat({ args: hex"", enforcer: address(argsEqualityCheckEnforcer), terms: argsTerms_ });

        // Create payment delegation from Bob to NativeTokenPaymentEnforcer
        Delegation[] memory paymentDelegations_ = new Delegation[](1);
        paymentDelegations_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        paymentDelegations_[0] = signDelegation(users.bob, paymentDelegations_[0]);

        // The args contain the payment delegation to redeem
        bytes memory args_ = abi.encode(paymentDelegations_);

        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        uint256 aliceBalanceBefore_ = address(users.alice.deleGator).balance;

        assertEq(aliceDeleGatorCounter.count(), 0);

        // Pass the delegation payment in the args.
        paidDelegations_[0].caveats[0].args = args_;
        invokeDelegation_UserOp(users.bob, paidDelegations_, action_);

        assertEq(aliceDeleGatorCounter.count(), 1);

        // Alice received the payment
        assertEq(address(users.alice.deleGator).balance, aliceBalanceBefore_ + 1 ether);
    }

    function test_delegationFrontRunning() public {
        address recipient_ = address(users.alice.deleGator);
        // The original terms indicating to send 1 ether to Alice as the payment for Bob
        bytes memory originalPaymentTerms_ = abi.encodePacked(recipient_, uint256(1 ether));

        (, Delegation memory originalPaidDelegation_) = _getExampleDelegation(originalPaymentTerms_, hex"");
        Delegation[] memory originalPaidDelegations_ = new Delegation[](1);
        originalPaidDelegations_[0] = originalPaidDelegation_;

        // The malicious terms indicating to send 1 ether to Alice as the payment for Carol
        bytes memory maliciousPaymentTerms_ = abi.encodePacked(recipient_, uint256(1 ether));
        (, Delegation memory maliciousPaidDelegation_) = _getMaliciousDelegation(maliciousPaymentTerms_, hex"");
        Delegation[] memory maliciousPaidDelegations_ = new Delegation[](1);
        maliciousPaidDelegations_[0] = maliciousPaidDelegation_;

        // Create the Allowance enforcer (No args enforcer comparison, prone to front-running)
        uint256 allowance_ = 1 ether;
        bytes memory allowanceTerms_ = abi.encode(allowance_);
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(nativeTokenTransferAmountEnforcer), terms: allowanceTerms_ });

        // Create payment delegation from Bob to NativeTokenPaymentEnforcer
        // This delegation is public any one could front-running it
        // Even though Bob created this delegation to pay for his Alice delegation, Carol uses this delegation to pay for her.
        Delegation[] memory paymentDelegations_ = new Delegation[](1);
        paymentDelegations_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        paymentDelegations_[0] = signDelegation(users.bob, paymentDelegations_[0]);

        // The args contain the payment delegation to redeem
        bytes memory argsWithBobPayment_ = abi.encode(paymentDelegations_);

        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        uint256 aliceBalanceBefore_ = address(users.alice.deleGator).balance;

        assertEq(aliceDeleGatorCounter.count(), 0);

        // Pass the delegation payment in the args.
        maliciousPaidDelegations_[0].caveats[0].args = argsWithBobPayment_;
        invokeDelegation_UserOp(users.carol, maliciousPaidDelegations_, action_);
        assertEq(aliceDeleGatorCounter.count(), 1);

        // Alice received the payment
        assertEq(address(users.alice.deleGator).balance, aliceBalanceBefore_ + 1 ether);

        // Pass the delegation payment in the args.
        originalPaidDelegations_[0].caveats[0].args = argsWithBobPayment_;
        invokeDelegation_UserOp(users.bob, originalPaidDelegations_, action_);
        // The execution did not work because the allowance has already been used.
        assertEq(aliceDeleGatorCounter.count(), 1);
    }

    function test_delegationArgsEnforcerPreventFrontRunning() public {
        // The original terms indicating to send 1 ether to Alice as the payment for Bob
        address recipient_ = address(users.alice.deleGator);
        bytes memory originalPaymentTerms_ = abi.encodePacked(recipient_, uint256(1 ether));

        (bytes32 originalPaidDelegationHash_, Delegation memory originalPaidDelegation_) =
            _getExampleDelegation(originalPaymentTerms_, hex"");
        Delegation[] memory originalPaidDelegations_ = new Delegation[](1);
        originalPaidDelegations_[0] = originalPaidDelegation_;

        // The malicious terms indicating to send 1 ether to Alice as the payment for Carol
        bytes memory maliciousPaymentTerms_ = abi.encodePacked(recipient_, uint256(1 ether));

        (, Delegation memory maliciousPaidDelegation_) = _getMaliciousDelegation(maliciousPaymentTerms_, hex"");
        Delegation[] memory maliciousPaidDelegations_ = new Delegation[](1);
        maliciousPaidDelegations_[0] = maliciousPaidDelegation_;

        // Create the Allowance enforcer (Combined with args enforcer, prevent front-running)
        uint256 allowance_ = 1 ether;
        bytes memory allowanceTerms_ = abi.encode(allowance_);
        bytes memory argsTerms_ = abi.encode(originalPaidDelegationHash_);

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(nativeTokenTransferAmountEnforcer), terms: allowanceTerms_ });
        caveats_[1] = Caveat({ args: hex"", enforcer: address(argsEqualityCheckEnforcer), terms: argsTerms_ });

        // Create payment delegation from Bob to NativeTokenPaymentEnforcer
        // This delegation is public any one could front-running it but it is protected with the args enforcer
        // Even though Bob created this delegation to pay for his Alice delegation, Carol tries to use it to pay for her.
        Delegation[] memory paymentDelegations_ = new Delegation[](1);
        paymentDelegations_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        paymentDelegations_[0] = signDelegation(users.bob, paymentDelegations_[0]);

        // The args contain the payment delegation to redeem
        bytes memory argsWithBobPayment_ = abi.encode(paymentDelegations_);

        Action memory action_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });

        uint256 aliceBalanceBefore_ = address(users.alice.deleGator).balance;

        assertEq(aliceDeleGatorCounter.count(), 0);

        // Pass the delegation payment in the args.
        maliciousPaidDelegations_[0].caveats[0].args = argsWithBobPayment_;
        invokeDelegation_UserOp(users.carol, maliciousPaidDelegations_, action_);
        // The execution did not work because the allowance fails due to the invalid args.
        assertEq(aliceDeleGatorCounter.count(), 0);
        // Alice did not receive the payment
        assertEq(address(users.alice.deleGator).balance, aliceBalanceBefore_);

        // Pass the delegation payment in the args.
        originalPaidDelegations_[0].caveats[0].args = argsWithBobPayment_;
        invokeDelegation_UserOp(users.bob, originalPaidDelegations_, action_);
        // The execution works well with a proper args
        assertEq(aliceDeleGatorCounter.count(), 1);
        // Alice received the payment
        assertEq(address(users.alice.deleGator).balance, aliceBalanceBefore_ + 1 ether);
    }

    function _getExampleDelegation(
        bytes memory inputTerms_,
        bytes memory args_
    )
        internal
        view
        returns (bytes32 delegationHash_, Delegation memory delegation_)
    {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: args_, enforcer: address(nativeTokenPaymentEnforcer), terms: inputTerms_ });

        delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);
        delegationHash_ = EncoderLib._getDelegationHash(delegation_);
    }

    function _getMaliciousDelegation(
        bytes memory inputTerms_,
        bytes memory args_
    )
        internal
        view
        returns (bytes32 delegationHash_, Delegation memory delegation_)
    {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: args_, enforcer: address(nativeTokenPaymentEnforcer), terms: inputTerms_ });

        delegation_ = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);
        delegationHash_ = EncoderLib._getDelegationHash(delegation_);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(nativeTokenPaymentEnforcer));
    }
}

/// @dev This contract is used for testing a case where the redeemDelegation() function doesn't work as expected
contract MockDelegationManager {
    function redeemDelegation(bytes[] calldata _permissionContexts, Action[] calldata _actions) external {
        // Does not do anything, the action is not processed
    }
}
