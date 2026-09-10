// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { BaseTest } from "./utils/BaseTest.t.sol";
import { BasicERC20 } from "./utils/BasicERC20.t.sol";
import { MockLimitOrderRouter } from "./utils/MockLimitOrderRouter.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { EIP7702MultiManagerDeleGator } from "../src/EIP7702/EIP7702MultiManagerDeleGator.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { IMetaSwap } from "../src/helpers/interfaces/IMetaSwap.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { MetaSwapMinimalDelegationManager } from "../src/MetaSwapMinimalDelegationManager.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../src/utils/Types.sol";

contract MetaSwapMinimalDelegationManagerTest is BaseTest {
    uint256 internal constant TOKEN_IN_AMOUNT = 1 ether;
    uint256 internal constant TOKEN_OUT_MIN = 0.9 ether;

    MetaSwapMinimalDelegationManager internal minimalManager;
    EIP7702MultiManagerDeleGator internal multiManagerImplementation;
    EIP7702MultiManagerDeleGator internal aliceAccount;

    BasicERC20 internal tokenIn;
    BasicERC20 internal tokenOut;
    MockLimitOrderRouter internal metaSwap;

    address internal alice;
    address internal relayer;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();

        minimalManager = new MetaSwapMinimalDelegationManager();
        multiManagerImplementation = new EIP7702MultiManagerDeleGator();
        alice = users.alice.addr;
        relayer = makeAddr("Relayer");

        vm.etch(alice, bytes.concat(hex"ef0100", abi.encodePacked(address(multiManagerImplementation))));
        aliceAccount = EIP7702MultiManagerDeleGator(payable(alice));
        vm.startPrank(alice);
        aliceAccount.approveDelegationManager(IDelegationManager(address(delegationManager)));
        aliceAccount.approveDelegationManager(IDelegationManager(address(minimalManager)));
        vm.stopPrank();

        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        metaSwap = new MockLimitOrderRouter();

        tokenIn.mint(alice, 100 ether);
        tokenOut.mint(address(metaSwap), 100 ether);
        vm.deal(address(metaSwap), 100 ether);
        metaSwap.setERC20AmountOut(TOKEN_IN_AMOUNT);
    }

    function test_gaslessExact_executesSignedExecution() public {
        Execution memory execution_ = Execution({
            target: address(metaSwap),
            value: TOKEN_IN_AMOUNT,
            callData: abi.encodeCall(MockLimitOrderRouter.swapNativeForERC20, (IERC20(address(tokenOut)), alice))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes32 executionHash_ = minimalManager.getGaslessExecutionHash(singleDefaultMode, executionCallData_);
        Delegation memory delegation_ = _sign(_gaslessTerms(executionHash_));

        _redeem(delegation_, singleDefaultMode, executionCallData_);

        assertEq(tokenOut.balanceOf(alice), TOKEN_IN_AMOUNT);
    }

    function test_gaslessExact_rejectsTamperedExecution() public {
        Execution memory execution_ = Execution({
            target: address(metaSwap),
            value: TOKEN_IN_AMOUNT,
            callData: abi.encodeCall(MockLimitOrderRouter.swapNativeForERC20, (IERC20(address(tokenOut)), alice))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        Delegation memory delegation_ =
            _sign(_gaslessTerms(minimalManager.getGaslessExecutionHash(singleDefaultMode, executionCallData_)));

        execution_.value++;
        vm.expectRevert(MetaSwapMinimalDelegationManager.InvalidMode.selector);
        _redeem(delegation_, singleDefaultMode, ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData));
    }

    function test_gaslessExact_isOneShot() public {
        Execution memory execution_ = Execution({
            target: address(metaSwap),
            value: TOKEN_IN_AMOUNT,
            callData: abi.encodeCall(MockLimitOrderRouter.swapNativeForERC20, (IERC20(address(tokenOut)), alice))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        Delegation memory delegation_ =
            _sign(_gaslessTerms(minimalManager.getGaslessExecutionHash(singleDefaultMode, executionCallData_)));

        _redeem(delegation_, singleDefaultMode, executionCallData_);

        vm.expectRevert(MetaSwapMinimalDelegationManager.DelegationAlreadyUsed.selector);
        _redeem(delegation_, singleDefaultMode, executionCallData_);
    }

    function test_limitOrder_erc20OneApproval() public {
        Delegation memory delegation_ = _sign(_limitTerms(address(tokenIn), address(tokenOut), false));

        _fill(delegation_, "best-route", abi.encode(tokenOut, TOKEN_IN_AMOUNT));

        assertEq(tokenIn.balanceOf(alice), 99 ether);
        assertEq(tokenOut.balanceOf(alice), TOKEN_IN_AMOUNT);
    }

    function test_limitOrder_erc20ResetApproval() public {
        vm.prank(alice);
        tokenIn.approve(address(metaSwap), 1);
        Delegation memory delegation_ = _sign(_limitTerms(address(tokenIn), address(tokenOut), true));

        _fill(delegation_, "best-route", abi.encode(tokenOut, TOKEN_IN_AMOUNT));

        assertEq(tokenIn.balanceOf(alice), 99 ether);
        assertEq(tokenOut.balanceOf(alice), TOKEN_IN_AMOUNT);
        assertEq(tokenIn.allowance(alice, address(metaSwap)), 0);
    }

    function test_limitOrder_nativeInput() public {
        Delegation memory delegation_ = _sign(_limitTerms(address(0), address(tokenOut), false));
        uint256 nativeBefore_ = alice.balance;

        _fill(delegation_, "best-route", abi.encode(tokenOut, TOKEN_IN_AMOUNT));

        assertEq(alice.balance, nativeBefore_ - TOKEN_IN_AMOUNT);
        assertEq(tokenOut.balanceOf(alice), TOKEN_IN_AMOUNT);
    }

    function test_limitOrder_nativeOutput() public {
        Delegation memory delegation_ = _sign(_limitTerms(address(tokenIn), address(0), false));
        uint256 nativeBefore_ = alice.balance;

        _fill(delegation_, "best-route", abi.encode(IERC20(address(0)), TOKEN_IN_AMOUNT));

        assertEq(tokenIn.balanceOf(alice), 99 ether);
        assertEq(alice.balance, nativeBefore_ + TOKEN_IN_AMOUNT);
    }

    function test_limitOrder_managerOverridesCallerSuppliedInputTokenAndAmount() public {
        BasicERC20 otherToken_ = new BasicERC20(address(this), "Other", "OTHER", 0);
        otherToken_.mint(alice, 10 ether);
        vm.prank(alice);
        otherToken_.approve(address(metaSwap), 10 ether);
        Delegation memory delegation_ = _sign(_limitTerms(address(tokenIn), address(tokenOut), false));

        // The route payload contains no tokenFrom or amount fields used to construct the MetaSwap call.
        _fill(delegation_, "caller-route", abi.encode(tokenOut, TOKEN_IN_AMOUNT));

        assertEq(otherToken_.balanceOf(alice), 10 ether);
        assertEq(tokenIn.balanceOf(alice), 99 ether);
    }

    function test_limitOrder_insufficientOutputCanRetryWithNewRoute() public {
        Delegation memory delegation_ = _sign(_limitTerms(address(tokenIn), address(tokenOut), false));

        vm.expectRevert(
            abi.encodeWithSelector(MetaSwapMinimalDelegationManager.InsufficientOutput.selector, TOKEN_OUT_MIN, TOKEN_OUT_MIN - 1)
        );
        _fill(delegation_, "bad-route", abi.encode(tokenOut, TOKEN_OUT_MIN - 1));

        _fill(delegation_, "new-route", abi.encode(tokenOut, TOKEN_OUT_MIN));

        assertEq(tokenOut.balanceOf(alice), TOKEN_OUT_MIN);
    }

    function _gaslessTerms(bytes32 executionHash_) private view returns (Caveat[] memory caveats_) {
        caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            enforcer: address(minimalManager),
            terms: abi.encodePacked(bytes1(minimalManager.GASLESS_EXACT_PROFILE()), executionHash_),
            args: hex""
        });
    }

    function _limitTerms(address tokenIn_, address tokenOut_, bool resetApproval_) private view returns (Caveat[] memory caveats_) {
        caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            enforcer: address(minimalManager),
            terms: abi.encodePacked(
                bytes1(minimalManager.LIMIT_ORDER_PROFILE()),
                address(metaSwap),
                tokenIn_,
                tokenOut_,
                TOKEN_IN_AMOUNT,
                TOKEN_OUT_MIN,
                bytes1(resetApproval_ ? 0x01 : 0x00)
            ),
            args: hex""
        });
    }

    function _sign(Caveat[] memory caveats_) private view returns (Delegation memory delegation_) {
        delegation_ = Delegation({
            delegate: ANY_DELEGATE, delegator: alice, authority: ROOT_AUTHORITY, caveats: caveats_, salt: 0, signature: hex""
        });

        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(minimalManager.getDomainHash(), delegationHash_);
        delegation_.signature = signHash(users.alice, typedDataHash_);
    }

    function _fill(Delegation memory delegation_, string memory aggregatorId_, bytes memory routeData_) private {
        _redeem(delegation_, batchDefaultMode, abi.encode(aggregatorId_, routeData_));
    }

    function _redeem(Delegation memory delegation_, ModeCode mode_, bytes memory executionCallData_) private {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = mode_;
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = executionCallData_;

        vm.prank(relayer);
        minimalManager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);
    }
}
