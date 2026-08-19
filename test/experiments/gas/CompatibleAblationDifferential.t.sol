// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { BaseTest } from "../../utils/BaseTest.t.sol";
import { Implementation, SignatureType, TestUser } from "../../utils/Types.t.sol";
import { BasicERC20 } from "../../utils/BasicERC20.t.sol";
import { SigningUtilsLib } from "../../utils/SigningUtilsLib.t.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../../src/utils/Types.sol";
import { EncoderLib } from "../../../src/libraries/EncoderLib.sol";
import { IDelegationManager } from "../../../src/interfaces/IDelegationManager.sol";
import { IDeleGatorCore } from "../../../src/interfaces/IDeleGatorCore.sol";
import { ExactExecutionBatchLimitedCallsEnforcer } from "../../../src/enforcers/ExactExecutionBatchLimitedCallsEnforcer.sol";
import { DelegationManagerC1 } from "../../../src/experiments/manager/DelegationManagerC1.sol";
import { DelegationManagerC2 } from "../../../src/experiments/manager/DelegationManagerC2.sol";
import { DelegationManagerC3 } from "../../../src/experiments/manager/DelegationManagerC3.sol";
import { DelegationManagerC4 } from "../../../src/experiments/manager/DelegationManagerC4.sol";
import { DelegationManagerC5 } from "../../../src/experiments/manager/DelegationManagerC5.sol";
import { EIP7702StatelessDeleGator } from "../../../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { DeleGatorCore } from "../../../src/DeleGatorCore.sol";
import { ExecuteFromExecutorWitnessEnforcer } from "./helpers/ExecuteFromExecutorWitnessEnforcer.sol";

/**
 * @notice Differential tests: C1–C4 must match canonical execution/revert/forwarding; C5 matches execution with lean events.
 * @dev Run: `forge test --match-contract CompatibleAblationDifferential -vv`
 */
contract CompatibleAblationDifferential is BaseTest {
    uint256 internal constant CALL_LIMIT = 1;
    uint256 internal constant USER_AMOUNT = 100e18;

    ExactExecutionBatchLimitedCallsEnforcer internal combinedEnforcer;
    ExecuteFromExecutorWitnessEnforcer internal witnessEnforcer;
    BasicERC20 internal token;

    DelegationManagerC1 internal c1;
    DelegationManagerC2 internal c2;
    DelegationManagerC3 internal c3;
    DelegationManagerC4 internal c4;
    DelegationManagerC5 internal c5;

    TestUser internal c1User;
    TestUser internal c2User;
    TestUser internal c3User;
    TestUser internal c4User;
    TestUser internal c5User;

    address internal relayer;
    address internal recipient;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();

        combinedEnforcer = new ExactExecutionBatchLimitedCallsEnforcer();
        witnessEnforcer = new ExecuteFromExecutorWitnessEnforcer();
        token = new BasicERC20(address(this), "Mock USDC", "USDC", 0);
        token.mint(address(users.alice.deleGator), 1_000_000e18);

        c1 = new DelegationManagerC1(makeAddr("c1-owner"));
        c2 = new DelegationManagerC2(makeAddr("c2-owner"));
        c3 = new DelegationManagerC3(makeAddr("c3-owner"));
        c4 = new DelegationManagerC4(makeAddr("c4-owner"));
        c5 = new DelegationManagerC5(makeAddr("c5-owner"));

        c1User = _etchVariantUser("C1Alice", c1);
        c2User = _etchVariantUser("C2Alice", c2);
        c3User = _etchVariantUser("C3Alice", c3);
        c4User = _etchVariantUser("C4Alice", c4);
        c5User = _etchVariantUser("C5Alice", c5);

        token.mint(address(c1User.deleGator), 1_000_000e18);
        token.mint(address(c2User.deleGator), 1_000_000e18);
        token.mint(address(c3User.deleGator), 1_000_000e18);
        token.mint(address(c4User.deleGator), 1_000_000e18);
        token.mint(address(c5User.deleGator), 1_000_000e18);

        relayer = makeAddr("ablation-relayer");
        recipient = makeAddr("ablation-recipient");
    }

    function test_differential_C1_successMatchesCanonical() public {
        _assertSuccessMatchesCanonical(IDelegationManager(address(c1)), c1User, address(c1User.deleGator));
    }

    function test_differential_C2_successMatchesCanonical() public {
        _assertSuccessMatchesCanonical(IDelegationManager(address(c2)), c2User, address(c2User.deleGator));
    }

    function test_differential_C3_successMatchesCanonical() public {
        _assertSuccessMatchesCanonical(IDelegationManager(address(c3)), c3User, address(c3User.deleGator));
    }

    function test_differential_C4_successMatchesCanonical() public {
        _assertSuccessMatchesCanonical(IDelegationManager(address(c4)), c4User, address(c4User.deleGator));
    }

    function test_differential_C5_executionMatchesCanonical_leanEvents() public {
        Execution[] memory executions_ = _oneExecution();
        bytes memory execData_ = ExecutionLib.encodeBatch(executions_);
        ModeCode mode_ = ModeLib.encodeSimpleBatch();

        uint256 snap_ = vm.snapshot();

        uint256 recipientBeforeCanonical_ = token.balanceOf(recipient);
        uint256 delegatorBeforeCanonical_ = token.balanceOf(address(users.alice.deleGator));
        _redeem(delegationManager, users.alice, address(users.alice.deleGator), mode_, execData_, executions_, false);
        uint256 canonicalRecipientDelta_ = token.balanceOf(recipient) - recipientBeforeCanonical_;
        uint256 canonicalDelegatorAfter_ = token.balanceOf(address(users.alice.deleGator));

        vm.revertTo(snap_);

        uint256 recipientBeforeVariant_ = token.balanceOf(recipient);
        uint256 delegatorBeforeVariant_ = token.balanceOf(address(c5User.deleGator));
        _redeem(c5, c5User, address(c5User.deleGator), mode_, execData_, executions_, false);
        uint256 variantRecipientDelta_ = token.balanceOf(recipient) - recipientBeforeVariant_;
        uint256 variantDelegatorAfter_ = token.balanceOf(address(c5User.deleGator));

        vm.revertTo(snap_);

        assertEq(variantRecipientDelta_, canonicalRecipientDelta_, "recipient delta");
        assertEq(delegatorBeforeCanonical_ - canonicalDelegatorAfter_, delegatorBeforeVariant_ - variantDelegatorAfter_, "delegator spend");
    }

    function test_differential_invalidSignature_sameRevert() public {
        Execution[] memory executions_ = _oneExecution();
        bytes memory execData_ = ExecutionLib.encodeBatch(executions_);
        ModeCode mode_ = ModeLib.encodeSimpleBatch();

        TestUser memory maker_ = createUser("InvalidSigMaker");
        TestUser memory wrongSigner_ = createUser("WrongSigner");
        vm.etch(maker_.addr, ""); // pure EOA delegator for InvalidEOASignature path

        Delegation memory badCanonical_ =
            _signForManager(delegationManager, wrongSigner_, _unsignedDelegation(executions_, maker_.addr));
        Delegation memory badC1_ =
            _signForManager(c1, wrongSigner_, _unsignedDelegation(executions_, maker_.addr));

        vm.expectRevert(IDelegationManager.InvalidEOASignature.selector);
        _redeemSigned(delegationManager, badCanonical_, mode_, execData_);

        vm.expectRevert(IDelegationManager.InvalidEOASignature.selector);
        _redeemSigned(c1, badC1_, mode_, execData_);
    }

    function test_differential_disabledDelegation_sameRevert() public {
        Execution[] memory executions_ = _oneExecution();
        bytes memory execData_ = ExecutionLib.encodeBatch(executions_);
        ModeCode mode_ = ModeLib.encodeSimpleBatch();

        Delegation memory signed_ = _signForManager(
            delegationManager, users.alice, _unsignedDelegation(executions_, address(users.alice.deleGator))
        );
        vm.prank(address(users.alice.deleGator));
        delegationManager.disableDelegation(signed_);

        bytes4 expectedSelector_ = IDelegationManager.CannotUseADisabledDelegation.selector;

        vm.expectRevert(expectedSelector_);
        _redeemSigned(delegationManager, signed_, mode_, execData_);

        Delegation memory signedC1_ =
            _signForManager(c1, c1User, _unsignedDelegation(executions_, address(c1User.deleGator)));
        vm.prank(address(c1User.deleGator));
        c1.disableDelegation(signedC1_);

        vm.expectRevert(expectedSelector_);
        _redeemSigned(c1, signedC1_, mode_, execData_);
    }

    function test_differential_forwardingSpy_C1_C4() public {
        Execution[] memory executions_ = _oneExecution();
        bytes memory execData_ = ExecutionLib.encodeBatch(executions_);
        ModeCode mode_ = ModeLib.encodeSimpleBatch();

        ForwardWitness memory canonical_ = _captureForward(delegationManager, users.alice, address(users.alice.deleGator), mode_, execData_, executions_);
        ForwardWitness memory c1_ = _captureForward(c1, c1User, address(c1User.deleGator), mode_, execData_, executions_);
        ForwardWitness memory c2_ = _captureForward(c2, c2User, address(c2User.deleGator), mode_, execData_, executions_);
        ForwardWitness memory c3_ = _captureForward(c3, c3User, address(c3User.deleGator), mode_, execData_, executions_);
        ForwardWitness memory c4_ = _captureForward(c4, c4User, address(c4User.deleGator), mode_, execData_, executions_);

        _assertForwardWitnessEqual(canonical_, c1_);
        _assertForwardWitnessEqual(canonical_, c2_);
        _assertForwardWitnessEqual(canonical_, c3_);
        _assertForwardWitnessEqual(canonical_, c4_);
    }

    struct ForwardWitness {
        ModeCode mode;
        bytes executionCalldata;
        uint256 witnessCount;
    }

    function _assertSuccessMatchesCanonical(
        IDelegationManager _variant,
        TestUser memory _variantUser,
        address _variantDelegator
    )
        internal
    {
        Execution[] memory executions_ = _oneExecution();
        bytes memory execData_ = ExecutionLib.encodeBatch(executions_);
        ModeCode mode_ = ModeLib.encodeSimpleBatch();

        uint256 snap_ = vm.snapshot();

        uint256 recipientBeforeCanonical_ = token.balanceOf(recipient);
        _redeem(delegationManager, users.alice, address(users.alice.deleGator), mode_, execData_, executions_, false);
        uint256 canonicalRecipientDelta_ = token.balanceOf(recipient) - recipientBeforeCanonical_;

        vm.revertTo(snap_);

        uint256 recipientBeforeVariant_ = token.balanceOf(recipient);
        _redeem(_variant, _variantUser, _variantDelegator, mode_, execData_, executions_, false);
        uint256 variantRecipientDelta_ = token.balanceOf(recipient) - recipientBeforeVariant_;

        vm.revertTo(snap_);

        assertEq(variantRecipientDelta_, canonicalRecipientDelta_, "recipient delta mismatch");
    }

    function _assertForwardWitnessEqual(ForwardWitness memory _a, ForwardWitness memory _b) internal {
        assertEq(ModeCode.unwrap(_a.mode), ModeCode.unwrap(_b.mode), "mode mismatch");
        assertEq(keccak256(_a.executionCalldata), keccak256(_b.executionCalldata), "executionCalldata mismatch");
        assertEq(_a.witnessCount, _b.witnessCount, "witness hook count mismatch");
    }

    function _captureForward(
        IDelegationManager _manager,
        TestUser memory _user,
        address _delegator,
        ModeCode _mode,
        bytes memory _execData,
        Execution[] memory _executions
    )
        internal
        returns (ForwardWitness memory w_)
    {
        witnessEnforcer.resetWitness();

        Delegation memory signed_ = _signForManager(_manager, _user, _witnessDelegation(_executions, _delegator));
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = signed_;

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = _mode;
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = _execData;

        vm.expectCall(_delegator, abi.encodeWithSelector(IDeleGatorCore.executeFromExecutor.selector, _mode, _execData));

        vm.prank(relayer);
        _manager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);

        w_.mode = witnessEnforcer.witnessedMode();
        w_.executionCalldata = witnessEnforcer.witnessedExecutionCalldata();
        w_.witnessCount = witnessEnforcer.witnessCount();
    }

    function _redeem(
        IDelegationManager _manager,
        TestUser memory _user,
        address _delegator,
        ModeCode _mode,
        bytes memory _execData,
        Execution[] memory _executions,
        bool _useWitness
    )
        internal
    {
        Delegation memory unsigned_ =
            _useWitness ? _witnessDelegation(_executions, _delegator) : _unsignedDelegation(_executions, _delegator);
        Delegation memory signed_ = _signForManager(_manager, _user, unsigned_);
        _redeemSigned(_manager, signed_, _mode, _execData);
    }

    function _redeemSigned(IDelegationManager _manager, Delegation memory _signed, ModeCode _mode, bytes memory _execData)
        internal
    {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _signed;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = _mode;
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = _execData;

        vm.prank(relayer);
        _manager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);
    }

    function _unsignedDelegation(Execution[] memory _executions, address _delegator) internal view returns (Delegation memory) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            enforcer: address(combinedEnforcer),
            terms: abi.encodePacked(CALL_LIMIT, ExecutionLib.encodeBatch(_executions)),
            args: hex""
        });

        return Delegation({
            delegate: relayer,
            delegator: _delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
    }

    function _witnessDelegation(Execution[] memory _executions, address _delegator) internal view returns (Delegation memory) {
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({ enforcer: address(witnessEnforcer), terms: hex"", args: hex"" });
        caveats_[1] = Caveat({
            enforcer: address(combinedEnforcer),
            terms: abi.encodePacked(CALL_LIMIT, ExecutionLib.encodeBatch(_executions)),
            args: hex""
        });

        return Delegation({
            delegate: relayer,
            delegator: _delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
    }

    function _signForManager(IDelegationManager _manager, TestUser memory _user, Delegation memory _delegation)
        internal
        view
        returns (Delegation memory signed_)
    {
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(_delegation);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(_manager.getDomainHash(), delegationHash_);
        signed_ = Delegation({
            delegate: _delegation.delegate,
            delegator: _delegation.delegator,
            authority: _delegation.authority,
            caveats: _delegation.caveats,
            salt: _delegation.salt,
            signature: SigningUtilsLib.signHash_EOA(_user.privateKey, typedDataHash_)
        });
    }

    function _etchVariantUser(string memory _name, IDelegationManager _manager) internal returns (TestUser memory user_) {
        user_ = createUser(_name);
        EIP7702StatelessDeleGator impl_ = new EIP7702StatelessDeleGator(_manager, entryPoint);
        vm.etch(user_.addr, bytes.concat(hex"ef0100", abi.encodePacked(address(impl_))));
        user_.deleGator = DeleGatorCore(payable(user_.addr));
    }

    function _oneExecution() internal view returns (Execution[] memory executions_) {
        executions_ = new Execution[](1);
        executions_[0] = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, recipient, USER_AMOUNT)
        });
    }
}
