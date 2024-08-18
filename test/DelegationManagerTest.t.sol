// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ShortStrings, ShortString } from "@openzeppelin/contracts/utils/ShortStrings.sol";

import { Counter } from "./utils/Counter.t.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { Delegation, Caveat, Action } from "../src/utils/Types.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { DelegationManager } from "../src/DelegationManager.sol";
import { Invalid1271Returns, Invalid1271Reverts } from "./utils/Invalid1271.t.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { EIP712_DOMAIN_TYPEHASH } from "../src/utils/Typehashes.sol";
import { MockCaveatEnforcer } from "./utils/MockCaveatEnforcer.sol";
import { MockFailureCaveatEnforcer } from "./utils/MockFailureCaveatEnforcer.sol";

contract DelegationManagerTest is BaseTest {
    using ShortStrings for *;

    string private _nameFallback;
    string private _versionFallback;

    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
    }

    ////////////////////////////// Events //////////////////////////////

    event SetDomain(
        bytes32 indexed domainHash, string contractName, string domainVersion, uint256 chainId, address indexed contractAddress
    );
    event Paused(address account);
    event Unpaused(address account);
    event TransferredOwnership();

    ////////////////////////////// External Methods //////////////////////////////

    // Should allow reading contract name
    function test_allow_contractNameReads() public {
        string memory contractName_ = delegationManager.NAME();
        assertEq("DelegationManager", contractName_);
    }

    // Should allow reading contract version
    function test_allow_contractVersionReads() public {
        string memory contractVersion_ = delegationManager.VERSION();
        assertEq("1.0.0", contractVersion_);
    }

    // Should allow reading contract version
    function test_allow_domainVersionReads() public {
        string memory domainVersion_ = delegationManager.DOMAIN_VERSION();
        assertEq("1", domainVersion_);
    }

    function test_allow_rootAuthorityReads() public {
        bytes32 rootAuthority = delegationManager.ROOT_AUTHORITY();
        bytes32 expectedRootAuthority = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
        assertEq(expectedRootAuthority, rootAuthority);
    }

    function test_allow_anyDelegateReads() public {
        address anyDelegateAddress = delegationManager.ANY_DELEGATE();
        assertEq(address(0xa11), anyDelegateAddress);
    }

    // Should allow reading domain hash
    function test_allow_domainHashReads() public {
        bytes32 domainHash_ = delegationManager.getDomainHash();
        bytes32 expectedDomainHash_ = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(delegationManager.NAME())),
                keccak256(bytes(delegationManager.DOMAIN_VERSION())),
                block.chainid,
                address(delegationManager)
            )
        );
        assertEq(expectedDomainHash_, domainHash_);
    }

    // Should allow reading domain hash when chain id changes
    function test_allow_domainHashReadsWhenChainIdChanges() public {
        uint256 newChainId_ = 123456789;
        // Update the chainId
        vm.chainId(newChainId_);

        bytes32 domainHash_ = delegationManager.getDomainHash();
        bytes32 expectedDomainHash_ = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(delegationManager.NAME())),
                keccak256(bytes(delegationManager.DOMAIN_VERSION())),
                newChainId_,
                address(delegationManager)
            )
        );
        assertEq(expectedDomainHash_, domainHash_);
    }

    // Should not allow signatures for one DelegationManager to work on another DelegationManager
    function test_notAllow_crossDelegationManagerReplays() public {
        // Create a new delegation manager to test against
        DelegationManager delegationManager2_ = new DelegationManager(bundler);

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Get EIP712 signature of a Delegation using the domain separator of the original DelegationManager
        bytes32 delegationHash_ = delegationManager.getDelegationHash(delegation_);
        delegation_ = signDelegation(users.alice, delegation_);

        // Get the typed data hash from the new delegation manager
        // The DelegationManager will build this typed data hash when checking signature validity
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(delegationManager2_.getDomainHash(), delegationHash_);

        // Validate the signature (SIG_VALIDATION_FAILED = 0xffffffff)
        bytes4 validationData_ = users.alice.deleGator.isValidSignature(typedDataHash_, delegation_.signature);
        assertEq(validationData_, bytes4(0xffffffff));
    }

    // should expose a method for retrieval of a delegations hash
    function test_allow_getDelegationHash() public {
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        bytes32 hash_ = delegationManager.getDelegationHash(delegation_);
        assertEq(hash_, EncoderLib._getDelegationHash(delegation_));
    }

    function test_notAllow_invalidSignatureReverts() public {
        Invalid1271Reverts invalidAccount_ = new Invalid1271Reverts();

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(invalidAccount_),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: new bytes(10)
        });

        // Validate the signature
        vm.expectRevert(bytes("Error"));
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        vm.prank(address(users.bob.addr));

        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encode(delegations_);

        Action[] memory actions_ = new Action[](1);
        actions_[0] = Action({ to: address(0), data: new bytes(0), value: 0 });

        delegationManager.redeemDelegation(dataArray, actions_);
    }

    function test_notAllow_invalidSignatureReturns() public {
        Invalid1271Returns invalidAccount_ = new Invalid1271Returns();

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(invalidAccount_),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: new bytes(10)
        });

        // Validate the signature
        vm.expectRevert(abi.encodeWithSelector(IDelegationManager.InvalidSignature.selector));
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        vm.prank(address(users.bob.addr));

        bytes[] memory dataArray = new bytes[](1);
        dataArray[0] = abi.encode(delegations_);

        Action[] memory actions_ = new Action[](1);
        actions_[0] = Action({ to: address(0), data: new bytes(0), value: 0 });

        delegationManager.redeemDelegation(dataArray, actions_);
    }

    function test_allow_redeemBatchDelegation() public {
        // Create a mock caveat enforcers contract
        MockCaveatEnforcer mockEnforcer = new MockCaveatEnforcer();

        // Create delegations with caveats
        Delegation memory delegation1 = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        delegation1.caveats[0] = Caveat({ enforcer: address(mockEnforcer), terms: hex"", args: hex"" });

        Delegation memory delegation2 = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        delegation2.caveats[0] = Caveat({ enforcer: address(mockEnforcer), terms: hex"", args: hex"" });

        bytes[] memory permissionContexts = new bytes[](2);

        // Sign delegations
        delegation1 = signDelegation(users.alice, delegation1);
        delegation2 = signDelegation(users.alice, delegation2);

        Delegation[] memory delegations1 = new Delegation[](1);
        delegations1[0] = delegation1;
        permissionContexts[0] = abi.encode(delegations1);

        Delegation[] memory delegations2 = new Delegation[](1);
        delegations2[0] = delegation2;
        permissionContexts[1] = abi.encode(delegations2);

        Action[] memory actions = new Action[](2);
        actions[0] = Action({ to: address(0), data: hex"", value: 0 });
        actions[1] = Action({ to: address(0), data: hex"", value: 0 });

        vm.prank(address(users.bob.addr));
        delegationManager.redeemDelegation(permissionContexts, actions);

        // Assert that beforeHook was called for each action
        assertEq(mockEnforcer.beforeHookCallCount(), 2);

        // Assert that afterHook was called after executing all actions
        assertEq(mockEnforcer.afterHookCallCount(), 2);
    }

    function test_allow_redeemBatchDelegationMixedWithNoDelegation() public {
        Counter aliceDeleGatorCounter = new Counter(address(users.alice.deleGator));
        Counter bobDeleGatorCounter = new Counter(address(users.bob.deleGator));

        // Create a mock caveat enforcers contract
        MockCaveatEnforcer mockEnforcer = new MockCaveatEnforcer();

        // Create delegations with caveats
        Delegation memory delegation1 = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        delegation1.caveats[0] = Caveat({ enforcer: address(mockEnforcer), terms: hex"", args: hex"" });

        // Create delegations with caveats
        Delegation memory delegation3 = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        delegation3.caveats[0] = Caveat({ enforcer: address(mockEnforcer), terms: hex"", args: hex"" });

        bytes[] memory permissionContexts = new bytes[](3);

        // Sign delegations
        delegation1 = signDelegation(users.alice, delegation1);
        delegation3 = signDelegation(users.alice, delegation3);

        Delegation[] memory delegations1 = new Delegation[](1);
        delegations1[0] = delegation1;
        permissionContexts[0] = abi.encode(delegations1);

        // This is an empty delegation for a self execution
        Delegation[] memory delegations2 = new Delegation[](0);
        permissionContexts[1] = abi.encode(delegations2);

        Delegation[] memory delegations3 = new Delegation[](1);
        delegations3[0] = delegation3;
        permissionContexts[2] = abi.encode(delegations3);

        Action memory incrementCounter_ =
            Action({ to: address(aliceDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        Action[] memory actions = new Action[](3);
        actions[0] = incrementCounter_;
        actions[1] =
            Action({ to: address(bobDeleGatorCounter), value: 0, data: abi.encodeWithSelector(Counter.increment.selector) });
        actions[2] = incrementCounter_;

        assertEq(aliceDeleGatorCounter.count(), 0);
        assertEq(bobDeleGatorCounter.count(), 0);

        vm.prank(address(users.bob.deleGator));
        delegationManager.redeemDelegation(permissionContexts, actions);

        // Assert that beforeHook was called for each action
        assertEq(mockEnforcer.beforeHookCallCount(), 2);

        // Assert that afterHook was called after executing all actions
        assertEq(mockEnforcer.afterHookCallCount(), 2);

        assertEq(aliceDeleGatorCounter.count(), 2);
        assertEq(bobDeleGatorCounter.count(), 1);
    }

    function test_allow_redeemBatchWithEoaInSecondBatchDelegation() public {
        // Create a mock caveat enforcers contract
        MockCaveatEnforcer mockEnforcer = new MockCaveatEnforcer();

        // Create delegations with caveats
        Delegation memory delegation1 = Delegation({
            delegate: address(users.carol.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        delegation1.caveats[0] = Caveat({ enforcer: address(mockEnforcer), terms: hex"", args: hex"" });

        Delegation memory delegation2 = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        delegation2.caveats[0] = Caveat({ enforcer: address(mockEnforcer), terms: hex"", args: hex"" });

        bytes32 delegation2Hash = delegationManager.getDelegationHash(delegation2);

        Delegation memory delegation3 = Delegation({
            delegate: address(users.carol.addr),
            delegator: address(users.bob.addr),
            authority: delegation2Hash,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        delegation3.caveats[0] = Caveat({ enforcer: address(mockEnforcer), terms: hex"", args: hex"" });

        bytes[] memory permissionContexts = new bytes[](2);

        // Sign delegations
        delegation1 = signDelegation(users.alice, delegation1);
        delegation2 = signDelegation(users.alice, delegation2);

        // Sign a delegation with an EOA
        bytes32 delegation3Hash = EncoderLib._getDelegationHash(delegation3);
        bytes32 domainHash = delegationManager.getDomainHash();
        bytes32 typedData3Hash = MessageHashUtils.toTypedDataHash(domainHash, delegation3Hash);
        delegation3.signature = signHash(SignatureType.EOA, users.bob, typedData3Hash);

        Delegation[] memory delegations1 = new Delegation[](1);
        delegations1[0] = delegation1;
        permissionContexts[0] = abi.encode(delegations1);

        Delegation[] memory delegations2 = new Delegation[](2);
        delegations2[0] = delegation3;
        delegations2[1] = delegation2;
        permissionContexts[1] = abi.encode(delegations2);

        Action[] memory actions = new Action[](2);
        actions[0] = Action({ to: address(0), data: hex"", value: 0 });
        actions[1] = Action({ to: address(0), data: hex"", value: 0 });

        vm.prank(address(users.carol.addr));
        delegationManager.redeemDelegation(permissionContexts, actions);

        // Assert that beforeHook was called for each action
        assertEq(mockEnforcer.beforeHookCallCount(), 3);

        // Assert that afterHook was called after executing all actions
        assertEq(mockEnforcer.afterHookCallCount(), 3);
    }

    // Should revert when any of the hooks revert
    function test_revert_whenAnyCaveatHookFails() public {
        // Create a mock caveat enforcers contract
        MockCaveatEnforcer mockEnforcer = new MockCaveatEnforcer();
        MockFailureCaveatEnforcer mockFailureEnforcer = new MockFailureCaveatEnforcer();

        // Create delegations with caveats
        Delegation memory delegation1 = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        delegation1.caveats[0] = Caveat({ enforcer: address(mockEnforcer), terms: hex"", args: hex"" });

        Delegation memory delegation2 = Delegation({
            delegate: address(users.bob.addr),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        delegation2.caveats[0] = Caveat({ enforcer: address(mockFailureEnforcer), terms: hex"", args: hex"" });

        bytes[] memory permissionContexts = new bytes[](2);

        // Sign delegations
        delegation1 = signDelegation(users.alice, delegation1);
        delegation2 = signDelegation(users.alice, delegation2);

        Delegation[] memory delegations1 = new Delegation[](1);
        delegations1[0] = delegation1;
        permissionContexts[0] = abi.encode(delegations1);

        Delegation[] memory delegations2 = new Delegation[](1);
        delegations2[0] = delegation2;
        permissionContexts[1] = abi.encode(delegations2);

        Action[] memory actions_ = new Action[](2);
        actions_[0] = Action({ to: address(0), data: hex"", value: 0 });
        actions_[1] = Action({ to: address(0), data: hex"", value: 0 });

        vm.prank(address(users.bob.addr));
        vm.expectRevert();
        delegationManager.redeemDelegation(permissionContexts, actions_);
    }

    /////////////////////////////// Ownership //////////////////////////////

    // Should allow to transfer and accept the ownership
    function test_ownership_transferAndAcceptOwnership() public {
        address currentOwner_ = delegationManager.owner();
        address newOwner_ = users.alice.addr;
        vm.prank(currentOwner_);

        vm.expectEmit(true, true, true, true, address(delegationManager));
        emit Ownable2Step.OwnershipTransferStarted(currentOwner_, newOwner_);
        delegationManager.transferOwnership(newOwner_);

        assertEq(delegationManager.pendingOwner(), newOwner_);

        vm.prank(newOwner_);
        vm.expectEmit(true, true, true, true, address(delegationManager));
        emit Ownable.OwnershipTransferred(currentOwner_, newOwner_);
        delegationManager.acceptOwnership();

        assertEq(delegationManager.owner(), newOwner_);
    }

    /////////////////////////////// Pausability //////////////////////////////

    // Should allow reading initial pause state
    function test_pausability_validateInitialPauseState() public {
        DelegationManager delegationManager_ = new DelegationManager(bundler);
        assertFalse(delegationManager_.paused());
    }

    // Should allow owner to pause
    function test_pausability_allowsOwnerToPause() public {
        assertFalse(delegationManager.paused());

        vm.startPrank(delegationManager.owner());
        vm.expectEmit(true, true, true, true, address(delegationManager));
        emit Paused(delegationManager.owner());
        delegationManager.pause();

        assertTrue(delegationManager.paused());
    }

    // Should allow owner to unpause
    function test_pausability_allowsOwnerToUnpause() public {
        // Pausing
        vm.startPrank(delegationManager.owner());
        delegationManager.pause();
        assertTrue(delegationManager.paused());

        // Unpausing
        vm.expectEmit(true, true, true, true, address(delegationManager));
        emit Unpaused(delegationManager.owner());
        delegationManager.unpause();
        assertFalse(delegationManager.paused());
    }

    // Should not allow not owner to unpause
    function test_pausability_failsToPauseIfNotOwner() public {
        assertFalse(delegationManager.paused());

        vm.prank(users.bob.addr);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.bob.addr));
        delegationManager.pause();

        assertFalse(delegationManager.paused());
    }

    // Should not allow not owner to unpause
    function test_pausability_failsToUnpauseIfNotOwner() public {
        // Pausing
        vm.prank(delegationManager.owner());
        delegationManager.pause();
        assertTrue(delegationManager.paused());

        // Unpausing
        vm.prank(users.bob.addr);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.bob.addr));
        delegationManager.pause();
        assertTrue(delegationManager.paused());
    }

    // Should allow owner to pause redemptions
    function test_pausability_allowsOwnerToPauseRedemptions() public {
        assertFalse(delegationManager.paused());

        vm.startPrank(delegationManager.owner());
        delegationManager.pause();

        Action[] memory actions_ = new Action[](1);

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = hex"";

        vm.expectRevert(Pausable.EnforcedPause.selector);
        delegationManager.redeemDelegation(permissionContexts_, actions_);
    }

    // Should fail to pause when the pause is active
    function test_pausability_failsToPauseWhenActivePause() public {
        // First pause
        vm.startPrank(delegationManager.owner());
        delegationManager.pause();
        assertTrue(delegationManager.paused());

        // Second pause
        vm.expectRevert(Pausable.EnforcedPause.selector);
        delegationManager.pause();
    }

    // Should fail to unpause when the pause is active
    function test_pausability_failsToPauseWhenActiveUnpause() public {
        // It is unpaused
        assertFalse(delegationManager.paused());

        // Trying to unpause again
        vm.startPrank(delegationManager.owner());
        vm.expectRevert(Pausable.ExpectedPause.selector);
        delegationManager.unpause();
    }
}
