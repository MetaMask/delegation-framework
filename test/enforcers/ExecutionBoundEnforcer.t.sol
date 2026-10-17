// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ExecutionBoundEnforcer } from "../../src/enforcers/ExecutionBoundEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Caveat, Delegation } from "../../src/utils/Types.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

contract ExecutionBoundEnforcerTest is CaveatEnforcerBaseTest {
    using MessageHashUtils for bytes32;

    ExecutionBoundEnforcer public enforcer;
    BasicERC20 public basicCF20;

    uint256 signerPrivateKey = 0xA11CE;
    address signer;

    function setUp() public override {
        super.setUp();
        enforcer = new ExecutionBoundEnforcer();
        vm.label(address(enforcer), "Execution Bound Enforcer");
        basicCF20 = new BasicERC20(address(users.alice.deleGator), "TestToken1", "TestToken1", 100 ether);
        signer = vm.addr(signerPrivateKey);
    }

    // terms = abi.encode(address authorizedSigner)
    function _buildTerms(address authorizedSigner_) internal pure returns (bytes memory) {
        return abi.encode(authorizedSigner_);
    }

    function _buildIntent(
        address account_,
        address target_,
        uint256 value_,
        bytes memory callData_,
        uint256 nonce_,
        uint256 deadline_
    ) internal pure returns (ExecutionBoundEnforcer.ExecutionIntent memory) {
        return ExecutionBoundEnforcer.ExecutionIntent({
            account:  account_,
            target:   target_,
            value:    value_,
            dataHash: keccak256(callData_),
            nonce:    nonce_,
            deadline: deadline_
        });
    }

    function _signIntent(ExecutionBoundEnforcer.ExecutionIntent memory intent_) internal view returns (bytes memory) {
        bytes32 digest_ = enforcer.intentDigest(intent_);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest_);
        return abi.encodePacked(r, s, v);
    }

    // args = abi.encode(ExecutionIntent intent, bytes signature)
    function _buildArgs(ExecutionBoundEnforcer.ExecutionIntent memory intent_, bytes memory sig_)
        internal pure returns (bytes memory) {
        return abi.encode(intent_, sig_);
    }

    function test_exactExecution_passes() public {
        bytes memory callData_ = abi.encodeWithSelector(
            basicCF20.transfer.selector, address(users.bob.deleGator), 10 ether
        );
        bytes memory execCallData_ = ExecutionLib.encodeSingle(address(basicCF20), 0, callData_);
        ExecutionBoundEnforcer.ExecutionIntent memory intent_ =
            _buildIntent(address(users.alice.deleGator), address(basicCF20), 0, callData_, 0, 0);
        bytes memory terms_ = _buildTerms(signer);
        bytes memory args_ = _buildArgs(intent_, _signIntent(intent_));

        vm.prank(address(delegationManager));
        enforcer.beforeHook(terms_, args_, singleDefaultMode, execCallData_, keccak256(""), address(users.alice.deleGator), address(users.bob.addr));
    }

    function test_nonceConsumed_afterSuccess() public {
        bytes memory callData_ = abi.encodeWithSelector(
            basicCF20.transfer.selector, address(users.bob.deleGator), 10 ether
        );
        bytes memory execCallData_ = ExecutionLib.encodeSingle(address(basicCF20), 0, callData_);
        ExecutionBoundEnforcer.ExecutionIntent memory intent_ =
            _buildIntent(address(users.alice.deleGator), address(basicCF20), 0, callData_, 42, 0);
        bytes memory terms_ = _buildTerms(signer);
        bytes memory args_ = _buildArgs(intent_, _signIntent(intent_));

        assertFalse(enforcer.isNonceUsed(address(delegationManager), address(users.alice.deleGator), 42));
        vm.prank(address(delegationManager));
        enforcer.beforeHook(terms_, args_, singleDefaultMode, execCallData_, keccak256(""), address(users.alice.deleGator), address(users.bob.addr));
        assertTrue(enforcer.isNonceUsed(address(delegationManager), address(users.alice.deleGator), 42));
    }

    function test_mutatedCalldata_reverts() public {
        bytes memory signedCallData_ = abi.encodeWithSelector(
            basicCF20.transfer.selector, address(users.bob.deleGator), 10 ether
        );
        bytes memory mutatedCallData_ = abi.encodeWithSelector(
            basicCF20.transfer.selector, address(users.eve.deleGator), 1000 ether
        );
        bytes memory mutatedExecCallData_ = ExecutionLib.encodeSingle(address(basicCF20), 0, mutatedCallData_);
        ExecutionBoundEnforcer.ExecutionIntent memory intent_ =
            _buildIntent(address(users.alice.deleGator), address(basicCF20), 0, signedCallData_, 0, 0);
        bytes memory terms_ = _buildTerms(signer);
        bytes memory args_ = _buildArgs(intent_, _signIntent(intent_));

        vm.prank(address(delegationManager));
        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundEnforcer.DataHashMismatch.selector,
            keccak256(signedCallData_), keccak256(mutatedCallData_)
        ));
        enforcer.beforeHook(terms_, args_, singleDefaultMode, mutatedExecCallData_, keccak256(""), address(users.alice.deleGator), address(users.bob.addr));
    }

    function test_replay_reverts() public {
        bytes memory callData_ = abi.encodeWithSelector(
            basicCF20.transfer.selector, address(users.bob.deleGator), 10 ether
        );
        bytes memory execCallData_ = ExecutionLib.encodeSingle(address(basicCF20), 0, callData_);
        ExecutionBoundEnforcer.ExecutionIntent memory intent_ =
            _buildIntent(address(users.alice.deleGator), address(basicCF20), 0, callData_, 0, 0);
        bytes memory terms_ = _buildTerms(signer);
        bytes memory args_ = _buildArgs(intent_, _signIntent(intent_));

        vm.prank(address(delegationManager));
        enforcer.beforeHook(terms_, args_, singleDefaultMode, execCallData_, keccak256(""), address(users.alice.deleGator), address(users.bob.addr));

        vm.prank(address(delegationManager));
        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundEnforcer.NonceAlreadyUsed.selector,
            address(delegationManager), address(users.alice.deleGator), 0
        ));
        enforcer.beforeHook(terms_, args_, singleDefaultMode, execCallData_, keccak256(""), address(users.alice.deleGator), address(users.bob.addr));
    }

    function test_unsupportedCallType_reverts() public {
        bytes memory callData_ = abi.encodeWithSelector(
            basicCF20.transfer.selector, address(users.bob.deleGator), 10 ether
        );
        bytes memory execCallData_ = ExecutionLib.encodeSingle(address(basicCF20), 0, callData_);
        ExecutionBoundEnforcer.ExecutionIntent memory intent_ =
            _buildIntent(address(users.alice.deleGator), address(basicCF20), 0, callData_, 0, 0);
        bytes memory terms_ = _buildTerms(signer);
        bytes memory args_ = _buildArgs(intent_, _signIntent(intent_));

        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        enforcer.beforeHook(terms_, args_, batchDefaultMode, execCallData_, keccak256(""), address(users.alice.deleGator), address(users.bob.addr));
    }

    function test_signerDistinctFromDelegator_passes() public {
        assertNotEq(signer, address(users.alice.deleGator));
        assertNotEq(signer, address(users.alice.addr));

        bytes memory callData_ = abi.encodeWithSelector(
            basicCF20.transfer.selector, address(users.bob.deleGator), 10 ether
        );
        bytes memory execCallData_ = ExecutionLib.encodeSingle(address(basicCF20), 0, callData_);
        ExecutionBoundEnforcer.ExecutionIntent memory intent_ =
            _buildIntent(address(users.alice.deleGator), address(basicCF20), 0, callData_, 0, 0);
        bytes memory terms_ = _buildTerms(signer);
        bytes memory args_ = _buildArgs(intent_, _signIntent(intent_));

        vm.prank(address(delegationManager));
        enforcer.beforeHook(terms_, args_, singleDefaultMode, execCallData_, keccak256(""), address(users.alice.deleGator), address(users.bob.addr));
    }

    function test_wrongSigner_reverts() public {
        bytes memory callData_ = abi.encodeWithSelector(
            basicCF20.transfer.selector, address(users.bob.deleGator), 10 ether
        );
        bytes memory execCallData_ = ExecutionLib.encodeSingle(address(basicCF20), 0, callData_);
        ExecutionBoundEnforcer.ExecutionIntent memory intent_ =
            _buildIntent(address(users.alice.deleGator), address(basicCF20), 0, callData_, 0, 0);

        // terms commits to signer, but signature is from a different key
        bytes memory terms_ = _buildTerms(signer);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBADBAD, enforcer.intentDigest(intent_));
        bytes memory args_ = abi.encode(intent_, abi.encodePacked(r, s, v));

        vm.prank(address(delegationManager));
        vm.expectRevert(ExecutionBoundEnforcer.InvalidSignature.selector);
        enforcer.beforeHook(terms_, args_, singleDefaultMode, execCallData_, keccak256(""), address(users.alice.deleGator), address(users.bob.addr));
    }

    function test_wrongAccount_reverts() public {
        bytes memory callData_ = abi.encodeWithSelector(
            basicCF20.transfer.selector, address(users.bob.deleGator), 10 ether
        );
        bytes memory execCallData_ = ExecutionLib.encodeSingle(address(basicCF20), 0, callData_);
        ExecutionBoundEnforcer.ExecutionIntent memory intent_ =
            _buildIntent(address(users.alice.deleGator), address(basicCF20), 0, callData_, 0, 0);
        bytes memory terms_ = _buildTerms(signer);
        bytes memory args_ = _buildArgs(intent_, _signIntent(intent_));

        vm.prank(address(delegationManager));
        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundEnforcer.AccountMismatch.selector,
            address(users.alice.deleGator), address(users.carol.deleGator)
        ));
        enforcer.beforeHook(terms_, args_, singleDefaultMode, execCallData_, keccak256(""), address(users.carol.deleGator), address(users.bob.addr));
    }

    function test_expiredDeadline_reverts() public {
        bytes memory callData_ = abi.encodeWithSelector(
            basicCF20.transfer.selector, address(users.bob.deleGator), 10 ether
        );
        bytes memory execCallData_ = ExecutionLib.encodeSingle(address(basicCF20), 0, callData_);
        vm.warp(1_000_000);
        uint256 deadline_ = block.timestamp - 1;
        ExecutionBoundEnforcer.ExecutionIntent memory intent_ =
            _buildIntent(address(users.alice.deleGator), address(basicCF20), 0, callData_, 0, deadline_);
        bytes memory terms_ = _buildTerms(signer);
        bytes memory args_ = _buildArgs(intent_, _signIntent(intent_));

        vm.prank(address(delegationManager));
        vm.expectRevert(abi.encodeWithSelector(
            ExecutionBoundEnforcer.IntentExpired.selector, deadline_, block.timestamp
        ));
        enforcer.beforeHook(terms_, args_, singleDefaultMode, execCallData_, keccak256(""), address(users.alice.deleGator), address(users.bob.addr));
    }

    function test_directCall_cannotGriefNonce() public {
        // Proves that calling beforeHook directly (not via delegationManager)
        // uses a different msg.sender scope and cannot consume the legitimate nonce
        bytes memory callData_ = abi.encodeWithSelector(
            basicCF20.transfer.selector, address(users.bob.deleGator), 10 ether
        );
        bytes memory execCallData_ = ExecutionLib.encodeSingle(address(basicCF20), 0, callData_);
        ExecutionBoundEnforcer.ExecutionIntent memory intent_ =
            _buildIntent(address(users.alice.deleGator), address(basicCF20), 0, callData_, 0, 0);
        bytes memory terms_ = _buildTerms(signer);
        bytes memory args_ = _buildArgs(intent_, _signIntent(intent_));

        // Attacker calls beforeHook directly — different msg.sender
        address attacker_ = makeAddr("attacker");
        vm.prank(attacker_);
        enforcer.beforeHook(terms_, args_, singleDefaultMode, execCallData_, keccak256(""), address(users.alice.deleGator), address(users.bob.addr));

        // Legitimate redemption via delegationManager still works — nonce not consumed for this manager
        assertFalse(enforcer.isNonceUsed(address(delegationManager), address(users.alice.deleGator), 0));
        vm.prank(address(delegationManager));
        enforcer.beforeHook(terms_, args_, singleDefaultMode, execCallData_, keccak256(""), address(users.alice.deleGator), address(users.bob.addr));
        assertTrue(enforcer.isNonceUsed(address(delegationManager), address(users.alice.deleGator), 0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
