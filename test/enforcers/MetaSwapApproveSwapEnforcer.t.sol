// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { MetaSwapApproveSwapEnforcer } from "../../src/enforcers/MetaSwapApproveSwapEnforcer.sol";
import { RedeemerEnforcer } from "../../src/enforcers/RedeemerEnforcer.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../src/utils/Types.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract MockMetaSwap is IMetaSwap {
    using SafeERC20 for IERC20;

    IERC20 internal immutable tokenOut;

    constructor(IERC20 _tokenOut) {
        tokenOut = _tokenOut;
    }

    function swap(string calldata, IERC20 _tokenFrom, uint256 _amount, bytes calldata _data) external payable {
        (,,,, uint256 amountTo_,,,,) = abi.decode(
            abi.encodePacked(abi.encode(address(0)), _data),
            (address, IERC20, IERC20, uint256, uint256, bytes, uint256, address, bool)
        );
        _tokenFrom.safeTransferFrom(msg.sender, address(this), _amount);
        tokenOut.safeTransfer(msg.sender, amountTo_);
    }

    function setAdapter(string calldata, address, bytes4, bytes calldata) external { }
    function removeAdapter(string calldata) external { }

    function adapters(string memory) external pure returns (Adapter memory) {
        return Adapter({ addr: address(0), selector: bytes4(0), data: hex"" });
    }
}

contract MockMetaSwapUnderpay is IMetaSwap {
    using SafeERC20 for IERC20;

    IERC20 internal immutable tokenOut;
    uint256 internal immutable payoutAmount;

    constructor(IERC20 _tokenOut, uint256 _payoutAmount) {
        tokenOut = _tokenOut;
        payoutAmount = _payoutAmount;
    }

    function swap(string calldata, IERC20 _tokenFrom, uint256 _amount, bytes calldata) external payable {
        _tokenFrom.safeTransferFrom(msg.sender, address(this), _amount);
        tokenOut.safeTransfer(msg.sender, payoutAmount);
    }

    function setAdapter(string calldata, address, bytes4, bytes calldata) external { }
    function removeAdapter(string calldata) external { }

    function adapters(string memory) external pure returns (Adapter memory) {
        return Adapter({ addr: address(0), selector: bytes4(0), data: hex"" });
    }
}

contract MockMetaSwapNoPull is IMetaSwap {
    using SafeERC20 for IERC20;

    IERC20 internal immutable tokenOut;

    constructor(IERC20 _tokenOut) {
        tokenOut = _tokenOut;
    }

    function swap(string calldata, IERC20, uint256, bytes calldata _data) external payable {
        (,,,, uint256 amountTo_,,,,) = abi.decode(
            abi.encodePacked(abi.encode(address(0)), _data),
            (address, IERC20, IERC20, uint256, uint256, bytes, uint256, address, bool)
        );
        tokenOut.safeTransfer(msg.sender, amountTo_);
    }

    function setAdapter(string calldata, address, bytes4, bytes calldata) external { }
    function removeAdapter(string calldata) external { }

    function adapters(string memory) external pure returns (Adapter memory) {
        return Adapter({ addr: address(0), selector: bytes4(0), data: hex"" });
    }
}

contract MetaSwapApproveSwapEnforcerTest is CaveatEnforcerBaseTest {
    uint256 internal constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 internal constant MIN_TOKEN_OUT = 190 ether;
    uint256 internal constant ACTUAL_TOKEN_OUT = 200 ether;

    BasicERC20 internal tokenIn;
    BasicERC20 internal tokenOut;
    MockMetaSwap internal metaSwap;
    MetaSwapApproveSwapEnforcer internal enforcer;
    RedeemerEnforcer internal redeemerEnforcer;

    address internal automation;

    function setUp() public override {
        super.setUp();
        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        metaSwap = new MockMetaSwap(tokenOut);
        enforcer = new MetaSwapApproveSwapEnforcer();
        redeemerEnforcer = new RedeemerEnforcer();
        automation = makeAddr("metamask-automation");

        tokenIn.mint(address(users.alice.deleGator), TOKEN_IN_AMOUNT);
        tokenOut.mint(address(metaSwap), 1_000 ether);

        vm.label(address(enforcer), "MetaSwap Approve Swap Enforcer");
        vm.label(address(metaSwap), "Mock MetaSwap");
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }

    ////////////////////// Valid cases //////////////////////

    function test_validBatchExecution() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);

        vm.prank(address(delegationManager));
        enforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    function test_validBatchExecutionWithBetterOutput() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(ACTUAL_TOKEN_OUT);

        vm.prank(address(delegationManager));
        enforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    function test_revertWithIdenticalTokens() public {
        MetaSwapApproveSwapEnforcer.Terms memory terms_ = MetaSwapApproveSwapEnforcer.Terms({
            metaSwap: address(metaSwap),
            tokenIn: address(tokenIn),
            tokenOut: address(tokenIn),
            tokenInAmount: TOKEN_IN_AMOUNT,
            minTokenOut: MIN_TOKEN_OUT
        });
        (, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.IdenticalTokens.selector);
        enforcer.beforeHook(
            abi.encode(terms_), hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0)
        );
    }

    function test_validResetBatchExecution() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidResetBatch(ACTUAL_TOKEN_OUT);

        vm.prank(address(delegationManager));
        enforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    function test_getTermsInfo() public {
        MetaSwapApproveSwapEnforcer.Terms memory terms_ = MetaSwapApproveSwapEnforcer.Terms({
            metaSwap: address(metaSwap),
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            tokenInAmount: TOKEN_IN_AMOUNT,
            minTokenOut: MIN_TOKEN_OUT
        });
        bytes memory encoded_ = abi.encode(terms_);
        MetaSwapApproveSwapEnforcer.Terms memory decoded_ = enforcer.getTermsInfo(encoded_);

        assertEq(decoded_.metaSwap, address(metaSwap));
        assertEq(decoded_.tokenIn, address(tokenIn));
        assertEq(decoded_.tokenOut, address(tokenOut));
        assertEq(decoded_.tokenInAmount, TOKEN_IN_AMOUNT);
        assertEq(decoded_.minTokenOut, MIN_TOKEN_OUT);
        assertEq(keccak256(enforcer.encodeTerms(terms_)), keccak256(encoded_));
    }

    function test_emitsDelegationExecuted() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        bytes32 delegationHash_ = keccak256("event");
        address delegator_ = address(users.alice.deleGator);

        vm.prank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(enforcer));
        emit MetaSwapApproveSwapEnforcer.DelegationExecuted(address(delegationManager), delegationHash_, delegator_);
        enforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, delegationHash_, delegator_, address(0));
    }

    function test_allowsFeeTakenFromInput() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[1].callData = abi.encodeWithSelector(
            IMetaSwap.swap.selector,
            "mock-aggregator",
            tokenIn,
            TOKEN_IN_AMOUNT,
            _encodeSwapData(
                address(tokenIn), address(tokenOut), TOKEN_IN_AMOUNT - 1 ether, MIN_TOKEN_OUT, 1 ether, address(this), false
            )
        );

        vm.prank(address(delegationManager));
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("fee-in"), address(0), address(0)
        );
    }

    function test_allowsFeeToTrueWithUnmatchedInputSplit() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[1].callData = abi.encodeWithSelector(
            IMetaSwap.swap.selector,
            "mock-aggregator",
            tokenIn,
            TOKEN_IN_AMOUNT,
            _encodeSwapData(
                address(tokenIn), address(tokenOut), TOKEN_IN_AMOUNT - 1 ether, MIN_TOKEN_OUT, 1 ether, address(this), true
            )
        );

        vm.prank(address(delegationManager));
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("fee-out"), address(0), address(0)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    function test_revertWithInvalidCallTypeMode() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);

        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeHook(hex"", hex"", batchTryMode, hex"", bytes32(0), address(0), address(0));
    }

    function test_revertOnDelegationReuse() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        bytes32 delegationHash_ = keccak256("test");

        vm.startPrank(address(delegationManager));
        enforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, delegationHash_, address(0), address(0));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.DelegationAlreadyUsed.selector);
        enforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, delegationHash_, address(0), address(0));
        vm.stopPrank();
    }

    function test_revertWithInvalidBatchSize() public {
        Execution[] memory executions_ = new Execution[](1);
        executions_[0] = Execution({
            target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (address(metaSwap), TOKEN_IN_AMOUNT))
        });
        (bytes memory terms_,) = _buildValidBatch(MIN_TOKEN_OUT);

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidBatchLength.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithInvalidBatchSizeFour() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        Execution[] memory fourExecutions_ = new Execution[](4);
        fourExecutions_[0] = executions_[0];
        fourExecutions_[1] = executions_[0];
        fourExecutions_[2] = executions_[0];
        fourExecutions_[3] = executions_[1];

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidBatchLength.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(fourExecutions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithInvalidResetAmount() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidResetBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[0].callData = abi.encodeCall(IERC20.approve, (address(metaSwap), 1));

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidApproveCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithInvalidResetSecondApproveAmount() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidResetBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[1].callData = abi.encodeCall(IERC20.approve, (address(metaSwap), TOKEN_IN_AMOUNT - 1));

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidApproveCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithInvalidResetSwapTarget() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidResetBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[2].target = address(tokenIn);

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidSwapCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_afterHook_revertsInsufficientOutput() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(ACTUAL_TOKEN_OUT);
        bytes32 delegationHash_ = keccak256("after-hook");
        address delegator_ = address(users.alice.deleGator);

        vm.startPrank(address(delegationManager));
        enforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, delegationHash_, delegator_, address(0));
        vm.expectRevert(abi.encodeWithSelector(MetaSwapApproveSwapEnforcer.InsufficientOutput.selector, MIN_TOKEN_OUT, 0));
        enforcer.afterHook(terms_, hex"", batchDefaultMode, executionCallData_, delegationHash_, delegator_, address(0));
        vm.stopPrank();
    }

    function test_revertWithInvalidApproveTarget() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[0].target = address(tokenOut);

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidApproveCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithInvalidApproveValue() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[0].value = 1 ether;

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidApproveCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithInvalidApproveSelector() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[0].callData = abi.encodeCall(IERC20.transfer, (address(metaSwap), TOKEN_IN_AMOUNT));

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidApproveCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithInvalidApproveSpender() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[0].callData = abi.encodeCall(IERC20.approve, (address(this), TOKEN_IN_AMOUNT));

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidApproveCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithInvalidApproveAmount() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[0].callData = abi.encodeCall(IERC20.approve, (address(metaSwap), TOKEN_IN_AMOUNT - 1));

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidApproveCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithInvalidSwapTarget() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[1].target = address(tokenIn);

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidSwapCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithInvalidSwapValue() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[1].value = 1 ether;

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidSwapCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithInvalidSwapSelector() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[1].callData = abi.encodeCall(IERC20.transfer, (address(tokenOut), TOKEN_IN_AMOUNT));

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidSwapCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithInvalidOuterTokenIn() public {
        BasicERC20 wrongTokenIn_ = new BasicERC20(address(this), "Wrong In", "WIN", 0);
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[1].callData = abi.encodeWithSelector(
            IMetaSwap.swap.selector,
            "mock-aggregator",
            wrongTokenIn_,
            TOKEN_IN_AMOUNT,
            _encodeSwapData(address(wrongTokenIn_), address(tokenOut), TOKEN_IN_AMOUNT, MIN_TOKEN_OUT)
        );

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidSwapCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithInvalidOuterAmount() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[1].callData = abi.encodeWithSelector(
            IMetaSwap.swap.selector,
            "mock-aggregator",
            tokenIn,
            TOKEN_IN_AMOUNT - 1,
            _encodeSwapData(address(tokenIn), address(tokenOut), TOKEN_IN_AMOUNT - 1, MIN_TOKEN_OUT)
        );

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidSwapCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithInvalidInnerTokenOut() public {
        BasicERC20 wrongTokenOut_ = new BasicERC20(address(this), "Wrong Out", "WOUT", 0);
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[1].callData = abi.encodeWithSelector(
            IMetaSwap.swap.selector,
            "mock-aggregator",
            tokenIn,
            TOKEN_IN_AMOUNT,
            _encodeSwapData(address(tokenIn), address(wrongTokenOut_), TOKEN_IN_AMOUNT, MIN_TOKEN_OUT)
        );

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidSwapCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithInvalidInnerTokenIn() public {
        BasicERC20 wrongTokenIn_ = new BasicERC20(address(this), "Wrong In", "WIN", 0);
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[1].callData = abi.encodeWithSelector(
            IMetaSwap.swap.selector,
            "mock-aggregator",
            tokenIn,
            TOKEN_IN_AMOUNT,
            _encodeSwapData(address(wrongTokenIn_), address(tokenOut), TOKEN_IN_AMOUNT, MIN_TOKEN_OUT)
        );

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidSwapCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithAmountFromMismatch() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(executionCallData_, (Execution[]));
        executions_[1].callData = abi.encodeWithSelector(
            IMetaSwap.swap.selector,
            "mock-aggregator",
            tokenIn,
            TOKEN_IN_AMOUNT,
            _encodeSwapData(address(tokenIn), address(tokenOut), TOKEN_IN_AMOUNT - 1 ether, MIN_TOKEN_OUT)
        );

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.AmountFromMismatch.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_revertWithBelowMinimumOutput() public {
        (bytes memory terms_, bytes memory executionCallData_) = _buildValidBatch(MIN_TOKEN_OUT - 1);

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapApproveSwapEnforcer.InvalidSwapCall.selector);
        enforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("test"), address(0), address(0));
    }

    ////////////////////// Integration //////////////////////

    function test_integration_happyPath() public {
        (Delegation memory delegation_, bytes memory executionCallData_) =
            _buildDelegation(ACTUAL_TOKEN_OUT, automation, automation);

        _redeem(delegation_, executionCallData_, automation);

        assertEq(tokenIn.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), ACTUAL_TOKEN_OUT);
        assertEq(tokenIn.balanceOf(address(metaSwap)), TOKEN_IN_AMOUNT);
    }

    function test_integration_resetApprovalHappyPath() public {
        (Delegation memory delegation_, bytes memory executionCallData_) =
            _buildDelegation(ACTUAL_TOKEN_OUT, automation, automation, true);

        vm.prank(address(delegationManager));
        users.alice.deleGator
            .executeFromExecutor(
                singleDefaultMode,
                ExecutionLib.encodeSingle(address(tokenIn), 0, abi.encodeCall(IERC20.approve, (address(metaSwap), uint256(1))))
            );
        assertEq(tokenIn.allowance(address(users.alice.deleGator), address(metaSwap)), 1);

        _redeem(delegation_, executionCallData_, automation);

        assertEq(tokenIn.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), ACTUAL_TOKEN_OUT);
        assertEq(tokenIn.allowance(address(users.alice.deleGator), address(metaSwap)), 0);
    }

    function test_integration_revertsUnauthorizedRedeemer() public {
        (Delegation memory delegation_, bytes memory executionCallData_) =
            _buildDelegation(ACTUAL_TOKEN_OUT, ANY_DELEGATE, automation);

        vm.expectRevert("RedeemerEnforcer:unauthorized-redeemer");
        _redeem(delegation_, executionCallData_, users.bob.addr);
    }

    function test_integration_revertsReplay() public {
        (Delegation memory delegation_, bytes memory executionCallData_) =
            _buildDelegation(ACTUAL_TOKEN_OUT, automation, automation);
        _redeem(delegation_, executionCallData_, automation);

        vm.expectRevert(MetaSwapApproveSwapEnforcer.DelegationAlreadyUsed.selector);
        _redeem(delegation_, executionCallData_, automation);
    }

    function test_integration_revertsInsufficientOutput() public {
        MockMetaSwapUnderpay underpayMetaSwap_ = new MockMetaSwapUnderpay(tokenOut, MIN_TOKEN_OUT - 1);
        tokenOut.mint(address(underpayMetaSwap_), 1_000 ether);

        (Delegation memory delegation_, bytes memory executionCallData_) =
            _buildDelegationWithMetaSwap(underpayMetaSwap_, ACTUAL_TOKEN_OUT, automation, automation);

        vm.expectRevert(
            abi.encodeWithSelector(MetaSwapApproveSwapEnforcer.InsufficientOutput.selector, MIN_TOKEN_OUT, MIN_TOKEN_OUT - 1)
        );
        _redeem(delegation_, executionCallData_, automation);
    }

    function test_integration_revertsRemainingAllowance() public {
        MockMetaSwapNoPull noPullMetaSwap_ = new MockMetaSwapNoPull(tokenOut);
        tokenOut.mint(address(noPullMetaSwap_), 1_000 ether);

        (Delegation memory delegation_, bytes memory executionCallData_) =
            _buildDelegationWithMetaSwap(noPullMetaSwap_, ACTUAL_TOKEN_OUT, automation, automation);

        vm.expectRevert(abi.encodeWithSelector(MetaSwapApproveSwapEnforcer.RemainingAllowance.selector, TOKEN_IN_AMOUNT));
        _redeem(delegation_, executionCallData_, automation);
    }

    ////////////////////// Helpers //////////////////////

    function _buildValidBatch(uint256 _amountTo) private view returns (bytes memory terms_, bytes memory executionCallData_) {
        MetaSwapApproveSwapEnforcer.Terms memory termsData_ = MetaSwapApproveSwapEnforcer.Terms({
            metaSwap: address(metaSwap),
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            tokenInAmount: TOKEN_IN_AMOUNT,
            minTokenOut: MIN_TOKEN_OUT
        });
        terms_ = abi.encode(termsData_);
        executionCallData_ = _encodeBatchExecution(_amountTo);
    }

    function _buildValidResetBatch(uint256 _amountTo) private view returns (bytes memory terms_, bytes memory executionCallData_) {
        MetaSwapApproveSwapEnforcer.Terms memory termsData_ = MetaSwapApproveSwapEnforcer.Terms({
            metaSwap: address(metaSwap),
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            tokenInAmount: TOKEN_IN_AMOUNT,
            minTokenOut: MIN_TOKEN_OUT
        });
        terms_ = abi.encode(termsData_);
        executionCallData_ = _encodeResetBatchExecution(_amountTo);
    }

    function _buildDelegation(
        uint256 _amountTo,
        address _delegate,
        address _allowedRedeemer
    )
        private
        view
        returns (Delegation memory delegation_, bytes memory executionCallData_)
    {
        return _buildDelegation(_amountTo, _delegate, _allowedRedeemer, false);
    }

    function _buildDelegation(
        uint256 _amountTo,
        address _delegate,
        address _allowedRedeemer,
        bool _resetApproval
    )
        private
        view
        returns (Delegation memory delegation_, bytes memory executionCallData_)
    {
        MetaSwapApproveSwapEnforcer.Terms memory termsData_ = MetaSwapApproveSwapEnforcer.Terms({
            metaSwap: address(metaSwap),
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            tokenInAmount: TOKEN_IN_AMOUNT,
            minTokenOut: MIN_TOKEN_OUT
        });

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({ enforcer: address(enforcer), terms: abi.encode(termsData_), args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(redeemerEnforcer), terms: abi.encodePacked(_allowedRedeemer), args: hex"" });

        delegation_ = signDelegation(
            users.alice,
            Delegation({
                delegate: _delegate,
                delegator: address(users.alice.deleGator),
                authority: ROOT_AUTHORITY,
                caveats: caveats_,
                salt: 42,
                signature: hex""
            })
        );
        executionCallData_ = _resetApproval ? _encodeResetBatchExecution(_amountTo) : _encodeBatchExecution(_amountTo);
    }

    function _buildDelegationWithMetaSwap(
        IMetaSwap _metaSwap,
        uint256 _amountTo,
        address _delegate,
        address _allowedRedeemer
    )
        private
        view
        returns (Delegation memory delegation_, bytes memory executionCallData_)
    {
        MetaSwapApproveSwapEnforcer.Terms memory termsData_ = MetaSwapApproveSwapEnforcer.Terms({
            metaSwap: address(_metaSwap),
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            tokenInAmount: TOKEN_IN_AMOUNT,
            minTokenOut: MIN_TOKEN_OUT
        });

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({ enforcer: address(enforcer), terms: abi.encode(termsData_), args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(redeemerEnforcer), terms: abi.encodePacked(_allowedRedeemer), args: hex"" });

        delegation_ = signDelegation(
            users.alice,
            Delegation({
                delegate: _delegate,
                delegator: address(users.alice.deleGator),
                authority: ROOT_AUTHORITY,
                caveats: caveats_,
                salt: 43,
                signature: hex""
            })
        );
        executionCallData_ = _encodeBatchExecution(_metaSwap, _amountTo);
    }

    function _encodeBatchExecution(uint256 _amountTo) private view returns (bytes memory) {
        return _encodeBatchExecution(metaSwap, _amountTo);
    }

    function _encodeBatchExecution(IMetaSwap _metaSwap, uint256 _amountTo) private view returns (bytes memory) {
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (address(_metaSwap), TOKEN_IN_AMOUNT))
        });
        executions_[1] = Execution({
            target: address(_metaSwap),
            value: 0,
            callData: abi.encodeWithSelector(
                IMetaSwap.swap.selector,
                "mock-aggregator",
                tokenIn,
                TOKEN_IN_AMOUNT,
                _encodeSwapData(address(tokenIn), address(tokenOut), TOKEN_IN_AMOUNT, _amountTo)
            )
        });
        return ExecutionLib.encodeBatch(executions_);
    }

    function _encodeResetBatchExecution(uint256 _amountTo) private view returns (bytes memory) {
        Execution[] memory executions_ = new Execution[](3);
        executions_[0] =
            Execution({ target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (address(metaSwap), 0)) });
        executions_[1] = Execution({
            target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (address(metaSwap), TOKEN_IN_AMOUNT))
        });
        executions_[2] = Execution({
            target: address(metaSwap),
            value: 0,
            callData: abi.encodeWithSelector(
                IMetaSwap.swap.selector,
                "mock-aggregator",
                tokenIn,
                TOKEN_IN_AMOUNT,
                _encodeSwapData(address(tokenIn), address(tokenOut), TOKEN_IN_AMOUNT, _amountTo)
            )
        });
        return ExecutionLib.encodeBatch(executions_);
    }

    function _encodeSwapData(
        address _tokenFrom,
        address _tokenTo,
        uint256 _amountFrom,
        uint256 _amountTo
    )
        private
        pure
        returns (bytes memory)
    {
        return _encodeSwapData(_tokenFrom, _tokenTo, _amountFrom, _amountTo, 0, address(0), false);
    }

    function _encodeSwapData(
        address _tokenFrom,
        address _tokenTo,
        uint256 _amountFrom,
        uint256 _amountTo,
        uint256 _fee,
        address _feeWallet,
        bool _feeTo
    )
        private
        pure
        returns (bytes memory)
    {
        return abi.encode(_tokenFrom, _tokenTo, _amountFrom, _amountTo, hex"", _fee, _feeWallet, _feeTo);
    }

    function _redeem(Delegation memory _delegation, bytes memory _execution, address _redeemer) private {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _delegation;

        bytes[] memory contexts_ = new bytes[](1);
        contexts_[0] = abi.encode(delegations_);

        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleBatch();

        bytes[] memory executions_ = new bytes[](1);
        executions_[0] = _execution;

        vm.prank(_redeemer);
        delegationManager.redeemDelegations(contexts_, modes_, executions_);
    }
}
