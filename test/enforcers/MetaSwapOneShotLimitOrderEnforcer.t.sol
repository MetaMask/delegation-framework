// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { MetaSwapOneShotLimitOrderEnforcer } from "../../src/enforcers/MetaSwapOneShotLimitOrderEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../src/utils/Types.sol";

contract OneShotMetaSwapMock is IMetaSwap {
    using SafeERC20 for IERC20;

    receive() external payable { }

    function swap(string calldata, IERC20 tokenFrom_, uint256 amount_, bytes calldata data_) external payable {
        (IERC20 tokenOut_, uint256 amountOut_) = abi.decode(data_, (IERC20, uint256));

        if (address(tokenFrom_) == address(0)) {
            require(msg.value == amount_, "OneShotMetaSwapMock:invalid-native-value");
        } else {
            require(msg.value == 0, "OneShotMetaSwapMock:unexpected-native-value");
            tokenFrom_.safeTransferFrom(msg.sender, address(this), amount_);
        }

        if (address(tokenOut_) == address(0)) {
            (bool success_,) = msg.sender.call{ value: amountOut_ }("");
            require(success_, "OneShotMetaSwapMock:native-transfer-failed");
        } else {
            tokenOut_.safeTransfer(msg.sender, amountOut_);
        }
    }

    function setAdapter(string calldata, address, bytes4, bytes calldata) external { }

    function removeAdapter(string calldata) external { }

    function adapters(string memory) external pure returns (Adapter memory adapter_) {
        adapter_ = Adapter({ addr: address(0), selector: bytes4(0), data: hex"" });
    }
}

contract MaxBalanceToken {
    uint256 private immutable BALANCE;

    constructor(uint256 balance_) {
        BALANCE = balance_;
    }

    function balanceOf(address) external view returns (uint256) {
        return BALANCE;
    }
}

contract MetaSwapOneShotLimitOrderEnforcerTest is CaveatEnforcerBaseTest {
    uint256 internal constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 internal constant TOKEN_OUT_MIN = 190 ether;
    uint256 internal constant TOKEN_OUT_AMOUNT = 200 ether;
    uint8 internal constant SKIP = 1;
    uint8 internal constant APPROVE = 2;
    uint8 internal constant RESET = 4;
    uint8 internal constant ALL_MODES = SKIP | APPROVE | RESET;

    MetaSwapOneShotLimitOrderEnforcer internal enforcer;
    BasicERC20 internal tokenIn;
    BasicERC20 internal tokenOut;
    OneShotMetaSwapMock internal metaSwap;
    address internal alice;
    address internal relayer;

    event OrderConsumed(address indexed delegationManager, bytes32 indexed delegationHash, address indexed redeemer);

    function setUp() public override {
        super.setUp();

        enforcer = new MetaSwapOneShotLimitOrderEnforcer();
        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        metaSwap = new OneShotMetaSwapMock();
        alice = address(users.alice.deleGator);
        relayer = makeAddr("Relayer");

        tokenIn.mint(alice, 1_000 ether);
        tokenOut.mint(address(metaSwap), 10_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(address(metaSwap), 10_000 ether);
    }

    function test_getTermsInfoDecodesERC20Order() public {
        MetaSwapOneShotLimitOrderEnforcer.Terms memory info_ =
            enforcer.getTermsInfo(_terms(address(tokenIn), ALL_MODES, address(tokenOut), alice));

        assertEq(info_.metaSwap, address(metaSwap));
        assertEq(info_.tokenIn, address(tokenIn));
        assertEq(info_.tokenInAmount, TOKEN_IN_AMOUNT);
        assertEq(info_.approvalPolicy, ALL_MODES);
        assertEq(info_.tokenOut, address(tokenOut));
        assertEq(info_.recipient, alice);
        assertEq(info_.tokenOutMin, TOKEN_OUT_MIN);
    }

    function test_getTermsInfoDecodesNativeInputOrder() public {
        MetaSwapOneShotLimitOrderEnforcer.Terms memory info_ =
            enforcer.getTermsInfo(_terms(address(0), 0, address(tokenOut), alice));

        assertEq(info_.tokenIn, address(0));
        assertEq(info_.approvalPolicy, 0);
    }

    function test_getOrderKeyUsesDelegationManagerAndDelegationHash() public {
        bytes32 delegationHash_ = keccak256("delegation");
        assertEq(
            enforcer.getOrderKey(address(delegationManager), delegationHash_),
            keccak256(abi.encode(address(delegationManager), delegationHash_))
        );
    }

    function test_acceptsFlexibleAggregatorAndRouteData() public {
        _before(
            _terms(address(tokenIn), APPROVE, address(tokenOut), alice),
            _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "a", hex"01"),
            keccak256("first")
        );
        _before(
            _terms(address(tokenIn), APPROVE, address(tokenOut), alice),
            _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "different-aggregator", new bytes(512)),
            keccak256("second")
        );
    }

    function test_acceptsEverySignedERC20ApprovalShape() public {
        bytes memory terms_ = _terms(address(tokenIn), ALL_MODES, address(tokenOut), alice);
        _before(terms_, _erc20Executions(0, address(tokenIn), TOKEN_IN_AMOUNT, "skip", hex""), keccak256("skip"));
        _before(terms_, _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "approve", hex""), keccak256("approve"));
        _before(terms_, _erc20Executions(2, address(tokenIn), TOKEN_IN_AMOUNT, "reset", hex""), keccak256("reset"));
    }

    function test_acceptsNativeInputShape() public {
        _before(
            _terms(address(0), 0, address(tokenOut), alice),
            _nativeExecutions(TOKEN_IN_AMOUNT, address(tokenOut), TOKEN_OUT_AMOUNT),
            keccak256("native")
        );
    }

    function test_revertsForSingleCallMode() public {
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        enforcer.beforeHook(
            _terms(address(tokenIn), APPROVE, address(tokenOut), alice),
            hex"",
            singleDefaultMode,
            ExecutionLib.encodeBatch(_erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"")),
            bytes32(0),
            alice,
            relayer
        );
    }

    function test_revertsForTryExecutionMode() public {
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeHook(
            _terms(address(tokenIn), APPROVE, address(tokenOut), alice),
            hex"",
            batchTryMode,
            ExecutionLib.encodeBatch(_erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"")),
            bytes32(0),
            alice,
            relayer
        );
    }

    function test_revertsForInvalidTermsLength() public {
        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-terms");
        enforcer.getTermsInfo(new bytes(144));

        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-terms");
        enforcer.getTermsInfo(new bytes(146));
    }

    function test_revertsForInvalidRequiredTerms() public {
        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-terms");
        enforcer.getTermsInfo(
            _rawTerms(address(0), address(tokenIn), TOKEN_IN_AMOUNT, APPROVE, address(tokenOut), alice, TOKEN_OUT_MIN)
        );

        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-terms");
        enforcer.getTermsInfo(_rawTerms(address(metaSwap), address(tokenIn), 0, APPROVE, address(tokenOut), alice, TOKEN_OUT_MIN));

        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-terms");
        enforcer.getTermsInfo(
            _rawTerms(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, APPROVE, address(tokenOut), address(0), TOKEN_OUT_MIN)
        );

        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-terms");
        enforcer.getTermsInfo(_rawTerms(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, APPROVE, address(tokenOut), alice, 0));

        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-terms");
        enforcer.getTermsInfo(
            _rawTerms(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, APPROVE, address(tokenIn), alice, TOKEN_OUT_MIN)
        );
    }

    function test_revertsForInvalidApprovalPolicy() public {
        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-approval-policy");
        enforcer.getTermsInfo(_terms(address(0), APPROVE, address(tokenOut), alice));

        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-approval-policy");
        enforcer.getTermsInfo(_terms(address(tokenIn), 0, address(tokenOut), alice));

        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-approval-policy");
        enforcer.getTermsInfo(_terms(address(tokenIn), 8, address(tokenOut), alice));
    }

    function test_revertsWhenApprovalShapeIsNotSigned() public {
        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:approval-shape-not-allowed");
        _before(
            _terms(address(tokenIn), APPROVE, address(tokenOut), alice),
            _erc20Executions(0, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""),
            bytes32(0)
        );

        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:approval-shape-not-allowed");
        _before(
            _terms(address(tokenIn), SKIP, address(tokenOut), alice),
            _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""),
            bytes32(0)
        );

        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:approval-shape-not-allowed");
        _before(
            _terms(address(tokenIn), APPROVE, address(tokenOut), alice),
            _erc20Executions(2, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""),
            bytes32(0)
        );
    }

    function test_revertsForUnsupportedBatchLengths() public {
        Execution[] memory empty_ = new Execution[](0);
        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:approval-shape-not-allowed");
        _before(_terms(address(tokenIn), ALL_MODES, address(tokenOut), alice), empty_, bytes32(0));

        Execution[] memory tooLong_ = new Execution[](4);
        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:approval-shape-not-allowed");
        _before(_terms(address(tokenIn), ALL_MODES, address(tokenOut), alice), tooLong_, bytes32(0));

        Execution[] memory nativeTooLong_ = new Execution[](2);
        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-batch-length");
        _before(_terms(address(0), 0, address(tokenOut), alice), nativeTooLong_, bytes32(0));
    }

    function test_revertsForInvalidApproval() public {
        Execution[] memory executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");

        executions_[0].target = makeAddr("OtherToken");
        _expectInvalidApproval(executions_);

        executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");
        executions_[0].value = 1;
        _expectInvalidApproval(executions_);

        executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");
        executions_[0].callData = abi.encodePacked(IERC20.approve.selector);
        _expectInvalidApproval(executions_);

        executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");
        executions_[0].callData = abi.encodeCall(IERC20.transfer, (address(metaSwap), TOKEN_IN_AMOUNT));
        _expectInvalidApproval(executions_);

        executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");
        executions_[0].callData = abi.encodeCall(IERC20.approve, (makeAddr("OtherSpender"), TOKEN_IN_AMOUNT));
        _expectInvalidApproval(executions_);

        executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");
        executions_[0].callData = abi.encodeCall(IERC20.approve, (address(metaSwap), TOKEN_IN_AMOUNT - 1));
        _expectInvalidApproval(executions_);
    }

    function test_revertsForInvalidResetApproval() public {
        Execution[] memory executions_ = _erc20Executions(2, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");
        executions_[0].callData = abi.encodeCall(IERC20.approve, (address(metaSwap), 1));

        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-approval");
        _before(_terms(address(tokenIn), RESET, address(tokenOut), alice), executions_, bytes32(0));
    }

    function test_revertsForInvalidSwap() public {
        Execution[] memory executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");
        executions_[1].target = makeAddr("OtherSwap");
        _expectInvalidSwap(executions_);

        executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");
        executions_[1].value = 1;
        _expectInvalidSwap(executions_);

        executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");
        executions_[1].callData = abi.encodePacked(IMetaSwap.swap.selector);
        _expectInvalidSwap(executions_);

        executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");
        executions_[1].callData = abi.encodeCall(IERC20.approve, (address(metaSwap), TOKEN_IN_AMOUNT));
        _expectInvalidSwap(executions_);

        _expectInvalidSwap(_erc20Executions(1, makeAddr("OtherToken"), TOKEN_IN_AMOUNT, "route", hex""));
        _expectInvalidSwap(_erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT - 1, "route", hex""));
    }

    function test_revertsForNativeSwapWithWrongValue() public {
        Execution[] memory executions_ = _nativeExecutions(TOKEN_IN_AMOUNT - 1, address(tokenOut), TOKEN_OUT_AMOUNT);
        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-swap");
        _before(_terms(address(0), 0, address(tokenOut), alice), executions_, bytes32(0));
    }

    function test_beforeHookCachesBalanceAndLocksOrder() public {
        tokenOut.mint(alice, 10);
        bytes32 delegationHash_ = keccak256("order");
        bytes32 orderKey_ = enforcer.getOrderKey(address(delegationManager), delegationHash_);
        vm.prank(address(delegationManager));
        enforcer.beforeHook(
            _terms(address(tokenIn), APPROVE, address(tokenOut), alice),
            hex"",
            batchDefaultMode,
            ExecutionLib.encodeBatch(_erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"")),
            delegationHash_,
            alice,
            relayer
        );

        assertEq(enforcer.orderStates(orderKey_), 11);

        vm.prank(address(delegationManager));
        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:order-already-used");
        enforcer.beforeHook(
            _terms(address(tokenIn), APPROVE, address(tokenOut), alice),
            hex"",
            batchDefaultMode,
            ExecutionLib.encodeBatch(_erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"")),
            delegationHash_,
            alice,
            relayer
        );
    }

    function test_beforeHookRevertsForMaximumBalance() public {
        _expectBalanceOverflow(new MaxBalanceToken(type(uint256).max), keccak256("max-balance"));
        _expectBalanceOverflow(new MaxBalanceToken(type(uint256).max - 1), keccak256("reserved-sentinel"));
    }

    function _expectBalanceOverflow(MaxBalanceToken token_, bytes32 delegationHash_) private {
        vm.prank(address(delegationManager));
        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:balance-overflow");
        enforcer.beforeHook(
            _rawTerms(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, APPROVE, address(token_), alice, TOKEN_OUT_MIN),
            hex"",
            batchDefaultMode,
            ExecutionLib.encodeBatch(_erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"")),
            delegationHash_,
            alice,
            relayer
        );
    }

    function test_afterHookRevertsWithoutActiveOrder() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:order-not-executing");
        enforcer.afterHook(
            _terms(address(tokenIn), APPROVE, address(tokenOut), alice),
            hex"",
            batchDefaultMode,
            hex"",
            keccak256("inactive"),
            alice,
            relayer
        );
    }

    function test_afterHookRevertsForInvalidTermsLength() public {
        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-terms");
        enforcer.afterHook(new bytes(144), hex"", batchDefaultMode, hex"", bytes32(0), alice, relayer);
    }

    function test_afterHookConsumesOrderAndEmitsEvent() public {
        bytes32 delegationHash_ = keccak256("successful-order");
        bytes memory terms_ = _terms(address(tokenIn), APPROVE, address(tokenOut), alice);
        _before(terms_, _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""), delegationHash_);
        tokenOut.mint(alice, TOKEN_OUT_MIN);

        vm.prank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(enforcer));
        emit OrderConsumed(address(delegationManager), delegationHash_, relayer);
        enforcer.afterHook(terms_, hex"", batchDefaultMode, hex"", delegationHash_, alice, relayer);

        assertEq(enforcer.orderStates(enforcer.getOrderKey(address(delegationManager), delegationHash_)), type(uint256).max);
    }

    function test_afterHookRevertsForInsufficientOutput() public {
        bytes32 delegationHash_ = keccak256("insufficient-order");
        bytes memory terms_ = _terms(address(tokenIn), APPROVE, address(tokenOut), alice);
        _before(terms_, _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""), delegationHash_);
        tokenOut.mint(alice, TOKEN_OUT_MIN - 1);

        vm.prank(address(delegationManager));
        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:insufficient-output");
        enforcer.afterHook(terms_, hex"", batchDefaultMode, hex"", delegationHash_, alice, relayer);
    }

    function test_redeemsERC20ApprovalOrder() public {
        _redeem(
            _sign(_terms(address(tokenIn), APPROVE, address(tokenOut), alice)),
            _erc20Executions(
                1, address(tokenIn), TOKEN_IN_AMOUNT, "best-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT)
            )
        );

        assertEq(tokenIn.balanceOf(alice), 900 ether);
        assertEq(tokenOut.balanceOf(alice), TOKEN_OUT_AMOUNT);
    }

    function test_redeemsERC20ResetApprovalOrder() public {
        vm.prank(alice);
        tokenIn.approve(address(metaSwap), 1);

        _redeem(
            _sign(_terms(address(tokenIn), RESET, address(tokenOut), alice)),
            _erc20Executions(
                2, address(tokenIn), TOKEN_IN_AMOUNT, "best-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT)
            )
        );

        assertEq(tokenIn.balanceOf(alice), 900 ether);
        assertEq(tokenIn.allowance(alice, address(metaSwap)), 0);
        assertEq(tokenOut.balanceOf(alice), TOKEN_OUT_AMOUNT);
    }

    function test_redeemsERC20OrderUsingExistingAllowance() public {
        vm.prank(alice);
        tokenIn.approve(address(metaSwap), TOKEN_IN_AMOUNT);

        _redeem(
            _sign(_terms(address(tokenIn), SKIP, address(tokenOut), alice)),
            _erc20Executions(
                0, address(tokenIn), TOKEN_IN_AMOUNT, "best-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT)
            )
        );

        assertEq(tokenIn.balanceOf(alice), 900 ether);
        assertEq(tokenOut.balanceOf(alice), TOKEN_OUT_AMOUNT);
    }

    function test_redeemsNativeInputOrder() public {
        uint256 nativeBefore_ = alice.balance;
        _redeem(
            _sign(_terms(address(0), 0, address(tokenOut), alice)),
            _nativeExecutions(TOKEN_IN_AMOUNT, address(tokenOut), TOKEN_OUT_AMOUNT)
        );

        assertEq(alice.balance, nativeBefore_ - TOKEN_IN_AMOUNT);
        assertEq(tokenOut.balanceOf(alice), TOKEN_OUT_AMOUNT);
    }

    function test_redeemsERC20ForNativeOutput() public {
        uint256 nativeBefore_ = alice.balance;
        _redeem(
            _sign(_terms(address(tokenIn), APPROVE, address(0), alice)),
            _erc20Executions(
                1, address(tokenIn), TOKEN_IN_AMOUNT, "native-output", abi.encode(IERC20(address(0)), TOKEN_OUT_AMOUNT)
            )
        );

        assertEq(tokenIn.balanceOf(alice), 900 ether);
        assertEq(alice.balance, nativeBefore_ + TOKEN_OUT_AMOUNT);
    }

    function test_revertsAtomicallyForInsufficientOutputAndAllowsRetry() public {
        bytes memory terms_ = _terms(address(tokenIn), APPROVE, address(tokenOut), alice);
        Delegation memory delegation_ = _sign(terms_);
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        Execution[] memory insufficient_ = _erc20Executions(
            1, address(tokenIn), TOKEN_IN_AMOUNT, "bad-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_MIN - 1)
        );

        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:insufficient-output");
        _redeem(delegation_, insufficient_);

        assertEq(tokenIn.balanceOf(alice), 1_000 ether);
        assertEq(tokenOut.balanceOf(alice), 0);
        assertEq(enforcer.orderStates(enforcer.getOrderKey(address(delegationManager), delegationHash_)), 0);

        _redeem(
            delegation_,
            _erc20Executions(
                1, address(tokenIn), TOKEN_IN_AMOUNT, "new-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_MIN)
            )
        );
        assertEq(tokenOut.balanceOf(alice), TOKEN_OUT_MIN);
    }

    function test_successfulOrderCannotBeRedeemedAgain() public {
        Delegation memory delegation_ = _sign(_terms(address(tokenIn), APPROVE, address(tokenOut), alice));
        Execution[] memory executions_ = _erc20Executions(
            1, address(tokenIn), TOKEN_IN_AMOUNT, "best-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT)
        );
        _redeem(delegation_, executions_);

        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:order-already-used");
        _redeem(delegation_, executions_);
    }

    function _expectInvalidApproval(Execution[] memory executions_) private {
        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-approval");
        _before(_terms(address(tokenIn), APPROVE, address(tokenOut), alice), executions_, bytes32(0));
    }

    function _expectInvalidSwap(Execution[] memory executions_) private {
        vm.expectRevert("MetaSwapOneShotLimitOrderEnforcer:invalid-swap");
        _before(_terms(address(tokenIn), APPROVE, address(tokenOut), alice), executions_, bytes32(0));
    }

    function _terms(address tokenIn_, uint8 policy_, address tokenOut_, address recipient_) private view returns (bytes memory) {
        return _rawTerms(address(metaSwap), tokenIn_, TOKEN_IN_AMOUNT, policy_, tokenOut_, recipient_, TOKEN_OUT_MIN);
    }

    function _rawTerms(
        address metaSwap_,
        address tokenIn_,
        uint256 tokenInAmount_,
        uint8 policy_,
        address tokenOut_,
        address recipient_,
        uint256 tokenOutMin_
    )
        private
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(metaSwap_, tokenIn_, tokenInAmount_, policy_, tokenOut_, recipient_, tokenOutMin_);
    }

    function _nativeExecutions(
        uint256 value_,
        address outputToken_,
        uint256 outputAmount_
    )
        private
        view
        returns (Execution[] memory executions_)
    {
        executions_ = new Execution[](1);
        executions_[0] =
            _swapExecution(address(0), TOKEN_IN_AMOUNT, value_, "native-route", abi.encode(IERC20(outputToken_), outputAmount_));
    }

    function _erc20Executions(
        uint8 shape_,
        address swapToken_,
        uint256 swapAmount_,
        string memory aggregatorId_,
        bytes memory routeData_
    )
        private
        view
        returns (Execution[] memory executions_)
    {
        uint256 swapIndex_ = shape_;
        executions_ = new Execution[](swapIndex_ + 1);
        if (shape_ == 2) executions_[0] = _approvalExecution(0);
        if (shape_ != 0) executions_[swapIndex_ - 1] = _approvalExecution(TOKEN_IN_AMOUNT);
        executions_[swapIndex_] = _swapExecution(swapToken_, swapAmount_, 0, aggregatorId_, routeData_);
    }

    function _approvalExecution(uint256 amount_) private view returns (Execution memory) {
        return
            Execution({
                target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (address(metaSwap), amount_))
            });
    }

    function _swapExecution(
        address swapToken_,
        uint256 swapAmount_,
        uint256 value_,
        string memory aggregatorId_,
        bytes memory routeData_
    )
        private
        view
        returns (Execution memory)
    {
        return Execution({
            target: address(metaSwap),
            value: value_,
            callData: abi.encodeCall(IMetaSwap.swap, (aggregatorId_, IERC20(swapToken_), swapAmount_, routeData_))
        });
    }

    function _before(bytes memory terms_, Execution[] memory executions_, bytes32 delegationHash_) private {
        vm.prank(address(delegationManager));
        enforcer.beforeHook(terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), delegationHash_, alice, relayer);
    }

    function _sign(bytes memory terms_) private view returns (Delegation memory delegation_) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(enforcer), terms: terms_, args: hex"" });
        delegation_ = Delegation({
            delegate: ANY_DELEGATE, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);
    }

    function _redeem(Delegation memory delegation_, Execution[] memory executions_) private {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleBatch();
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeBatch(executions_);

        vm.prank(relayer);
        delegationManager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
