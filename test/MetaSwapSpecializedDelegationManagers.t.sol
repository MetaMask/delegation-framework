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
import { MetaSwapFlexibleSettlementManagerBase } from "../src/experiments/MetaSwapFlexibleSettlementManagerBase.sol";
import { MetaSwapExecutionBuilderDelegationManager } from "../src/experiments/MetaSwapExecutionBuilderDelegationManager.sol";
import { MetaSwapHooklessDelegationManager } from "../src/experiments/MetaSwapHooklessDelegationManager.sol";
import { DelegationManager } from "../src/DelegationManager.sol";
import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { MetaSwapFlexibleSettlementEnforcer } from "../src/enforcers/MetaSwapFlexibleSettlementEnforcer.sol";
import { IMetaSwap } from "../src/helpers/interfaces/IMetaSwap.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { BasicERC20 } from "./utils/BasicERC20.t.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../src/utils/Types.sol";

contract SpecializedManagerMetaSwapMock is IMetaSwap {
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

contract MetaSwapSpecializedDelegationManagersTest is Test {
    uint256 private constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 private constant TOKEN_OUT_MIN = 190 ether;
    uint256 private constant TOKEN_OUT_AMOUNT = 200 ether;
    uint256 private constant STANDARD_KEY = 0x5151;
    uint256 private constant HOOKLESS_KEY = 0xA11CE;
    uint256 private constant BUILDER_KEY = 0xB0B;

    EntryPoint private entryPoint;
    SpecializedManagerMetaSwapMock private metaSwap;
    BasicERC20 private tokenIn;
    BasicERC20 private tokenOut;
    DelegationManager private standardManager;
    MetaSwapFlexibleSettlementEnforcer private standardEnforcer;
    MetaSwapHooklessDelegationManager private hooklessManager;
    MetaSwapExecutionBuilderDelegationManager private builderManager;
    address private standardAccount;
    address private hooklessAccount;
    address private builderAccount;
    address private relayer;

    function setUp() public {
        entryPoint = new EntryPoint();
        metaSwap = new SpecializedManagerMetaSwapMock();
        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        relayer = makeAddr("Relayer");

        standardManager = new DelegationManager(address(this));
        standardEnforcer = new MetaSwapFlexibleSettlementEnforcer();
        hooklessManager = new MetaSwapHooklessDelegationManager();
        builderManager = new MetaSwapExecutionBuilderDelegationManager();

        standardAccount = vm.addr(STANDARD_KEY);
        hooklessAccount = vm.addr(HOOKLESS_KEY);
        builderAccount = vm.addr(BUILDER_KEY);
        _installDeleGator(standardAccount, address(standardManager));
        _installDeleGator(hooklessAccount, address(hooklessManager));
        _installDeleGator(builderAccount, address(builderManager));

        tokenIn.mint(standardAccount, 1_000 ether);
        tokenIn.mint(hooklessAccount, 1_000 ether);
        tokenIn.mint(builderAccount, 1_000 ether);
        tokenOut.mint(address(metaSwap), 10_000 ether);
        vm.deal(standardAccount, 1_000 ether);
        vm.deal(hooklessAccount, 1_000 ether);
        vm.deal(builderAccount, 1_000 ether);
        vm.deal(address(metaSwap), 10_000 ether);
    }

    function test_hooklessManagerRedeemsValidatedExecutionBatch() public {
        bytes memory terms_ = _terms(address(tokenIn), _approveMode(), address(tokenOut), hooklessAccount);
        Delegation memory delegation_ = _sign(hooklessManager, HOOKLESS_KEY, hooklessAccount, terms_, 1);

        _redeemHookless(delegation_, _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, TOKEN_OUT_AMOUNT));

        assertEq(tokenIn.balanceOf(hooklessAccount), 900 ether);
        assertEq(tokenOut.balanceOf(hooklessAccount), TOKEN_OUT_AMOUNT);
        assertTrue(hooklessManager.disabledDelegations(hooklessManager.getDelegationHash(delegation_)));
    }

    function test_hooklessManagerRedeemsSkipApprovalExecution() public {
        vm.prank(hooklessAccount);
        tokenIn.approve(address(metaSwap), TOKEN_IN_AMOUNT);

        bytes memory terms_ = _terms(address(tokenIn), _skipApprovalMode(), address(tokenOut), hooklessAccount);
        Delegation memory delegation_ = _sign(hooklessManager, HOOKLESS_KEY, hooklessAccount, terms_, 12);

        _redeemHookless(delegation_, _erc20Executions(0, address(tokenIn), TOKEN_IN_AMOUNT, TOKEN_OUT_AMOUNT));

        assertEq(tokenOut.balanceOf(hooklessAccount), TOKEN_OUT_AMOUNT);
    }

    function test_hooklessManagerRedeemsResetApproveExecution() public {
        vm.prank(hooklessAccount);
        tokenIn.approve(address(metaSwap), 1);

        bytes memory terms_ = _terms(address(tokenIn), _resetApproveMode(), address(tokenOut), hooklessAccount);
        Delegation memory delegation_ = _sign(hooklessManager, HOOKLESS_KEY, hooklessAccount, terms_, 13);

        _redeemHookless(delegation_, _erc20Executions(2, address(tokenIn), TOKEN_IN_AMOUNT, TOKEN_OUT_AMOUNT));

        assertEq(tokenOut.balanceOf(hooklessAccount), TOKEN_OUT_AMOUNT);
    }

    function test_hooklessManagerRedeemsNativeInputExecution() public {
        bytes memory terms_ = _terms(address(0), _noneMode(), address(tokenOut), hooklessAccount);
        Delegation memory delegation_ = _sign(hooklessManager, HOOKLESS_KEY, hooklessAccount, terms_, 14);
        uint256 nativeBefore_ = hooklessAccount.balance;

        _redeemHookless(delegation_, _nativeExecutions(TOKEN_OUT_AMOUNT));

        assertEq(hooklessAccount.balance, nativeBefore_ - TOKEN_IN_AMOUNT);
        assertEq(tokenOut.balanceOf(hooklessAccount), TOKEN_OUT_AMOUNT);
    }

    function test_gas_standardManagerWithSettlementEnforcer() public {
        bytes memory terms_ = _terms(address(tokenIn), _approveMode(), address(tokenOut), standardAccount);
        Delegation memory delegation_ = _signStandard(STANDARD_KEY, standardAccount, terms_, 100);
        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) = _redemptionInputs(
            delegation_, ExecutionLib.encodeBatch(_erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, TOKEN_OUT_AMOUNT))
        );

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        standardManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("standard manager + enforcer", gasBefore_ - gasleft());
    }

    function test_gas_hooklessManager() public {
        bytes memory terms_ = _terms(address(tokenIn), _approveMode(), address(tokenOut), hooklessAccount);
        Delegation memory delegation_ = _sign(hooklessManager, HOOKLESS_KEY, hooklessAccount, terms_, 102);
        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) = _redemptionInputs(
            delegation_, ExecutionLib.encodeBatch(_erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, TOKEN_OUT_AMOUNT))
        );

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        hooklessManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("hookless manager", gasBefore_ - gasleft());
    }

    function test_gas_executionBuilderManager() public {
        bytes memory terms_ = _terms(address(tokenIn), _approveMode(), address(tokenOut), builderAccount);
        Delegation memory delegation_ = _sign(builderManager, BUILDER_KEY, builderAccount, terms_, 103);
        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, abi.encode("redeemer-route", abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT)));

        uint256 gasBefore_ = gasleft();
        vm.prank(relayer);
        builderManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
        emit log_named_uint("execution builder", gasBefore_ - gasleft());
    }

    function test_hooklessManagerRejectsInvalidExecutionWithoutCallingHooks() public {
        bytes memory terms_ = _terms(address(tokenIn), _approveMode(), address(tokenOut), hooklessAccount);
        Delegation memory delegation_ = _sign(hooklessManager, HOOKLESS_KEY, hooklessAccount, terms_, 3);
        Execution[] memory executions_ = _erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, TOKEN_OUT_AMOUNT);
        executions_[1].target = makeAddr("UnapprovedSwapTarget");

        vm.expectRevert(MetaSwapHooklessDelegationManager.InvalidSwap.selector);
        _redeemHookless(delegation_, executions_);
    }

    function test_builderManagerConstructsApproveAndSwapExecutions() public {
        bytes memory terms_ = _terms(address(tokenIn), _approveMode(), address(tokenOut), builderAccount);
        Delegation memory delegation_ = _sign(builderManager, BUILDER_KEY, builderAccount, terms_, 4);

        _redeemBuilder(delegation_, TOKEN_OUT_AMOUNT);

        assertEq(tokenIn.balanceOf(builderAccount), 900 ether);
        assertEq(tokenIn.allowance(builderAccount, address(metaSwap)), 0);
        assertEq(tokenOut.balanceOf(builderAccount), TOKEN_OUT_AMOUNT);
    }

    function test_builderManagerConstructsResetApproveAndSwapExecutions() public {
        vm.prank(builderAccount);
        tokenIn.approve(address(metaSwap), 1);

        bytes memory terms_ = _terms(address(tokenIn), _resetApproveMode(), address(tokenOut), builderAccount);
        Delegation memory delegation_ = _sign(builderManager, BUILDER_KEY, builderAccount, terms_, 5);

        _redeemBuilder(delegation_, TOKEN_OUT_AMOUNT);

        assertEq(tokenIn.balanceOf(builderAccount), 900 ether);
        assertEq(tokenOut.balanceOf(builderAccount), TOKEN_OUT_AMOUNT);
    }

    function test_builderManagerConstructsSkipApprovalSwapExecution() public {
        vm.prank(builderAccount);
        tokenIn.approve(address(metaSwap), TOKEN_IN_AMOUNT);

        bytes memory terms_ = _terms(address(tokenIn), _skipApprovalMode(), address(tokenOut), builderAccount);
        Delegation memory delegation_ = _sign(builderManager, BUILDER_KEY, builderAccount, terms_, 6);

        _redeemBuilder(delegation_, TOKEN_OUT_AMOUNT);

        assertEq(tokenIn.balanceOf(builderAccount), 900 ether);
        assertEq(tokenOut.balanceOf(builderAccount), TOKEN_OUT_AMOUNT);
    }

    function test_builderManagerConstructsNativeInputSwapExecution() public {
        bytes memory terms_ = _terms(address(0), _noneMode(), address(tokenOut), builderAccount);
        Delegation memory delegation_ = _sign(builderManager, BUILDER_KEY, builderAccount, terms_, 7);
        uint256 nativeBefore_ = builderAccount.balance;

        _redeemBuilder(delegation_, TOKEN_OUT_AMOUNT);

        assertEq(builderAccount.balance, nativeBefore_ - TOKEN_IN_AMOUNT);
        assertEq(tokenOut.balanceOf(builderAccount), TOKEN_OUT_AMOUNT);
    }

    function test_builderManagerRejectsNativeApprovalMode() public {
        bytes memory terms_ = _terms(address(0), _approveMode(), address(tokenOut), builderAccount);
        Delegation memory delegation_ = _sign(builderManager, BUILDER_KEY, builderAccount, terms_, 15);

        vm.expectRevert(MetaSwapFlexibleSettlementManagerBase.InvalidApprovalMode.selector);
        _redeemBuilder(delegation_, TOKEN_OUT_AMOUNT);
    }

    function test_builderManagerRejectsNoneModeForERC20() public {
        bytes memory terms_ = _terms(address(tokenIn), _noneMode(), address(tokenOut), builderAccount);
        Delegation memory delegation_ = _sign(builderManager, BUILDER_KEY, builderAccount, terms_, 16);

        vm.expectRevert(MetaSwapFlexibleSettlementManagerBase.InvalidApprovalMode.selector);
        _redeemBuilder(delegation_, TOKEN_OUT_AMOUNT);
    }

    function test_builderManagerRevertsAtomicallyForInsufficientOutput() public {
        bytes memory terms_ = _terms(address(tokenIn), _approveMode(), address(tokenOut), builderAccount);
        Delegation memory delegation_ = _sign(builderManager, BUILDER_KEY, builderAccount, terms_, 8);
        bytes32 delegationHash_ = builderManager.getDelegationHash(delegation_);

        vm.expectRevert(MetaSwapDelegationManagerBase.InsufficientOutput.selector);
        _redeemBuilder(delegation_, TOKEN_OUT_MIN - 1);

        assertFalse(builderManager.disabledDelegations(delegationHash_));
        assertEq(tokenIn.balanceOf(builderAccount), 1_000 ether);
        assertEq(tokenOut.balanceOf(builderAccount), 0);
    }

    function test_successfulSettlementCannotBeReplayed() public {
        bytes memory terms_ = _terms(address(tokenIn), _approveMode(), address(tokenOut), builderAccount);
        Delegation memory delegation_ = _sign(builderManager, BUILDER_KEY, builderAccount, terms_, 9);

        _redeemBuilder(delegation_, TOKEN_OUT_AMOUNT);

        vm.expectRevert(MetaSwapDelegationManagerBase.CannotUseADisabledDelegation.selector);
        _redeemBuilder(delegation_, TOKEN_OUT_AMOUNT);
    }

    function test_disableDelegationUsesSameOneShotState() public {
        bytes memory terms_ = _terms(address(tokenIn), _approveMode(), address(tokenOut), builderAccount);
        Delegation memory delegation_ = _sign(builderManager, BUILDER_KEY, builderAccount, terms_, 10);

        vm.prank(builderAccount);
        builderManager.disableDelegation(delegation_);

        vm.expectRevert(MetaSwapDelegationManagerBase.CannotUseADisabledDelegation.selector);
        _redeemBuilder(delegation_, TOKEN_OUT_AMOUNT);
    }

    function test_rejectsSignatureFromDifferentEOA() public {
        bytes memory terms_ = _terms(address(tokenIn), _approveMode(), address(tokenOut), builderAccount);
        Delegation memory delegation_ = _sign(builderManager, HOOKLESS_KEY, builderAccount, terms_, 11);

        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidERC1271Signature.selector);
        _redeemBuilder(delegation_, TOKEN_OUT_AMOUNT);
    }

    function test_rejectsUnsupportedBatchShapeAndMode() public {
        bytes[] memory emptyContexts_ = new bytes[](0);
        ModeCode[] memory emptyModes_ = new ModeCode[](0);
        vm.expectRevert(MetaSwapDelegationManagerBase.BatchDataLengthMismatch.selector);
        hooklessManager.redeemDelegations(emptyContexts_, emptyModes_, emptyContexts_);

        bytes memory terms_ = _terms(address(tokenIn), _approveMode(), address(tokenOut), hooklessAccount);
        Delegation memory delegation_ = _sign(hooklessManager, HOOKLESS_KEY, hooklessAccount, terms_, 17);
        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) = _redemptionInputs(
            delegation_, ExecutionLib.encodeBatch(_erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, TOKEN_OUT_AMOUNT))
        );
        modes_[0] = ModeLib.encodeSimpleSingle();

        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidMode.selector);
        hooklessManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
    }

    function test_rejectsDelegationChainAndInvalidRootFields() public {
        bytes memory terms_ = _terms(address(tokenIn), _approveMode(), address(tokenOut), hooklessAccount);
        Delegation memory delegation_ = _sign(hooklessManager, HOOKLESS_KEY, hooklessAccount, terms_, 18);
        bytes memory executionContext_ =
            ExecutionLib.encodeBatch(_erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, TOKEN_OUT_AMOUNT));

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = delegation_;
        delegations_[1] = delegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleBatch();
        bytes[] memory executionContexts_ = new bytes[](1);
        executionContexts_[0] = executionContext_;
        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidPermissionContext.selector);
        hooklessManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);

        delegation_.delegate = makeAddr("WrongDelegate");
        (permissionContexts_, modes_, executionContexts_) = _redemptionInputs(delegation_, executionContext_);
        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidDelegate.selector);
        hooklessManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);

        delegation_.delegate = address(0xa11);
        delegation_.authority = bytes32(0);
        (permissionContexts_, modes_, executionContexts_) = _redemptionInputs(delegation_, executionContext_);
        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidAuthority.selector);
        hooklessManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
    }

    function test_rejectsNonManagerCaveatAndInvalidTerms() public {
        bytes memory terms_ = _terms(address(tokenIn), _approveMode(), address(tokenOut), hooklessAccount);
        Delegation memory delegation_ = _sign(hooklessManager, HOOKLESS_KEY, hooklessAccount, terms_, 19);
        bytes memory executionContext_ =
            ExecutionLib.encodeBatch(_erc20Executions(1, address(tokenIn), TOKEN_IN_AMOUNT, TOKEN_OUT_AMOUNT));

        delegation_.caveats[0].enforcer = makeAddr("ExternalEnforcer");
        (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionContexts_) =
            _redemptionInputs(delegation_, executionContext_);
        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidCaveat.selector);
        hooklessManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);

        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidTerms.selector);
        hooklessManager.getTermsInfo(new bytes(144));

        // Mutating signed terms changes the hash, so signature validation fails before terms decoding.
        delegation_.caveats[0].enforcer = address(hooklessManager);
        delegation_.caveats[0].terms = new bytes(144);
        (permissionContexts_, modes_, executionContexts_) = _redemptionInputs(delegation_, executionContext_);
        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidERC1271Signature.selector);
        hooklessManager.redeemDelegations(permissionContexts_, modes_, executionContexts_);
    }

    function test_onlyDelegatorCanDisableDelegation() public {
        bytes memory terms_ = _terms(address(tokenIn), _approveMode(), address(tokenOut), builderAccount);
        Delegation memory delegation_ = _sign(builderManager, BUILDER_KEY, builderAccount, terms_, 20);

        vm.expectRevert(MetaSwapDelegationManagerBase.InvalidDelegator.selector);
        builderManager.disableDelegation(delegation_);
    }

    function _installDeleGator(address account_, address manager_) private {
        EIP7702StatelessDeleGator implementation_ = new EIP7702StatelessDeleGator(IDelegationManager(manager_), entryPoint);
        vm.etch(account_, bytes.concat(hex"ef0100", abi.encodePacked(implementation_)));
    }

    function _sign(
        MetaSwapDelegationManagerBase manager_,
        uint256 signerKey_,
        address delegator_,
        bytes memory terms_,
        uint256 salt_
    )
        private
        view
        returns (Delegation memory delegation_)
    {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(manager_), terms: terms_, args: hex"" });
        delegation_ = Delegation({
            delegate: address(0xa11),
            delegator: delegator_,
            authority: manager_.ROOT_AUTHORITY(),
            caveats: caveats_,
            salt: salt_,
            signature: hex""
        });

        bytes32 delegationHash_ = manager_.getDelegationHash(delegation_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(manager_.getDomainHash(), delegationHash_);
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

    function _signStandard(
        uint256 signerKey_,
        address delegator_,
        bytes memory terms_,
        uint256 salt_
    )
        private
        view
        returns (Delegation memory delegation_)
    {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(standardEnforcer), terms: terms_, args: hex"" });
        delegation_ = Delegation({
            delegate: address(0xa11),
            delegator: delegator_,
            authority: standardManager.ROOT_AUTHORITY(),
            caveats: caveats_,
            salt: salt_,
            signature: hex""
        });

        bytes32 delegationHash_ = standardManager.getDelegationHash(delegation_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(standardManager.getDomainHash(), delegationHash_);
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

    function _redeemHookless(Delegation memory delegation_, Execution[] memory executions_) private {
        _redeemHookless(hooklessManager, delegation_, executions_);
    }

    function _redeemHookless(
        MetaSwapHooklessDelegationManager manager_,
        Delegation memory delegation_,
        Execution[] memory executions_
    )
        private
    {
        bytes[] memory executionContexts_ = new bytes[](1);
        executionContexts_[0] = ExecutionLib.encodeBatch(executions_);
        _redeem(manager_, delegation_, executionContexts_);
    }

    function _redeemBuilder(Delegation memory delegation_, uint256 outputAmount_) private {
        bytes[] memory executionContexts_ = new bytes[](1);
        executionContexts_[0] = abi.encode("redeemer-route", abi.encode(IERC20(address(tokenOut)), outputAmount_));
        _redeem(builderManager, delegation_, executionContexts_);
    }

    function _redeem(
        MetaSwapDelegationManagerBase manager_,
        Delegation memory delegation_,
        bytes[] memory executionContexts_
    )
        private
    {
        (bytes[] memory permissionContexts_, ModeCode[] memory modes_,) = _redemptionInputs(delegation_, executionContexts_[0]);

        vm.prank(relayer);
        manager_.redeemDelegations(permissionContexts_, modes_, executionContexts_);
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

    function _terms(
        address tokenIn_,
        MetaSwapFlexibleSettlementManagerBase.ApprovalMode approvalMode_,
        address tokenOut_,
        address recipient_
    )
        private
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            address(metaSwap), tokenIn_, TOKEN_IN_AMOUNT, uint8(approvalMode_), tokenOut_, recipient_, TOKEN_OUT_MIN
        );
    }

    function _erc20Executions(
        uint8 approvalCount_,
        address swapToken_,
        uint256 swapAmount_,
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
                ("redeemer-route", IERC20(swapToken_), swapAmount_, abi.encode(IERC20(address(tokenOut)), outputAmount_))
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

    function _noneMode() private pure returns (MetaSwapFlexibleSettlementManagerBase.ApprovalMode) {
        return MetaSwapFlexibleSettlementManagerBase.ApprovalMode.None;
    }

    function _skipApprovalMode() private pure returns (MetaSwapFlexibleSettlementManagerBase.ApprovalMode) {
        return MetaSwapFlexibleSettlementManagerBase.ApprovalMode.SkipApproval;
    }

    function _approveMode() private pure returns (MetaSwapFlexibleSettlementManagerBase.ApprovalMode) {
        return MetaSwapFlexibleSettlementManagerBase.ApprovalMode.Approve;
    }

    function _resetApproveMode() private pure returns (MetaSwapFlexibleSettlementManagerBase.ApprovalMode) {
        return MetaSwapFlexibleSettlementManagerBase.ApprovalMode.ResetApprove;
    }
}
