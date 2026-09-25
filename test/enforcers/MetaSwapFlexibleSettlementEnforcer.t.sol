// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { DelegationManager } from "../../src/DelegationManager.sol";
import { MetaSwapFlexibleSettlementEnforcer } from "../../src/enforcers/MetaSwapFlexibleSettlementEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../src/utils/Types.sol";

contract FlexibleSettlementMetaSwapMock is IMetaSwap {
    using SafeERC20 for IERC20;

    receive() external payable { }

    function swap(string calldata, IERC20 tokenFrom_, uint256 amount_, bytes calldata data_) external payable {
        (IERC20 tokenOut_, uint256 amountOut_) = abi.decode(data_, (IERC20, uint256));

        if (address(tokenFrom_) == address(0)) {
            require(msg.value == amount_, "FlexibleSettlementMetaSwapMock:invalid-native-value");
        } else {
            require(msg.value == 0, "FlexibleSettlementMetaSwapMock:unexpected-native-value");
            tokenFrom_.safeTransferFrom(msg.sender, address(this), amount_);
        }

        if (address(tokenOut_) == address(0)) {
            (bool success_,) = msg.sender.call{ value: amountOut_ }("");
            require(success_, "FlexibleSettlementMetaSwapMock:native-transfer-failed");
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

contract MetaSwapFlexibleSettlementEnforcerTest is CaveatEnforcerBaseTest {
    uint256 internal constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 internal constant TOKEN_OUT_MIN = 190 ether;
    uint256 internal constant TOKEN_OUT_AMOUNT = 200 ether;
    MetaSwapFlexibleSettlementEnforcer.ApprovalMode internal constant NONE = MetaSwapFlexibleSettlementEnforcer.ApprovalMode.None;
    MetaSwapFlexibleSettlementEnforcer.ApprovalMode internal constant SKIP =
    MetaSwapFlexibleSettlementEnforcer.ApprovalMode.SkipApproval;
    MetaSwapFlexibleSettlementEnforcer.ApprovalMode internal constant APPROVE =
    MetaSwapFlexibleSettlementEnforcer.ApprovalMode.Approve;
    MetaSwapFlexibleSettlementEnforcer.ApprovalMode internal constant RESET =
    MetaSwapFlexibleSettlementEnforcer.ApprovalMode.ResetApprove;

    uint256 internal constant ORDER_ID = 42;
    uint128 internal constant NO_TIMESTAMP = 0;
    uint256 internal constant NO_ID = 0;

    MetaSwapFlexibleSettlementEnforcer internal enforcer;
    BasicERC20 internal tokenIn;
    BasicERC20 internal tokenOut;
    FlexibleSettlementMetaSwapMock internal metaSwap;
    address internal alice;
    address internal relayer;
    uint128 internal expiresAt;

    event SettlementConsumed(
        address indexed delegationManager, bytes32 indexed delegationHash, address indexed redeemer, uint256 id
    );
    event UsedId(address indexed sender, address indexed delegator, address indexed redeemer, uint256 id);

    function setUp() public override {
        super.setUp();

        enforcer = new MetaSwapFlexibleSettlementEnforcer();
        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        metaSwap = new FlexibleSettlementMetaSwapMock();
        alice = address(users.alice.deleGator);
        relayer = makeAddr("Relayer");
        expiresAt = uint128(block.timestamp + 1 days);

        tokenIn.mint(alice, 1_000 ether);
        tokenOut.mint(address(metaSwap), 10_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(address(metaSwap), 10_000 ether);
    }

    function test_getTermsInfoDecodesERC20Settlement() public {
        MetaSwapFlexibleSettlementEnforcer.Terms memory info_ =
            enforcer.getTermsInfo(_terms(address(tokenIn), APPROVE, address(tokenOut), alice));

        assertEq(info_.metaSwap, address(metaSwap));
        assertEq(info_.tokenIn, address(tokenIn));
        assertEq(info_.tokenInAmount, TOKEN_IN_AMOUNT);
        assertEq(uint8(info_.approvalMode), uint8(APPROVE));
        assertEq(info_.tokenOut, address(tokenOut));
        assertEq(info_.recipient, alice);
        assertEq(info_.tokenOutMin, TOKEN_OUT_MIN);
        assertEq(info_.timestampAfter, NO_TIMESTAMP);
        assertEq(info_.timestampBefore, NO_TIMESTAMP);
        assertEq(info_.id, NO_ID);
        assertEq(info_.redeemers.length, 1);
        assertEq(info_.redeemers[0], relayer);
    }

    function test_getTermsInfoDecodesNativeInputSettlement() public {
        MetaSwapFlexibleSettlementEnforcer.Terms memory info_ =
            enforcer.getTermsInfo(_terms(address(0), NONE, address(tokenOut), alice));

        assertEq(info_.tokenIn, address(0));
        assertEq(uint8(info_.approvalMode), uint8(NONE));
    }

    function test_getSettlementKeyUsesDelegationManagerAndDelegationHash() public {
        bytes32 delegationHash_ = keccak256("delegation");
        assertEq(
            enforcer.getSettlementKey(address(delegationManager), delegationHash_),
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

    function test_acceptsMinimumLengthSwapCalldata() public {
        Execution[] memory executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");
        executions_[1].callData = _minimumSwapCalldata(bytes32(uint256(uint160(address(tokenIn)))));

        assertEq(executions_[1].callData.length, 196);
        _before(_terms(address(tokenIn), APPROVE, address(tokenOut), alice), executions_, keccak256("minimum-calldata"));
    }

    function test_acceptsEachExactERC20ApprovalMode() public {
        _before(
            _terms(address(tokenIn), SKIP, address(tokenOut), alice),
            _erc20Executions(0, address(tokenIn), TOKEN_IN_AMOUNT, "skip", hex""),
            keccak256("skip")
        );
        _before(
            _terms(address(tokenIn), APPROVE, address(tokenOut), alice),
            _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "approve", hex""),
            keccak256("approve")
        );
        _before(
            _terms(address(tokenIn), RESET, address(tokenOut), alice),
            _erc20Executions(2, address(tokenIn), TOKEN_IN_AMOUNT, "reset", hex""),
            keccak256("reset")
        );
    }

    function testFuzz_enforcesExactERC20ApprovalMode(uint8 rawMode_, uint8 approvalCount_) public {
        rawMode_ = uint8(bound(rawMode_, uint8(SKIP), uint8(RESET)));
        approvalCount_ = uint8(bound(approvalCount_, 0, 2));
        MetaSwapFlexibleSettlementEnforcer.ApprovalMode approvalMode_ = MetaSwapFlexibleSettlementEnforcer.ApprovalMode(rawMode_);

        bool validShape_ = (approvalMode_ == SKIP && approvalCount_ == 0) || (approvalMode_ == APPROVE && approvalCount_ == 1)
            || (approvalMode_ == RESET && approvalCount_ == 2);

        if (!validShape_) {
            vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:approval-shape-not-allowed");
        }

        _before(
            _terms(address(tokenIn), approvalMode_, address(tokenOut), alice),
            _erc20Executions(approvalCount_, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""),
            keccak256(abi.encode(rawMode_, approvalCount_))
        );
    }

    function testFuzz_nativeInputOnlyAcceptsNone(uint8 rawMode_) public {
        rawMode_ = uint8(bound(rawMode_, uint8(NONE), uint8(RESET)));
        MetaSwapFlexibleSettlementEnforcer.ApprovalMode approvalMode_ = MetaSwapFlexibleSettlementEnforcer.ApprovalMode(rawMode_);

        if (approvalMode_ != NONE) {
            vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-approval-mode");
        }

        _before(
            _terms(address(0), approvalMode_, address(tokenOut), alice),
            _nativeExecutions(TOKEN_IN_AMOUNT, address(tokenOut), TOKEN_OUT_AMOUNT),
            keccak256(abi.encode(rawMode_))
        );
    }

    function testFuzz_revertsForUndefinedApprovalMode(uint8 rawMode_) public {
        rawMode_ = uint8(bound(rawMode_, uint8(RESET) + 1, type(uint8).max));

        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-approval-mode");
        enforcer.getTermsInfo(
            _rawTerms(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, rawMode_, address(tokenOut), alice, TOKEN_OUT_MIN)
        );
    }

    function test_acceptsNativeInputShape() public {
        _before(
            _terms(address(0), NONE, address(tokenOut), alice),
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
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-terms");
        enforcer.getTermsInfo(new bytes(228));

        // Long enough for the fixed header + redeemer bytes, but not a multiple of 20.
        bytes memory misaligned_ = _terms(address(tokenIn), APPROVE, address(tokenOut), alice);
        bytes memory padded_ = bytes.concat(misaligned_, bytes1(0x00));
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-terms");
        enforcer.getTermsInfo(padded_);

        bytes memory truncated_ = new bytes(misaligned_.length - 1);
        for (uint256 i_; i_ < truncated_.length; ++i_) {
            truncated_[i_] = misaligned_[i_];
        }
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-terms");
        enforcer.getTermsInfo(truncated_);
    }

    function test_revertsForInvalidRequiredTerms() public {
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-terms");
        enforcer.getTermsInfo(
            _rawTerms(address(0), address(tokenIn), TOKEN_IN_AMOUNT, uint8(APPROVE), address(tokenOut), alice, TOKEN_OUT_MIN)
        );

        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-terms");
        enforcer.getTermsInfo(
            _rawTerms(address(metaSwap), address(tokenIn), 0, uint8(APPROVE), address(tokenOut), alice, TOKEN_OUT_MIN)
        );

        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-terms");
        enforcer.getTermsInfo(
            _rawTerms(
                address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, uint8(APPROVE), address(tokenOut), address(0), TOKEN_OUT_MIN
            )
        );

        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-terms");
        enforcer.getTermsInfo(
            _rawTerms(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, uint8(APPROVE), address(tokenOut), alice, 0)
        );

        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-terms");
        enforcer.getTermsInfo(
            _rawTerms(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, uint8(APPROVE), address(tokenIn), alice, TOKEN_OUT_MIN)
        );
    }

    function test_revertsForInvalidApprovalMode() public {
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-approval-mode");
        _before(
            _terms(address(0), APPROVE, address(tokenOut), alice),
            _nativeExecutions(TOKEN_IN_AMOUNT, address(tokenOut), TOKEN_OUT_AMOUNT),
            keccak256("native-approval-mode")
        );

        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-approval-mode");
        _before(
            _terms(address(tokenIn), NONE, address(tokenOut), alice),
            _erc20Executions(0, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""),
            keccak256("erc20-none-mode")
        );

        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-approval-mode");
        enforcer.getTermsInfo(
            _rawTerms(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, 4, address(tokenOut), alice, TOKEN_OUT_MIN)
        );
    }

    function test_revertsWhenApprovalShapeIsNotSigned() public {
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:approval-shape-not-allowed");
        _before(
            _terms(address(tokenIn), APPROVE, address(tokenOut), alice),
            _erc20Executions(0, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""),
            bytes32(0)
        );

        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:approval-shape-not-allowed");
        _before(
            _terms(address(tokenIn), SKIP, address(tokenOut), alice),
            _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""),
            bytes32(0)
        );

        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:approval-shape-not-allowed");
        _before(
            _terms(address(tokenIn), APPROVE, address(tokenOut), alice),
            _erc20Executions(2, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""),
            bytes32(0)
        );
    }

    function test_revertsForUnsupportedBatchLengths() public {
        Execution[] memory empty_ = new Execution[](0);
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:approval-shape-not-allowed");
        _before(_terms(address(tokenIn), SKIP, address(tokenOut), alice), empty_, bytes32(0));

        Execution[] memory tooLong_ = new Execution[](4);
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:approval-shape-not-allowed");
        _before(_terms(address(tokenIn), RESET, address(tokenOut), alice), tooLong_, bytes32(0));

        Execution[] memory nativeTooLong_ = new Execution[](2);
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-batch-length");
        _before(_terms(address(0), NONE, address(tokenOut), alice), nativeTooLong_, bytes32(0));
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
        executions_[0].callData = abi.encodePacked(
            IERC20.approve.selector, bytes32(uint256(uint160(address(metaSwap))) | (uint256(1) << 255)), bytes32(TOKEN_IN_AMOUNT)
        );
        _expectInvalidApproval(executions_);

        executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");
        executions_[0].callData = abi.encodeCall(IERC20.approve, (address(metaSwap), TOKEN_IN_AMOUNT - 1));
        _expectInvalidApproval(executions_);
    }

    function test_revertsForInvalidResetApproval() public {
        Execution[] memory executions_ = _erc20Executions(2, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");
        executions_[0].callData = abi.encodeCall(IERC20.approve, (address(metaSwap), 1));

        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-approval");
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

        executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");
        executions_[1].callData = _minimumSwapCalldata(bytes32(uint256(uint160(address(tokenIn))) | (uint256(1) << 255)));
        _expectInvalidSwap(executions_);

        _expectInvalidSwap(_erc20Executions(1, makeAddr("OtherToken"), TOKEN_IN_AMOUNT, "route", hex""));
        _expectInvalidSwap(_erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT - 1, "route", hex""));
    }

    function test_revertsForStructurallyIncompleteSwapCalldata() public {
        Execution[] memory executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");
        executions_[1].callData = abi.encodePacked(
            IMetaSwap.swap.selector,
            uint256(128),
            bytes32(uint256(uint160(address(tokenIn)))),
            TOKEN_IN_AMOUNT,
            uint256(160),
            uint256(0),
            bytes31(0)
        );

        assertEq(executions_[1].callData.length, 195);
        _expectInvalidSwap(executions_);
    }

    function test_revertsForNativeSwapWithWrongValue() public {
        Execution[] memory executions_ = _nativeExecutions(TOKEN_IN_AMOUNT - 1, address(tokenOut), TOKEN_OUT_AMOUNT);
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-swap");
        _before(_terms(address(0), NONE, address(tokenOut), alice), executions_, bytes32(0));
    }

    function test_beforeHookMarksSettlementUsedAndRejectsReuse() public {
        tokenOut.mint(alice, 10);
        bytes32 delegationHash_ = keccak256("settlement");
        bytes32 settlementKey_ = enforcer.getSettlementKey(address(delegationManager), delegationHash_);
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

        assertTrue(enforcer.consumedSettlements(settlementKey_));

        vm.prank(address(delegationManager));
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:settlement-already-used");
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

    function test_identicalDelegationHashIsIsolatedAcrossDelegationManagers() public {
        DelegationManager secondDelegationManager_ = new DelegationManager(address(this));
        bytes32 delegationHash_ = keccak256("shared-delegation-hash");
        bytes memory terms_ = _terms(address(tokenIn), APPROVE, address(tokenOut), alice);
        Execution[] memory executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex"");

        _beforeAs(address(delegationManager), terms_, executions_, delegationHash_);
        _beforeAs(address(secondDelegationManager_), terms_, executions_, delegationHash_);

        bytes32 firstKey_ = enforcer.getSettlementKey(address(delegationManager), delegationHash_);
        bytes32 secondKey_ = enforcer.getSettlementKey(address(secondDelegationManager_), delegationHash_);
        assertNotEq(firstKey_, secondKey_);
        assertTrue(enforcer.consumedSettlements(firstKey_));
        assertTrue(enforcer.consumedSettlements(secondKey_));
    }

    function test_afterHookRevertsForInvalidTermsLength() public {
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-terms");
        enforcer.afterHook(new bytes(228), hex"", batchDefaultMode, hex"", bytes32(0), alice, relayer);

        bytes memory misaligned_ = bytes.concat(_terms(address(tokenIn), APPROVE, address(tokenOut), alice), bytes1(0x00));
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-terms");
        enforcer.afterHook(misaligned_, hex"", batchDefaultMode, hex"", bytes32(0), alice, relayer);
    }

    function test_afterHookConsumesSettlementAndEmitsEvent() public {
        bytes32 delegationHash_ = keccak256("successful-settlement");
        bytes memory terms_ = _terms(address(tokenIn), APPROVE, address(tokenOut), alice);
        _before(terms_, _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""), delegationHash_);
        tokenOut.mint(alice, TOKEN_OUT_MIN);

        vm.prank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(enforcer));
        emit SettlementConsumed(address(delegationManager), delegationHash_, relayer, NO_ID);
        enforcer.afterHook(terms_, hex"", batchDefaultMode, hex"", delegationHash_, alice, relayer);

        assertTrue(enforcer.consumedSettlements(enforcer.getSettlementKey(address(delegationManager), delegationHash_)));
    }

    function test_revertsForUnauthorizedRedeemer() public {
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:unauthorized-redeemer");
        _beforeAs(
            address(delegationManager),
            _terms(address(tokenIn), APPROVE, address(tokenOut), alice),
            _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""),
            keccak256("unauthorized"),
            makeAddr("Intruder")
        );
    }

    function test_optionalTimestampAllowsUnboundedWindow() public {
        _before(
            _policyTerms(address(tokenIn), APPROVE, address(tokenOut), alice, NO_TIMESTAMP, NO_TIMESTAMP, NO_ID),
            _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""),
            keccak256("no-timestamp")
        );
    }

    function test_acceptsTimestampAfterWhenWindowIsOpen() public {
        vm.warp(100);
        expiresAt = uint128(block.timestamp + 1 days);
        _before(
            _policyTerms(address(tokenIn), APPROVE, address(tokenOut), alice, 50, expiresAt, NO_ID),
            _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""),
            keccak256("timestamp-after-ok")
        );
    }

    function test_allowsRedeemerAnywhereInAllowlist() public {
        address[] memory redeemers_ = new address[](3);
        redeemers_[0] = address(0);
        redeemers_[1] = makeAddr("OtherSigner");
        redeemers_[2] = relayer;

        bytes memory terms_ = _rawTerms(
            address(metaSwap),
            address(tokenIn),
            TOKEN_IN_AMOUNT,
            uint8(APPROVE),
            address(tokenOut),
            alice,
            TOKEN_OUT_MIN,
            NO_TIMESTAMP,
            NO_TIMESTAMP,
            NO_ID,
            redeemers_
        );
        _before(terms_, _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""), keccak256("multi-redeemer"));
    }

    function test_getIsUsedReturnsFalseForUnusedId() public {
        assertFalse(enforcer.getIsUsed(address(delegationManager), alice, ORDER_ID));
    }

    function test_revertsForExpiredDelegation() public {
        vm.warp(expiresAt);
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:expired-delegation");
        _before(
            _policyTerms(address(tokenIn), APPROVE, address(tokenOut), alice, NO_TIMESTAMP, expiresAt, NO_ID),
            _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""),
            keccak256("expired")
        );
    }

    function test_revertsForEarlyDelegation() public {
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:early-delegation");
        _before(
            _policyTerms(address(tokenIn), APPROVE, address(tokenOut), alice, uint128(block.timestamp + 1), expiresAt, NO_ID),
            _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""),
            keccak256("early")
        );
    }

    function test_optionalIdUsesHashBasedConsumption() public {
        Delegation memory delegation_ = _sign(_terms(address(tokenIn), APPROVE, address(tokenOut), alice));
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        Execution[] memory executions_ = _erc20Executions(
            1, address(tokenIn), TOKEN_IN_AMOUNT, "best-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT)
        );
        _redeem(delegation_, executions_);

        assertTrue(enforcer.consumedSettlements(enforcer.getSettlementKey(address(delegationManager), delegationHash_)));
        assertFalse(enforcer.getIsUsed(address(delegationManager), alice, NO_ID));

        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:settlement-already-used");
        _redeem(delegation_, executions_);
    }

    function test_nonZeroIdUsesBitmapAndSkipsHashConsumption() public {
        bytes memory terms_ = _policyTerms(address(tokenIn), APPROVE, address(tokenOut), alice, NO_TIMESTAMP, expiresAt, ORDER_ID);
        Delegation memory delegation_ = _sign(terms_);
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        Execution[] memory executions_ = _erc20Executions(
            1, address(tokenIn), TOKEN_IN_AMOUNT, "best-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT)
        );

        vm.expectEmit(true, true, true, true, address(enforcer));
        emit UsedId(address(delegationManager), alice, relayer, ORDER_ID);
        vm.expectEmit(true, true, true, true, address(enforcer));
        emit SettlementConsumed(address(delegationManager), delegationHash_, relayer, ORDER_ID);
        _redeem(delegation_, executions_);

        assertTrue(enforcer.getIsUsed(address(delegationManager), alice, ORDER_ID));
        assertFalse(enforcer.consumedSettlements(enforcer.getSettlementKey(address(delegationManager), delegationHash_)));
    }

    function test_replacementOrdersShareIdAreMutuallyExclusive() public {
        bytes memory terms_ = _policyTerms(address(tokenIn), APPROVE, address(tokenOut), alice, NO_TIMESTAMP, expiresAt, ORDER_ID);
        Execution[] memory executions_ = _erc20Executions(
            1, address(tokenIn), TOKEN_IN_AMOUNT, "best-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT)
        );
        Delegation memory first_ = _signWithSalt(terms_, 0);
        Delegation memory second_ = _signWithSalt(terms_, 1);

        _redeem(second_, executions_);
        assertTrue(enforcer.getIsUsed(address(delegationManager), alice, ORDER_ID));

        tokenIn.mint(alice, TOKEN_IN_AMOUNT);
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:id-already-used");
        _redeem(first_, executions_);
    }

    function test_idConsumptionRollsBackOnInsufficientOutput() public {
        bytes memory terms_ = _policyTerms(address(tokenIn), APPROVE, address(tokenOut), alice, NO_TIMESTAMP, expiresAt, ORDER_ID);
        Delegation memory delegation_ = _sign(terms_);
        Execution[] memory insufficient_ = _erc20Executions(
            1, address(tokenIn), TOKEN_IN_AMOUNT, "bad-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_MIN - 1)
        );

        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:insufficient-output");
        _redeem(delegation_, insufficient_);
        assertFalse(enforcer.getIsUsed(address(delegationManager), alice, ORDER_ID));

        _redeem(
            delegation_,
            _erc20Executions(
                1, address(tokenIn), TOKEN_IN_AMOUNT, "new-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_MIN)
            )
        );
        assertTrue(enforcer.getIsUsed(address(delegationManager), alice, ORDER_ID));
    }

    function test_afterHookRevertsForInsufficientOutput() public {
        bytes32 delegationHash_ = keccak256("insufficient-settlement");
        bytes memory terms_ = _terms(address(tokenIn), APPROVE, address(tokenOut), alice);
        _before(terms_, _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, "route", hex""), delegationHash_);
        tokenOut.mint(alice, TOKEN_OUT_MIN - 1);

        vm.prank(address(delegationManager));
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:insufficient-output");
        enforcer.afterHook(terms_, hex"", batchDefaultMode, hex"", delegationHash_, alice, relayer);
    }

    function test_redeemsERC20ApprovalSettlement() public {
        _redeem(
            _sign(_terms(address(tokenIn), APPROVE, address(tokenOut), alice)),
            _erc20Executions(
                1, address(tokenIn), TOKEN_IN_AMOUNT, "best-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT)
            )
        );

        assertEq(tokenIn.balanceOf(alice), 900 ether);
        assertEq(tokenOut.balanceOf(alice), TOKEN_OUT_AMOUNT);
    }

    function test_redeemsERC20ResetApprovalSettlement() public {
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

    function test_redeemsERC20SettlementSkippingApproval() public {
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

    function test_redeemsNativeInputSettlement() public {
        uint256 nativeBefore_ = alice.balance;
        _redeem(
            _sign(_terms(address(0), NONE, address(tokenOut), alice)),
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

        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:insufficient-output");
        _redeem(delegation_, insufficient_);

        assertEq(tokenIn.balanceOf(alice), 1_000 ether);
        assertEq(tokenOut.balanceOf(alice), 0);
        assertFalse(enforcer.consumedSettlements(enforcer.getSettlementKey(address(delegationManager), delegationHash_)));

        _redeem(
            delegation_,
            _erc20Executions(
                1, address(tokenIn), TOKEN_IN_AMOUNT, "new-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_MIN)
            )
        );
        assertEq(tokenOut.balanceOf(alice), TOKEN_OUT_MIN);
    }

    function test_successfulSettlementCannotBeRedeemedAgain() public {
        Delegation memory delegation_ = _sign(_terms(address(tokenIn), APPROVE, address(tokenOut), alice));
        Execution[] memory executions_ = _erc20Executions(
            1, address(tokenIn), TOKEN_IN_AMOUNT, "best-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT)
        );
        _redeem(delegation_, executions_);

        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:settlement-already-used");
        _redeem(delegation_, executions_);
    }

    function _expectInvalidApproval(Execution[] memory executions_) private {
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-approval");
        _before(_terms(address(tokenIn), APPROVE, address(tokenOut), alice), executions_, bytes32(0));
    }

    function _expectInvalidSwap(Execution[] memory executions_) private {
        vm.expectRevert("MetaSwapFlexibleSettlementEnforcer:invalid-swap");
        _before(_terms(address(tokenIn), APPROVE, address(tokenOut), alice), executions_, bytes32(0));
    }

    function _terms(
        address tokenIn_,
        MetaSwapFlexibleSettlementEnforcer.ApprovalMode approvalMode_,
        address tokenOut_,
        address recipient_
    )
        private
        view
        returns (bytes memory)
    {
        return _policyTerms(tokenIn_, approvalMode_, tokenOut_, recipient_, NO_TIMESTAMP, NO_TIMESTAMP, NO_ID);
    }

    function _policyTerms(
        address tokenIn_,
        MetaSwapFlexibleSettlementEnforcer.ApprovalMode approvalMode_,
        address tokenOut_,
        address recipient_,
        uint128 timestampAfter_,
        uint128 timestampBefore_,
        uint256 id_
    )
        private
        view
        returns (bytes memory)
    {
        address[] memory redeemers_ = new address[](1);
        redeemers_[0] = relayer;
        return _rawTerms(
            address(metaSwap),
            tokenIn_,
            TOKEN_IN_AMOUNT,
            uint8(approvalMode_),
            tokenOut_,
            recipient_,
            TOKEN_OUT_MIN,
            timestampAfter_,
            timestampBefore_,
            id_,
            redeemers_
        );
    }

    function _rawTerms(
        address metaSwap_,
        address tokenIn_,
        uint256 tokenInAmount_,
        uint8 approvalMode_,
        address tokenOut_,
        address recipient_,
        uint256 tokenOutMin_
    )
        private
        view
        returns (bytes memory)
    {
        address[] memory redeemers_ = new address[](1);
        redeemers_[0] = relayer;
        return _rawTerms(
            metaSwap_,
            tokenIn_,
            tokenInAmount_,
            approvalMode_,
            tokenOut_,
            recipient_,
            tokenOutMin_,
            NO_TIMESTAMP,
            NO_TIMESTAMP,
            NO_ID,
            redeemers_
        );
    }

    function _rawTerms(
        address metaSwap_,
        address tokenIn_,
        uint256 tokenInAmount_,
        uint8 approvalMode_,
        address tokenOut_,
        address recipient_,
        uint256 tokenOutMin_,
        uint128 timestampAfter_,
        uint128 timestampBefore_,
        uint256 id_,
        address[] memory redeemers_
    )
        private
        pure
        returns (bytes memory)
    {
        bytes memory packed_ = abi.encodePacked(
            metaSwap_,
            tokenIn_,
            tokenInAmount_,
            approvalMode_,
            tokenOut_,
            recipient_,
            tokenOutMin_,
            timestampAfter_,
            timestampBefore_,
            id_
        );
        for (uint256 i_; i_ < redeemers_.length; ++i_) {
            packed_ = abi.encodePacked(packed_, redeemers_[i_]);
        }
        return packed_;
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

    function _minimumSwapCalldata(bytes32 tokenInWord_) private pure returns (bytes memory) {
        return abi.encodePacked(
            IMetaSwap.swap.selector, uint256(128), tokenInWord_, TOKEN_IN_AMOUNT, uint256(160), uint256(0), uint256(0)
        );
    }

    function _before(bytes memory terms_, Execution[] memory executions_, bytes32 delegationHash_) private {
        _beforeAs(address(delegationManager), terms_, executions_, delegationHash_, relayer);
    }

    function _beforeAs(
        address delegationManager_,
        bytes memory terms_,
        Execution[] memory executions_,
        bytes32 delegationHash_
    )
        private
    {
        _beforeAs(delegationManager_, terms_, executions_, delegationHash_, relayer);
    }

    function _beforeAs(
        address delegationManager_,
        bytes memory terms_,
        Execution[] memory executions_,
        bytes32 delegationHash_,
        address redeemer_
    )
        private
    {
        vm.prank(delegationManager_);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), delegationHash_, alice, redeemer_
        );
    }

    function _sign(bytes memory terms_) private view returns (Delegation memory) {
        return _signWithSalt(terms_, 0);
    }

    function _signWithSalt(bytes memory terms_, uint256 salt_) private view returns (Delegation memory delegation_) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(enforcer), terms: terms_, args: hex"" });
        delegation_ = Delegation({
            delegate: ANY_DELEGATE, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats_, salt: salt_, signature: hex""
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
