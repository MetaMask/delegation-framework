// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { MetaSwapDelegationManagerBase } from "../src/MetaSwapDelegationManagerBase.sol";
import { MetaSwapOrderDelegationManager } from "../src/MetaSwapOrderDelegationManager.sol";
import { MetaSwapFlexibleSettlementManagerBase } from "../src/experiments/MetaSwapFlexibleSettlementManagerBase.sol";
import { MetaSwapHooklessDelegationManager } from "../src/experiments/MetaSwapHooklessDelegationManager.sol";
import { DelegationManager } from "../src/DelegationManager.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { ExactExecutionBatchEnforcer } from "../src/enforcers/ExactExecutionBatchEnforcer.sol";
import { LimitedCallsEnforcer } from "../src/enforcers/LimitedCallsEnforcer.sol";
import { MetaSwapFlexibleSettlementEnforcer } from "../src/enforcers/MetaSwapFlexibleSettlementEnforcer.sol";
import { IMetaSwap } from "../src/helpers/interfaces/IMetaSwap.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { BasicERC20 } from "./utils/BasicERC20.t.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../src/utils/Types.sol";
import { ERC1271Lib } from "../src/libraries/ERC1271Lib.sol";

contract OrderManager1271Account {
    using ExecutionLib for bytes;

    function isValidSignature(bytes32 hash_, bytes memory signature_) external pure returns (bytes4) {
        if (signature_.length == 32 && bytes32(signature_) == hash_) return ERC1271Lib.EIP1271_MAGIC_VALUE;
        return ERC1271Lib.SIG_VALIDATION_FAILED;
    }

    function executeFromExecutor(ModeCode, bytes calldata executionCallData_)
        external
        payable
        returns (bytes[] memory returnData_)
    {
        Execution[] calldata executions_ = executionCallData_.decodeBatch();
        returnData_ = new bytes[](executions_.length);
        for (uint256 i; i < executions_.length; ++i) {
            (bool ok_, bytes memory ret_) = executions_[i].target.call{ value: executions_[i].value }(executions_[i].callData);
            require(ok_, "exec-failed");
            returnData_[i] = ret_;
        }
    }
}

contract OrderManagerMetaSwapMock is IMetaSwap {
    using SafeERC20 for IERC20;

    mapping(string aggregatorId => Adapter adapter) private adapters_;

    function setAdapter(string calldata aggregatorId_, address addr_, bytes4 selector_, bytes calldata data_) external {
        adapters_[aggregatorId_] = Adapter({ addr: addr_, selector: selector_, data: data_ });
    }

    function removeAdapter(string calldata aggregatorId_) external {
        delete adapters_[aggregatorId_];
    }

    function adapters(string memory aggregatorId_) external view returns (Adapter memory) {
        return adapters_[aggregatorId_];
    }

    function swap(string calldata, IERC20 tokenFrom_, uint256 amount_, bytes calldata data_) external payable {
        if (address(tokenFrom_) == address(0)) {
            require(msg.value == amount_, "invalid-native-input");
        } else {
            tokenFrom_.safeTransferFrom(msg.sender, address(this), amount_);
        }

        (IERC20 tokenOut_, uint256 amountOut_) = abi.decode(data_, (IERC20, uint256));
        if (address(tokenOut_) == address(0)) {
            (bool success_,) = msg.sender.call{ value: amountOut_ }("");
            require(success_, "native-output-failed");
        } else {
            tokenOut_.safeTransfer(msg.sender, amountOut_);
        }
    }

    receive() external payable { }
}

contract MetaSwapOrderDelegationManagerTest is Test {
    uint256 private constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 private constant TOKEN_OUT_MIN = 190 ether;
    uint256 private constant TOKEN_OUT_AMOUNT = 200 ether;

    uint256 private constant GENERIC_KEY = 0x1111;
    uint256 private constant HOOKLESS_KEY = 0x2222;
    uint256 private constant ORDER_KEY = 0x3333;

    EntryPoint private entryPoint;
    OrderManagerMetaSwapMock private metaSwap;
    BasicERC20 private tokenIn;
    BasicERC20 private tokenOut;

    DelegationManager private genericManager;
    ExactExecutionBatchEnforcer private exactBatchEnforcer;
    LimitedCallsEnforcer private limitedCallsEnforcer;
    MetaSwapFlexibleSettlementEnforcer private flexibleEnforcer;
    MetaSwapHooklessDelegationManager private hooklessManager;
    MetaSwapOrderDelegationManager private orderManager;

    address private genericAccount;
    address private hooklessAccount;
    address private orderAccount;
    address private relayer;

    function setUp() public {
        entryPoint = new EntryPoint();
        metaSwap = new OrderManagerMetaSwapMock();
        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        relayer = makeAddr("Relayer");

        genericManager = new DelegationManager(address(this));
        exactBatchEnforcer = new ExactExecutionBatchEnforcer();
        limitedCallsEnforcer = new LimitedCallsEnforcer();
        flexibleEnforcer = new MetaSwapFlexibleSettlementEnforcer();
        hooklessManager = new MetaSwapHooklessDelegationManager();
        orderManager = new MetaSwapOrderDelegationManager();

        genericAccount = vm.addr(GENERIC_KEY);
        hooklessAccount = vm.addr(HOOKLESS_KEY);
        orderAccount = vm.addr(ORDER_KEY);

        _installDeleGator(genericAccount, address(genericManager));
        _installDeleGator(hooklessAccount, address(hooklessManager));
        _installDeleGator(orderAccount, address(orderManager));

        tokenIn.mint(genericAccount, 1_000 ether);
        tokenIn.mint(hooklessAccount, 1_000 ether);
        tokenIn.mint(orderAccount, 1_000 ether);
        tokenOut.mint(address(metaSwap), 10_000 ether);
        vm.deal(genericAccount, 1_000 ether);
        vm.deal(hooklessAccount, 1_000 ether);
        vm.deal(orderAccount, 1_000 ether);
        vm.deal(address(metaSwap), 10_000 ether);
    }

    // -------- Exact intent --------

    function test_exactRedeemsApproveAndSwap() public {
        Execution[] memory executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        bytes memory encoded_ = ExecutionLib.encodeBatch(executions_);
        Delegation memory delegation_ = _signIntent(_exactTerms(keccak256(encoded_)), 1);

        vm.expectEmit(true, true, true, true, address(orderManager));
        emit MetaSwapDelegationManagerBase.RedeemedDelegation(
            orderAccount,
            relayer,
            orderManager.getDelegationHash(delegation_),
            uint8(MetaSwapOrderDelegationManager.Intent.ExactCalldata)
        );
        _redeemIntent(delegation_, encoded_);

        assertEq(tokenIn.balanceOf(orderAccount), 900 ether);
        assertEq(tokenOut.balanceOf(orderAccount), TOKEN_OUT_AMOUNT);
        assertTrue(orderManager.disabledDelegations(orderManager.getDelegationHash(delegation_)));
    }

    function test_exactRedeemsSkipApprovalSwap() public {
        vm.prank(orderAccount);
        tokenIn.approve(address(metaSwap), TOKEN_IN_AMOUNT);

        Execution[] memory executions_ = _erc20Executions(0, TOKEN_OUT_AMOUNT);
        bytes memory encoded_ = ExecutionLib.encodeBatch(executions_);
        Delegation memory delegation_ = _signIntent(_exactTerms(keccak256(encoded_)), 2);

        _redeemIntent(delegation_, encoded_);
        assertEq(tokenOut.balanceOf(orderAccount), TOKEN_OUT_AMOUNT);
    }

    function test_exactRedeemsResetApproveAndSwap() public {
        vm.prank(orderAccount);
        tokenIn.approve(address(metaSwap), 1);

        Execution[] memory executions_ = _erc20Executions(2, TOKEN_OUT_AMOUNT);
        bytes memory encoded_ = ExecutionLib.encodeBatch(executions_);
        Delegation memory delegation_ = _signIntent(_exactTerms(keccak256(encoded_)), 3);

        _redeemIntent(delegation_, encoded_);
        assertEq(tokenOut.balanceOf(orderAccount), TOKEN_OUT_AMOUNT);
    }

    function test_exactRedeemsNativeSwap() public {
        Execution[] memory executions_ = _nativeExecutions(TOKEN_OUT_AMOUNT);
        bytes memory encoded_ = ExecutionLib.encodeBatch(executions_);
        Delegation memory delegation_ = _signIntent(_exactTerms(keccak256(encoded_)), 4);
        uint256 nativeBefore_ = orderAccount.balance;

        _redeemIntent(delegation_, encoded_);

        assertEq(orderAccount.balance, nativeBefore_ - TOKEN_IN_AMOUNT);
        assertEq(tokenOut.balanceOf(orderAccount), TOKEN_OUT_AMOUNT);
    }

    function test_exactRevertsForHashMismatch() public {
        Execution[] memory executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        bytes memory encoded_ = ExecutionLib.encodeBatch(executions_);
        Delegation memory delegation_ = _signIntent(_exactTerms(keccak256(encoded_)), 5);

        executions_[1].value = 1;
        vm.expectRevert(MetaSwapOrderDelegationManager.InvalidExecutionHash.selector);
        _redeemIntent(delegation_, ExecutionLib.encodeBatch(executions_));
    }

    function test_exactRevertsOnReplay() public {
        Execution[] memory executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        bytes memory encoded_ = ExecutionLib.encodeBatch(executions_);
        Delegation memory delegation_ = _signIntent(_exactTerms(keccak256(encoded_)), 6);

        _redeemIntent(delegation_, encoded_);

        vm.expectRevert(MetaSwapDelegationManagerBase.CannotUseADisabledDelegation.selector);
        _redeemIntent(delegation_, encoded_);
    }

    function test_exactDisableDelegationCancels() public {
        Execution[] memory executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        bytes memory encoded_ = ExecutionLib.encodeBatch(executions_);
        Delegation memory delegation_ = _signIntent(_exactTerms(keccak256(encoded_)), 7);

        vm.prank(orderAccount);
        orderManager.disableDelegation(delegation_);

        vm.expectRevert(MetaSwapDelegationManagerBase.CannotUseADisabledDelegation.selector);
        _redeemIntent(delegation_, encoded_);
    }

    function test_exactRejectsWrongSigner() public {
        Execution[] memory executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        bytes memory encoded_ = ExecutionLib.encodeBatch(executions_);
        Delegation memory delegation_ = _signIntentWithKey(HOOKLESS_KEY, _exactTerms(keccak256(encoded_)), 8);

        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidERC1271Signature.selector);
        _redeemIntent(delegation_, encoded_);
    }

    function test_exactRejectsWrongSignerOnCodelessEOA() public {
        address eoa_ = vm.addr(0xE0A);
        bytes memory encoded_ = ExecutionLib.encodeBatch(_erc20Executions(1, TOKEN_OUT_AMOUNT));
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(orderManager), terms: _exactTerms(keccak256(encoded_)), args: hex"" });
        Delegation memory delegation_ = _signManager(orderManager, HOOKLESS_KEY, eoa_, caveats_, 40);

        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidEOASignature.selector);
        _redeemIntent(delegation_, encoded_);
    }

    function test_exactRedeemsWithERC1271Fallback() public {
        OrderManager1271Account account_ = new OrderManager1271Account();
        tokenIn.mint(address(account_), 1_000 ether);

        bytes memory encoded_ = ExecutionLib.encodeBatch(_erc20Executions(1, TOKEN_OUT_AMOUNT));
        bytes memory terms_ = _exactTerms(keccak256(encoded_));
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(orderManager), terms: terms_, args: hex"" });
        Delegation memory delegation_ = Delegation({
            delegate: address(0xa11),
            delegator: address(account_),
            authority: orderManager.ROOT_AUTHORITY(),
            caveats: caveats_,
            salt: 41,
            signature: hex""
        });
        bytes32 typedDataHash_ =
            MessageHashUtils.toTypedDataHash(orderManager.getDomainHash(), orderManager.getDelegationHash(delegation_));
        delegation_.signature = abi.encodePacked(typedDataHash_);

        _redeemIntent(delegation_, encoded_);

        assertEq(tokenOut.balanceOf(address(account_)), TOKEN_OUT_AMOUNT);
    }

    function test_exactRejectsInvalidERC1271Signature() public {
        OrderManager1271Account account_ = new OrderManager1271Account();
        bytes memory encoded_ = ExecutionLib.encodeBatch(_erc20Executions(1, TOKEN_OUT_AMOUNT));
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(orderManager), terms: _exactTerms(keccak256(encoded_)), args: hex"" });
        Delegation memory delegation_ = Delegation({
            delegate: address(0xa11),
            delegator: address(account_),
            authority: orderManager.ROOT_AUTHORITY(),
            caveats: caveats_,
            salt: 42,
            signature: abi.encodePacked(bytes32(uint256(1)))
        });

        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidERC1271Signature.selector);
        _redeemIntent(delegation_, encoded_);
    }

    // -------- Flexible intent --------

    function test_flexibleRedeemsApproveAndSwap() public {
        bytes memory terms_ = _flexibleTerms(address(tokenIn), _approveMode(), address(tokenOut), orderAccount);
        Delegation memory delegation_ = _signIntent(terms_, 10);
        bytes memory encoded_ = ExecutionLib.encodeBatch(_erc20Executions(1, TOKEN_OUT_AMOUNT));

        vm.expectEmit(true, true, true, true, address(orderManager));
        emit MetaSwapDelegationManagerBase.RedeemedDelegation(
            orderAccount,
            relayer,
            orderManager.getDelegationHash(delegation_),
            uint8(MetaSwapOrderDelegationManager.Intent.FlexibleSettlement)
        );
        _redeemIntent(delegation_, encoded_);

        assertEq(tokenIn.balanceOf(orderAccount), 900 ether);
        assertEq(tokenOut.balanceOf(orderAccount), TOKEN_OUT_AMOUNT);
    }

    function test_flexibleRedeemsSkipApproval() public {
        vm.prank(orderAccount);
        tokenIn.approve(address(metaSwap), TOKEN_IN_AMOUNT);

        bytes memory terms_ = _flexibleTerms(address(tokenIn), _skipApprovalMode(), address(tokenOut), orderAccount);
        Delegation memory delegation_ = _signIntent(terms_, 11);

        _redeemIntent(delegation_, ExecutionLib.encodeBatch(_erc20Executions(0, TOKEN_OUT_AMOUNT)));
        assertEq(tokenOut.balanceOf(orderAccount), TOKEN_OUT_AMOUNT);
    }

    function test_flexibleRedeemsResetApprove() public {
        vm.prank(orderAccount);
        tokenIn.approve(address(metaSwap), 1);

        bytes memory terms_ = _flexibleTerms(address(tokenIn), _resetApproveMode(), address(tokenOut), orderAccount);
        Delegation memory delegation_ = _signIntent(terms_, 12);

        _redeemIntent(delegation_, ExecutionLib.encodeBatch(_erc20Executions(2, TOKEN_OUT_AMOUNT)));
        assertEq(tokenOut.balanceOf(orderAccount), TOKEN_OUT_AMOUNT);
    }

    function test_flexibleRedeemsNativeInput() public {
        bytes memory terms_ = _flexibleTerms(address(0), _noneMode(), address(tokenOut), orderAccount);
        Delegation memory delegation_ = _signIntent(terms_, 13);
        uint256 nativeBefore_ = orderAccount.balance;

        _redeemIntent(delegation_, ExecutionLib.encodeBatch(_nativeExecutions(TOKEN_OUT_AMOUNT)));

        assertEq(orderAccount.balance, nativeBefore_ - TOKEN_IN_AMOUNT);
        assertEq(tokenOut.balanceOf(orderAccount), TOKEN_OUT_AMOUNT);
    }

    function test_flexibleRedeemsNativeOutput() public {
        bytes memory terms_ = _flexibleTerms(address(tokenIn), _approveMode(), address(0), orderAccount);
        Delegation memory delegation_ = _signIntent(terms_, 19);
        Execution[] memory executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[1].callData = abi.encodeCall(
            IMetaSwap.swap,
            ("redeemer-route", IERC20(address(tokenIn)), TOKEN_IN_AMOUNT, abi.encode(IERC20(address(0)), TOKEN_OUT_AMOUNT))
        );
        uint256 nativeBefore_ = orderAccount.balance;

        _redeemIntent(delegation_, ExecutionLib.encodeBatch(executions_));

        assertEq(tokenIn.balanceOf(orderAccount), 900 ether);
        assertEq(orderAccount.balance, nativeBefore_ + TOKEN_OUT_AMOUNT);
    }

    function test_flexibleAllowsDifferentRouteData() public {
        bytes memory terms_ = _flexibleTerms(address(tokenIn), _approveMode(), address(tokenOut), orderAccount);

        Execution[] memory first_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        first_[1].callData = abi.encodeCall(
            IMetaSwap.swap, ("route-a", IERC20(address(tokenIn)), TOKEN_IN_AMOUNT, abi.encode(tokenOut, TOKEN_OUT_AMOUNT))
        );
        _redeemIntent(_signIntent(terms_, 14), ExecutionLib.encodeBatch(first_));

        Execution[] memory second_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        second_[1].callData = abi.encodeCall(
            IMetaSwap.swap, ("route-b", IERC20(address(tokenIn)), TOKEN_IN_AMOUNT, abi.encode(tokenOut, TOKEN_OUT_AMOUNT))
        );
        _redeemIntent(_signIntent(terms_, 15), ExecutionLib.encodeBatch(second_));

        assertEq(tokenOut.balanceOf(orderAccount), TOKEN_OUT_AMOUNT * 2);
    }

    function test_flexibleRevertsAtomicallyForInsufficientOutput() public {
        bytes memory terms_ = _flexibleTerms(address(tokenIn), _approveMode(), address(tokenOut), orderAccount);
        Delegation memory delegation_ = _signIntent(terms_, 16);
        bytes32 hash_ = orderManager.getDelegationHash(delegation_);

        vm.expectRevert(MetaSwapDelegationManagerBase.InsufficientOutput.selector);
        _redeemIntent(delegation_, ExecutionLib.encodeBatch(_erc20Executions(1, TOKEN_OUT_MIN - 1)));

        assertFalse(orderManager.disabledDelegations(hash_));
        assertEq(tokenIn.balanceOf(orderAccount), 1_000 ether);
    }

    function test_flexibleRejectsInvalidApprovalMode() public {
        bytes memory terms_ = _flexibleTerms(address(0), _approveMode(), address(tokenOut), orderAccount);
        Delegation memory delegation_ = _signIntent(terms_, 17);

        vm.expectRevert(MetaSwapOrderDelegationManager.InvalidApprovalMode.selector);
        _redeemIntent(delegation_, ExecutionLib.encodeBatch(_nativeExecutions(TOKEN_OUT_AMOUNT)));
    }

    function test_rejectsUnknownIntent() public {
        bytes memory terms_ = abi.encodePacked(uint8(2), bytes32(0));
        Delegation memory delegation_ = _signIntent(terms_, 18);

        vm.expectRevert(MetaSwapOrderDelegationManager.InvalidIntent.selector);
        _redeemIntent(delegation_, ExecutionLib.encodeBatch(_erc20Executions(1, TOKEN_OUT_AMOUNT)));
    }

    // -------- Flexible validation (ported from MetaSwapFlexibleSettlementEnforcer) --------

    function test_flexibleRejectsInvalidTermsLength() public {
        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidTerms.selector);
        orderManager.getFlexibleTermsInfo(new bytes(145));

        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidTerms.selector);
        orderManager.getFlexibleTermsInfo(new bytes(147));
    }

    function test_flexibleRejectsInvalidRequiredTerms() public {
        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidTerms.selector);
        orderManager.getFlexibleTermsInfo(
            _rawFlexibleTerms(address(0), address(tokenIn), TOKEN_IN_AMOUNT, uint8(_approveMode()), address(tokenOut), orderAccount)
        );

        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidTerms.selector);
        orderManager.getFlexibleTermsInfo(
            _rawFlexibleTerms(address(metaSwap), address(tokenIn), 0, uint8(_approveMode()), address(tokenOut), orderAccount)
        );

        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidTerms.selector);
        orderManager.getFlexibleTermsInfo(
            _rawFlexibleTerms(
                address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, uint8(_approveMode()), address(tokenOut), address(0)
            )
        );

        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidTerms.selector);
        orderManager.getFlexibleTermsInfo(
            _rawFlexibleTerms(
                address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, uint8(_approveMode()), address(tokenOut), orderAccount, 0
            )
        );

        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidTerms.selector);
        orderManager.getFlexibleTermsInfo(
            _rawFlexibleTerms(
                address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, uint8(_approveMode()), address(tokenIn), orderAccount
            )
        );
    }

    function test_flexibleRejectsUndefinedApprovalMode() public {
        vm.expectRevert(MetaSwapOrderDelegationManager.InvalidApprovalMode.selector);
        orderManager.getFlexibleTermsInfo(
            _rawFlexibleTerms(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, 4, address(tokenOut), orderAccount)
        );
    }

    function test_flexibleRejectsErc20NoneMode() public {
        bytes memory terms_ = _flexibleTerms(address(tokenIn), _noneMode(), address(tokenOut), orderAccount);
        _expectFlexibleRevert(
            terms_, _erc20Executions(0, TOKEN_OUT_AMOUNT), MetaSwapOrderDelegationManager.InvalidApprovalMode.selector, 50
        );
    }

    function test_flexibleRejectsWrongApprovalShape() public {
        _expectFlexibleRevert(
            _flexibleTerms(address(tokenIn), _approveMode(), address(tokenOut), orderAccount),
            _erc20Executions(0, TOKEN_OUT_AMOUNT),
            MetaSwapOrderDelegationManager.ApprovalShapeNotAllowed.selector,
            51
        );
        _expectFlexibleRevert(
            _flexibleTerms(address(tokenIn), _skipApprovalMode(), address(tokenOut), orderAccount),
            _erc20Executions(1, TOKEN_OUT_AMOUNT),
            MetaSwapOrderDelegationManager.ApprovalShapeNotAllowed.selector,
            52
        );
        _expectFlexibleRevert(
            _flexibleTerms(address(tokenIn), _approveMode(), address(tokenOut), orderAccount),
            _erc20Executions(2, TOKEN_OUT_AMOUNT),
            MetaSwapOrderDelegationManager.ApprovalShapeNotAllowed.selector,
            53
        );
    }

    function test_flexibleRejectsUnsupportedBatchLengths() public {
        Execution[] memory empty_ = new Execution[](0);
        _expectFlexibleRevert(
            _flexibleTerms(address(tokenIn), _skipApprovalMode(), address(tokenOut), orderAccount),
            empty_,
            MetaSwapOrderDelegationManager.ApprovalShapeNotAllowed.selector,
            54
        );

        Execution[] memory tooLong_ = new Execution[](4);
        _expectFlexibleRevert(
            _flexibleTerms(address(tokenIn), _resetApproveMode(), address(tokenOut), orderAccount),
            tooLong_,
            MetaSwapOrderDelegationManager.ApprovalShapeNotAllowed.selector,
            55
        );

        Execution[] memory nativeTooLong_ = new Execution[](2);
        _expectFlexibleRevert(
            _flexibleTerms(address(0), _noneMode(), address(tokenOut), orderAccount),
            nativeTooLong_,
            MetaSwapOrderDelegationManager.InvalidBatchLength.selector,
            56
        );
    }

    function test_flexibleRejectsInvalidApproval() public {
        Execution[] memory executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[0].target = makeAddr("OtherToken");
        _expectInvalidApproval(executions_, 57);

        executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[0].value = 1;
        _expectInvalidApproval(executions_, 58);

        executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[0].callData = abi.encodePacked(IERC20.approve.selector);
        _expectInvalidApproval(executions_, 59);

        executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[0].callData = abi.encodeCall(IERC20.transfer, (address(metaSwap), TOKEN_IN_AMOUNT));
        _expectInvalidApproval(executions_, 60);

        executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[0].callData = abi.encodeCall(IERC20.approve, (makeAddr("OtherSpender"), TOKEN_IN_AMOUNT));
        _expectInvalidApproval(executions_, 61);

        executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[0].callData = abi.encodePacked(
            IERC20.approve.selector, bytes32(uint256(uint160(address(metaSwap))) | (uint256(1) << 255)), bytes32(TOKEN_IN_AMOUNT)
        );
        _expectInvalidApproval(executions_, 62);

        executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[0].callData = abi.encodeCall(IERC20.approve, (address(metaSwap), TOKEN_IN_AMOUNT - 1));
        _expectInvalidApproval(executions_, 63);
    }

    function test_flexibleRejectsInvalidResetApproval() public {
        Execution[] memory executions_ = _erc20Executions(2, TOKEN_OUT_AMOUNT);
        executions_[0].callData = abi.encodeCall(IERC20.approve, (address(metaSwap), 1));
        _expectInvalidApproval(executions_, 64);
    }

    function test_flexibleRejectsInvalidSwap() public {
        Execution[] memory executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[1].target = makeAddr("OtherSwap");
        _expectInvalidSwap(executions_, 65);

        executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[1].value = 1;
        _expectInvalidSwap(executions_, 66);

        executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[1].callData = abi.encodePacked(IMetaSwap.swap.selector);
        _expectInvalidSwap(executions_, 67);

        executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[1].callData = abi.encodeCall(IERC20.approve, (address(metaSwap), TOKEN_IN_AMOUNT));
        _expectInvalidSwap(executions_, 68);

        executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[1].callData = _minimumSwapCalldata(bytes32(uint256(uint160(address(tokenIn))) | (uint256(1) << 255)));
        _expectInvalidSwap(executions_, 69);

        executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[1].callData = abi.encodeCall(
            IMetaSwap.swap, ("redeemer-route", IERC20(makeAddr("OtherToken")), TOKEN_IN_AMOUNT, abi.encode(tokenOut, TOKEN_OUT_AMOUNT))
        );
        _expectInvalidSwap(executions_, 70);

        executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[1].callData = abi.encodeCall(
            IMetaSwap.swap, ("redeemer-route", IERC20(address(tokenIn)), TOKEN_IN_AMOUNT - 1, abi.encode(tokenOut, TOKEN_OUT_AMOUNT))
        );
        _expectInvalidSwap(executions_, 71);
    }

    function test_flexibleRejectsIncompleteSwapCalldata() public {
        Execution[] memory executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
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
        _expectInvalidSwap(executions_, 72);
    }

    function test_flexibleAcceptsMinimumLengthSwapCalldata() public {
        Execution[] memory executions_ = _erc20Executions(1, TOKEN_OUT_AMOUNT);
        executions_[1].callData = _minimumSwapCalldata(bytes32(uint256(uint160(address(tokenIn)))));
        assertEq(executions_[1].callData.length, 196);

        bytes memory revertData_ = _redeemCatch(
            _signIntent(_flexibleTerms(address(tokenIn), _approveMode(), address(tokenOut), orderAccount), 73),
            ExecutionLib.encodeBatch(executions_)
        );
        if (revertData_.length >= 4) {
            assertTrue(bytes4(revertData_) != MetaSwapOrderDelegationManager.InvalidSwap.selector);
        }
    }

    function test_flexibleRejectsNativeSwapWithWrongValue() public {
        Execution[] memory executions_ = _nativeExecutions(TOKEN_OUT_AMOUNT);
        executions_[0].value = TOKEN_IN_AMOUNT - 1;
        _expectInvalidSwap(executions_, 74, _flexibleTerms(address(0), _noneMode(), address(tokenOut), orderAccount));
    }

    // -------- Gas comparisons --------

    function test_gas_genericExactBatchPlusLimitedCalls() public {
        Execution[] memory executions_ = _erc20ExecutionsFor(genericAccount, 1, TOKEN_OUT_AMOUNT);
        bytes memory encoded_ = ExecutionLib.encodeBatch(executions_);

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({ enforcer: address(exactBatchEnforcer), terms: encoded_, args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(uint256(1)), args: hex"" });
        Delegation memory delegation_ = _signGeneric(caveats_, 100);

        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, encoded_);

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        genericManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("generic ExactBatch + LimitedCalls(1)", gasBefore_ - gasleft());
    }

    function test_gas_genericExactBatchPlusLimitedCallsResetApproval() public {
        bytes memory encoded_ = ExecutionLib.encodeBatch(_erc20ExecutionsFor(genericAccount, 2, TOKEN_OUT_AMOUNT));
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({ enforcer: address(exactBatchEnforcer), terms: encoded_, args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(uint256(1)), args: hex"" });
        Delegation memory delegation_ = _signGeneric(caveats_, 105);

        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, encoded_);

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        genericManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("generic ExactBatch + LimitedCalls(1), reset approval", gasBefore_ - gasleft());
    }

    function test_gas_genericExactBatchPlusLimitedCallsNative() public {
        bytes memory encoded_ = ExecutionLib.encodeBatch(_nativeExecutions(TOKEN_OUT_AMOUNT));
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({ enforcer: address(exactBatchEnforcer), terms: encoded_, args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(uint256(1)), args: hex"" });
        Delegation memory delegation_ = _signGeneric(caveats_, 106);

        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, encoded_);

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        genericManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("generic ExactBatch + LimitedCalls(1), native", gasBefore_ - gasleft());
    }

    function test_gas_genericFlexibleSettlementEnforcer() public {
        bytes memory terms_ = abi.encodePacked(
            address(metaSwap),
            address(tokenIn),
            TOKEN_IN_AMOUNT,
            uint8(MetaSwapFlexibleSettlementEnforcer.ApprovalMode.Approve),
            address(tokenOut),
            genericAccount,
            TOKEN_OUT_MIN
        );
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(flexibleEnforcer), terms: terms_, args: hex"" });
        Delegation memory delegation_ = _signGeneric(caveats_, 101);
        bytes memory encoded_ = ExecutionLib.encodeBatch(_erc20ExecutionsFor(genericAccount, 1, TOKEN_OUT_AMOUNT));

        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, encoded_);

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        genericManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("generic FlexibleSettlementEnforcer", gasBefore_ - gasleft());
    }

    function test_gas_genericFlexibleSettlementEnforcerResetApproval() public {
        bytes memory terms_ = abi.encodePacked(
            address(metaSwap),
            address(tokenIn),
            TOKEN_IN_AMOUNT,
            uint8(MetaSwapFlexibleSettlementEnforcer.ApprovalMode.ResetApprove),
            address(tokenOut),
            genericAccount,
            TOKEN_OUT_MIN
        );
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(flexibleEnforcer), terms: terms_, args: hex"" });
        Delegation memory delegation_ = _signGeneric(caveats_, 107);
        bytes memory encoded_ = ExecutionLib.encodeBatch(_erc20ExecutionsFor(genericAccount, 2, TOKEN_OUT_AMOUNT));

        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, encoded_);

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        genericManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("generic FlexibleSettlementEnforcer, reset approval", gasBefore_ - gasleft());
    }

    function test_gas_genericFlexibleSettlementEnforcerNative() public {
        bytes memory terms_ = abi.encodePacked(
            address(metaSwap),
            address(0),
            TOKEN_IN_AMOUNT,
            uint8(MetaSwapFlexibleSettlementEnforcer.ApprovalMode.None),
            address(tokenOut),
            genericAccount,
            TOKEN_OUT_MIN
        );
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(flexibleEnforcer), terms: terms_, args: hex"" });
        Delegation memory delegation_ = _signGeneric(caveats_, 108);
        bytes memory encoded_ = ExecutionLib.encodeBatch(_nativeExecutions(TOKEN_OUT_AMOUNT));

        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, encoded_);

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        genericManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("generic FlexibleSettlementEnforcer, native", gasBefore_ - gasleft());
    }

    function test_gas_hooklessFlexible() public {
        bytes memory terms_ = abi.encodePacked(
            address(metaSwap),
            address(tokenIn),
            TOKEN_IN_AMOUNT,
            uint8(MetaSwapFlexibleSettlementManagerBase.ApprovalMode.Approve),
            address(tokenOut),
            hooklessAccount,
            TOKEN_OUT_MIN
        );
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(hooklessManager), terms: terms_, args: hex"" });
        Delegation memory delegation_ = _signManager(hooklessManager, HOOKLESS_KEY, hooklessAccount, caveats_, 102);
        bytes memory encoded_ = ExecutionLib.encodeBatch(_erc20ExecutionsFor(hooklessAccount, 1, TOKEN_OUT_AMOUNT));

        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, encoded_);

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        hooklessManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("hookless flexible", gasBefore_ - gasleft());
    }

    function test_gas_orderExact() public {
        bytes memory encoded_ = ExecutionLib.encodeBatch(_erc20Executions(1, TOKEN_OUT_AMOUNT));
        Delegation memory delegation_ = _signIntent(_exactTerms(keccak256(encoded_)), 103);

        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, encoded_);

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        orderManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("order ExactCalldata", gasBefore_ - gasleft());
    }

    function test_gas_orderExactResetApproval() public {
        bytes memory encoded_ = ExecutionLib.encodeBatch(_erc20Executions(2, TOKEN_OUT_AMOUNT));
        Delegation memory delegation_ = _signIntent(_exactTerms(keccak256(encoded_)), 109);

        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, encoded_);

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        orderManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("order ExactCalldata, reset approval", gasBefore_ - gasleft());
    }

    function test_gas_orderExactNative() public {
        bytes memory encoded_ = ExecutionLib.encodeBatch(_nativeExecutions(TOKEN_OUT_AMOUNT));
        Delegation memory delegation_ = _signIntent(_exactTerms(keccak256(encoded_)), 110);

        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, encoded_);

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        orderManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("order ExactCalldata, native", gasBefore_ - gasleft());
    }

    function test_gas_orderFlexible() public {
        bytes memory terms_ = _flexibleTerms(address(tokenIn), _approveMode(), address(tokenOut), orderAccount);
        Delegation memory delegation_ = _signIntent(terms_, 104);
        bytes memory encoded_ = ExecutionLib.encodeBatch(_erc20Executions(1, TOKEN_OUT_AMOUNT));

        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, encoded_);

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        orderManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("order FlexibleSettlement", gasBefore_ - gasleft());
    }

    function test_gas_orderFlexibleResetApproval() public {
        bytes memory terms_ = _flexibleTerms(address(tokenIn), _resetApproveMode(), address(tokenOut), orderAccount);
        Delegation memory delegation_ = _signIntent(terms_, 111);
        bytes memory encoded_ = ExecutionLib.encodeBatch(_erc20Executions(2, TOKEN_OUT_AMOUNT));

        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, encoded_);

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        orderManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("order FlexibleSettlement, reset approval", gasBefore_ - gasleft());
    }

    function test_gas_orderFlexibleNative() public {
        bytes memory terms_ = _flexibleTerms(address(0), _noneMode(), address(tokenOut), orderAccount);
        Delegation memory delegation_ = _signIntent(terms_, 112);
        bytes memory encoded_ = ExecutionLib.encodeBatch(_nativeExecutions(TOKEN_OUT_AMOUNT));

        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, encoded_);

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        orderManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("order FlexibleSettlement, native", gasBefore_ - gasleft());
    }

    // -------- Helpers --------

    function _installDeleGator(address account_, address manager_) private {
        EIP7702StatelessDeleGator implementation_ = new EIP7702StatelessDeleGator(IDelegationManager(manager_), entryPoint);
        vm.etch(account_, bytes.concat(hex"ef0100", abi.encodePacked(implementation_)));
    }

    function _exactTerms(bytes32 executionHash_) private pure returns (bytes memory) {
        return abi.encodePacked(uint8(MetaSwapOrderDelegationManager.Intent.ExactCalldata), executionHash_);
    }

    function _flexibleTerms(
        address tokenIn_,
        MetaSwapOrderDelegationManager.ApprovalMode approvalMode_,
        address tokenOut_,
        address recipient_
    )
        private
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            uint8(MetaSwapOrderDelegationManager.Intent.FlexibleSettlement),
            address(metaSwap),
            tokenIn_,
            TOKEN_IN_AMOUNT,
            uint8(approvalMode_),
            tokenOut_,
            recipient_,
            TOKEN_OUT_MIN
        );
    }

    function _rawFlexibleTerms(
        address metaSwap_,
        address tokenIn_,
        uint256 tokenInAmount_,
        uint8 approvalMode_,
        address tokenOut_,
        address recipient_
    )
        private
        pure
        returns (bytes memory)
    {
        return _rawFlexibleTerms(metaSwap_, tokenIn_, tokenInAmount_, approvalMode_, tokenOut_, recipient_, TOKEN_OUT_MIN);
    }

    function _rawFlexibleTerms(
        address metaSwap_,
        address tokenIn_,
        uint256 tokenInAmount_,
        uint8 approvalMode_,
        address tokenOut_,
        address recipient_,
        uint256 tokenOutMin_
    )
        private
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            uint8(MetaSwapOrderDelegationManager.Intent.FlexibleSettlement),
            metaSwap_,
            tokenIn_,
            tokenInAmount_,
            approvalMode_,
            tokenOut_,
            recipient_,
            tokenOutMin_
        );
    }

    function _minimumSwapCalldata(bytes32 tokenInWord_) private pure returns (bytes memory) {
        return abi.encodePacked(
            IMetaSwap.swap.selector, uint256(128), tokenInWord_, TOKEN_IN_AMOUNT, uint256(160), uint256(0), uint256(0)
        );
    }

    function _expectFlexibleRevert(
        bytes memory terms_,
        Execution[] memory executions_,
        bytes4 selector_,
        uint256 salt_
    )
        private
    {
        Delegation memory delegation_ = _signIntent(terms_, salt_);
        vm.expectRevert(selector_);
        _redeemIntent(delegation_, ExecutionLib.encodeBatch(executions_));
    }

    function _expectInvalidApproval(Execution[] memory executions_, uint256 salt_) private {
        bytes memory terms_ = executions_.length == 3
            ? _flexibleTerms(address(tokenIn), _resetApproveMode(), address(tokenOut), orderAccount)
            : _flexibleTerms(address(tokenIn), _approveMode(), address(tokenOut), orderAccount);
        _expectFlexibleRevert(terms_, executions_, MetaSwapOrderDelegationManager.InvalidApproval.selector, salt_);
    }

    function _expectInvalidSwap(Execution[] memory executions_, uint256 salt_) private {
        _expectInvalidSwap(executions_, salt_, _flexibleTerms(address(tokenIn), _approveMode(), address(tokenOut), orderAccount));
    }

    function _expectInvalidSwap(Execution[] memory executions_, uint256 salt_, bytes memory terms_) private {
        _expectFlexibleRevert(terms_, executions_, MetaSwapOrderDelegationManager.InvalidSwap.selector, salt_);
    }

    function _redeemCatch(
        Delegation memory delegation_,
        bytes memory executionContext_
    )
        private
        returns (bytes memory revertData_)
    {
        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, executionContext_);
        vm.prank(relayer);
        try orderManager.redeemDelegations(permissionContexts_, modes_, executionContexts_) { }
        catch (bytes memory reason_) {
            return reason_;
        }
    }

    function _signIntent(bytes memory terms_, uint256 salt_) private view returns (Delegation memory) {
        return _signIntentWithKey(ORDER_KEY, terms_, salt_);
    }

    function _signIntentWithKey(
        uint256 signerKey_,
        bytes memory terms_,
        uint256 salt_
    )
        private
        view
        returns (Delegation memory delegation_)
    {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(orderManager), terms: terms_, args: hex"" });
        return _signManager(orderManager, signerKey_, orderAccount, caveats_, salt_);
    }

    function _signGeneric(Caveat[] memory caveats_, uint256 salt_) private view returns (Delegation memory) {
        return _signManager(MetaSwapDelegationManagerBase(address(0)), GENERIC_KEY, genericAccount, caveats_, salt_, true);
    }

    function _signManager(
        MetaSwapDelegationManagerBase manager_,
        uint256 signerKey_,
        address delegator_,
        Caveat[] memory caveats_,
        uint256 salt_
    )
        private
        view
        returns (Delegation memory)
    {
        return _signManager(manager_, signerKey_, delegator_, caveats_, salt_, false);
    }

    function _signManager(
        MetaSwapDelegationManagerBase manager_,
        uint256 signerKey_,
        address delegator_,
        Caveat[] memory caveats_,
        uint256 salt_,
        bool useGeneric_
    )
        private
        view
        returns (Delegation memory delegation_)
    {
        bytes32 rootAuthority_ = useGeneric_ ? genericManager.ROOT_AUTHORITY() : manager_.ROOT_AUTHORITY();
        delegation_ = Delegation({
            delegate: address(0xa11),
            delegator: delegator_,
            authority: rootAuthority_,
            caveats: caveats_,
            salt: salt_,
            signature: hex""
        });

        bytes32 delegationHash_;
        bytes32 domainHash_;
        if (useGeneric_) {
            delegationHash_ = genericManager.getDelegationHash(delegation_);
            domainHash_ = genericManager.getDomainHash();
        } else {
            delegationHash_ = manager_.getDelegationHash(delegation_);
            domainHash_ = manager_.getDomainHash();
        }

        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(domainHash_, delegationHash_);
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(signerKey_, typedDataHash_);
        delegation_ = Delegation({
            delegate: delegation_.delegate,
            delegator: delegation_.delegator,
            authority: delegation_.authority,
            caveats: delegation_.caveats,
            salt: delegation_.salt,
            signature: abi.encodePacked(r_, s_, v_)
        });
    }

    function _redeemIntent(Delegation memory delegation_, bytes memory executionContext_) private {
        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, executionContext_);
        vm.prank(relayer);
        orderManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
    }

    function _redemptionInputs(
        Delegation memory delegation_,
        bytes memory executionContext_
    )
        private
        pure
        returns (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_)
    {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);
        modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleBatch();
        executionContexts_ = new bytes[](1);
        executionContexts_[0] = executionContext_;
    }

    function _erc20Executions(uint8 approvalCount_, uint256 outputAmount_) private view returns (Execution[] memory) {
        return _erc20ExecutionsFor(orderAccount, approvalCount_, outputAmount_);
    }

    function _erc20ExecutionsFor(
        address,
        uint8 approvalCount_,
        uint256 outputAmount_
    )
        private
        view
        returns (Execution[] memory executions_)
    {
        uint256 swapIndex_ = approvalCount_;
        executions_ = new Execution[](swapIndex_ + 1);
        if (approvalCount_ == 2) executions_[0] = _approvalExecution(0);
        if (approvalCount_ != 0) executions_[swapIndex_ - 1] = _approvalExecution(TOKEN_IN_AMOUNT);
        executions_[swapIndex_] = Execution({
            target: address(metaSwap),
            value: 0,
            callData: abi.encodeCall(
                IMetaSwap.swap,
                ("redeemer-route", IERC20(address(tokenIn)), TOKEN_IN_AMOUNT, abi.encode(IERC20(address(tokenOut)), outputAmount_))
            )
        });
    }

    function _nativeExecutions(uint256 outputAmount_) private view returns (Execution[] memory executions_) {
        executions_ = new Execution[](1);
        executions_[0] = Execution({
            target: address(metaSwap),
            value: TOKEN_IN_AMOUNT,
            callData: abi.encodeCall(
                IMetaSwap.swap,
                ("redeemer-route", IERC20(address(0)), TOKEN_IN_AMOUNT, abi.encode(IERC20(address(tokenOut)), outputAmount_))
            )
        });
    }

    function _approvalExecution(uint256 amount_) private view returns (Execution memory) {
        return
            Execution({
                target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.approve, (address(metaSwap), amount_))
            });
    }

    function _noneMode() private pure returns (MetaSwapOrderDelegationManager.ApprovalMode) {
        return MetaSwapOrderDelegationManager.ApprovalMode.None;
    }

    function _skipApprovalMode() private pure returns (MetaSwapOrderDelegationManager.ApprovalMode) {
        return MetaSwapOrderDelegationManager.ApprovalMode.SkipApproval;
    }

    function _approveMode() private pure returns (MetaSwapOrderDelegationManager.ApprovalMode) {
        return MetaSwapOrderDelegationManager.ApprovalMode.Approve;
    }

    function _resetApproveMode() private pure returns (MetaSwapOrderDelegationManager.ApprovalMode) {
        return MetaSwapOrderDelegationManager.ApprovalMode.ResetApprove;
    }
}
