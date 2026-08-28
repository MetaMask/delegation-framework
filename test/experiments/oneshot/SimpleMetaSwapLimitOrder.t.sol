// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { IMetaSwap } from "../../../src/helpers/interfaces/IMetaSwap.sol";
import { MetaSwapLimitOrderEnforcer } from "../../../src/experiments/oneshot/MetaSwapLimitOrderEnforcer.sol";
import { SimpleMetaSwapAdapter } from "../../../src/experiments/oneshot/SimpleMetaSwapAdapter.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../../src/utils/Types.sol";
import { BasicERC20 } from "../../utils/BasicERC20.t.sol";
import { BaseTest } from "../../utils/BaseTest.t.sol";
import { Implementation, SignatureType } from "../../utils/Types.t.sol";
import { GasExperimentHarness } from "../gas/GasExperimentHarness.sol";

contract MockMetaSwapForLimitOrder is IMetaSwap {
    using SafeERC20 for IERC20;

    IERC20 internal immutable tokenOut;

    constructor(IERC20 _tokenOut) {
        tokenOut = _tokenOut;
    }

    function swap(string calldata, IERC20 _tokenFrom, uint256 _amount, bytes calldata _data) external payable {
        uint256 tokenOutAmount_ = abi.decode(_data, (uint256));
        _tokenFrom.safeTransferFrom(msg.sender, address(this), _amount);
        tokenOut.safeTransfer(msg.sender, tokenOutAmount_);
    }

    function setAdapter(string calldata, address, bytes4, bytes calldata) external { }
    function removeAdapter(string calldata) external { }

    function adapters(string memory) external pure returns (Adapter memory) {
        return Adapter({ addr: address(0), selector: bytes4(0), data: hex"" });
    }
}

contract SimpleMetaSwapLimitOrderTest is BaseTest, GasExperimentHarness {
    uint256 internal constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 internal constant MIN_TOKEN_OUT = 190 ether;

    BasicERC20 internal tokenIn;
    BasicERC20 internal tokenOut;
    MockMetaSwapForLimitOrder internal metaSwap;
    SimpleMetaSwapAdapter internal adapter;
    MetaSwapLimitOrderEnforcer internal enforcer;

    address internal automation;
    address internal apiSigner;
    uint256 internal apiSignerKey;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();
        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        metaSwap = new MockMetaSwapForLimitOrder(tokenOut);
        (apiSigner, apiSignerKey) = makeAddrAndKey("metaswap-api-signer");
        adapter = new SimpleMetaSwapAdapter(metaSwap, apiSigner);
        enforcer = new MetaSwapLimitOrderEnforcer();
        automation = makeAddr("metamask-automation");

        tokenIn.mint(address(users.alice.deleGator), TOKEN_IN_AMOUNT);
        tokenOut.mint(address(metaSwap), 1_000 ether);
    }

    function test_limitOrder_happyPath_allowsBetterThanMinimum() public {
        (Delegation memory delegation_, bytes memory execution_) =
            _buildOrder(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, 200 ether, block.timestamp + 5 minutes, apiSignerKey);

        _redeem(delegation_, execution_);

        assertEq(tokenIn.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), 200 ether);
        assertEq(tokenIn.balanceOf(address(metaSwap)), TOKEN_IN_AMOUNT);
    }

    function test_limitOrder_revertsWrongTokenOut() public {
        BasicERC20 wrongTokenOut_ = new BasicERC20(address(this), "Wrong", "WRONG", 0);
        (Delegation memory delegation_, bytes memory execution_) =
            _buildOrder(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, 200 ether, block.timestamp + 5 minutes, apiSignerKey);
        execution_ = _replaceSwapExecution(
            execution_,
            tokenIn,
            wrongTokenOut_,
            TOKEN_IN_AMOUNT,
            MIN_TOKEN_OUT,
            _quote(200 ether, block.timestamp + 5 minutes, apiSignerKey)
        );

        vm.expectRevert(MetaSwapLimitOrderEnforcer.InvalidSwapCall.selector);
        _redeem(delegation_, execution_);
    }

    function test_limitOrder_revertsWrongInputAmount() public {
        (Delegation memory delegation_, bytes memory execution_) =
            _buildOrder(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, 200 ether, block.timestamp + 5 minutes, apiSignerKey);
        Execution[] memory executions_ = abi.decode(execution_, (Execution[]));
        executions_[0].callData = abi.encodeCall(IERC20.transfer, (address(adapter), TOKEN_IN_AMOUNT - 1));

        vm.expectRevert(MetaSwapLimitOrderEnforcer.InvalidTransferCall.selector);
        _redeem(delegation_, ExecutionLib.encodeBatch(executions_));
    }

    function test_limitOrder_revertsExpiredApiQuote() public {
        uint256 expiration_ = block.timestamp + 10;
        (Delegation memory delegation_, bytes memory execution_) =
            _buildOrder(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, 200 ether, expiration_, apiSignerKey);
        vm.warp(expiration_);

        vm.expectRevert(SimpleMetaSwapAdapter.ApiQuoteExpired.selector);
        _redeem(delegation_, execution_);
    }

    function test_limitOrder_revertsInvalidApiSignature() public {
        (, uint256 wrongKey_) = makeAddrAndKey("wrong-api-signer");
        (Delegation memory delegation_, bytes memory execution_) =
            _buildOrder(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, 200 ether, block.timestamp + 5 minutes, wrongKey_);

        vm.expectRevert(SimpleMetaSwapAdapter.InvalidApiSignature.selector);
        _redeem(delegation_, execution_);
    }

    function test_limitOrder_revertsBelowMinimumOutput() public {
        (Delegation memory delegation_, bytes memory execution_) = _buildOrder(
            tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, MIN_TOKEN_OUT - 1, block.timestamp + 5 minutes, apiSignerKey
        );

        vm.expectRevert(abi.encodeWithSelector(SimpleMetaSwapAdapter.InsufficientOutput.selector, MIN_TOKEN_OUT, MIN_TOKEN_OUT - 1));
        _redeem(delegation_, execution_);
    }

    function test_limitOrder_revertsReplay() public {
        (Delegation memory delegation_, bytes memory execution_) =
            _buildOrder(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, 200 ether, block.timestamp + 5 minutes, apiSignerKey);
        _redeem(delegation_, execution_);

        vm.expectRevert(MetaSwapLimitOrderEnforcer.DelegationAlreadyUsed.selector);
        _redeem(delegation_, execution_);
    }

    function test_limitOrder_revertsMalformedBatch() public {
        (Delegation memory delegation_, bytes memory execution_) =
            _buildOrder(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, 200 ether, block.timestamp + 5 minutes, apiSignerKey);
        Execution[] memory executions_ = abi.decode(execution_, (Execution[]));
        Execution[] memory oneExecution_ = new Execution[](1);
        oneExecution_[0] = executions_[0];

        vm.expectRevert(MetaSwapLimitOrderEnforcer.InvalidBatchLength.selector);
        _redeem(delegation_, ExecutionLib.encodeBatch(oneExecution_));
    }

    function test_gas_limitOrder_redeemDelegations() public {
        (Delegation memory delegation_, bytes memory execution_) =
            _buildOrder(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, 200 ether, block.timestamp + 5 minutes, apiSignerKey);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        uint256 snap_ = saveGasSnapshot();
        GasMeasurement memory measurement_ = measureManagerCall(
            address(delegationManager), automation, encodeRedeemCall(delegations_, ModeLib.encodeSimpleBatch(), execution_)
        );
        restoreGasSnapshot(snap_);
        logGasReport("simple-metaswap-limit-order | transfer+swap batch", measurement_);
    }

    function _buildOrder(
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _tokenInAmount,
        uint256 _minTokenOut,
        uint256 _actualTokenOut,
        uint256 _expiration,
        uint256 _signerKey
    )
        private
        returns (Delegation memory delegation_, bytes memory execution_)
    {
        MetaSwapLimitOrderEnforcer.Terms memory terms_ = MetaSwapLimitOrderEnforcer.Terms({
            adapter: address(adapter),
            tokenIn: address(_tokenIn),
            tokenOut: address(_tokenOut),
            tokenInAmount: _tokenInAmount,
            minTokenOut: _minTokenOut
        });
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(enforcer), terms: abi.encode(terms_), args: hex"" });
        delegation_ = signDelegation(
            users.alice,
            Delegation({
                delegate: automation,
                delegator: address(users.alice.deleGator),
                authority: ROOT_AUTHORITY,
                caveats: caveats_,
                salt: 77,
                signature: hex""
            })
        );

        SimpleMetaSwapAdapter.ApiQuote memory quote_ = _quote(_actualTokenOut, _expiration, _signerKey);
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(_tokenIn), value: 0, callData: abi.encodeCall(IERC20.transfer, (address(adapter), _tokenInAmount))
        });
        executions_[1] = Execution({
            target: address(adapter),
            value: 0,
            callData: abi.encodeCall(SimpleMetaSwapAdapter.swap, (_tokenIn, _tokenOut, _tokenInAmount, _minTokenOut, quote_))
        });
        execution_ = ExecutionLib.encodeBatch(executions_);
    }

    function _quote(
        uint256 _actualTokenOut,
        uint256 _expiration,
        uint256 _signerKey
    )
        private
        returns (SimpleMetaSwapAdapter.ApiQuote memory quote_)
    {
        quote_.apiData = abi.encode("mock-aggregator", abi.encode(_actualTokenOut));
        quote_.expiration = _expiration;
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(_signerKey, adapter.getQuoteDigest(quote_.apiData, _expiration));
        quote_.signature = abi.encodePacked(r_, s_, v_);
    }

    function _replaceSwapExecution(
        bytes memory _execution,
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _tokenInAmount,
        uint256 _minTokenOut,
        SimpleMetaSwapAdapter.ApiQuote memory _quoteData
    )
        private
        view
        returns (bytes memory)
    {
        Execution[] memory executions_ = abi.decode(_execution, (Execution[]));
        executions_[1].callData =
            abi.encodeCall(SimpleMetaSwapAdapter.swap, (_tokenIn, _tokenOut, _tokenInAmount, _minTokenOut, _quoteData));
        return ExecutionLib.encodeBatch(executions_);
    }

    function _redeem(Delegation memory _delegation, bytes memory _execution) private {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _delegation;
        bytes[] memory contexts_ = new bytes[](1);
        contexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleBatch();
        bytes[] memory executions_ = new bytes[](1);
        executions_[0] = _execution;

        vm.prank(automation);
        delegationManager.redeemDelegations(contexts_, modes_, executions_);
    }
}
