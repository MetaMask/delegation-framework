// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { MetaSwapPrefundEnforcer } from "../../src/enforcers/MetaSwapPrefundEnforcer.sol";
import { RedeemerEnforcer } from "../../src/enforcers/RedeemerEnforcer.sol";
import { MetaSwapForwardingAdapter } from "../../src/helpers/MetaSwapForwardingAdapter.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "../enforcers/CaveatEnforcerBaseTest.t.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

contract ForwardingMetaSwapMock is IMetaSwap {
    using SafeERC20 for IERC20;

    bool internal skipInputPull;
    bool internal refundInput;
    bool internal useOutputOverride;
    bool internal forceRevert;
    uint256 internal outputOverride;

    error MockSwapFailed();
    error InvalidValue();
    error NativeTransferFailed();

    receive() external payable { }

    function setBehavior(
        bool _skipInputPull,
        bool _refundInput,
        bool _useOutputOverride,
        uint256 _outputOverride,
        bool _forceRevert
    )
        external
    {
        skipInputPull = _skipInputPull;
        refundInput = _refundInput;
        useOutputOverride = _useOutputOverride;
        outputOverride = _outputOverride;
        forceRevert = _forceRevert;
    }

    function swap(string calldata, IERC20 _tokenIn, uint256 _amountIn, bytes calldata _swapData) external payable {
        if (forceRevert) revert MockSwapFailed();

        (IERC20 tokenOut_, uint256 quotedOutput_) = abi.decode(_swapData, (IERC20, uint256));

        if (address(_tokenIn) == address(0)) {
            if (msg.value != _amountIn) revert InvalidValue();
            if (refundInput) {
                (bool refundSuccess_,) = msg.sender.call{ value: 1 }("");
                if (!refundSuccess_) revert NativeTransferFailed();
            }
        } else {
            if (msg.value != 0) revert InvalidValue();
            if (!skipInputPull) _tokenIn.safeTransferFrom(msg.sender, address(this), _amountIn);
            if (refundInput) _tokenIn.safeTransfer(msg.sender, 1);
        }

        uint256 output_ = useOutputOverride ? outputOverride : quotedOutput_;
        if (address(tokenOut_) == address(0)) {
            (bool success_,) = msg.sender.call{ value: output_ }("");
            if (!success_) revert NativeTransferFailed();
        } else {
            tokenOut_.safeTransfer(msg.sender, output_);
        }
    }

    function setAdapter(string calldata, address, bytes4, bytes calldata) external { }
    function removeAdapter(string calldata) external { }

    function adapters(string memory) external pure returns (Adapter memory) {
        return Adapter({ addr: address(0), selector: bytes4(0), data: hex"" });
    }
}

contract MetaSwapForwardingAdapterTest is CaveatEnforcerBaseTest {
    uint256 internal constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 internal constant MIN_TOKEN_OUT = 190 ether;
    uint256 internal constant TOKEN_OUT_AMOUNT = 200 ether;

    BasicERC20 internal tokenIn;
    BasicERC20 internal tokenOut;
    ForwardingMetaSwapMock internal metaSwap;
    MetaSwapForwardingAdapter internal adapter;
    MetaSwapPrefundEnforcer internal enforcer;
    RedeemerEnforcer internal redeemerEnforcer;

    address internal automation;
    address internal apiSigner;
    uint256 internal apiSignerKey;

    function setUp() public override {
        super.setUp();

        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        metaSwap = new ForwardingMetaSwapMock();
        (apiSigner, apiSignerKey) = makeAddrAndKey("forwarding-api-signer");
        adapter = new MetaSwapForwardingAdapter(address(this), apiSigner, metaSwap);
        enforcer = new MetaSwapPrefundEnforcer(adapter);
        redeemerEnforcer = new RedeemerEnforcer();
        automation = makeAddr("forwarding-automation");

        tokenIn.mint(address(users.alice.deleGator), TOKEN_IN_AMOUNT);
        tokenOut.mint(address(metaSwap), 10_000 ether);
        vm.deal(address(metaSwap), 10_000 ether);
        vm.deal(address(users.alice.deleGator), TOKEN_IN_AMOUNT);
    }

    receive() external payable { }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }

    function test_adapterForwardsExactApiDataForErc20Input() public {
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        MetaSwapForwardingAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT, apiSignerKey);
        vm.expectCall(address(metaSwap), quote_.apiData);

        uint256 output_ = adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        assertEq(output_, TOKEN_OUT_AMOUNT);
        assertEq(tokenOut.balanceOf(address(this)), TOKEN_OUT_AMOUNT);
        assertEq(tokenIn.balanceOf(address(adapter)), 0);
        assertEq(tokenIn.allowance(address(adapter), address(metaSwap)), 0);
    }

    function test_adapterForwardsPrefundedNativeInput() public {
        IERC20 nativeToken_ = IERC20(address(0));
        vm.deal(address(adapter), TOKEN_IN_AMOUNT);
        MetaSwapForwardingAdapter.ApiQuote memory quote_ =
            _quote(nativeToken_, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT, apiSignerKey);
        vm.expectCall(address(metaSwap), quote_.apiData);

        adapter.swap(nativeToken_, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        assertEq(tokenOut.balanceOf(address(this)), TOKEN_OUT_AMOUNT);
        assertEq(address(adapter).balance, 0);
    }

    function test_adapterForwardsNativeOutput() public {
        IERC20 nativeToken_ = IERC20(address(0));
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        MetaSwapForwardingAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, nativeToken_, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT, apiSignerKey);
        uint256 balanceBefore_ = address(this).balance;

        adapter.swap(tokenIn, nativeToken_, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        assertEq(address(this).balance - balanceBefore_, TOKEN_OUT_AMOUNT);
    }

    function test_adapterRejectsInvalidApiSelector() public {
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        MetaSwapForwardingAdapter.ApiQuote memory quote_ =
            _signedQuote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, hex"deadbeef", apiSignerKey);

        vm.expectRevert(MetaSwapForwardingAdapter.InvalidApiData.selector);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterRejectsManifestTampering() public {
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        MetaSwapForwardingAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT, apiSignerKey);

        vm.expectRevert(MetaSwapForwardingAdapter.InvalidApiSignature.selector);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT - 1, quote_);
    }

    function test_adapterRejectsExpiredAndInvalidSignatures() public {
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        MetaSwapForwardingAdapter.ApiQuote memory expiredQuote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT, apiSignerKey);
        vm.warp(expiredQuote_.expiration);
        vm.expectRevert(MetaSwapForwardingAdapter.ApiQuoteExpired.selector);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, expiredQuote_);

        (, uint256 wrongSignerKey_) = makeAddrAndKey("wrong-forwarding-signer");
        MetaSwapForwardingAdapter.ApiQuote memory invalidQuote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT, wrongSignerKey_);
        vm.expectRevert(MetaSwapForwardingAdapter.InvalidApiSignature.selector);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, invalidQuote_);
    }

    function test_adapterRejectsInvalidInputState() public {
        MetaSwapForwardingAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT, apiSignerKey);

        vm.expectRevert(abi.encodeWithSelector(MetaSwapForwardingAdapter.UnexpectedInputBalance.selector, TOKEN_IN_AMOUNT, 0));
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        vm.expectRevert(MetaSwapForwardingAdapter.IdenticalTokens.selector);
        adapter.swap(tokenIn, tokenIn, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterRejectsInsufficientOutputAndResidualInput() public {
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        MetaSwapForwardingAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT, apiSignerKey);

        metaSwap.setBehavior(false, false, true, MIN_TOKEN_OUT - 1, false);
        vm.expectRevert(
            abi.encodeWithSelector(MetaSwapForwardingAdapter.InsufficientOutput.selector, MIN_TOKEN_OUT, MIN_TOKEN_OUT - 1)
        );
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        metaSwap.setBehavior(false, true, false, 0, false);
        vm.expectRevert(abi.encodeWithSelector(MetaSwapForwardingAdapter.RemainingInputBalance.selector, 1));
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterBubblesMetaSwapRevert() public {
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        MetaSwapForwardingAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT, apiSignerKey);
        metaSwap.setBehavior(false, false, false, 0, true);

        vm.expectRevert(ForwardingMetaSwapMock.MockSwapFailed.selector);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_enforcerAllowsErc20AndNativePrefundBatches() public {
        (bytes memory erc20Terms_, bytes memory erc20Execution_) =
            _order(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT);
        _beforeHook(erc20Terms_, batchDefaultMode, erc20Execution_, keccak256("erc20-prefund"));

        (bytes memory nativeTerms_, bytes memory nativeExecution_) =
            _order(IERC20(address(0)), tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT);
        _beforeHook(nativeTerms_, batchDefaultMode, nativeExecution_, keccak256("native-prefund"));
    }

    function test_enforcerRejectsWrongCallTypeAndBatchLength() public {
        (bytes memory terms_, bytes memory execution_) = _order(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT);

        vm.expectRevert(MetaSwapPrefundEnforcer.InvalidCallType.selector);
        _beforeHook(terms_, singleDefaultMode, execution_, keccak256("single"));

        Execution[] memory executions_ = abi.decode(execution_, (Execution[]));
        Execution[] memory shortBatch_ = new Execution[](1);
        shortBatch_[0] = executions_[0];
        vm.expectRevert(MetaSwapPrefundEnforcer.InvalidBatchLength.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(shortBatch_), keccak256("short"));
    }

    function test_enforcerRejectsMalformedErc20Prefund() public {
        (bytes memory terms_, bytes memory execution_) = _order(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT);
        Execution[] memory executions_ = abi.decode(execution_, (Execution[]));

        executions_[0].target = address(tokenOut);
        vm.expectRevert(MetaSwapPrefundEnforcer.InvalidPrefundCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("prefund-target"));

        executions_[0].target = address(tokenIn);
        executions_[0].callData = abi.encodeCall(IERC20.transfer, (address(adapter), TOKEN_IN_AMOUNT - 1));
        vm.expectRevert(MetaSwapPrefundEnforcer.InvalidPrefundCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("prefund-amount"));

        executions_[0].callData = abi.encodeCall(IERC20.approve, (address(adapter), TOKEN_IN_AMOUNT));
        vm.expectRevert(MetaSwapPrefundEnforcer.InvalidPrefundCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("prefund-selector"));
    }

    function test_enforcerRejectsMalformedNativePrefund() public {
        (bytes memory terms_, bytes memory execution_) =
            _order(IERC20(address(0)), tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT);
        Execution[] memory executions_ = abi.decode(execution_, (Execution[]));

        executions_[0].value = TOKEN_IN_AMOUNT - 1;
        vm.expectRevert(MetaSwapPrefundEnforcer.InvalidPrefundCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("native-value"));

        executions_[0].value = TOKEN_IN_AMOUNT;
        executions_[0].callData = hex"00";
        vm.expectRevert(MetaSwapPrefundEnforcer.InvalidPrefundCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("native-data"));
    }

    function test_enforcerRejectsMalformedSwapCall() public {
        (bytes memory terms_, bytes memory execution_) = _order(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT);
        Execution[] memory executions_ = abi.decode(execution_, (Execution[]));
        bytes memory validSwapCall_ = executions_[1].callData;

        executions_[1].target = address(metaSwap);
        vm.expectRevert(MetaSwapPrefundEnforcer.InvalidSwapCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("swap-target"));

        executions_[1].target = address(adapter);
        executions_[1].callData = abi.encodeCall(IERC20.transfer, (address(adapter), TOKEN_IN_AMOUNT));
        vm.expectRevert(MetaSwapPrefundEnforcer.InvalidSwapCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("swap-selector"));

        executions_[1].callData = validSwapCall_;
        executions_[1].value = 1;
        vm.expectRevert(MetaSwapPrefundEnforcer.InvalidSwapCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("swap-value"));
    }

    function test_enforcerRejectsSwapInputMismatch() public {
        (bytes memory terms_, bytes memory execution_) = _order(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT);
        Execution[] memory executions_ = abi.decode(execution_, (Execution[]));
        MetaSwapForwardingAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT, apiSignerKey);

        executions_[1].callData = abi.encodeCall(adapter.swap, (tokenOut, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_));
        vm.expectRevert(MetaSwapPrefundEnforcer.InvalidSwapCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("swap-token"));

        executions_[1].callData = abi.encodeCall(adapter.swap, (tokenIn, tokenOut, TOKEN_IN_AMOUNT - 1, MIN_TOKEN_OUT, quote_));
        vm.expectRevert(MetaSwapPrefundEnforcer.InvalidSwapCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("swap-amount"));
    }

    function test_enforcerRejectsReplay() public {
        (bytes memory terms_, bytes memory execution_) = _order(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT);
        bytes32 delegationHash_ = keccak256("prefund-replay");

        _beforeHook(terms_, batchDefaultMode, execution_, delegationHash_);
        vm.expectRevert(MetaSwapPrefundEnforcer.DelegationAlreadyUsed.selector);
        _beforeHook(terms_, batchDefaultMode, execution_, delegationHash_);
    }

    function test_integrationErc20PrefundAndForward() public {
        (Delegation memory delegation_, bytes memory execution_, bytes memory apiData_) = _delegation(tokenIn);
        vm.expectCall(address(metaSwap), apiData_);

        _redeem(delegation_, execution_, automation);

        assertEq(tokenIn.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), TOKEN_OUT_AMOUNT);
    }

    function test_integrationNativePrefundAndForward() public {
        (Delegation memory delegation_, bytes memory execution_, bytes memory apiData_) = _delegation(IERC20(address(0)));
        vm.expectCall(address(metaSwap), apiData_);

        _redeem(delegation_, execution_, automation);

        assertEq(address(adapter).balance, 0);
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), TOKEN_OUT_AMOUNT);
    }

    function test_integrationRejectsUnauthorizedRedeemer() public {
        (Delegation memory delegation_, bytes memory execution_,) = _delegationFor(ANY_DELEGATE, tokenIn);

        vm.expectRevert("RedeemerEnforcer:unauthorized-redeemer");
        _redeem(delegation_, execution_, users.bob.addr);
    }

    function _delegation(IERC20 _tokenIn)
        private
        view
        returns (Delegation memory delegation_, bytes memory execution_, bytes memory apiData_)
    {
        return _delegationFor(automation, _tokenIn);
    }

    function _delegationFor(
        address _delegate,
        IERC20 _tokenIn
    )
        private
        view
        returns (Delegation memory delegation_, bytes memory execution_, bytes memory apiData_)
    {
        (bytes memory terms_, bytes memory order_) = _order(_tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT);
        MetaSwapForwardingAdapter.ApiQuote memory quote_ =
            _quote(_tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, TOKEN_OUT_AMOUNT, apiSignerKey);

        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({ enforcer: address(enforcer), terms: terms_, args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(redeemerEnforcer), terms: abi.encodePacked(automation), args: hex"" });

        delegation_ = signDelegation(
            users.alice,
            Delegation({
                delegate: _delegate,
                delegator: address(users.alice.deleGator),
                authority: ROOT_AUTHORITY,
                caveats: caveats_,
                salt: 1,
                signature: hex""
            })
        );
        execution_ = order_;
        apiData_ = quote_.apiData;
    }

    function _order(
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _tokenInAmount,
        uint256 _minTokenOut,
        uint256 _tokenOutAmount
    )
        private
        view
        returns (bytes memory terms_, bytes memory execution_)
    {
        MetaSwapForwardingAdapter.ApiQuote memory quote_ =
            _quote(_tokenIn, _tokenOut, _tokenInAmount, _minTokenOut, _tokenOutAmount, apiSignerKey);

        terms_ = abi.encode(MetaSwapPrefundEnforcer.Terms({ tokenIn: address(_tokenIn), tokenInAmount: _tokenInAmount }));

        Execution[] memory executions_ = new Execution[](2);
        if (address(_tokenIn) == address(0)) {
            executions_[0] = Execution({ target: address(adapter), value: _tokenInAmount, callData: hex"" });
        } else {
            executions_[0] = Execution({
                target: address(_tokenIn), value: 0, callData: abi.encodeCall(IERC20.transfer, (address(adapter), _tokenInAmount))
            });
        }
        executions_[1] = Execution({
            target: address(adapter),
            value: 0,
            callData: abi.encodeCall(adapter.swap, (_tokenIn, _tokenOut, _tokenInAmount, _minTokenOut, quote_))
        });
        execution_ = ExecutionLib.encodeBatch(executions_);
    }

    function _quote(
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _tokenInAmount,
        uint256 _minTokenOut,
        uint256 _tokenOutAmount,
        uint256 _signerKey
    )
        private
        view
        returns (MetaSwapForwardingAdapter.ApiQuote memory quote_)
    {
        bytes memory apiData_ = abi.encodeCall(
            IMetaSwap.swap, ("forwarding-aggregator", _tokenIn, _tokenInAmount, abi.encode(_tokenOut, _tokenOutAmount))
        );
        quote_ = _signedQuote(_tokenIn, _tokenOut, _tokenInAmount, _minTokenOut, apiData_, _signerKey);
    }

    function _signedQuote(
        IERC20 _tokenIn,
        IERC20 _tokenOut,
        uint256 _tokenInAmount,
        uint256 _minTokenOut,
        bytes memory _apiData,
        uint256 _signerKey
    )
        private
        view
        returns (MetaSwapForwardingAdapter.ApiQuote memory quote_)
    {
        quote_.apiData = _apiData;
        quote_.expiration = block.timestamp + 5 minutes;
        bytes32 digest_ =
            adapter.getQuoteDigest(_tokenIn, _tokenOut, _tokenInAmount, _minTokenOut, quote_.apiData, quote_.expiration);
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(_signerKey, digest_);
        quote_.signature = abi.encodePacked(r_, s_, v_);
    }

    function _beforeHook(bytes memory _terms, ModeCode _mode, bytes memory _execution, bytes32 _hash) private {
        vm.prank(address(delegationManager));
        enforcer.beforeHook(_terms, hex"", _mode, _execution, _hash, address(users.alice.deleGator), address(0));
    }

    function _redeem(Delegation memory _delegationValue, bytes memory _execution, address _redeemer) private {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _delegationValue;
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
