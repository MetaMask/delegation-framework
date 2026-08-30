// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { ERC20BalanceChangeEnforcer } from "../../src/enforcers/ERC20BalanceChangeEnforcer.sol";
import { LimitedCallsEnforcer } from "../../src/enforcers/LimitedCallsEnforcer.sol";
import { MetaSwapBatchCalldataEnforcer } from "../../src/enforcers/MetaSwapBatchCalldataEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../src/utils/Types.sol";

contract MetaSwapMock is IMetaSwap {
    using SafeERC20 for IERC20;

    error InvalidNativeValue();
    error UnexpectedNativeValue();
    error NativeTransferFailed();

    receive() external payable { }

    function swap(string calldata, IERC20 tokenFrom_, uint256 amount_, bytes calldata data_) external payable {
        (IERC20 tokenOut_, uint256 amountOut_) = abi.decode(data_, (IERC20, uint256));

        if (address(tokenFrom_) == address(0)) {
            if (msg.value != amount_) revert InvalidNativeValue();
        } else {
            if (msg.value != 0) revert UnexpectedNativeValue();
            tokenFrom_.safeTransferFrom(msg.sender, address(this), amount_);
        }

        if (address(tokenOut_) == address(0)) {
            (bool success_,) = msg.sender.call{ value: amountOut_ }("");
            if (!success_) revert NativeTransferFailed();
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

contract MetaSwapBatchCalldataEnforcerTest is CaveatEnforcerBaseTest {
    uint256 internal constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 internal constant TOKEN_OUT_MIN = 190 ether;
    uint256 internal constant TOKEN_OUT_AMOUNT = 200 ether;

    MetaSwapBatchCalldataEnforcer internal enforcer;
    LimitedCallsEnforcer internal limitedCallsEnforcer;
    ERC20BalanceChangeEnforcer internal balanceChangeEnforcer;
    BasicERC20 internal tokenIn;
    BasicERC20 internal tokenOut;
    MetaSwapMock internal metaSwap;
    address internal relayer;

    function setUp() public override {
        super.setUp();

        enforcer = new MetaSwapBatchCalldataEnforcer();
        limitedCallsEnforcer = new LimitedCallsEnforcer();
        balanceChangeEnforcer = new ERC20BalanceChangeEnforcer();
        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        metaSwap = new MetaSwapMock();
        relayer = makeAddr("Relayer");

        tokenIn.mint(address(users.alice.deleGator), 1_000 ether);
        tokenOut.mint(address(metaSwap), 10_000 ether);
        vm.deal(address(users.alice.deleGator), 1_000 ether);
        vm.deal(address(metaSwap), 10_000 ether);
    }

    function test_acceptsERC20ApprovalAndFlexibleSwapData() public view {
        _enforce(_terms(address(tokenIn), false), _erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT, "a", hex"01"));
        _enforce(
            _terms(address(tokenIn), false),
            _erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT, "different-aggregator", new bytes(512))
        );
    }

    function test_acceptsERC20ResetApprovalAndSwap() public view {
        _enforce(
            _terms(address(tokenIn), true), _erc20Executions(true, address(tokenIn), TOKEN_IN_AMOUNT, "aggregator", new bytes(96))
        );
    }

    function test_acceptsNativeSwapWithExactValue() public view {
        Execution[] memory executions_ = new Execution[](1);
        executions_[0] = _swapExecution(address(0), TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, "aggregator", hex"1234");
        _enforce(_terms(address(0), false), executions_);
    }

    function test_revertsForSingleCallMode() public {
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        _enforceWithMode(
            _terms(address(tokenIn), false),
            _erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT, "aggregator", hex""),
            singleDefaultMode
        );
    }

    function test_revertsForTryExecutionMode() public {
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        _enforceWithMode(
            _terms(address(tokenIn), false),
            _erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT, "aggregator", hex""),
            batchTryMode
        );
    }

    function test_revertsForShortTerms() public {
        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-terms");
        enforcer.getTermsInfo(new bytes(72));
    }

    function test_revertsForLongTerms() public {
        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-terms");
        enforcer.getTermsInfo(new bytes(74));
    }

    function test_revertsForZeroMetaSwap() public {
        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-terms");
        enforcer.getTermsInfo(abi.encodePacked(address(0), address(tokenIn), TOKEN_IN_AMOUNT, bytes1(0)));
    }

    function test_revertsForZeroInputAmount() public {
        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-terms");
        enforcer.getTermsInfo(abi.encodePacked(address(metaSwap), address(tokenIn), uint256(0), bytes1(0)));
    }

    function test_revertsForInvalidResetApprovalFlag() public {
        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-terms");
        enforcer.getTermsInfo(abi.encodePacked(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, hex"02"));
    }

    function test_revertsWhenNativeTermsRequestResetApproval() public {
        Execution[] memory executions_ = new Execution[](1);
        executions_[0] = _swapExecution(address(0), TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, "aggregator", hex"");

        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-batch-length");
        _enforce(_terms(address(0), true), executions_);
    }

    function test_revertsWhenNativeBatchContainsExtraExecution() public {
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = _swapExecution(address(0), TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, "aggregator", hex"");
        executions_[1] = executions_[0];

        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-batch-length");
        _enforce(_terms(address(0), false), executions_);
    }

    function test_revertsWhenERC20BatchOmitsSwap() public {
        Execution[] memory executions_ = new Execution[](1);
        executions_[0] = _approvalExecution(TOKEN_IN_AMOUNT);

        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-batch-length");
        _enforce(_terms(address(tokenIn), false), executions_);
    }

    function test_revertsWhenResetApprovalBatchOmitsReset() public {
        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-batch-length");
        _enforce(_terms(address(tokenIn), true), _erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT, "aggregator", hex""));
    }

    function test_revertsForWrongApprovalTarget() public {
        Execution[] memory executions_ = _erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT, "aggregator", hex"");
        executions_[0].target = makeAddr("OtherToken");
        _expectInvalidApproval(executions_);
    }

    function test_revertsForApprovalWithValue() public {
        Execution[] memory executions_ = _erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT, "aggregator", hex"");
        executions_[0].value = 1;
        _expectInvalidApproval(executions_);
    }

    function test_revertsForShortApprovalCalldata() public {
        Execution[] memory executions_ = _erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT, "aggregator", hex"");
        executions_[0].callData = abi.encodePacked(IERC20.approve.selector);
        _expectInvalidApproval(executions_);
    }

    function test_revertsForWrongApprovalSelector() public {
        Execution[] memory executions_ = _erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT, "aggregator", hex"");
        executions_[0].callData = abi.encodeCall(IERC20.transfer, (address(metaSwap), TOKEN_IN_AMOUNT));
        _expectInvalidApproval(executions_);
    }

    function test_revertsForWrongApprovalSpender() public {
        Execution[] memory executions_ = _erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT, "aggregator", hex"");
        executions_[0].callData = abi.encodeCall(IERC20.approve, (makeAddr("OtherSpender"), TOKEN_IN_AMOUNT));
        _expectInvalidApproval(executions_);
    }

    function test_revertsForWrongApprovalAmount() public {
        Execution[] memory executions_ = _erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT, "aggregator", hex"");
        executions_[0].callData = abi.encodeCall(IERC20.approve, (address(metaSwap), TOKEN_IN_AMOUNT - 1));
        _expectInvalidApproval(executions_);
    }

    function test_revertsForWrongResetApprovalAmount() public {
        Execution[] memory executions_ = _erc20Executions(true, address(tokenIn), TOKEN_IN_AMOUNT, "aggregator", hex"");
        executions_[0].callData = abi.encodeCall(IERC20.approve, (address(metaSwap), 1));

        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-approval");
        _enforce(_terms(address(tokenIn), true), executions_);
    }

    function test_revertsForWrongSwapTarget() public {
        Execution[] memory executions_ = _erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT, "aggregator", hex"");
        executions_[1].target = makeAddr("OtherSwap");
        _expectInvalidSwap(executions_);
    }

    function test_revertsForERC20SwapWithValue() public {
        Execution[] memory executions_ = _erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT, "aggregator", hex"");
        executions_[1].value = 1;
        _expectInvalidSwap(executions_);
    }

    function test_revertsForNativeSwapWithWrongValue() public {
        Execution[] memory executions_ = new Execution[](1);
        executions_[0] = _swapExecution(address(0), TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT - 1, "aggregator", hex"");

        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-swap");
        _enforce(_terms(address(0), false), executions_);
    }

    function test_revertsForShortSwapCalldata() public {
        Execution[] memory executions_ = _erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT, "aggregator", hex"");
        executions_[1].callData = abi.encodePacked(IMetaSwap.swap.selector);
        _expectInvalidSwap(executions_);
    }

    function test_revertsForWrongSwapSelector() public {
        Execution[] memory executions_ = _erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT, "aggregator", hex"");
        executions_[1].callData = abi.encodeCall(IERC20.approve, (address(metaSwap), TOKEN_IN_AMOUNT));
        _expectInvalidSwap(executions_);
    }

    function test_revertsForWrongSwapInputToken() public {
        _expectInvalidSwap(_erc20Executions(false, makeAddr("OtherToken"), TOKEN_IN_AMOUNT, "aggregator", hex""));
    }

    function test_revertsForWrongSwapInputAmount() public {
        _expectInvalidSwap(_erc20Executions(false, address(tokenIn), TOKEN_IN_AMOUNT - 1, "aggregator", hex""));
    }

    function test_redeemsERC20ApprovalAndSwapThroughDelegationManager() public {
        Delegation memory delegation_ = _signDelegation(false);

        _redeem(
            delegation_,
            _erc20Executions(
                false, address(tokenIn), TOKEN_IN_AMOUNT, "best-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT)
            )
        );

        assertEq(tokenIn.balanceOf(address(users.alice.deleGator)), 900 ether);
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), TOKEN_OUT_AMOUNT);
    }

    function test_redeemsERC20ResetApprovalAndSwapThroughDelegationManager() public {
        vm.prank(address(users.alice.deleGator));
        tokenIn.approve(address(metaSwap), 1);
        Delegation memory delegation_ = _signDelegation(true);

        _redeem(
            delegation_,
            _erc20Executions(
                true, address(tokenIn), TOKEN_IN_AMOUNT, "best-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT)
            )
        );

        assertEq(tokenIn.balanceOf(address(users.alice.deleGator)), 900 ether);
        assertEq(tokenIn.allowance(address(users.alice.deleGator), address(metaSwap)), 0);
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), TOKEN_OUT_AMOUNT);
    }

    function test_redeemsNativeSwapThroughDelegationManager() public {
        Delegation memory delegation_ = _signNativeDelegation();
        uint256 nativeBefore_ = address(users.alice.deleGator).balance;

        Execution[] memory executions_ = new Execution[](1);
        executions_[0] = _swapExecution(
            address(0), TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, "best-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT)
        );
        _redeem(delegation_, executions_);

        assertEq(address(users.alice.deleGator).balance, nativeBefore_ - TOKEN_IN_AMOUNT);
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), TOKEN_OUT_AMOUNT);
    }

    function test_balanceCheckRevertsInsufficientOutputAndAllowsRetry() public {
        Delegation memory delegation_ = _signDelegation(false);

        vm.expectRevert("ERC20BalanceChangeEnforcer:insufficient-balance-increase");
        _redeem(
            delegation_,
            _erc20Executions(
                false, address(tokenIn), TOKEN_IN_AMOUNT, "bad-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_MIN - 1)
            )
        );

        _redeem(
            delegation_,
            _erc20Executions(
                false, address(tokenIn), TOKEN_IN_AMOUNT, "new-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_MIN)
            )
        );
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), TOKEN_OUT_MIN);
    }

    function test_limitedCallsPreventsSecondSuccessfulRedemption() public {
        Delegation memory delegation_ = _signDelegation(false);
        Execution[] memory executions_ = _erc20Executions(
            false, address(tokenIn), TOKEN_IN_AMOUNT, "best-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT)
        );
        _redeem(delegation_, executions_);

        vm.expectRevert("LimitedCallsEnforcer:limit-exceeded");
        _redeem(delegation_, executions_);
    }

    function _expectInvalidApproval(Execution[] memory executions_) private {
        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-approval");
        _enforce(_terms(address(tokenIn), false), executions_);
    }

    function _expectInvalidSwap(Execution[] memory executions_) private {
        vm.expectRevert("MetaSwapBatchCalldataEnforcer:invalid-swap");
        _enforce(_terms(address(tokenIn), false), executions_);
    }

    function _terms(address tokenIn_, bool resetApproval_) private view returns (bytes memory) {
        return abi.encodePacked(address(metaSwap), tokenIn_, TOKEN_IN_AMOUNT, bytes1(resetApproval_ ? 0x01 : 0x00));
    }

    function _erc20Executions(
        bool resetApproval_,
        address swapToken_,
        uint256 swapAmount_,
        string memory aggregatorId_,
        bytes memory routeData_
    )
        private
        view
        returns (Execution[] memory executions_)
    {
        uint256 swapIndex_ = resetApproval_ ? 2 : 1;
        executions_ = new Execution[](swapIndex_ + 1);
        if (resetApproval_) executions_[0] = _approvalExecution(0);
        executions_[swapIndex_ - 1] = _approvalExecution(TOKEN_IN_AMOUNT);
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

    function _enforce(bytes memory terms_, Execution[] memory executions_) private view {
        _enforceWithMode(terms_, executions_, batchDefaultMode);
    }

    function _enforceWithMode(bytes memory terms_, Execution[] memory executions_, ModeCode mode_) private view {
        enforcer.beforeHook(
            terms_, hex"", mode_, ExecutionLib.encodeBatch(executions_), bytes32(0), address(users.alice.deleGator), relayer
        );
    }

    function _signDelegation(bool resetApproval_) private view returns (Delegation memory delegation_) {
        delegation_ = _signWithCaveats(_caveats(address(tokenIn), resetApproval_));
    }

    function _signNativeDelegation() private view returns (Delegation memory delegation_) {
        delegation_ = _signWithCaveats(_caveats(address(0), false));
    }

    function _caveats(address tokenIn_, bool resetApproval_) private view returns (Caveat[] memory caveats_) {
        caveats_ = new Caveat[](3);
        caveats_[0] = Caveat({ enforcer: address(enforcer), terms: _terms(tokenIn_, resetApproval_), args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(uint256(1)), args: hex"" });
        caveats_[2] = Caveat({
            enforcer: address(balanceChangeEnforcer),
            terms: abi.encodePacked(false, address(tokenOut), address(users.alice.deleGator), TOKEN_OUT_MIN),
            args: hex""
        });
    }

    function _signWithCaveats(Caveat[] memory caveats_) private view returns (Delegation memory delegation_) {
        delegation_ = Delegation({
            delegate: ANY_DELEGATE,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
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
