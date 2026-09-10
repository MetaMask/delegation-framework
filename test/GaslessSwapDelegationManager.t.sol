// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { BaseTest } from "./utils/BaseTest.t.sol";
import { BasicERC20 } from "./utils/BasicERC20.t.sol";
import { MockLimitOrderRouter } from "./utils/MockLimitOrderRouter.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { GaslessSwapDelegationManager } from "../src/GaslessSwapDelegationManager.sol";
import { EIP7702MultiManagerDeleGator } from "../src/EIP7702/EIP7702MultiManagerDeleGator.sol";
import { EIP7702MultiManagerDeleGatorCore } from "../src/EIP7702/EIP7702MultiManagerDeleGatorCore.sol";
import { ERC20BalanceChangeEnforcer } from "../src/enforcers/ERC20BalanceChangeEnforcer.sol";
import { ExactExecutionEnforcer } from "../src/enforcers/ExactExecutionEnforcer.sol";
import { LimitedCallsEnforcer } from "../src/enforcers/LimitedCallsEnforcer.sol";
import { MetaSwap7702CalldataEnforcer } from "../src/enforcers/MetaSwap7702CalldataEnforcer.sol";
import { NativeBalanceChangeEnforcer } from "../src/enforcers/NativeBalanceChangeEnforcer.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { IERC7821 } from "../src/interfaces/IERC7821.sol";
import { IMetaSwap } from "../src/helpers/interfaces/IMetaSwap.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../src/utils/Types.sol";

/**
 * @title GaslessSwapDelegationManagerTest
 * @notice Exercises both supported profiles through an EIP-7702 account that approves multiple delegation managers.
 */
contract GaslessSwapDelegationManagerTest is BaseTest {
    using MessageHashUtils for bytes32;

    uint256 internal constant SWAP_AMOUNT = 1 ether;
    uint256 internal constant TOKEN_OUT_MIN = 0.9 ether;

    ExactExecutionEnforcer internal exactExecutionEnforcer;
    MetaSwap7702CalldataEnforcer internal metaSwap7702CalldataEnforcer;
    LimitedCallsEnforcer internal limitedCallsEnforcer;
    NativeBalanceChangeEnforcer internal nativeBalanceChangeEnforcer;
    ERC20BalanceChangeEnforcer internal erc20BalanceChangeEnforcer;
    GaslessSwapDelegationManager internal swapManager;

    EIP7702MultiManagerDeleGator internal multiManagerImplementation;
    EIP7702MultiManagerDeleGator internal aliceAccount;

    BasicERC20 internal tokenIn;
    BasicERC20 internal tokenOut;
    MockLimitOrderRouter internal router;

    address internal alice;
    address internal relayer;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();

        exactExecutionEnforcer = new ExactExecutionEnforcer();
        metaSwap7702CalldataEnforcer = new MetaSwap7702CalldataEnforcer();
        limitedCallsEnforcer = new LimitedCallsEnforcer();
        nativeBalanceChangeEnforcer = new NativeBalanceChangeEnforcer();
        erc20BalanceChangeEnforcer = new ERC20BalanceChangeEnforcer();
        swapManager = new GaslessSwapDelegationManager(
            address(exactExecutionEnforcer),
            address(metaSwap7702CalldataEnforcer),
            address(limitedCallsEnforcer),
            address(nativeBalanceChangeEnforcer),
            address(erc20BalanceChangeEnforcer)
        );

        alice = users.alice.addr;
        relayer = makeAddr("Relayer");

        multiManagerImplementation = new EIP7702MultiManagerDeleGator();
        vm.etch(alice, bytes.concat(hex"ef0100", abi.encodePacked(address(multiManagerImplementation))));
        aliceAccount = EIP7702MultiManagerDeleGator(payable(alice));

        // The same 7702 account retains the canonical manager and opts into the specialized manager.
        vm.startPrank(alice);
        aliceAccount.approveDelegationManager(IDelegationManager(address(delegationManager)));
        aliceAccount.approveDelegationManager(IDelegationManager(address(swapManager)));
        vm.stopPrank();

        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        router = new MockLimitOrderRouter();

        tokenIn.mint(alice, 100 ether);
        tokenOut.mint(address(router), 100 ether);
        vm.deal(address(router), 100 ether);
        router.setERC20AmountOut(SWAP_AMOUNT);
        router.setNativeAmountOut(SWAP_AMOUNT);
    }

    function test_multiManagerAccountApprovesCanonicalAndSwapManagers() public {
        assertTrue(aliceAccount.isApprovedDelegationManager(IDelegationManager(address(delegationManager))));
        assertTrue(aliceAccount.isApprovedDelegationManager(IDelegationManager(address(swapManager))));
    }

    function test_gaslessProfile_nativeInERC20Out() public {
        Execution memory execution_ = _wrap7702Batch(_nativeInERC20OutExecutions());
        Delegation memory delegation_ = _signDelegation(_gaslessCaveats(execution_));

        uint256 tokenBefore_ = tokenOut.balanceOf(alice);
        uint256 nativeBefore_ = alice.balance;

        _redeem(delegation_, execution_);

        assertEq(tokenOut.balanceOf(alice), tokenBefore_ + SWAP_AMOUNT);
        assertEq(alice.balance, nativeBefore_ - SWAP_AMOUNT);
    }

    function test_gaslessProfile_erc20InNativeOut() public {
        Execution memory execution_ = _wrap7702Batch(_erc20InNativeOutExecutions());
        Delegation memory delegation_ = _signDelegation(_gaslessCaveats(execution_));

        uint256 tokenBefore_ = tokenIn.balanceOf(alice);
        uint256 nativeBefore_ = alice.balance;

        _redeem(delegation_, execution_);

        assertEq(tokenIn.balanceOf(alice), tokenBefore_ - SWAP_AMOUNT);
        assertEq(alice.balance, nativeBefore_ + SWAP_AMOUNT);
    }

    function test_gaslessProfile_replayReverts() public {
        Execution memory execution_ = _wrap7702Batch(_nativeInERC20OutExecutions());
        Delegation memory delegation_ = _signDelegation(_gaslessCaveats(execution_));

        _redeem(delegation_, execution_);

        vm.expectRevert("LimitedCallsEnforcer:limit-exceeded");
        _redeem(delegation_, execution_);
    }

    function test_limitOrder_erc20OutputEnforcesMinimumIncrease() public {
        Execution memory execution_ = _wrap7702Batch(_nativeInERC20OutExecutions());
        Caveat memory balanceCaveat_ = Caveat({
            enforcer: address(erc20BalanceChangeEnforcer),
            terms: abi.encodePacked(false, address(tokenOut), alice, TOKEN_OUT_MIN),
            args: hex""
        });
        Delegation memory delegation_ = _signDelegation(_limitOrderCaveats(execution_, balanceCaveat_));

        uint256 balanceBefore_ = tokenOut.balanceOf(alice);
        _redeem(delegation_, execution_);

        assertEq(tokenOut.balanceOf(alice), balanceBefore_ + SWAP_AMOUNT);
    }

    function test_limitOrder_nativeOutputEnforcesMinimumIncrease() public {
        Execution memory execution_ = _wrap7702Batch(_erc20InNativeOutExecutions());
        Caveat memory balanceCaveat_ = Caveat({
            enforcer: address(nativeBalanceChangeEnforcer), terms: abi.encodePacked(false, alice, TOKEN_OUT_MIN), args: hex""
        });
        Delegation memory delegation_ = _signDelegation(_limitOrderCaveats(execution_, balanceCaveat_));

        uint256 balanceBefore_ = alice.balance;
        _redeem(delegation_, execution_);

        assertEq(alice.balance, balanceBefore_ + SWAP_AMOUNT);
    }

    function test_flexibleMetaSwapLimitOrder_erc20OneApproval() public {
        Execution memory execution_ =
            _wrap7702Batch(_metaSwapERC20Executions(false, "best-route", abi.encode(tokenOut, SWAP_AMOUNT)));
        Caveat memory balanceCaveat_ = Caveat({
            enforcer: address(erc20BalanceChangeEnforcer),
            terms: abi.encodePacked(false, address(tokenOut), alice, TOKEN_OUT_MIN),
            args: hex""
        });
        Delegation memory delegation_ = _signDelegation(_dynamicLimitOrderCaveats(address(tokenIn), false, balanceCaveat_));

        _redeem(delegation_, execution_);

        assertEq(tokenIn.balanceOf(alice), 99 ether);
        assertEq(tokenOut.balanceOf(alice), SWAP_AMOUNT);
    }

    function test_flexibleMetaSwapLimitOrder_erc20ResetApproval() public {
        vm.prank(alice);
        tokenIn.approve(address(router), 1);

        Execution memory execution_ =
            _wrap7702Batch(_metaSwapERC20Executions(true, "best-route", abi.encode(tokenOut, SWAP_AMOUNT)));
        Caveat memory balanceCaveat_ = Caveat({
            enforcer: address(erc20BalanceChangeEnforcer),
            terms: abi.encodePacked(false, address(tokenOut), alice, TOKEN_OUT_MIN),
            args: hex""
        });
        Delegation memory delegation_ = _signDelegation(_dynamicLimitOrderCaveats(address(tokenIn), true, balanceCaveat_));

        _redeem(delegation_, execution_);

        assertEq(tokenIn.balanceOf(alice), 99 ether);
        assertEq(tokenOut.balanceOf(alice), SWAP_AMOUNT);
        assertEq(tokenIn.allowance(alice, address(router)), 0);
    }

    function test_flexibleMetaSwapLimitOrder_nativeInput() public {
        Execution memory execution_ = _wrap7702Batch(_metaSwapNativeExecutions("best-route", abi.encode(tokenOut, SWAP_AMOUNT)));
        Caveat memory balanceCaveat_ = Caveat({
            enforcer: address(erc20BalanceChangeEnforcer),
            terms: abi.encodePacked(false, address(tokenOut), alice, TOKEN_OUT_MIN),
            args: hex""
        });
        Delegation memory delegation_ = _signDelegation(_dynamicLimitOrderCaveats(address(0), false, balanceCaveat_));

        uint256 nativeBefore_ = alice.balance;
        _redeem(delegation_, execution_);

        assertEq(alice.balance, nativeBefore_ - SWAP_AMOUNT);
        assertEq(tokenOut.balanceOf(alice), SWAP_AMOUNT);
    }

    function test_flexibleMetaSwapLimitOrder_nativeOutput() public {
        Execution memory execution_ = _wrap7702Batch(
            _metaSwapERC20Executions(false, "best-route", abi.encode(IERC20(address(0)), SWAP_AMOUNT))
        );
        Caveat memory balanceCaveat_ = Caveat({
            enforcer: address(nativeBalanceChangeEnforcer), terms: abi.encodePacked(false, alice, TOKEN_OUT_MIN), args: hex""
        });
        Delegation memory delegation_ =
            _signDelegation(_dynamicLimitOrderCaveats(address(tokenIn), false, balanceCaveat_));

        uint256 nativeBefore_ = alice.balance;
        _redeem(delegation_, execution_);

        assertEq(tokenIn.balanceOf(alice), 99 ether);
        assertEq(alice.balance, nativeBefore_ + SWAP_AMOUNT);
    }

    function test_flexibleMetaSwapLimitOrder_badRouteCanRetryWithDifferentCalldata() public {
        Caveat memory balanceCaveat_ = Caveat({
            enforcer: address(erc20BalanceChangeEnforcer),
            terms: abi.encodePacked(false, address(tokenOut), alice, TOKEN_OUT_MIN),
            args: hex""
        });
        Delegation memory delegation_ = _signDelegation(_dynamicLimitOrderCaveats(address(tokenIn), false, balanceCaveat_));

        Execution memory badExecution_ =
            _wrap7702Batch(_metaSwapERC20Executions(false, "bad", abi.encode(tokenOut, TOKEN_OUT_MIN - 1)));
        vm.expectRevert("ERC20BalanceChangeEnforcer:insufficient-balance-increase");
        _redeem(delegation_, badExecution_);

        Execution memory goodExecution_ =
            _wrap7702Batch(_metaSwapERC20Executions(false, "new-route", abi.encode(tokenOut, TOKEN_OUT_MIN)));
        _redeem(delegation_, goodExecution_);

        assertEq(tokenOut.balanceOf(alice), TOKEN_OUT_MIN);
    }

    function test_limitOrder_insufficientOutputRevertsAndRemainsRetryable() public {
        router.setERC20AmountOut(TOKEN_OUT_MIN - 1);

        Execution memory execution_ = _wrap7702Batch(_nativeInERC20OutExecutions());
        Caveat memory balanceCaveat_ = Caveat({
            enforcer: address(erc20BalanceChangeEnforcer),
            terms: abi.encodePacked(false, address(tokenOut), alice, TOKEN_OUT_MIN),
            args: hex""
        });
        Delegation memory delegation_ = _signDelegation(_limitOrderCaveats(execution_, balanceCaveat_));
        bytes32 delegationHash_ = swapManager.getDelegationHash(delegation_);

        vm.expectRevert("ERC20BalanceChangeEnforcer:insufficient-balance-increase");
        _redeem(delegation_, execution_);

        assertEq(limitedCallsEnforcer.callCounts(address(swapManager), delegationHash_), 0);
        assertFalse(
            erc20BalanceChangeEnforcer.isLocked(
                erc20BalanceChangeEnforcer.getHashKey(address(swapManager), address(tokenOut), delegationHash_)
            )
        );

        router.setERC20AmountOut(TOKEN_OUT_MIN);
        _redeem(delegation_, execution_);

        assertEq(tokenOut.balanceOf(alice), TOKEN_OUT_MIN);
        assertEq(limitedCallsEnforcer.callCounts(address(swapManager), delegationHash_), 1);
    }

    function test_limitOrder_rejectsBalanceRecipientOtherThanDelegator() public {
        Execution memory execution_ = _wrap7702Batch(_nativeInERC20OutExecutions());
        Caveat memory balanceCaveat_ = Caveat({
            enforcer: address(erc20BalanceChangeEnforcer),
            terms: abi.encodePacked(false, address(tokenOut), makeAddr("OtherRecipient"), TOKEN_OUT_MIN),
            args: hex""
        });
        Delegation memory delegation_ = _signDelegation(_limitOrderCaveats(execution_, balanceCaveat_));

        vm.expectRevert(GaslessSwapDelegationManager.InvalidBalanceTerms.selector);
        _redeem(delegation_, execution_);
    }

    function test_rejectsUnapprovedManagerAtAccountBoundary() public {
        GaslessSwapDelegationManager unapprovedManager_ = new GaslessSwapDelegationManager(
            address(exactExecutionEnforcer),
            address(metaSwap7702CalldataEnforcer),
            address(limitedCallsEnforcer),
            address(nativeBalanceChangeEnforcer),
            address(erc20BalanceChangeEnforcer)
        );
        Execution memory execution_ = _wrap7702Batch(_nativeInERC20OutExecutions());
        Delegation memory delegation_ = _signDelegationFor(unapprovedManager_, _gaslessCaveats(execution_));

        vm.expectRevert(EIP7702MultiManagerDeleGatorCore.NotDelegationManager.selector);
        _redeemThrough(unapprovedManager_, delegation_, execution_);
    }

    function _nativeInERC20OutExecutions() internal view returns (Execution[] memory executions_) {
        executions_ = new Execution[](1);
        executions_[0] = Execution({
            target: address(router),
            value: SWAP_AMOUNT,
            callData: abi.encodeCall(MockLimitOrderRouter.swapNativeForERC20, (IERC20(address(tokenOut)), alice))
        });
    }

    function _erc20InNativeOutExecutions() internal view returns (Execution[] memory executions_) {
        executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (address(router), SWAP_AMOUNT))
        });
        executions_[1] = Execution({
            target: address(router),
            value: 0,
            callData: abi.encodeCall(
                MockLimitOrderRouter.swapERC20ForNative, (IERC20(address(tokenIn)), SWAP_AMOUNT, payable(alice))
            )
        });
    }

    function _metaSwapERC20Executions(
        bool resetApproval_,
        string memory aggregatorId_,
        bytes memory route_
    )
        internal
        view
        returns (Execution[] memory executions_)
    {
        uint256 swapIndex_ = resetApproval_ ? 2 : 1;
        executions_ = new Execution[](swapIndex_ + 1);
        if (resetApproval_) {
            executions_[0] =
                Execution({ target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (address(router), 0)) });
        }
        executions_[swapIndex_ - 1] = Execution({
            target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (address(router), SWAP_AMOUNT))
        });
        executions_[swapIndex_] = Execution({
            target: address(router),
            value: 0,
            callData: abi.encodeCall(IMetaSwap.swap, (aggregatorId_, IERC20(address(tokenIn)), SWAP_AMOUNT, route_))
        });
    }

    function _metaSwapNativeExecutions(
        string memory aggregatorId_,
        bytes memory route_
    )
        internal
        view
        returns (Execution[] memory executions_)
    {
        executions_ = new Execution[](1);
        executions_[0] = Execution({
            target: address(router),
            value: SWAP_AMOUNT,
            callData: abi.encodeCall(IMetaSwap.swap, (aggregatorId_, IERC20(address(0)), SWAP_AMOUNT, route_))
        });
    }

    function _wrap7702Batch(Execution[] memory executions_) internal view returns (Execution memory execution_) {
        execution_ = Execution({
            target: alice,
            value: 0,
            callData: abi.encodeCall(IERC7821.execute, (ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(executions_)))
        });
    }

    function _gaslessCaveats(Execution memory execution_) internal view returns (Caveat[] memory caveats_) {
        caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({
            enforcer: address(exactExecutionEnforcer),
            terms: ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData),
            args: hex""
        });
        caveats_[1] = Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(uint256(1)), args: hex"" });
    }

    function _limitOrderCaveats(
        Execution memory execution_,
        Caveat memory balanceCaveat_
    )
        internal
        view
        returns (Caveat[] memory caveats_)
    {
        Caveat[] memory gaslessCaveats_ = _gaslessCaveats(execution_);
        caveats_ = new Caveat[](3);
        caveats_[0] = gaslessCaveats_[0];
        caveats_[1] = gaslessCaveats_[1];
        caveats_[2] = balanceCaveat_;
    }

    function _dynamicLimitOrderCaveats(
        address tokenIn_,
        bool resetApproval_,
        Caveat memory balanceCaveat_
    )
        internal
        view
        returns (Caveat[] memory caveats_)
    {
        caveats_ = new Caveat[](3);
        caveats_[0] = Caveat({
            enforcer: address(metaSwap7702CalldataEnforcer),
            terms: abi.encodePacked(address(router), tokenIn_, SWAP_AMOUNT, bytes1(resetApproval_ ? 0x01 : 0x00)),
            args: hex""
        });
        caveats_[1] = Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(uint256(1)), args: hex"" });
        caveats_[2] = balanceCaveat_;
    }

    function _signDelegation(Caveat[] memory caveats_) internal view returns (Delegation memory delegation_) {
        delegation_ = _signDelegationFor(swapManager, caveats_);
    }

    function _signDelegationFor(
        GaslessSwapDelegationManager manager_,
        Caveat[] memory caveats_
    )
        internal
        view
        returns (Delegation memory delegation_)
    {
        delegation_ = Delegation({
            delegate: ANY_DELEGATE, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex""
        });

        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(manager_.getDomainHash(), delegationHash_);
        delegation_.signature = signHash(users.alice, typedDataHash_);
    }

    function _redeem(Delegation memory delegation_, Execution memory execution_) internal {
        _redeemThrough(swapManager, delegation_, execution_);
    }

    function _redeemThrough(
        GaslessSwapDelegationManager manager_,
        Delegation memory delegation_,
        Execution memory execution_
    )
        internal
    {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = singleDefaultMode;

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(relayer);
        manager_.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);
    }
}
