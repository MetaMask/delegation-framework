// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { DelegationManager } from "../../src/DelegationManager.sol";
import { SimpleDelegationManager } from "../../src/SimpleDelegationManager.sol";
import { EIP7702MultiManagerDeleGator } from "../../src/EIP7702/EIP7702MultiManagerDeleGator.sol";
import { EIP7702MultiManagerDeleGatorCore } from "../../src/EIP7702/EIP7702MultiManagerDeleGatorCore.sol";
import { CaveatEnforcer } from "../../src/enforcers/CaveatEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { ModeSelector, ModePayload, ModeCode, Caveat, Delegation } from "../../src/utils/Types.sol";
import { CALLTYPE_SINGLE, EXECTYPE_DEFAULT, EXECTYPE_TRY, MODE_DEFAULT } from "../../src/utils/Constants.sol";

contract RejectingPolicyAccount {
    bool public executed;

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }

    function executeFromExecutor(ModeCode, bytes calldata) external payable returns (bytes[] memory returnData_) {
        executed = true;
        returnData_ = new bytes[](0);
    }
}

contract RecoverToSelfAccount {
    bool public executed;

    function isValidSignature(bytes32 _hash, bytes calldata _signature) external view returns (bytes4) {
        (address recovered_, ECDSA.RecoverError error_,) = ECDSA.tryRecover(_hash, _signature);
        return error_ == ECDSA.RecoverError.NoError && recovered_ == address(this) ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function executeFromExecutor(ModeCode, bytes calldata) external payable returns (bytes[] memory returnData_) {
        executed = true;
        returnData_ = new bytes[](0);
    }
}

contract AfterHookRevertingEnforcer is CaveatEnforcer {
    error AfterHookReached();

    function afterHook(bytes calldata, bytes calldata, ModeCode, bytes calldata, bytes32, address, address) public pure override {
        revert AfterHookReached();
    }
}

contract ReviewTarget {
    bool public called;

    function markCalled() external {
        called = true;
    }
}

/**
 * @notice Local review regressions that demonstrate production-readiness findings on PR #189.
 * @dev These tests intentionally document current unsafe or inconsistent behavior and should be
 *      converted into negative regression tests when the implementation is fixed.
 */
contract OptimizedDelegationManagerReviewTest is Test {
    bytes32 internal constant ROOT_AUTHORITY = bytes32(type(uint256).max);
    bytes32 internal constant TRY_FAILURE_EVENT = keccak256("TryExecuteUnsuccessful(uint256,bytes)");

    uint256 internal constant OWNER_KEY = 0xA11CE;

    address internal owner;
    address internal relayer;

    DelegationManager internal canonicalManager;
    SimpleDelegationManager internal simpleManager;
    EIP7702MultiManagerDeleGator internal multiManagerImplementation;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        relayer = makeAddr("relayer");
        canonicalManager = new DelegationManager(address(this));
        simpleManager = new SimpleDelegationManager();
        multiManagerImplementation = new EIP7702MultiManagerDeleGator();
    }

    function test_simpleManagerBypassesRejectingERC1271Policy() public {
        RejectingPolicyAccount template_ = new RejectingPolicyAccount();
        vm.etch(owner, address(template_).code);

        Delegation[] memory simpleDelegations_ =
            _signedRootDelegations(IDelegationManager(address(simpleManager)), owner, relayer, new Caveat[](0));

        _redeem(IDelegationManager(address(simpleManager)), simpleDelegations_);

        assertTrue(RejectingPolicyAccount(owner).executed(), "Simple manager bypassed ERC-1271 and executed");

        vm.store(owner, bytes32(0), bytes32(0));
        Delegation[] memory canonicalDelegations_ =
            _signedRootDelegations(IDelegationManager(address(canonicalManager)), owner, relayer, new Caveat[](0));

        vm.expectRevert(IDelegationManager.InvalidERC1271Signature.selector);
        _redeem(IDelegationManager(address(canonicalManager)), canonicalDelegations_);
        assertFalse(RejectingPolicyAccount(owner).executed(), "Canonical manager must honor ERC-1271 rejection");
    }

    function test_unsupportedAfterHookCaveatFailsOpenOnSimpleManager() public {
        RecoverToSelfAccount template_ = new RecoverToSelfAccount();
        vm.etch(owner, address(template_).code);

        AfterHookRevertingEnforcer enforcer_ = new AfterHookRevertingEnforcer();
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(enforcer_), terms: hex"", args: hex"" });

        Delegation[] memory simpleDelegations_ =
            _signedRootDelegations(IDelegationManager(address(simpleManager)), owner, relayer, caveats_);
        _redeem(IDelegationManager(address(simpleManager)), simpleDelegations_);
        assertTrue(RecoverToSelfAccount(owner).executed(), "Simple manager silently skipped afterHook");

        vm.store(owner, bytes32(0), bytes32(0));
        Delegation[] memory canonicalDelegations_ =
            _signedRootDelegations(IDelegationManager(address(canonicalManager)), owner, relayer, caveats_);

        vm.expectRevert(AfterHookRevertingEnforcer.AfterHookReached.selector);
        _redeem(IDelegationManager(address(canonicalManager)), canonicalDelegations_);
        assertFalse(RecoverToSelfAccount(owner).executed(), "Canonical afterHook revert must roll execution back");
    }

    function test_relayerCannotBootstrapFirstDelegationManager() public {
        EIP7702MultiManagerDeleGator account_ = _installMultiManagerAccount(owner);

        vm.prank(relayer);
        vm.expectRevert(EIP7702MultiManagerDeleGatorCore.NotSelf.selector);
        account_.approveDelegationManager(IDelegationManager(address(canonicalManager)));

        assertFalse(account_.isApprovedDelegationManager(IDelegationManager(address(canonicalManager))));
    }

    function test_approvedManagerCanPersistAuthorityThroughAccountSelfCall() public {
        EIP7702MultiManagerDeleGator account_ = _installMultiManagerAccount(owner);
        address rogueManager_ = makeAddr("rogueManager");

        vm.prank(owner);
        account_.approveDelegationManager(IDelegationManager(address(this)));

        bytes memory installRogueCall_ =
            abi.encodeCall(EIP7702MultiManagerDeleGatorCore.approveDelegationManager, (IDelegationManager(rogueManager_)));
        account_.executeFromExecutor(ModeLib.encodeSimpleSingle(), ExecutionLib.encodeSingle(owner, 0, installRogueCall_));

        vm.prank(owner);
        account_.revokeDelegationManager(IDelegationManager(address(this)));

        ReviewTarget target_ = new ReviewTarget();
        vm.prank(rogueManager_);
        account_.executeFromExecutor(
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(address(target_), 0, abi.encodeCall(ReviewTarget.markCalled, ()))
        );

        assertTrue(target_.called(), "Rogue manager retained root execution after original manager revocation");
    }

    function test_executionAcceptsModeReportedAsUnsupported() public {
        EIP7702MultiManagerDeleGator account_ = _installMultiManagerAccount(owner);
        vm.prank(owner);
        account_.approveDelegationManager(IDelegationManager(address(this)));

        ModeCode unsupportedMode_ = ModeLib.encode(
            CALLTYPE_SINGLE, EXECTYPE_DEFAULT, ModeSelector.wrap(bytes4(0xdeadbeef)), ModePayload.wrap(bytes22(0))
        );
        assertFalse(account_.supportsExecutionMode(unsupportedMode_));

        ReviewTarget target_ = new ReviewTarget();
        account_.executeFromExecutor(
            unsupportedMode_, ExecutionLib.encodeSingle(address(target_), 0, abi.encodeCall(ReviewTarget.markCalled, ()))
        );

        assertTrue(target_.called(), "Unsupported mode still executed");
    }

    function test_oldERC7579DependencyReportsSuccessfulTryCallAsFailure() public {
        EIP7702MultiManagerDeleGator account_ = _installMultiManagerAccount(owner);
        vm.prank(owner);
        account_.approveDelegationManager(IDelegationManager(address(this)));

        ReviewTarget target_ = new ReviewTarget();
        ModeCode tryMode_ = ModeLib.encode(CALLTYPE_SINGLE, EXECTYPE_TRY, MODE_DEFAULT, ModePayload.wrap(bytes22(0)));

        vm.recordLogs();
        account_.executeFromExecutor(
            tryMode_, ExecutionLib.encodeSingle(address(target_), 0, abi.encodeCall(ReviewTarget.markCalled, ()))
        );
        Vm.Log[] memory logs_ = vm.getRecordedLogs();

        assertTrue(target_.called(), "Underlying TRY call succeeded");
        assertTrue(_containsTryFailureEvent(logs_, owner), "Old dependency emitted a failure event for the successful call");
    }

    function _installMultiManagerAccount(address _account) internal returns (EIP7702MultiManagerDeleGator account_) {
        vm.etch(_account, bytes.concat(hex"ef0100", abi.encodePacked(address(multiManagerImplementation))));
        account_ = EIP7702MultiManagerDeleGator(payable(_account));
    }

    function _signedRootDelegations(
        IDelegationManager _manager,
        address _delegator,
        address _delegate,
        Caveat[] memory _caveats
    )
        internal
        view
        returns (Delegation[] memory delegations_)
    {
        Delegation memory delegation_ = Delegation({
            delegate: _delegate, delegator: _delegator, authority: ROOT_AUTHORITY, caveats: _caveats, salt: 0, signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 digest_ = MessageHashUtils.toTypedDataHash(_manager.getDomainHash(), delegationHash_);
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(OWNER_KEY, digest_);
        delegation_.signature = abi.encodePacked(r_, s_, v_);

        delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
    }

    function _redeem(IDelegationManager _manager, Delegation[] memory _delegations) internal {
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleSingle();
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = hex"";

        vm.prank(relayer);
        _manager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);
    }

    function _containsTryFailureEvent(Vm.Log[] memory _logs, address _emitter) internal pure returns (bool) {
        for (uint256 i_; i_ < _logs.length; ++i_) {
            if (_logs[i_].emitter == _emitter && _logs[i_].topics.length > 0 && _logs[i_].topics[0] == TRY_FAILURE_EVENT) {
                return true;
            }
        }
        return false;
    }
}
