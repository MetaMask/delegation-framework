// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { BaseTest } from "../../utils/BaseTest.t.sol";
import { BasicERC20 } from "../../utils/BasicERC20.t.sol";
import { Implementation, SignatureType } from "../../utils/Types.t.sol";
import { AllowedCalldataEnforcer } from "../../../src/enforcers/AllowedCalldataEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../../src/enforcers/AllowedTargetsEnforcer.sol";
import { ERC20BalanceChangeEnforcer } from "../../../src/enforcers/ERC20BalanceChangeEnforcer.sol";
import { LimitedCallsEnforcer } from "../../../src/enforcers/LimitedCallsEnforcer.sol";
import { MetaSwapBatchCalldataEnforcer } from "../../../src/enforcers/MetaSwapBatchCalldataEnforcer.sol";
import { MetaSwap7702CalldataEnforcer } from "../../../src/enforcers/MetaSwap7702CalldataEnforcer.sol";
import { NativeBalanceChangeEnforcer } from "../../../src/enforcers/NativeBalanceChangeEnforcer.sol";
import { NativeTokenTransferAmountEnforcer } from "../../../src/enforcers/NativeTokenTransferAmountEnforcer.sol";
import { IERC7821 } from "../../../src/interfaces/IERC7821.sol";
import { IMetaSwap } from "../../../src/helpers/interfaces/IMetaSwap.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../../src/utils/Types.sol";

contract FlexibleMetaSwapMock is IMetaSwap {
    using SafeERC20 for IERC20;

    receive() external payable { }

    function swap(string calldata, IERC20 tokenFrom_, uint256 amount_, bytes calldata data_) external payable {
        (IERC20 tokenOut_, uint256 amountOut_,) = abi.decode(data_, (IERC20, uint256, bytes));

        if (address(tokenFrom_) == address(0)) {
            require(msg.value == amount_, "invalid-native-input");
        } else {
            require(msg.value == 0, "unexpected-value");
            tokenFrom_.safeTransferFrom(msg.sender, address(this), amount_);
        }

        if (address(tokenOut_) == address(0)) {
            (bool success_,) = msg.sender.call{ value: amountOut_ }("");
            require(success_, "native-output-failed");
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

/**
 * @notice Proof that disjoint AllowedCalldata checks can secure a flexible MetaSwap route inside one outer 7702 execution.
 * @dev This intentionally uses the canonical manager. It validates the caveat composition before changing the specialized manager.
 */
contract AllowedCalldataLimitOrderTest is BaseTest {
    using SafeERC20 for IERC20;

    uint256 internal constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 internal constant TOKEN_OUT_MIN = 190 ether;
    uint256 internal constant ACTUAL_TOKEN_OUT = 200 ether;

    // IERC7821.execute(ModeCode,bytes): selector + mode + bytes offset.
    uint256 internal constant OUTER_HEADER_LENGTH = 68;
    // The dynamic batch bytes begin after selector + two ABI head words + bytes length.
    uint256 internal constant INNER_BATCH_START = 100;

    AllowedCalldataEnforcer internal allowedCalldataEnforcer;
    AllowedTargetsEnforcer internal allowedTargetsEnforcer;
    NativeTokenTransferAmountEnforcer internal outerValueEnforcer;
    LimitedCallsEnforcer internal limitedCallsEnforcer;
    MetaSwapBatchCalldataEnforcer internal metaSwapBatchCalldataEnforcer;
    MetaSwap7702CalldataEnforcer internal metaSwap7702CalldataEnforcer;
    ERC20BalanceChangeEnforcer internal erc20BalanceChangeEnforcer;
    NativeBalanceChangeEnforcer internal nativeBalanceChangeEnforcer;

    BasicERC20 internal tokenIn;
    BasicERC20 internal tokenOut;
    BasicERC20 internal preapprovedToken;
    FlexibleMetaSwapMock internal metaSwap;

    address internal alice;
    address internal relayer;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();

        allowedCalldataEnforcer = new AllowedCalldataEnforcer();
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        outerValueEnforcer = new NativeTokenTransferAmountEnforcer();
        limitedCallsEnforcer = new LimitedCallsEnforcer();
        metaSwapBatchCalldataEnforcer = new MetaSwapBatchCalldataEnforcer();
        metaSwap7702CalldataEnforcer = new MetaSwap7702CalldataEnforcer();
        erc20BalanceChangeEnforcer = new ERC20BalanceChangeEnforcer();
        nativeBalanceChangeEnforcer = new NativeBalanceChangeEnforcer();

        alice = address(users.alice.deleGator);
        relayer = makeAddr("Relayer");

        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        preapprovedToken = new BasicERC20(address(this), "Preapproved Token", "OLD", 0);
        metaSwap = new FlexibleMetaSwapMock();

        tokenIn.mint(alice, 1_000 ether);
        preapprovedToken.mint(alice, 1_000 ether);
        tokenOut.mint(address(metaSwap), 10_000 ether);
        vm.deal(address(metaSwap), 10_000 ether);
    }

    function test_erc20OneApproval_routeAndAggregatorRemainFlexible() public {
        Execution memory template_ =
            _wrap(_erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT, "template", _route(tokenOut, ACTUAL_TOKEN_OUT, hex"01")));
        Delegation memory delegation_ = _sign(_secureCaveats(template_, tokenOut, TOKEN_OUT_MIN));

        // Different dynamic string and bytes lengths are accepted after the user signs.
        Execution memory fill_ = _wrap(
            _erc20Inner(
                false,
                tokenIn,
                TOKEN_IN_AMOUNT,
                "a-different-aggregator",
                _route(tokenOut, ACTUAL_TOKEN_OUT, hex"010203040506070809")
            )
        );

        _redeem(delegation_, fill_);

        assertEq(tokenIn.balanceOf(alice), 900 ether);
        assertEq(tokenOut.balanceOf(alice), ACTUAL_TOKEN_OUT);
    }

    function test_erc20ResetAndApproval_routeRemainsFlexible() public {
        vm.prank(alice);
        tokenIn.approve(address(metaSwap), 1);

        Execution memory template_ =
            _wrap(_erc20Inner(true, tokenIn, TOKEN_IN_AMOUNT, "template", _route(tokenOut, ACTUAL_TOKEN_OUT, hex"")));
        Delegation memory delegation_ = _sign(_secureCaveats(template_, tokenOut, TOKEN_OUT_MIN));
        Execution memory fill_ =
            _wrap(_erc20Inner(true, tokenIn, TOKEN_IN_AMOUNT, "new-route", _route(tokenOut, ACTUAL_TOKEN_OUT, new bytes(96))));

        _redeem(delegation_, fill_);

        assertEq(tokenIn.balanceOf(alice), 900 ether);
        assertEq(tokenOut.balanceOf(alice), ACTUAL_TOKEN_OUT);
        assertEq(tokenIn.allowance(alice, address(metaSwap)), 0);
    }

    function test_customEnforcer_erc20OneApproval_sameCanonicalManager() public {
        Delegation memory delegation_ = _sign(_customCaveats(false, tokenOut, TOKEN_OUT_MIN));
        Execution memory fill_ = _wrap(
            _erc20Inner(
                false, tokenIn, TOKEN_IN_AMOUNT, "a-different-aggregator", _route(tokenOut, ACTUAL_TOKEN_OUT, new bytes(96))
            )
        );

        _redeem(delegation_, fill_);

        assertEq(tokenIn.balanceOf(alice), 900 ether);
        assertEq(tokenOut.balanceOf(alice), ACTUAL_TOKEN_OUT);
    }

    function test_customEnforcer_erc20ResetApproval_sameCanonicalManager() public {
        vm.prank(alice);
        tokenIn.approve(address(metaSwap), 1);

        Delegation memory delegation_ = _sign(_customCaveats(true, tokenOut, TOKEN_OUT_MIN));
        Execution memory fill_ =
            _wrap(_erc20Inner(true, tokenIn, TOKEN_IN_AMOUNT, "new-route", _route(tokenOut, ACTUAL_TOKEN_OUT, new bytes(96))));

        _redeem(delegation_, fill_);

        assertEq(tokenIn.balanceOf(alice), 900 ether);
        assertEq(tokenOut.balanceOf(alice), ACTUAL_TOKEN_OUT);
    }

    function test_directBatchEnforcer_erc20OneApproval_sameCanonicalManager() public {
        Delegation memory delegation_ = _sign(_directBatchCaveats(false, tokenOut, TOKEN_OUT_MIN));
        Execution[] memory executions_ =
            _erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT, "best-route", _route(tokenOut, ACTUAL_TOKEN_OUT, new bytes(96)));

        _redeemBatch(delegation_, executions_);

        assertEq(tokenIn.balanceOf(alice), 900 ether);
        assertEq(tokenOut.balanceOf(alice), ACTUAL_TOKEN_OUT);
    }

    function test_directBatchEnforcer_erc20ResetApproval_sameCanonicalManager() public {
        vm.prank(alice);
        tokenIn.approve(address(metaSwap), 1);

        Delegation memory delegation_ = _sign(_directBatchCaveats(true, tokenOut, TOKEN_OUT_MIN));
        Execution[] memory executions_ =
            _erc20Inner(true, tokenIn, TOKEN_IN_AMOUNT, "best-route", _route(tokenOut, ACTUAL_TOKEN_OUT, new bytes(96)));

        _redeemBatch(delegation_, executions_);

        assertEq(tokenIn.balanceOf(alice), 900 ether);
        assertEq(tokenOut.balanceOf(alice), ACTUAL_TOKEN_OUT);
    }

    function test_nativeInput_singleInnerExecutionAndFlexibleRoute() public {
        Execution memory template_ = _wrap(_nativeInner("template", _route(tokenOut, ACTUAL_TOKEN_OUT, hex"01")));
        Delegation memory delegation_ = _sign(_secureCaveats(template_, tokenOut, TOKEN_OUT_MIN));
        Execution memory fill_ =
            _wrap(_nativeInner("better-aggregator", _route(tokenOut, ACTUAL_TOKEN_OUT, hex"010203040506070809")));

        uint256 nativeBefore_ = alice.balance;
        _redeem(delegation_, fill_);

        assertEq(alice.balance, nativeBefore_ - TOKEN_IN_AMOUNT);
        assertEq(tokenOut.balanceOf(alice), ACTUAL_TOKEN_OUT);
    }

    function test_nativeOutput_balanceCaveatWorksWithFlexibleRoute() public {
        Execution memory template_ =
            _wrap(_erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT, "template", _route(IERC20(address(0)), ACTUAL_TOKEN_OUT, hex"")));
        Delegation memory delegation_ = _sign(_secureNativeOutputCaveats(template_, TOKEN_OUT_MIN));
        Execution memory fill_ = _wrap(
            _erc20Inner(
                false, tokenIn, TOKEN_IN_AMOUNT, "better-aggregator", _route(IERC20(address(0)), ACTUAL_TOKEN_OUT, new bytes(64))
            )
        );

        uint256 nativeBefore_ = alice.balance;
        _redeem(delegation_, fill_);

        assertEq(alice.balance, nativeBefore_ + ACTUAL_TOKEN_OUT);
    }

    function test_insufficientOutputRevertsButDifferentRouteCanRetry() public {
        Execution memory template_ =
            _wrap(_erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT, "template", _route(tokenOut, TOKEN_OUT_MIN, hex"")));
        Delegation memory delegation_ = _sign(_secureCaveats(template_, tokenOut, TOKEN_OUT_MIN));

        Execution memory badFill_ =
            _wrap(_erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT, "bad", _route(tokenOut, TOKEN_OUT_MIN - 1, bytes("bad"))));
        vm.expectRevert("ERC20BalanceChangeEnforcer:insufficient-balance-increase");
        _redeem(delegation_, badFill_);

        Execution memory goodFill_ =
            _wrap(_erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT, "good", _route(tokenOut, TOKEN_OUT_MIN, bytes("good"))));
        _redeem(delegation_, goodFill_);

        assertEq(tokenOut.balanceOf(alice), TOKEN_OUT_MIN);
    }

    function test_secureSlicesRejectDifferentTokenIn() public {
        Execution memory template_ =
            _wrap(_erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT, "template", _route(tokenOut, ACTUAL_TOKEN_OUT, hex"")));
        Delegation memory delegation_ = _sign(_secureCaveats(template_, tokenOut, TOKEN_OUT_MIN));
        Execution memory tampered_ =
            _wrap(_erc20Inner(false, preapprovedToken, TOKEN_IN_AMOUNT, "route", _route(tokenOut, ACTUAL_TOKEN_OUT, hex"")));

        vm.expectRevert("AllowedCalldataEnforcer:invalid-calldata");
        _redeem(delegation_, tampered_);
    }

    function test_singlePrefixCannotKeepDifferentLengthRouteFlexible() public {
        Execution memory template_ =
            _wrap(_erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT, "template", _route(tokenOut, ACTUAL_TOKEN_OUT, hex"")));
        Execution memory fill_ = _wrap(
            _erc20Inner(
                false, tokenIn, TOKEN_IN_AMOUNT, "longer-aggregator-name", _route(tokenOut, ACTUAL_TOKEN_OUT, new bytes(96))
            )
        );

        uint256 selectorOffset_ = _indexOf(template_.callData, IMetaSwap.swap.selector);
        bytes memory onePrefixTerms_ = abi.encodePacked(uint256(0), _slice(template_.callData, 0, selectorOffset_ + 4));
        bytes memory fillExecutionCallData_ = ExecutionLib.encodeSingle(fill_.target, fill_.value, fill_.callData);

        vm.prank(address(delegationManager));
        vm.expectRevert("AllowedCalldataEnforcer:invalid-calldata");
        allowedCalldataEnforcer.beforeHook(
            onePrefixTerms_, hex"", singleDefaultMode, fillExecutionCallData_, bytes32(0), alice, relayer
        );
    }

    function test_oneApprovalTermsDoNotAlsoPermitResetApprovalShape() public {
        Execution memory template_ =
            _wrap(_erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT, "template", _route(tokenOut, ACTUAL_TOKEN_OUT, hex"")));
        Delegation memory delegation_ = _sign(_secureCaveats(template_, tokenOut, TOKEN_OUT_MIN));
        Execution memory resetFill_ =
            _wrap(_erc20Inner(true, tokenIn, TOKEN_IN_AMOUNT, "template", _route(tokenOut, ACTUAL_TOKEN_OUT, hex"")));

        vm.expectRevert("AllowedCalldataEnforcer:invalid-calldata");
        _redeem(delegation_, resetFill_);
    }

    function test_ignoringSwapInputsCanDrainAnotherPreapprovedToken() public {
        vm.prank(alice);
        preapprovedToken.approve(address(metaSwap), TOKEN_IN_AMOUNT);

        Execution memory template_ =
            _wrap(_erc20Inner(false, tokenIn, TOKEN_IN_AMOUNT, "template", _route(tokenOut, ACTUAL_TOKEN_OUT, hex"")));
        // Deliberately omit the tokenFrom + amount slice, matching the proposed "ignore swap inputs" version.
        Delegation memory unsafeDelegation_ = _sign(_unsafeCaveats(template_, tokenOut, TOKEN_OUT_MIN));
        Execution memory maliciousFill_ = _wrap(
            _erc20Inner(false, preapprovedToken, TOKEN_IN_AMOUNT, "malicious-route", _route(tokenOut, ACTUAL_TOKEN_OUT, hex""))
        );

        _redeem(unsafeDelegation_, maliciousFill_);

        assertEq(tokenIn.balanceOf(alice), 1_000 ether, "intended token was not spent");
        assertEq(preapprovedToken.balanceOf(alice), 900 ether, "unbound preapproved token was drained");
        assertEq(tokenOut.balanceOf(alice), ACTUAL_TOKEN_OUT, "output check still passed");
    }

    function _secureCaveats(
        Execution memory template_,
        IERC20 tokenOut_,
        uint256 minOut_
    )
        private
        view
        returns (Caveat[] memory caveats_)
    {
        Caveat[] memory calldataCaveats_ = _calldataCaveats(template_, true);
        caveats_ = _commonCaveats(calldataCaveats_, calldataCaveats_.length + 4);
        caveats_[caveats_.length - 2] =
            Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(uint256(1)), args: hex"" });
        caveats_[caveats_.length - 1] = Caveat({
            enforcer: address(erc20BalanceChangeEnforcer),
            terms: abi.encodePacked(false, address(tokenOut_), alice, minOut_),
            args: hex""
        });
    }

    function _customCaveats(bool resetApproval_, IERC20 tokenOut_, uint256 minOut_)
        private
        view
        returns (Caveat[] memory caveats_)
    {
        caveats_ = new Caveat[](3);
        caveats_[0] = Caveat({
            enforcer: address(metaSwap7702CalldataEnforcer),
            terms: abi.encodePacked(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, bytes1(resetApproval_ ? 0x01 : 0x00)),
            args: hex""
        });
        caveats_[1] = Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(uint256(1)), args: hex"" });
        caveats_[2] = Caveat({
            enforcer: address(erc20BalanceChangeEnforcer),
            terms: abi.encodePacked(false, address(tokenOut_), alice, minOut_),
            args: hex""
        });
    }

    function _directBatchCaveats(
        bool resetApproval_,
        IERC20 tokenOut_,
        uint256 minOut_
    )
        private
        view
        returns (Caveat[] memory caveats_)
    {
        caveats_ = new Caveat[](3);
        caveats_[0] = Caveat({
            enforcer: address(metaSwapBatchCalldataEnforcer),
            terms: abi.encodePacked(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, bytes1(resetApproval_ ? 0x01 : 0x00)),
            args: hex""
        });
        caveats_[1] = Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(uint256(1)), args: hex"" });
        caveats_[2] = Caveat({
            enforcer: address(erc20BalanceChangeEnforcer),
            terms: abi.encodePacked(false, address(tokenOut_), alice, minOut_),
            args: hex""
        });
    }

    function _secureNativeOutputCaveats(
        Execution memory template_,
        uint256 minOut_
    )
        private
        view
        returns (Caveat[] memory caveats_)
    {
        Caveat[] memory calldataCaveats_ = _calldataCaveats(template_, true);
        caveats_ = _commonCaveats(calldataCaveats_, calldataCaveats_.length + 4);
        caveats_[caveats_.length - 2] =
            Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(uint256(1)), args: hex"" });
        caveats_[caveats_.length - 1] =
            Caveat({ enforcer: address(nativeBalanceChangeEnforcer), terms: abi.encodePacked(false, alice, minOut_), args: hex"" });
    }

    function _unsafeCaveats(
        Execution memory template_,
        IERC20 tokenOut_,
        uint256 minOut_
    )
        private
        view
        returns (Caveat[] memory caveats_)
    {
        Caveat[] memory calldataCaveats_ = _calldataCaveats(template_, false);
        caveats_ = _commonCaveats(calldataCaveats_, calldataCaveats_.length + 4);
        caveats_[caveats_.length - 2] =
            Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(uint256(1)), args: hex"" });
        caveats_[caveats_.length - 1] = Caveat({
            enforcer: address(erc20BalanceChangeEnforcer),
            terms: abi.encodePacked(false, address(tokenOut_), alice, minOut_),
            args: hex""
        });
    }

    function _commonCaveats(Caveat[] memory calldataCaveats_, uint256 totalLength_)
        private
        view
        returns (Caveat[] memory caveats_)
    {
        caveats_ = new Caveat[](totalLength_);
        caveats_[0] = Caveat({ enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(alice), args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(outerValueEnforcer), terms: abi.encode(uint256(0)), args: hex"" });
        for (uint256 i; i < calldataCaveats_.length; ++i) {
            caveats_[i + 2] = calldataCaveats_[i];
        }
    }

    function _calldataCaveats(Execution memory template_, bool bindSwapInputs_) private view returns (Caveat[] memory caveats_) {
        uint256 selectorOffset_ = _indexOf(template_.callData, IMetaSwap.swap.selector);
        uint256 swapCallDataLengthOffset_ = selectorOffset_ - 32;
        uint256 count_ = bindSwapInputs_ ? 4 : 3;
        caveats_ = new Caveat[](count_);

        // Skip the outer dynamic-bytes length at [68:100], which changes with route length.
        caveats_[0] = _allowedCalldataCaveat(0, _slice(template_.callData, 0, OUTER_HEADER_LENGTH));
        // Bind inner count, offsets, exact approvals, and the final MetaSwap target/value; stop before swap calldata length.
        caveats_[1] = _allowedCalldataCaveat(
            INNER_BATCH_START, _slice(template_.callData, INNER_BATCH_START, swapCallDataLengthOffset_ - INNER_BATCH_START)
        );
        caveats_[2] = _allowedCalldataCaveat(selectorOffset_, abi.encodePacked(IMetaSwap.swap.selector));

        if (bindSwapInputs_) {
            // IMetaSwap.swap head: selector | string offset | tokenFrom | amount | bytes offset.
            caveats_[3] = _allowedCalldataCaveat(selectorOffset_ + 36, _slice(template_.callData, selectorOffset_ + 36, 64));
        }
    }

    function _allowedCalldataCaveat(uint256 offset_, bytes memory expected_) private view returns (Caveat memory caveat_) {
        caveat_ = Caveat({ enforcer: address(allowedCalldataEnforcer), terms: abi.encodePacked(offset_, expected_), args: hex"" });
    }

    function _erc20Inner(
        bool resetApproval_,
        IERC20 swapToken_,
        uint256 swapAmount_,
        string memory aggregatorId_,
        bytes memory route_
    )
        private
        view
        returns (Execution[] memory executions_)
    {
        uint256 swapIndex_ = resetApproval_ ? 2 : 1;
        executions_ = new Execution[](swapIndex_ + 1);
        if (resetApproval_) {
            executions_[0] =
                Execution({ target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (address(metaSwap), 0)) });
        }
        executions_[swapIndex_ - 1] = Execution({
            target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (address(metaSwap), TOKEN_IN_AMOUNT))
        });
        executions_[swapIndex_] = Execution({
            target: address(metaSwap),
            value: 0,
            callData: abi.encodeCall(IMetaSwap.swap, (aggregatorId_, swapToken_, swapAmount_, route_))
        });
    }

    function _nativeInner(string memory aggregatorId_, bytes memory route_) private view returns (Execution[] memory executions_) {
        executions_ = new Execution[](1);
        executions_[0] = Execution({
            target: address(metaSwap),
            value: TOKEN_IN_AMOUNT,
            callData: abi.encodeCall(IMetaSwap.swap, (aggregatorId_, IERC20(address(0)), TOKEN_IN_AMOUNT, route_))
        });
    }

    function _route(IERC20 tokenOut_, uint256 amountOut_, bytes memory routeData_) private pure returns (bytes memory) {
        return abi.encode(tokenOut_, amountOut_, routeData_);
    }

    function _wrap(Execution[] memory inner_) private view returns (Execution memory execution_) {
        execution_ = Execution({
            target: alice,
            value: 0,
            callData: abi.encodeCall(IERC7821.execute, (ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(inner_)))
        });
    }

    function _sign(Caveat[] memory caveats_) private view returns (Delegation memory delegation_) {
        delegation_ = Delegation({
            delegate: ANY_DELEGATE, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);
    }

    function _redeem(Delegation memory delegation_, Execution memory execution_) private {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = singleDefaultMode;
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(relayer);
        delegationManager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);
    }

    function _redeemBatch(Delegation memory delegation_, Execution[] memory executions_) private {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = batchDefaultMode;
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeBatch(executions_);

        vm.prank(relayer);
        delegationManager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);
    }

    function _indexOf(bytes memory data_, bytes4 needle_) private pure returns (uint256 index_) {
        for (uint256 i; i + 4 <= data_.length; ++i) {
            bytes4 candidate_;
            assembly {
                candidate_ := mload(add(add(data_, 0x20), i))
            }
            if (candidate_ == needle_) return i;
        }
        revert("selector-not-found");
    }

    function _slice(bytes memory data_, uint256 start_, uint256 length_) private pure returns (bytes memory result_) {
        result_ = new bytes(length_);
        for (uint256 i; i < length_; ++i) {
            result_[i] = data_[start_ + i];
        }
    }
}
