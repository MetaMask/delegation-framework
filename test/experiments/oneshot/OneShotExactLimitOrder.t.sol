// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib, ModeCode } from "@erc7579/lib/ModeLib.sol";

import { BaseTest } from "../../utils/BaseTest.t.sol";
import { BasicERC20 } from "../../utils/BasicERC20.t.sol";
import { Implementation, SignatureType } from "../../utils/Types.t.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../../src/utils/Types.sol";
import { ExactExecutionBatchLimitedCallsEnforcer } from "../../../src/enforcers/ExactExecutionBatchLimitedCallsEnforcer.sol";
import { TimestampEnforcer } from "../../../src/enforcers/TimestampEnforcer.sol";
import { OneShotExactLimitOrderLib } from "../../../src/experiments/oneshot/OneShotExactLimitOrderLib.sol";
import { EncoderLib } from "../../../src/libraries/EncoderLib.sol";

/**
 * @notice O-exact: canonical manager + combined enforcer + TimestampEnforcer one-shot limit order.
 */
contract OneShotExactLimitOrderTest is BaseTest {
    ExactExecutionBatchLimitedCallsEnforcer internal combinedEnforcer;
    TimestampEnforcer internal timestampEnforcer;
    BasicERC20 internal sellToken;
    BasicERC20 internal buyToken;

    address internal relayer;
    address internal receiver;

    uint256 internal constant SELL_AMOUNT = 100e18;
    uint256 internal constant MIN_BUY = 95e18;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();
        combinedEnforcer = new ExactExecutionBatchLimitedCallsEnforcer();
        timestampEnforcer = new TimestampEnforcer();
        sellToken = new BasicERC20(address(this), "SELL", "SELL", 0);
        buyToken = new BasicERC20(address(this), "BUY", "BUY", 0);
        sellToken.mint(address(users.alice.deleGator), 1_000_000e18);
        buyToken.mint(address(this), 1_000_000e18);

        relayer = makeAddr("oneshot-relayer");
        receiver = makeAddr("oneshot-receiver");
    }

    function test_happyPath_oneShotExactExecution() public {
        Delegation memory delegation_ = _signOneShotDelegation(uint128(block.timestamp - 1), uint128(block.timestamp + 1 days));
        _redeemOnce(delegation_, _buildExactBatchExecution());
        assertEq(sellToken.balanceOf(receiver), 0);
        assertEq(buyToken.balanceOf(receiver), MIN_BUY);
    }

    function test_revertWhen_expiredTimestamp() public {
        Delegation memory delegation_ = _signOneShotDelegation(uint128(block.timestamp - 1), uint128(block.timestamp + 100));
        vm.warp(block.timestamp + 101);
        vm.expectRevert("TimestampEnforcer:expired-delegation");
        _redeemOnce(delegation_, _buildExactBatchExecution());
    }

    function test_revertWhen_replaySecondRedemption() public {
        Delegation memory delegation_ = _signOneShotDelegation(uint128(block.timestamp - 1), uint128(block.timestamp + 1 days));
        _redeemOnce(delegation_, _buildExactBatchExecution());
        vm.expectRevert("ExactExecutionBatchLimitedCallsEnforcer:limit-exceeded");
        _redeemOnce(delegation_, _buildExactBatchExecution());
    }

    function test_revertWhen_executionMismatch() public {
        Delegation memory delegation_ = _signOneShotDelegation(uint128(block.timestamp - 1), uint128(block.timestamp + 1 days));
        Execution[] memory wrong_ = _wrongExecutions();
        vm.expectRevert("ExactExecutionBatchLimitedCallsEnforcer:invalid-execution");
        _redeemOnce(delegation_, ExecutionLib.encodeBatch(wrong_));
    }

    function _signOneShotDelegation(uint128 _validAfter, uint128 _validBefore) internal returns (Delegation memory) {
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({
            enforcer: address(combinedEnforcer),
            terms: OneShotExactLimitOrderLib.encodeCombinedEnforcerTerms(_expectedExecutions()),
            args: hex""
        });
        caveats_[1] = Caveat({
            enforcer: address(timestampEnforcer),
            terms: OneShotExactLimitOrderLib.encodeTimestampTerms(_validAfter, _validBefore),
            args: hex""
        });

        Delegation memory delegation_ = Delegation({
            delegate: relayer,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 1,
            signature: hex""
        });
        return signDelegation(users.alice, delegation_);
    }

    function _redeemOnce(Delegation memory _delegation, bytes memory _executionCalldata) internal {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _delegation;
        bytes[] memory contexts_ = new bytes[](1);
        contexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleBatch();
        bytes[] memory execDatas_ = new bytes[](1);
        execDatas_[0] = _executionCalldata;
        vm.prank(relayer);
        delegationManager.redeemDelegations(contexts_, modes_, execDatas_);
    }

    function _buildExactBatchExecution() internal view returns (bytes memory) {
        return ExecutionLib.encodeBatch(_expectedExecutions());
    }

    function _expectedExecutions() internal view returns (Execution[] memory executions_) {
        executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(sellToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.approve.selector, address(this), SELL_AMOUNT)
        });
        executions_[1] = Execution({
            target: address(this),
            value: 0,
            callData: abi.encodeWithSelector(this.settleExact.selector, receiver, SELL_AMOUNT, MIN_BUY)
        });
    }

    function _wrongExecutions() internal view returns (Execution[] memory executions_) {
        executions_ = _expectedExecutions();
        executions_[1].callData = abi.encodeWithSelector(this.settleExact.selector, receiver, SELL_AMOUNT, MIN_BUY - 1);
    }

    /// @dev Mock settlement: pull sell, push buy (exact pinned calldata).
    function settleExact(address _receiver, uint256 _sellAmount, uint256 _buyAmount) external {
        sellToken.transferFrom(msg.sender, address(this), _sellAmount);
        buyToken.transfer(_receiver, _buyAmount);
    }
}
