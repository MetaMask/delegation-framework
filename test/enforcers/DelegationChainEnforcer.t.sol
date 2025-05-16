// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { BaseTest } from "../utils/BaseTest.t.sol";
import { Delegation, Caveat, Execution, ModeCode } from "../../src/utils/Types.sol";
import { Implementation, SignatureType, TestUser } from "../utils/Types.t.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { DelegationManager } from "../../src/DelegationManager.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { MultiSigDeleGator } from "../../src/MultiSigDeleGator.sol";
import { DelegationChainEnforcer } from "../../src/enforcers/DelegationChainEnforcer.sol";
import { ArgsEqualityCheckEnforcer } from "../../src/enforcers/ArgsEqualityCheckEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { RedeemerEnforcer } from "../../src/enforcers/RedeemerEnforcer.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import "forge-std/Test.sol";

// Import the event
import { DelegationChainEnforcer as DelegationChainEnforcerEvents } from "../../src/enforcers/DelegationChainEnforcer.sol";

contract DelegationChainEnforcerTest is BaseTest {
    ////////////////////////////// Setup //////////////////////////////

    TestUser public chainIntegrity;
    TestUser public treasury;
    // Intermediary Chain Account
    TestUser public ICA;

    MultiSigDeleGator public aliceDeleGator;
    MultiSigDeleGator public bobDeleGator;
    DelegationChainEnforcer public delegationChainEnforcer;
    ArgsEqualityCheckEnforcer public argsEqualityCheckEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    ValueLteEnforcer public valueLteEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    ERC20TransferAmountEnforcer public erc20TransferAmountEnforcer;
    RedeemerEnforcer public redeemerEnforcer;
    address[] public delegators;

    // Prize levels for the delegation chain rewards
    uint256[] public prizeLevels;
    BasicERC20 public token;
    bytes32 public firstReferralDelegationHash;

    constructor() {
        IMPLEMENTATION = Implementation.MultiSig;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public virtual override {
        super.setUp();

        chainIntegrity = createUser("ChainIntegrity");
        treasury = createUser("Treasury");
        ICA = createUser("Intermediary Chain Account");
        aliceDeleGator = MultiSigDeleGator(payable(users.alice.deleGator));
        bobDeleGator = MultiSigDeleGator(payable(users.bob.deleGator));

        // Set up prize levels
        prizeLevels.push(10 ether);
        prizeLevels.push(10 ether);
        prizeLevels.push(2.5 ether);
        prizeLevels.push(1.5 ether);
        prizeLevels.push(1 ether);

        argsEqualityCheckEnforcer = new ArgsEqualityCheckEnforcer();
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        valueLteEnforcer = new ValueLteEnforcer();
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        erc20TransferAmountEnforcer = new ERC20TransferAmountEnforcer();
        redeemerEnforcer = new RedeemerEnforcer();

        token = new BasicERC20(address(this), "USDC", "USDC", 18);
        token.mint(address(treasury.deleGator), 100 ether);

        delegationChainEnforcer = new DelegationChainEnforcer(
            address(chainIntegrity.deleGator),
            IDelegationManager(address(delegationManager)),
            address(argsEqualityCheckEnforcer),
            address(token),
            prizeLevels
        );
    }

    ////////////////////////////// Constructor Tests //////////////////////////////

    /// @notice Tests that constructor reverts when delegation manager address is zero
    function test_delegationManagerZero() public {
        vm.expectRevert("DelegationChainEnforcer:invalid-delegationManager");
        new DelegationChainEnforcer(
            address(chainIntegrity.deleGator),
            IDelegationManager(address(0)),
            address(argsEqualityCheckEnforcer),
            address(token),
            prizeLevels
        );
    }

    /// @notice Tests that constructor reverts when args equality check enforcer address is zero
    function test_argsEqualityCheckEnforcerZero() public {
        vm.expectRevert("DelegationChainEnforcer:invalid-argsEqualityCheckEnforcer");
        new DelegationChainEnforcer(
            address(chainIntegrity.deleGator),
            IDelegationManager(address(delegationManager)),
            address(0),
            address(token),
            prizeLevels
        );
    }

    /// @notice Tests that constructor reverts when prize token address is zero
    function test_prizeTokenZero() public {
        vm.expectRevert("DelegationChainEnforcer:invalid-prizeToken");
        new DelegationChainEnforcer(
            address(chainIntegrity.deleGator),
            IDelegationManager(address(delegationManager)),
            address(argsEqualityCheckEnforcer),
            address(0),
            prizeLevels
        );
    }

    /// @notice Tests that constructor reverts when prize amounts array has only one element
    function test_prizeAmountsLengthOne() public {
        uint256[] memory singlePrize = new uint256[](1);
        singlePrize[0] = 10 ether;

        vm.expectRevert("DelegationChainEnforcer:invalid-max-prize-payments");
        new DelegationChainEnforcer(
            address(chainIntegrity.deleGator),
            IDelegationManager(address(delegationManager)),
            address(argsEqualityCheckEnforcer),
            address(token),
            singlePrize
        );
    }

    /// @notice Tests that constructor reverts when any prize amount in the array is zero
    function test_prizeAmountZero() public {
        uint256[] memory invalidPrizes = new uint256[](2);
        invalidPrizes[0] = 10 ether;
        invalidPrizes[1] = 0;

        vm.expectRevert("DelegationChainEnforcer:invalid-prize-amount");
        new DelegationChainEnforcer(
            address(chainIntegrity.deleGator),
            IDelegationManager(address(delegationManager)),
            address(argsEqualityCheckEnforcer),
            address(token),
            invalidPrizes
        );
    }

    ////////////////////////////// setPrizes Tests //////////////////////////////

    /// @notice Tests that owner can successfully set new prize amounts
    function test_setPrizes() public {
        uint256[] memory newPrizes = new uint256[](5);
        newPrizes[0] = 20 ether;
        newPrizes[1] = 15 ether;
        newPrizes[2] = 10 ether;
        newPrizes[3] = 5 ether;
        newPrizes[4] = 2.5 ether;

        vm.prank(address(chainIntegrity.deleGator));
        delegationChainEnforcer.setPrizes(newPrizes);

        // Verify each prize amount was set correctly
        for (uint256 i = 0; i < newPrizes.length; i++) {
            assertEq(delegationChainEnforcer.prizeAmounts(i), newPrizes[i]);
        }
    }

    /// @notice Tests that non-owner cannot set prize amounts
    function test_setPrizesOnlyOwner() public {
        uint256[] memory newPrizes = new uint256[](5);
        newPrizes[0] = 20 ether;
        newPrizes[1] = 15 ether;
        newPrizes[2] = 10 ether;
        newPrizes[3] = 5 ether;
        newPrizes[4] = 2.5 ether;

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(users.bob.deleGator)));
        delegationChainEnforcer.setPrizes(newPrizes);
    }

    /// @notice Tests that setting prize amounts with wrong length reverts
    function test_setPrizesWrongLength() public {
        uint256[] memory wrongLengthPrizes = new uint256[](3); // Should be 5
        wrongLengthPrizes[0] = 20 ether;
        wrongLengthPrizes[1] = 15 ether;
        wrongLengthPrizes[2] = 10 ether;

        vm.prank(address(chainIntegrity.deleGator));
        vm.expectRevert("DelegationChainEnforcer:invalid-prize-amounts-length");
        delegationChainEnforcer.setPrizes(wrongLengthPrizes);
    }

    /// @notice Tests that setting prize amounts with zero value reverts
    function test_setPrizesZeroAmount() public {
        uint256[] memory zeroPrizes = new uint256[](5);
        zeroPrizes[0] = 20 ether;
        zeroPrizes[1] = 15 ether;
        zeroPrizes[2] = 10 ether;
        zeroPrizes[3] = 5 ether;
        zeroPrizes[4] = 0; // Zero amount

        vm.prank(address(chainIntegrity.deleGator));
        vm.expectRevert("DelegationChainEnforcer:invalid-prize-amount");
        delegationChainEnforcer.setPrizes(zeroPrizes);
    }

    /// @notice Tests that setting prize amounts emits PrizesSet event
    function test_setPrizesEmitsEvent() public {
        uint256[] memory newPrizes = new uint256[](5);
        newPrizes[0] = 20 ether;
        newPrizes[1] = 15 ether;
        newPrizes[2] = 10 ether;
        newPrizes[3] = 5 ether;
        newPrizes[4] = 2.5 ether;

        vm.prank(address(chainIntegrity.deleGator));
        vm.expectEmit(true, false, false, true);
        emit DelegationChainEnforcerEvents.PrizesSet(address(chainIntegrity.deleGator), newPrizes);
        delegationChainEnforcer.setPrizes(newPrizes);
    }

    // Should create a delegation chain from chainIntegrity -> alice -> ICA -> bob -> ICA
    function test_chainIntegrityCanDelegateToAliceToICAToBoB() public {
        // Create delegation from chainIntegrity to alice
        Delegation memory chainToAlice_ = Delegation({
            delegate: address(users.alice.deleGator),
            delegator: address(chainIntegrity.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: _getChainIntegrityCaveats(),
            salt: 0,
            signature: hex""
        });
        chainToAlice_ = signDelegation(chainIntegrity, chainToAlice_);

        // Create delegation from alice to ICA
        Delegation memory aliceToICA_ = Delegation({
            delegate: address(ICA.deleGator),
            delegator: address(users.alice.deleGator),
            authority: EncoderLib._getDelegationHash(chainToAlice_),
            caveats: _getPositionCaveats(0),
            salt: 0,
            signature: hex""
        });
        aliceToICA_ = signDelegation(users.alice, aliceToICA_);
        firstReferralDelegationHash = EncoderLib._getDelegationHash(aliceToICA_);

        // Create delegation from ICA to bob
        Delegation memory ICAToBob_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(ICA.deleGator),
            authority: firstReferralDelegationHash,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        ICAToBob_ = signDelegation(ICA, ICAToBob_);

        // Create delegation from bob back to ICA
        Delegation memory bobToICA_ = Delegation({
            delegate: address(ICA.deleGator),
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(ICAToBob_),
            caveats: _getPositionCaveats(1),
            salt: 0,
            signature: hex""
        });
        bobToICA_ = signDelegation(users.bob, bobToICA_);

        delegators.push(address(users.alice.deleGator));
        delegators.push(address(users.bob.deleGator));

        // Adding the redemption args only to the alice delegation
        aliceToICA_.caveats[0].args = _getRedemptionArgs();

        // Build delegation chain
        Delegation[] memory delegations_ = new Delegation[](4);
        delegations_[0] = bobToICA_;
        delegations_[1] = ICAToBob_;
        delegations_[2] = aliceToICA_;
        delegations_[3] = chainToAlice_;

        uint256[] memory balancesBefore_ = _getBalances(delegators);

        // Execute the delegation chain through ICA
        invokeDelegation_UserOp(ICA, delegations_, _getExecution());

        _validatePayments(balancesBefore_);
    }

    ////////////////////////////// Post Function Tests //////////////////////////////

    /// @notice Tests that post function works with minimum valid delegators length
    function test_postMinimumDelegators() public {
        address[] memory delegators_ = new address[](2);
        delegators_[0] = address(users.alice.deleGator);
        delegators_[1] = address(users.bob.deleGator);

        vm.prank(address(chainIntegrity.deleGator));
        vm.expectEmit(true, true, false, true);
        emit DelegationChainEnforcerEvents.ReferralArrayPosted(
            address(chainIntegrity.deleGator), keccak256(abi.encode(delegators_))
        );
        delegationChainEnforcer.post(delegators_);

        // Verify the referrals were stored correctly
        address[] memory storedReferrals = delegationChainEnforcer.getReferrals(keccak256(abi.encode(delegators_)));
        assertEq(storedReferrals.length, 2, "referrals length should be 2");
        assertEq(storedReferrals[0], delegators_[0], "referral[0] should be alice");
        assertEq(storedReferrals[1], delegators_[1], "referral[1] should be bob");
    }

    /// @notice Tests that post function works with maximum valid delegators length
    function test_postMaximumDelegators() public {
        address[] memory delegators_ = new address[](20); // MAX_REFERRAL_DEPTH
        for (uint256 i = 0; i < 20; i++) {
            delegators_[i] = address(uint160(i + 1)); // Use different addresses
        }

        vm.prank(address(chainIntegrity.deleGator));
        vm.expectEmit(true, true, false, true);
        emit DelegationChainEnforcerEvents.ReferralArrayPosted(
            address(chainIntegrity.deleGator), keccak256(abi.encode(delegators_))
        );
        delegationChainEnforcer.post(delegators_);

        // Verify the referrals were stored correctly (only last maxPrizePayments)
        address[] memory storedReferrals = delegationChainEnforcer.getReferrals(keccak256(abi.encode(delegators_)));
        assertEq(storedReferrals.length, 5, "referrals length should be 5"); // maxPrizePayments
        uint256 count = 0;
        for (uint256 i = delegators_.length - 5; i < delegators_.length; ++i) {
            assertEq(storedReferrals[count], delegators_[i], "referral order mismatch"); // Last 5
            count++;
        }
    }

    /// @notice Tests that post function reverts when called by non-owner
    function test_postOnlyOwner() public {
        address[] memory delegators_ = new address[](2);
        delegators_[0] = address(users.alice.deleGator);
        delegators_[1] = address(users.bob.deleGator);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(users.bob.deleGator)));
        delegationChainEnforcer.post(delegators_);
    }

    /// @notice Tests that post function reverts when delegators length is 1
    function test_postDelegatorsLengthOne() public {
        address[] memory delegators_ = new address[](1);
        delegators_[0] = address(users.alice.deleGator);

        vm.prank(address(chainIntegrity.deleGator));
        vm.expectRevert("DelegationChainEnforcer:invalid-delegators-length");
        delegationChainEnforcer.post(delegators_);
    }

    /// @notice Tests that post function reverts when delegators length exceeds MAX_REFERRAL_DEPTH
    function test_postDelegatorsLengthExceedsMax() public {
        uint256 maxReferralDepth = delegationChainEnforcer.MAX_REFERRAL_DEPTH();
        address[] memory delegators_ = new address[](maxReferralDepth + 1); // MAX_REFERRAL_DEPTH + 1
        for (uint256 i = 0; i < maxReferralDepth + 1; i++) {
            delegators_[i] = address(uint160(i + 1));
        }

        vm.prank(address(chainIntegrity.deleGator));
        vm.expectRevert("DelegationChainEnforcer:invalid-delegators-length");
        delegationChainEnforcer.post(delegators_);
    }

    /// @notice Tests that post function reverts when trying to post the same chain twice
    function test_postDuplicateChain() public {
        address[] memory delegators_ = new address[](2);
        delegators_[0] = address(users.alice.deleGator);
        delegators_[1] = address(users.bob.deleGator);

        vm.prank(address(chainIntegrity.deleGator));
        delegationChainEnforcer.post(delegators_);

        vm.prank(address(chainIntegrity.deleGator));
        vm.expectRevert("DelegationChainEnforcer:referral-chain-already-posted");
        delegationChainEnforcer.post(delegators_);
    }

    /// @notice Tests that post function correctly stores delegators in correct order
    function test_postCorrectOrder() public {
        address[] memory delegators_ = new address[](3);
        delegators_[0] = address(users.alice.deleGator);
        delegators_[1] = address(users.bob.deleGator);
        delegators_[2] = address(users.carol.deleGator);

        vm.prank(address(chainIntegrity.deleGator));
        delegationChainEnforcer.post(delegators_);

        // Verify the referrals were stored in correct order
        address[] memory storedReferrals = delegationChainEnforcer.getReferrals(keccak256(abi.encode(delegators_)));
        assertEq(storedReferrals.length, 3, "referrals length should be 3");
        assertEq(storedReferrals[0], delegators_[0], "referral[0] should be alice");
        assertEq(storedReferrals[1], delegators_[1], "referral[1] should be bob");
        assertEq(storedReferrals[2], delegators_[2], "referral[2] should be carol");
    }

    /// @notice Tests that post function correctly handles delegators array with length less than maxPrizePayments
    function test_postLessThanMaxPrizePayments() public {
        address[] memory delegators_ = new address[](3); // Less than maxPrizePayments (5)
        delegators_[0] = address(users.alice.deleGator);
        delegators_[1] = address(users.bob.deleGator);
        delegators_[2] = address(users.carol.deleGator);

        vm.prank(address(chainIntegrity.deleGator));
        delegationChainEnforcer.post(delegators_);

        // Verify all delegators were stored since length < maxPrizePayments
        address[] memory storedReferrals = delegationChainEnforcer.getReferrals(keccak256(abi.encode(delegators_)));
        assertEq(storedReferrals.length, 3, "referrals length should be 3");
        assertEq(storedReferrals[0], delegators_[0], "referral[0] should be alice");
        assertEq(storedReferrals[1], delegators_[1], "referral[1] should be bob");
        assertEq(storedReferrals[2], delegators_[2], "referral[2] should be carol");
    }

    /// @notice Tests that afterHook reverts when delegations length doesn't match referrals length
    function test_afterHookInvalidDelegationsLength() public {
        // First post a valid referral chain
        address[] memory delegators_ = new address[](2);
        delegators_[0] = address(users.alice.deleGator);
        delegators_[1] = address(users.bob.deleGator);

        vm.prank(address(chainIntegrity.deleGator));
        delegationChainEnforcer.post(delegators_);

        // Create execution data for the post function
        Execution memory execution_ = Execution({
            target: address(delegationChainEnforcer),
            value: 0,
            callData: abi.encodeCall(DelegationChainEnforcer.post, (delegators_))
        });

        // Create a single delegation (should be 2 to match referrals length)
        Delegation[][] memory delegations_ = new Delegation[][](1);
        delegations_[0] = new Delegation[](1);

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({
            args: hex"",
            enforcer: address(argsEqualityCheckEnforcer),
            terms: abi.encodePacked(firstReferralDelegationHash, address(ICA.deleGator))
        });
        caveats_[1] = Caveat({
            args: hex"",
            enforcer: address(erc20TransferAmountEnforcer),
            terms: abi.encodePacked(address(token), prizeLevels[0])
        });

        delegations_[0][0] = Delegation({
            delegate: address(delegationChainEnforcer),
            delegator: address(treasury.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        // Try to execute afterHook with mismatched lengths
        vm.prank(address(delegationManager));
        vm.expectRevert("DelegationChainEnforcer:invalid-delegations-length");
        delegationChainEnforcer.afterHook(
            hex"",
            abi.encode(delegations_),
            singleDefaultMode,
            ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData),
            firstReferralDelegationHash,
            address(users.alice.deleGator),
            address(ICA.deleGator)
        );
    }

    /// @notice Tests that afterHook reverts when args enforcer is missing in the first delegation
    function test_afterHookInvalidArgsEnforcerInFirstDelegation() public {
        // First post a valid referral chain
        address[] memory delegators_ = new address[](2);
        delegators_[0] = address(users.alice.deleGator);
        delegators_[1] = address(users.bob.deleGator);

        vm.prank(address(chainIntegrity.deleGator));
        delegationChainEnforcer.post(delegators_);

        // Create execution data for the post function
        Execution memory execution_ = Execution({
            target: address(delegationChainEnforcer),
            value: 0,
            callData: abi.encodeCall(DelegationChainEnforcer.post, (delegators_))
        });

        Delegation[][] memory delegations_ = new Delegation[][](2);
        delegations_[0] = new Delegation[](1);
        delegations_[1] = new Delegation[](1);

        Caveat[] memory caveats_ = new Caveat[](2);
        // The args enforcer is missing in the first caveat
        caveats_[0] = Caveat({
            args: hex"",
            enforcer: address(erc20TransferAmountEnforcer),
            terms: abi.encodePacked(address(token), prizeLevels[0])
        });
        // The args enforcer required to be in the first caveat
        caveats_[1] = Caveat({
            args: hex"",
            enforcer: address(argsEqualityCheckEnforcer),
            terms: abi.encodePacked(firstReferralDelegationHash, address(ICA.deleGator))
        });

        delegations_[0][0] = Delegation({
            delegate: address(delegationChainEnforcer),
            delegator: address(treasury.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        // Try to execute afterHook with missing args enforcer
        vm.prank(address(delegationManager));
        vm.expectRevert("DelegationChainEnforcer:missing-argsEqualityCheckEnforcer");
        delegationChainEnforcer.afterHook(
            hex"",
            abi.encode(delegations_),
            singleDefaultMode,
            ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData),
            firstReferralDelegationHash,
            address(users.alice.deleGator),
            address(ICA.deleGator)
        );
    }

    /// @notice Tests that afterHook reverts when empty caveats
    function test_afterHookInvalidEmptyCaveats() public {
        // First post a valid referral chain
        address[] memory delegators_ = new address[](2);
        delegators_[0] = address(users.alice.deleGator);
        delegators_[1] = address(users.bob.deleGator);

        vm.prank(address(chainIntegrity.deleGator));
        delegationChainEnforcer.post(delegators_);

        // Create execution data for the post function
        Execution memory execution_ = Execution({
            target: address(delegationChainEnforcer),
            value: 0,
            callData: abi.encodeCall(DelegationChainEnforcer.post, (delegators_))
        });

        Delegation[][] memory delegations_ = new Delegation[][](2);
        delegations_[0] = new Delegation[](1);
        delegations_[1] = new Delegation[](1);

        // Delegation with empty caveats means that the args enforcer is missing, it reverts.
        delegations_[0][0] = Delegation({
            delegate: address(delegationChainEnforcer),
            delegator: address(treasury.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Try to execute afterHook with missing args enforcer
        vm.prank(address(delegationManager));
        vm.expectRevert("DelegationChainEnforcer:missing-argsEqualityCheckEnforcer");
        delegationChainEnforcer.afterHook(
            hex"",
            abi.encode(delegations_),
            singleDefaultMode,
            ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData),
            firstReferralDelegationHash,
            address(users.alice.deleGator),
            address(ICA.deleGator)
        );
    }

    /// @notice Tests that afterHook reverts when payment transfer fails
    function test_afterHookPaymentNotReceived() public {
        DelegationManagerEmptyMock delegationManagerEmptyMock_ = new DelegationManagerEmptyMock();

        delegationChainEnforcer = new DelegationChainEnforcer(
            address(chainIntegrity.deleGator),
            IDelegationManager(address(delegationManagerEmptyMock_)),
            address(argsEqualityCheckEnforcer),
            address(token),
            prizeLevels
        );

        // First post a valid referral chain
        address[] memory delegators_ = new address[](2);
        delegators_[0] = address(users.alice.deleGator);
        delegators_[1] = address(users.bob.deleGator);

        vm.prank(address(chainIntegrity.deleGator));
        delegationChainEnforcer.post(delegators_);
        bytes32 referralChainHash_ = keccak256(abi.encode(delegators_));

        // Create execution data for the post function
        Execution memory execution_ = Execution({
            target: address(delegationChainEnforcer),
            value: 0,
            callData: abi.encodeCall(DelegationChainEnforcer.post, (delegators_))
        });

        // Create delegations with valid structure but insufficient token balance
        Delegation[][] memory delegations_ = new Delegation[][](2);
        delegations_[0] = new Delegation[](1);
        delegations_[1] = new Delegation[](1);

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({
            args: hex"",
            enforcer: address(argsEqualityCheckEnforcer),
            terms: abi.encodePacked(firstReferralDelegationHash, address(ICA.deleGator))
        });
        caveats_[1] = Caveat({
            args: hex"",
            enforcer: address(erc20TransferAmountEnforcer),
            terms: abi.encodePacked(address(token), prizeLevels[0])
        });

        delegations_[0][0] = Delegation({
            delegate: address(delegationChainEnforcer),
            delegator: address(treasury.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegations_[1][0] = Delegation({
            delegate: address(delegationChainEnforcer),
            delegator: address(treasury.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegations_[0][0] = signDelegation(treasury, delegations_[0][0]);
        delegations_[1][0] = signDelegation(treasury, delegations_[1][0]);
        // Try to execute afterHook, but it will revert because the delegation manager
        // redemption function didn't execute the erc20 token transfer
        vm.prank(address(delegationManagerEmptyMock_));
        vm.expectRevert("DelegationChainEnforcer:payment-not-received");
        delegationChainEnforcer.afterHook(
            hex"",
            abi.encode(delegations_),
            singleDefaultMode,
            ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData),
            firstReferralDelegationHash,
            address(users.alice.deleGator),
            address(ICA.deleGator)
        );
    }

    /// @notice Tests that afterHook reverts when allowance delegations array is empty
    function test_afterHookInvalidAllowanceDelegationsLength() public {
        // First post a valid referral chain
        address[] memory delegators_ = new address[](2);
        delegators_[0] = address(users.alice.deleGator);
        delegators_[1] = address(users.bob.deleGator);

        vm.prank(address(chainIntegrity.deleGator));
        delegationChainEnforcer.post(delegators_);

        // Create execution data for the post function
        Execution memory execution_ = Execution({
            target: address(delegationChainEnforcer),
            value: 0,
            callData: abi.encodeCall(DelegationChainEnforcer.post, (delegators_))
        });

        // Create empty delegations array
        Delegation[][] memory delegations_ = new Delegation[][](0);

        // Try to execute afterHook with empty delegations array
        vm.prank(address(delegationManager));
        vm.expectRevert("DelegationChainEnforcer:invalid-allowance-delegations-length");
        delegationChainEnforcer.afterHook(
            hex"",
            abi.encode(delegations_),
            singleDefaultMode,
            ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData),
            firstReferralDelegationHash,
            address(users.alice.deleGator),
            address(ICA.deleGator)
        );
    }

    ////////////////////////////// getTermsInfo Tests //////////////////////////////

    /// @notice Tests that getTermsInfo correctly decodes valid terms
    function test_getTermsInfoValid() public {
        uint256 expectedPosition = 5;
        bytes memory terms = abi.encodePacked(expectedPosition);

        uint256 result = delegationChainEnforcer.getTermsInfo(terms);
        assertEq(result, expectedPosition, "getTermsInfo should return correct position");
    }

    /// @notice Tests that getTermsInfo reverts when terms length is not 32 bytes
    function test_getTermsInfoInvalidLength() public {
        bytes memory terms = abi.encodePacked(uint256(5), uint256(6)); // 64 bytes

        vm.expectRevert("DelegationChainEnforcer:invalid-terms-length");
        delegationChainEnforcer.getTermsInfo(terms);
    }

    /// @notice Tests that getTermsInfo handles zero position correctly
    function test_getTermsInfoZeroPosition() public {
        uint256 expectedPosition = 0;
        bytes memory terms = abi.encodePacked(expectedPosition);

        uint256 result = delegationChainEnforcer.getTermsInfo(terms);
        assertEq(result, expectedPosition, "getTermsInfo should handle zero position");
    }

    /// @notice Tests that getTermsInfo handles maximum position correctly
    function test_getTermsInfoMaxPosition() public {
        uint256 expectedPosition = type(uint256).max;
        bytes memory terms = abi.encodePacked(expectedPosition);

        uint256 result = delegationChainEnforcer.getTermsInfo(terms);
        assertEq(result, expectedPosition, "getTermsInfo should handle max position");
    }

    /// @notice Tests that beforeHook reverts when delegators length exceeds MAX_REFERRAL_DEPTH
    function test_beforeHookInvalidDelegatorsLength() public {
        // Create delegators array exceeding MAX_REFERRAL_DEPTH (20)
        address[] memory delegators_ = new address[](21);
        for (uint256 i = 0; i < 21; i++) {
            delegators_[i] = address(uint160(i + 1));
        }

        Execution memory execution_ = Execution({
            target: address(delegationChainEnforcer),
            value: 0,
            callData: abi.encodeCall(DelegationChainEnforcer.post, (delegators_))
        });

        vm.prank(address(delegationManager));
        vm.expectRevert("DelegationChainEnforcer:invalid-delegators-length");
        delegationChainEnforcer.beforeHook(
            abi.encodePacked(uint256(0)),
            hex"",
            singleDefaultMode,
            ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData),
            keccak256(""),
            address(users.alice.deleGator),
            address(0)
        );
    }

    /// @notice Tests that beforeHook reverts when expected position is greater than delegators length
    function test_beforeHookInvalidExpectedPosition() public {
        // Create delegators array with length 2
        address[] memory delegators_ = new address[](2);
        delegators_[0] = address(users.alice.deleGator);
        delegators_[1] = address(users.bob.deleGator);

        Execution memory execution_ = Execution({
            target: address(delegationChainEnforcer),
            value: 0,
            callData: abi.encodeCall(DelegationChainEnforcer.post, (delegators_))
        });

        // Try with position 2 (should be 0 or 1)
        vm.prank(address(delegationManager));
        vm.expectRevert("DelegationChainEnforcer:invalid-expected-position");
        delegationChainEnforcer.beforeHook(
            abi.encodePacked(uint256(2)),
            hex"",
            singleDefaultMode,
            ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData),
            keccak256(""),
            address(users.alice.deleGator),
            address(0)
        );
    }

    /// @notice Tests that beforeHook reverts when delegator doesn't match position
    function test_beforeHookInvalidDelegatorOrPosition() public {
        // Create delegators array with length 2
        address[] memory delegators_ = new address[](2);
        delegators_[0] = address(users.alice.deleGator);
        delegators_[1] = address(users.bob.deleGator);

        Execution memory execution_ = Execution({
            target: address(delegationChainEnforcer),
            value: 0,
            callData: abi.encodeCall(DelegationChainEnforcer.post, (delegators_))
        });

        // Try with position 0 but wrong delegator
        vm.prank(address(delegationManager));
        vm.expectRevert("DelegationChainEnforcer:invalid-delegator-or-position");
        delegationChainEnforcer.beforeHook(
            abi.encodePacked(uint256(0)),
            hex"",
            singleDefaultMode,
            ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData),
            keccak256(""),
            address(users.carol.deleGator), // Wrong delegator for position 0
            address(0)
        );
    }

    ////////////////////////////// Internal Utils //////////////////////////////

    // The args contain a delegation chain for each of the delegators/prize levels, and the token to redeem the payments.
    function _getRedemptionArgs() internal view returns (bytes memory encoded_) {
        // Create delegation from treasury with caveats
        // Args enforcer at index 0
        // Includes the first referral delegation hash and the ICA address, because the first delegation with the delegation chain
        // enforcer is the one that redeems the payments after that the others skip it.
        // The args enforcer needs the redeemer, the delegation hash alone is not enough.

        Delegation[][] memory delegations_ = new Delegation[][](delegators.length);
        for (uint256 i = 0; i < delegators.length; i++) {
            delegations_[i] = new Delegation[](1);

            Caveat[] memory caveats_ = new Caveat[](2);

            caveats_[0] = Caveat({
                args: hex"",
                enforcer: address(argsEqualityCheckEnforcer),
                terms: abi.encodePacked(firstReferralDelegationHash, address(address(ICA.deleGator)))
            });

            caveats_[1] = Caveat({
                args: hex"",
                enforcer: address(erc20TransferAmountEnforcer),
                terms: abi.encodePacked(address(token), prizeLevels[i])
            });

            delegations_[i][0] = Delegation({
                delegate: address(delegationChainEnforcer),
                delegator: address(treasury.deleGator),
                authority: ROOT_AUTHORITY,
                caveats: caveats_,
                salt: i,
                signature: hex""
            });

            delegations_[i][0] = signDelegation(treasury, delegations_[i][0]);
        }
        encoded_ = abi.encode(delegations_);
    }

    function _getBalances(address[] memory _recipients) internal view returns (uint256[] memory balances_) {
        uint256 recipientsLength_ = _recipients.length;
        balances_ = new uint256[](recipientsLength_);
        for (uint256 i = 0; i < recipientsLength_; ++i) {
            balances_[i] = IERC20(token).balanceOf(_recipients[i]);
        }
    }

    function _validatePayments(uint256[] memory balanceBefore_) internal {
        uint256[] memory balances_ = _getBalances(delegators);
        for (uint256 i = 0; i < delegators.length; i++) {
            assertEq(balances_[i], balanceBefore_[i] + prizeLevels[i], "The balance after is insufficient");
        }
    }

    function _getExecution() internal view returns (Execution memory execution_) {
        execution_ = Execution({
            target: address(delegationChainEnforcer),
            value: 0,
            callData: abi.encodeCall(DelegationChainEnforcer.post, (delegators))
        });
    }

    function _getPositionCaveats(uint256 _position) internal view returns (Caveat[] memory caveats_) {
        caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(delegationChainEnforcer), terms: abi.encodePacked(uint256(_position)) });
    }

    function _getChainIntegrityCaveats() internal view returns (Caveat[] memory caveats_) {
        caveats_ = new Caveat[](4);
        // Check target is the enforcer
        caveats_[0] = Caveat({
            args: hex"",
            enforcer: address(allowedTargetsEnforcer),
            terms: abi.encodePacked(address(delegationChainEnforcer))
        });
        // Check value is 0
        caveats_[1] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encodePacked(uint256(0)) });
        // Check method is post()
        caveats_[2] = Caveat({
            args: hex"",
            enforcer: address(allowedMethodsEnforcer),
            terms: abi.encodePacked(DelegationChainEnforcer.post.selector)
        });
        // Check redeemer is ICA
        caveats_[3] = Caveat({ args: hex"", enforcer: address(redeemerEnforcer), terms: abi.encodePacked(address(ICA.deleGator)) });
    }
}

contract DelegationManagerEmptyMock {
    function redeemDelegations(bytes[] calldata, ModeCode[] calldata, bytes[] calldata) external {
        // Left empty on purpose
    }
}
