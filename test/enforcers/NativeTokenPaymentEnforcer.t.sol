// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
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

    address public validRedeemer;
    address public invalidRedeemer;
    address public paymentRecipient;
    uint256 public paymentAmount;
    bytes public paymentTerms;
    Execution public execution;
    bytes public executionCalldata;
    bytes public allowanceTerms;
    bytes public argsEnforcerTerms;
    bytes public argsWithBobAllowance;

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
        validRedeemer = address(users.bob.deleGator);
        invalidRedeemer = address(users.carol.deleGator);
        paymentRecipient = address(users.alice.deleGator);
        paymentAmount = 1 ether;
        execution = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });

        executionCalldata = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);
        paymentTerms = abi.encodePacked(paymentRecipient, paymentAmount);
    }

    //////////////////// Valid cases //////////////////////

    // Should set the initialization values correctly
    function test_readInitializationValues() public {
        address delegationManager_ = address(9999999999);
        address argsEnforcer_ = address(8888888888);
        nativeTokenPaymentEnforcer = new NativeTokenPaymentEnforcer(IDelegationManager(delegationManager_), argsEnforcer_);
        assertEq(address(nativeTokenPaymentEnforcer.delegationManager()), delegationManager_);
        assertEq(nativeTokenPaymentEnforcer.argsEqualityCheckEnforcer(), argsEnforcer_);
    }

    // The terms can be decoded with the enforcer
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
        (bytes32 delegationHash_,) = _getExampleDelegation(paymentTerms, hex"");

        (, argsWithBobAllowance) = _getAllowanceDelegation(delegationHash_, address(users.bob.deleGator));

        vm.startPrank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(nativeTokenPaymentEnforcer));
        emit NativeTokenPaymentEnforcer.ValidatedPayment(
            address(delegationManager),
            delegationHash_,
            paymentRecipient,
            address(users.alice.deleGator),
            address(users.bob.deleGator),
            1 ether
        );

        nativeTokenPaymentEnforcer.afterAllHook(
            paymentTerms,
            argsWithBobAllowance,
            singleDefaultMode,
            executionCalldata,
            delegationHash_,
            address(users.alice.deleGator),
            validRedeemer
        );
    }

    // Should SUCCEED to pay with an allowance redelegation
    function test_validationPassWithValidRedelegationAllowance() public {
        (bytes32 delegationHash_,) = _getExampleDelegation(paymentTerms, hex"");

        Delegation[] memory allowanceDelegations_ = new Delegation[](2);
        allowanceDelegations_[1] = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.carol.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        allowanceDelegations_[1] = signDelegation(users.carol, allowanceDelegations_[1]);

        argsEnforcerTerms = abi.encodePacked(delegationHash_, address(users.bob.deleGator));
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(argsEqualityCheckEnforcer), terms: argsEnforcerTerms });

        allowanceDelegations_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(allowanceDelegations_[1]),
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        allowanceDelegations_[0] = signDelegation(users.bob, allowanceDelegations_[0]);

        argsWithBobAllowance = abi.encode(allowanceDelegations_);

        vm.startPrank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(nativeTokenPaymentEnforcer));
        emit NativeTokenPaymentEnforcer.ValidatedPayment(
            address(delegationManager),
            delegationHash_,
            paymentRecipient,
            address(users.alice.deleGator),
            address(users.bob.deleGator),
            1 ether
        );

        nativeTokenPaymentEnforcer.afterAllHook(
            paymentTerms,
            argsWithBobAllowance,
            singleDefaultMode,
            executionCalldata,
            delegationHash_,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
    }

    // Should SUCCEED to overwrite only the args on the args equality enforcer
    function test_onlyOverwriteAllowanceEnforcerArgs() public {
        (bytes32 delegationHash_,) = _getExampleDelegation(paymentTerms, hex"");

        // Create the Allowance enforcer
        allowanceTerms = abi.encode(paymentAmount);
        argsEnforcerTerms = abi.encodePacked(delegationHash_, address(users.bob.deleGator));

        // The args of the nativeTokenTransferAmountEnforcer will be overwritten
        // The limitedCallsEnforcer and allowedTargetsEnforcer should stay the same
        Caveat[] memory allowanceCaveats_ = new Caveat[](4);
        allowanceCaveats_[0] = Caveat({ args: hex"", enforcer: address(argsEqualityCheckEnforcer), terms: argsEnforcerTerms });
        allowanceCaveats_[1] = Caveat({ args: hex"", enforcer: address(nativeTokenTransferAmountEnforcer), terms: allowanceTerms });
        allowanceCaveats_[2] =
            Caveat({ args: hex"", enforcer: address(limitedCallsEnforcer), terms: abi.encodePacked(uint256(10)) });
        allowanceCaveats_[3] = Caveat({
            args: hex"",
            enforcer: address(allowedTargetsEnforcer),
            terms: abi.encodePacked(address(users.alice.deleGator))
        });

        // Create allowance delegation from Bob to NativeTokenPaymentEnforcer
        Delegation[] memory allowanceDelegations_ = new Delegation[](1);
        allowanceDelegations_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: allowanceCaveats_,
            salt: 0,
            signature: hex""
        });

        allowanceDelegations_[0] = signDelegation(users.bob, allowanceDelegations_[0]);

        // The args contain the allowance delegation to redeem
        argsWithBobAllowance = abi.encode(allowanceDelegations_);

        vm.startPrank(address(delegationManager));

        // Expect this to be overwritten in the event
        allowanceDelegations_[0].caveats[0].args = argsEnforcerTerms;

        // Checks the args of the caveats in the DelegationManager event
        vm.expectEmit(true, true, true, true, address(delegationManager));
        emit IDelegationManager.RedeemedDelegation(
            allowanceDelegations_[0].delegator, address(nativeTokenPaymentEnforcer), allowanceDelegations_[0]
        );
        nativeTokenPaymentEnforcer.afterAllHook(
            paymentTerms,
            argsWithBobAllowance,
            singleDefaultMode,
            executionCalldata,
            delegationHash_,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
    }

    // Should FAIL to process the payment if the args equality check enforcer is missing
    function test_paymentFailsIfArgsEnforcerIsMissing() public {
        (bytes32 delegationHash_,) = _getExampleDelegation(paymentTerms, hex"");

        // Create the Allowance enforcer
        allowanceTerms = abi.encode(paymentAmount);

        // Even with other enforcers it should revert if it does not include the args enforcer
        Caveat[] memory allowanceCaveats_ = new Caveat[](3);
        allowanceCaveats_[0] = Caveat({ args: hex"", enforcer: address(nativeTokenTransferAmountEnforcer), terms: allowanceTerms });
        allowanceCaveats_[1] =
            Caveat({ args: hex"", enforcer: address(limitedCallsEnforcer), terms: abi.encodePacked(uint256(10)) });
        allowanceCaveats_[2] = Caveat({
            args: hex"",
            enforcer: address(allowedTargetsEnforcer),
            terms: abi.encodePacked(address(users.alice.deleGator))
        });

        // Create allowance delegation from Bob to NativeTokenPaymentEnforcer
        Delegation[] memory allowanceDelegations_ = new Delegation[](1);
        allowanceDelegations_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: allowanceCaveats_,
            salt: 0,
            signature: hex""
        });

        allowanceDelegations_[0] = signDelegation(users.bob, allowanceDelegations_[0]);

        // The args contain the allowance delegation to redeem
        argsWithBobAllowance = abi.encode(allowanceDelegations_);

        vm.startPrank(address(delegationManager));

        vm.expectRevert("NativeTokenPaymentEnforcer:missing-argsEqualityCheckEnforcer");
        nativeTokenPaymentEnforcer.afterAllHook(
            paymentTerms,
            argsWithBobAllowance,
            singleDefaultMode,
            executionCalldata,
            delegationHash_,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
    }

    // Should FAIL if the allowance delegation is empty
    function test_paymentFailsIfAllowanceDelegationIsEmpty() public {
        (bytes32 delegationHash_,) = _getExampleDelegation(paymentTerms, hex"");

        // This is empty to make it revert
        Delegation[] memory allowanceDelegations_ = new Delegation[](0);

        // The args contain the allowance delegation to redeem
        argsWithBobAllowance = abi.encode(allowanceDelegations_);

        vm.startPrank(address(delegationManager));

        vm.expectRevert("NativeTokenPaymentEnforcer:invalid-allowance-delegations-length");
        nativeTokenPaymentEnforcer.afterAllHook(
            paymentTerms,
            argsWithBobAllowance,
            singleDefaultMode,
            executionCalldata,
            delegationHash_,
            address(users.alice.deleGator),
            address(users.bob.deleGator)
        );
    }

    // Should FAIL if the allowance delegation caveats are empty
    function test_validationFailWithEmptyCaveatsInAllowanceDelegation() public {
        (bytes32 delegationHash_,) = _getExampleDelegation(paymentTerms, hex"");

        Delegation[] memory allowanceDelegations_ = new Delegation[](1);
        allowanceDelegations_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        allowanceDelegations_[0] = signDelegation(users.bob, allowanceDelegations_[0]);
        argsWithBobAllowance = abi.encode(allowanceDelegations_);

        vm.startPrank(address(delegationManager));
        vm.expectRevert("NativeTokenPaymentEnforcer:missing-argsEqualityCheckEnforcer");
        nativeTokenPaymentEnforcer.afterAllHook(
            paymentTerms,
            argsWithBobAllowance,
            singleDefaultMode,
            executionCalldata,
            delegationHash_,
            address(0),
            address(users.bob.deleGator)
        );
    }

    // Should FAIL if the args enforcer is not in the first caveat of the allowance delegation
    function test_validationFailIfArgsEnforcerNotInFirstPlace() public {
        (bytes32 delegationHash_,) = _getExampleDelegation(paymentTerms, hex"");

        Caveat[] memory caveats_ = new Caveat[](2);
        allowanceTerms = abi.encode(paymentAmount);
        argsEnforcerTerms = abi.encodePacked(delegationHash_, address(users.bob.deleGator));
        caveats_[0] = Caveat({ args: hex"", enforcer: address(nativeTokenTransferAmountEnforcer), terms: allowanceTerms });
        caveats_[1] = Caveat({ args: hex"", enforcer: address(argsEqualityCheckEnforcer), terms: argsEnforcerTerms });

        Delegation[] memory allowanceDelegations_ = new Delegation[](1);
        allowanceDelegations_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        allowanceDelegations_[0] = signDelegation(users.bob, allowanceDelegations_[0]);
        argsWithBobAllowance = abi.encode(allowanceDelegations_);

        vm.startPrank(address(delegationManager));
        vm.expectRevert("NativeTokenPaymentEnforcer:missing-argsEqualityCheckEnforcer");
        nativeTokenPaymentEnforcer.afterAllHook(
            paymentTerms,
            argsWithBobAllowance,
            singleDefaultMode,
            executionCalldata,
            delegationHash_,
            address(0),
            address(users.bob.deleGator)
        );
    }

    // should FAIL to get terms info when passing invalid terms length
    function test_getTermsInfoFailsForInvalidLength() public {
        vm.expectRevert("NativeTokenPaymentEnforcer:invalid-terms-length");
        nativeTokenPaymentEnforcer.getTermsInfo(bytes("1"));
    }

    // Should FAIL if the payment is insufficient
    function test_validationFailWithInsufficientPayment() public {
        address mockDelegationManager_ = address(new MockDelegationManager());
        // Overwriting the delegation manager for testing purposes
        nativeTokenPaymentEnforcer =
            new NativeTokenPaymentEnforcer(IDelegationManager(mockDelegationManager_), address(argsEqualityCheckEnforcer));
        vm.label(address(nativeTokenPaymentEnforcer), "Native Paid Enforcer");

        (bytes32 delegationHash_,) = _getExampleDelegation(paymentTerms, hex"");

        (, argsWithBobAllowance) = _getAllowanceDelegation(delegationHash_, address(users.bob.deleGator));

        vm.startPrank(mockDelegationManager_);
        vm.expectRevert("NativeTokenPaymentEnforcer:payment-not-received");
        nativeTokenPaymentEnforcer.afterAllHook(
            paymentTerms,
            argsWithBobAllowance,
            singleDefaultMode,
            executionCalldata,
            delegationHash_,
            address(0),
            address(users.bob.deleGator)
        );
    }

    // Should FAIL if the sender is different from the delegation manager.
    function test_validationFailWhenInvalidSender() public {
        // Using an invalid sender, it must be the delegation manager
        vm.startPrank(address(users.bob.deleGator));
        vm.expectRevert("NativeTokenPaymentEnforcer:only-delegation-manager");
        nativeTokenPaymentEnforcer.afterAllHook(hex"", hex"", singleDefaultMode, new bytes(0), bytes32(0), address(0), address(0));
    }

    // Should SUCCEED to charge the payment from the allowance delegation
    function test_chargePaymentFromAllowance() public {
        // The terms indicate to send 1 ether to Alice.
        (bytes32 delegationHash_, Delegation memory paidDelegation_) = _getExampleDelegation(paymentTerms, hex"");

        Delegation[] memory paidDelegations_ = new Delegation[](1);
        paidDelegations_[0] = paidDelegation_;

        // Create the Allowance enforcer
        allowanceTerms = abi.encode(paymentAmount);
        argsEnforcerTerms = abi.encodePacked(delegationHash_, address(users.bob.deleGator));

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(argsEqualityCheckEnforcer), terms: argsEnforcerTerms });
        caveats_[1] = Caveat({ args: hex"", enforcer: address(nativeTokenTransferAmountEnforcer), terms: allowanceTerms });

        // Create allowance delegation from Bob to NativeTokenPaymentEnforcer
        Delegation[] memory allowanceDelegations_ = new Delegation[](1);
        allowanceDelegations_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        allowanceDelegations_[0] = signDelegation(users.bob, allowanceDelegations_[0]);

        // The args contain the allowance delegation to redeem
        argsWithBobAllowance = abi.encode(allowanceDelegations_);

        uint256 aliceBalanceBefore_ = address(users.alice.deleGator).balance;

        assertEq(aliceDeleGatorCounter.count(), 0);

        // Pass the delegation allowance in the args.
        paidDelegations_[0].caveats[0].args = argsWithBobAllowance;
        invokeDelegation_UserOp(users.bob, paidDelegations_, execution);

        assertEq(aliceDeleGatorCounter.count(), 1);

        // Alice received the payment
        assertEq(address(users.alice.deleGator).balance, aliceBalanceBefore_ + 1 ether);
    }

    // Should SUCCEED to redelegate, adding more required payments on each hop.
    function test_allowsRedelegationAddingExtraCosts() public {
        // Creating paid delegation
        Caveat[] memory caveatsAlice_ = new Caveat[](1);
        caveatsAlice_[0] = Caveat({ args: hex"", enforcer: address(nativeTokenPaymentEnforcer), terms: paymentTerms });
        Caveat[] memory caveatsBob_ = new Caveat[](1);
        caveatsBob_[0] = Caveat({
            args: hex"",
            enforcer: address(nativeTokenPaymentEnforcer),
            terms: abi.encodePacked(address(users.bob.deleGator), paymentAmount / 2)
        });

        Delegation[] memory paidDelegations_ = new Delegation[](2);
        paidDelegations_[1] = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveatsAlice_,
            salt: 0,
            signature: hex""
        });
        paidDelegations_[1] = signDelegation(users.alice, paidDelegations_[1]);
        bytes32 delegationHashAlice_ = EncoderLib._getDelegationHash(paidDelegations_[1]);

        paidDelegations_[0] = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: delegationHashAlice_,
            caveats: caveatsBob_,
            salt: 0,
            signature: hex""
        });
        paidDelegations_[0] = signDelegation(users.bob, paidDelegations_[0]);
        bytes32 delegationHashBob_ = EncoderLib._getDelegationHash(paidDelegations_[0]);

        // Creating allowance delegation
        Caveat[] memory caveatsToAlice_ = new Caveat[](2);
        caveatsToAlice_[0] = Caveat({
            args: hex"",
            enforcer: address(argsEqualityCheckEnforcer),
            terms: abi.encodePacked(delegationHashAlice_, address(users.carol.deleGator))
        });
        caveatsToAlice_[1] =
            Caveat({ args: hex"", enforcer: address(nativeTokenTransferAmountEnforcer), terms: abi.encode(paymentAmount) });

        Caveat[] memory caveatsToBob_ = new Caveat[](2);
        caveatsToBob_[0] = Caveat({
            args: hex"",
            enforcer: address(argsEqualityCheckEnforcer),
            terms: abi.encodePacked(delegationHashBob_, address(users.carol.deleGator))
        });
        caveatsToBob_[1] =
            Caveat({ args: hex"", enforcer: address(nativeTokenTransferAmountEnforcer), terms: abi.encode(paymentAmount / 2) });

        // Create allowance delegation from Bob to NativeTokenPaymentEnforcer
        Delegation[] memory allowanceDelegationsToAlice_ = new Delegation[](1);
        allowanceDelegationsToAlice_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.carol.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveatsToAlice_,
            salt: 0,
            signature: hex""
        });
        allowanceDelegationsToAlice_[0] = signDelegation(users.carol, allowanceDelegationsToAlice_[0]);

        Delegation[] memory allowanceDelegationsToBob_ = new Delegation[](1);
        allowanceDelegationsToBob_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.carol.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveatsToBob_,
            salt: 0,
            signature: hex""
        });
        allowanceDelegationsToBob_[0] = signDelegation(users.carol, allowanceDelegationsToBob_[0]);

        // Check state before execution
        uint256 aliceBalanceBefore_ = address(users.alice.deleGator).balance;
        uint256 bobBalanceBefore_ = address(users.bob.deleGator).balance;
        uint256 carolBalanceBefore_ = address(users.carol.deleGator).balance;
        assertEq(aliceDeleGatorCounter.count(), 0);

        // Pass the allowances in the args.
        paidDelegations_[1].caveats[0].args = abi.encode(allowanceDelegationsToAlice_);
        paidDelegations_[0].caveats[0].args = abi.encode(allowanceDelegationsToBob_);
        invokeDelegation_UserOp(users.carol, paidDelegations_, execution);

        assertEq(aliceDeleGatorCounter.count(), 1);

        // Alice and Bob received the payment, the funds were taken from Carol
        assertEq(address(users.alice.deleGator).balance, aliceBalanceBefore_ + 1 ether);
        assertEq(address(users.bob.deleGator).balance, bobBalanceBefore_ + paymentAmount / 2);
        assertTrue(address(users.carol.deleGator).balance < (carolBalanceBefore_ - paymentAmount - paymentAmount / 2));
        assertApproxEqAbs(address(users.carol.deleGator).balance, (carolBalanceBefore_ - paymentAmount - paymentAmount / 2), 1e8);
    }

    // Should SUCCEED to prevent front running using the args enforcer, catches the error
    function test_delegationPreventFrontRunningWithArgsCatchError() public {
        (bytes32 originalDelegationHash_, Delegation memory originalPaidDelegation_) = _getExampleDelegation(paymentTerms, hex"");

        (bytes32 maliciousDelegationHash_, Delegation memory maliciousPaidDelegation_) =
            _getMaliciousDelegation(paymentTerms, hex"");

        (, argsWithBobAllowance) = _getAllowanceDelegation(originalDelegationHash_, address(users.bob.deleGator));

        vm.startPrank(address(delegationManager));

        // The redeemer is Carol and not Bob who is the delegator of the allowance delegation
        vm.expectRevert("ArgsEqualityCheckEnforcer:different-args-and-terms");
        nativeTokenPaymentEnforcer.afterAllHook(
            paymentTerms,
            argsWithBobAllowance,
            singleDefaultMode,
            executionCalldata,
            maliciousDelegationHash_,
            maliciousPaidDelegation_.delegator,
            maliciousPaidDelegation_.delegate
        );

        // The redeemer is Bob who is the delegator of the payment delegations
        nativeTokenPaymentEnforcer.afterAllHook(
            paymentTerms,
            argsWithBobAllowance,
            singleDefaultMode,
            executionCalldata,
            originalDelegationHash_,
            originalPaidDelegation_.delegator,
            originalPaidDelegation_.delegate
        );
    }

    // Should SUCCEED to prevent front running using the args enforcer
    function test_delegationPreventFrontRunningWithArgs() public {
        (bytes32 openPaidDelegationHash_, Delegation memory openPaidDelegation_) = _getOpenDelegation(paymentTerms, hex"");
        Delegation[] memory openPaidDelegations_ = new Delegation[](1);
        openPaidDelegations_[0] = openPaidDelegation_;

        // Create the Allowance enforcer (Combined with args enforcer, prevent front-running)
        allowanceTerms = abi.encode(paymentAmount);
        argsEnforcerTerms = abi.encodePacked(openPaidDelegationHash_, address(users.bob.deleGator));

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(argsEqualityCheckEnforcer), terms: argsEnforcerTerms });
        caveats_[1] = Caveat({ args: hex"", enforcer: address(nativeTokenTransferAmountEnforcer), terms: allowanceTerms });

        // Create allowance delegation from Bob to NativeTokenPaymentEnforcer
        // This delegation is protected with the args enforcer
        // Even though Bob created this delegation to pay for his Alice delegation, Carol tries to use it to pay for her.
        Delegation[] memory allowanceDelegations_ = new Delegation[](1);
        allowanceDelegations_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        allowanceDelegations_[0] = signDelegation(users.bob, allowanceDelegations_[0]);

        // The args contain the allowance delegation to redeem
        argsWithBobAllowance = abi.encode(allowanceDelegations_);

        uint256 aliceBalanceBefore_ = address(users.alice.deleGator).balance;

        assertEq(aliceDeleGatorCounter.count(), 0);

        // Pass the delegation allowance in the args.
        openPaidDelegations_[0].caveats[0].args = argsWithBobAllowance;

        invokeDelegation_UserOp(users.carol, openPaidDelegations_, execution);
        // The execution did not work because the redeemer is not Carol.
        assertEq(aliceDeleGatorCounter.count(), 0);
        // Alice did not receive the payment
        assertEq(address(users.alice.deleGator).balance, aliceBalanceBefore_);

        invokeDelegation_UserOp(users.bob, openPaidDelegations_, execution);
        // The execution works well with a proper args and using Bob as redeemer
        assertEq(aliceDeleGatorCounter.count(), 1);
        // Alice received the payment
        assertEq(address(users.alice.deleGator).balance, aliceBalanceBefore_ + 1 ether);
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        nativeTokenPaymentEnforcer.afterAllHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
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

    function _getOpenDelegation(
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
            delegate: delegationManager.ANY_DELEGATE(),
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

    function _getAllowanceDelegation(
        bytes32 _delegationHash,
        address _redeemer
    )
        internal
        returns (Delegation[] memory allowanceDelegations_, bytes memory encodedallowanceDelegations_)
    {
        Caveat[] memory caveats_ = new Caveat[](2);
        allowanceTerms = abi.encode(paymentAmount);
        argsEnforcerTerms = abi.encodePacked(_delegationHash, _redeemer);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(argsEqualityCheckEnforcer), terms: argsEnforcerTerms });
        caveats_[1] = Caveat({ args: hex"", enforcer: address(nativeTokenTransferAmountEnforcer), terms: allowanceTerms });

        allowanceDelegations_ = new Delegation[](1);
        allowanceDelegations_[0] = Delegation({
            delegate: address(nativeTokenPaymentEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        allowanceDelegations_[0] = signDelegation(users.bob, allowanceDelegations_[0]);
        encodedallowanceDelegations_ = abi.encode(allowanceDelegations_);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(nativeTokenPaymentEnforcer));
    }
}

/// @dev This contract is used for testing a case where the redeemDelegations() function doesn't work as expected
contract MockDelegationManager {
    function redeemDelegations(
        bytes[] calldata _permissionContexts,
        ModeCode[] calldata _modes,
        bytes[] calldata _executionCallDatas
    )
        external
    {
        // Does not do anything, the execution is not processed
    }
}
