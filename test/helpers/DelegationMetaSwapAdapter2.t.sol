// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { MetaSwapTransferSwapEnforcer } from "../../src/enforcers/MetaSwapTransferSwapEnforcer.sol";
import { RedeemerEnforcer } from "../../src/enforcers/RedeemerEnforcer.sol";
import { MetaSwapAdapter as DelegationMetaSwapAdapter2 } from "../../src/helpers/MetaSwapAdapter.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../src/utils/Types.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { CaveatEnforcerBaseTest } from "../enforcers/CaveatEnforcerBaseTest.t.sol";

contract MetaSwapAdapter2Mock is IMetaSwap {
    using SafeERC20 for IERC20;

    bool internal pullInput = true;
    bool internal returnInput;
    bool internal usePayoutOverride;
    uint256 internal payoutOverride;

    receive() external payable { }

    function setBehavior(bool _pullInput, bool _returnInput, bool _usePayoutOverride, uint256 _payoutOverride) external {
        pullInput = _pullInput;
        returnInput = _returnInput;
        usePayoutOverride = _usePayoutOverride;
        payoutOverride = _payoutOverride;
    }

    function swap(string calldata, IERC20 _tokenIn, uint256 _amountIn, bytes calldata _swapData) external payable {
        (,, IERC20 tokenOut_,, uint256 quotedOutput_,,,,) = abi.decode(
            abi.encodePacked(abi.encode(address(0)), _swapData),
            (address, IERC20, IERC20, uint256, uint256, bytes, uint256, address, bool)
        );

        if (address(_tokenIn) == address(0)) {
            require(msg.value == _amountIn, "invalid-native-input");
            if (returnInput) {
                (bool refundSuccess_,) = msg.sender.call{ value: 1 }("");
                require(refundSuccess_, "native-refund-failed");
            }
        } else {
            require(msg.value == 0, "unexpected-value");
            if (pullInput) _tokenIn.safeTransferFrom(msg.sender, address(this), _amountIn);
            if (returnInput) _tokenIn.safeTransfer(msg.sender, 1);
        }

        uint256 payout_ = usePayoutOverride ? payoutOverride : quotedOutput_;
        if (address(tokenOut_) == address(0)) {
            (bool payoutSuccess_,) = msg.sender.call{ value: payout_ }("");
            require(payoutSuccess_, "native-output-failed");
        } else {
            tokenOut_.safeTransfer(msg.sender, payout_);
        }
    }

    function setAdapter(string calldata, address, bytes4, bytes calldata) external { }
    function removeAdapter(string calldata) external { }

    function adapters(string memory) external pure returns (Adapter memory) {
        return Adapter({ addr: address(0), selector: bytes4(0), data: hex"" });
    }
}

contract RejectNativeRecipient {
    function execute(
        DelegationMetaSwapAdapter2 _adapter,
        IERC20 _tokenIn,
        uint256 _tokenInAmount,
        uint256 _minTokenOut,
        DelegationMetaSwapAdapter2.ApiQuote calldata _quote
    )
        external
    {
        _adapter.swap(_tokenIn, IERC20(address(0)), _tokenInAmount, _minTokenOut, _quote);
    }

    receive() external payable {
        revert();
    }
}

contract ZeroFirstERC20 is ERC20 {
    constructor() ERC20("Zero First", "ZERO") { }

    function mint(address _recipient, uint256 _amount) external {
        _mint(_recipient, _amount);
    }

    function seedAllowance(address _owner, address _spender, uint256 _amount) external {
        _approve(_owner, _spender, _amount);
    }

    function approve(address _spender, uint256 _amount) public override returns (bool) {
        require(_amount == 0 || allowance(msg.sender, _spender) == 0, "zero-first");
        return super.approve(_spender, _amount);
    }
}

contract MetaSwapAdapterTest is CaveatEnforcerBaseTest {
    uint256 internal constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 internal constant MIN_TOKEN_OUT = 190 ether;
    uint256 internal constant ACTUAL_TOKEN_OUT = 200 ether;

    BasicERC20 internal tokenIn;
    BasicERC20 internal tokenOut;
    MetaSwapAdapter2Mock internal metaSwap;
    DelegationMetaSwapAdapter2 internal adapter;
    MetaSwapTransferSwapEnforcer internal enforcer;
    RedeemerEnforcer internal redeemerEnforcer;

    address internal automation;
    address internal apiSigner;
    uint256 internal apiSignerKey;

    function setUp() public override {
        super.setUp();
        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        metaSwap = new MetaSwapAdapter2Mock();
        (apiSigner, apiSignerKey) = makeAddrAndKey("api-signer");
        adapter = new DelegationMetaSwapAdapter2(address(this), apiSigner, metaSwap);
        enforcer = new MetaSwapTransferSwapEnforcer();
        redeemerEnforcer = new RedeemerEnforcer();
        automation = makeAddr("metamask-automation");

        tokenIn.mint(address(users.alice.deleGator), TOKEN_IN_AMOUNT);
        tokenOut.mint(address(metaSwap), 10_000 ether);
        vm.deal(address(metaSwap), 10_000 ether);
    }

    receive() external payable { }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert();
        new DelegationMetaSwapAdapter2(address(0), apiSigner, metaSwap);

        vm.expectRevert(DelegationMetaSwapAdapter2.InvalidZeroAddress.selector);
        new DelegationMetaSwapAdapter2(address(this), address(0), metaSwap);

        vm.expectRevert(DelegationMetaSwapAdapter2.InvalidZeroAddress.selector);
        new DelegationMetaSwapAdapter2(address(this), apiSigner, IMetaSwap(address(0)));
    }

    function test_withdrawsErc20AndNativeTokens() public {
        address recipient_ = makeAddr("withdraw-recipient");
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        vm.deal(address(adapter), TOKEN_IN_AMOUNT);

        adapter.withdraw(tokenIn, recipient_, TOKEN_IN_AMOUNT);
        adapter.withdraw(IERC20(address(0)), recipient_, TOKEN_IN_AMOUNT);

        assertEq(tokenIn.balanceOf(recipient_), TOKEN_IN_AMOUNT);
        assertEq(recipient_.balance, TOKEN_IN_AMOUNT);
    }

    function test_withdrawRejectsZeroRecipientAndNonOwner() public {
        vm.expectRevert(DelegationMetaSwapAdapter2.InvalidZeroAddress.selector);
        adapter.withdraw(tokenIn, address(0), 1);

        vm.prank(makeAddr("not-owner"));
        vm.expectRevert();
        adapter.withdraw(tokenIn, address(this), 1);
    }

    function test_withdrawRevertsWhenRecipientRejectsNative() public {
        RejectNativeRecipient recipient_ = new RejectNativeRecipient();
        vm.deal(address(adapter), 1);

        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter2.FailedNativeTokenTransfer.selector, address(recipient_)));
        adapter.withdraw(IERC20(address(0)), address(recipient_), 1);
    }

    function test_adapterSwapHappyPath() public {
        tokenIn.mint(address(this), TOKEN_IN_AMOUNT);
        tokenIn.transfer(address(adapter), TOKEN_IN_AMOUNT);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        uint256 received_ = adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        assertEq(received_, ACTUAL_TOKEN_OUT);
        assertEq(tokenOut.balanceOf(address(this)), ACTUAL_TOKEN_OUT);
        assertEq(tokenIn.balanceOf(address(adapter)), 0);
        assertEq(tokenIn.allowance(address(adapter), address(metaSwap)), 0);
    }

    function test_adapterSwapsNativeInputForErc20() public {
        IERC20 nativeToken_ = IERC20(address(0));
        vm.deal(address(this), TOKEN_IN_AMOUNT);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(nativeToken_, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        uint256 received_ = adapter.swap{ value: TOKEN_IN_AMOUNT }(nativeToken_, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        assertEq(received_, ACTUAL_TOKEN_OUT);
        assertEq(tokenOut.balanceOf(address(this)), ACTUAL_TOKEN_OUT);
        assertEq(address(adapter).balance, 0);
    }

    function test_adapterSwapsNativeInputWithoutConsumingExistingDust() public {
        IERC20 nativeToken_ = IERC20(address(0));
        vm.deal(address(adapter), 1 ether);
        vm.deal(address(this), TOKEN_IN_AMOUNT);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(nativeToken_, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        adapter.swap{ value: TOKEN_IN_AMOUNT }(nativeToken_, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        assertEq(address(adapter).balance, 1 ether);
    }

    function test_adapterSwapsErc20InputForNative() public {
        IERC20 nativeToken_ = IERC20(address(0));
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, nativeToken_, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);
        uint256 nativeBefore_ = address(this).balance;

        uint256 received_ = adapter.swap(tokenIn, nativeToken_, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        assertEq(received_, ACTUAL_TOKEN_OUT);
        assertEq(address(this).balance - nativeBefore_, ACTUAL_TOKEN_OUT);
        assertEq(address(adapter).balance, 0);
    }

    function test_adapterRejectsIncorrectNativeValueAndUnexpectedErc20Value() public {
        IERC20 nativeToken_ = IERC20(address(0));
        vm.deal(address(this), TOKEN_IN_AMOUNT);
        DelegationMetaSwapAdapter2.ApiQuote memory nativeQuote_ =
            _quote(nativeToken_, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.expectRevert(
            abi.encodeWithSelector(DelegationMetaSwapAdapter2.InvalidValue.selector, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT - 1)
        );
        adapter.swap{ value: TOKEN_IN_AMOUNT - 1 }(nativeToken_, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, nativeQuote_);

        DelegationMetaSwapAdapter2.ApiQuote memory erc20Quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);
        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter2.InvalidValue.selector, 0, 1));
        adapter.swap{ value: 1 }(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, erc20Quote_);
    }

    function test_adapterRevertsWhenMetaSwapRefundsNativeInput() public {
        IERC20 nativeToken_ = IERC20(address(0));
        vm.deal(address(this), TOKEN_IN_AMOUNT);
        metaSwap.setBehavior(true, true, false, 0);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(nativeToken_, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter2.RemainingInputBalance.selector, 1));
        adapter.swap{ value: TOKEN_IN_AMOUNT }(nativeToken_, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterAllowsSignedQuoteReuse() public {
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        assertEq(tokenOut.balanceOf(address(this)), ACTUAL_TOKEN_OUT * 2);
    }

    function test_adapterRevertsWhenNativeRecipientRejectsOutput() public {
        IERC20 nativeToken_ = IERC20(address(0));
        RejectNativeRecipient recipient_ = new RejectNativeRecipient();
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, nativeToken_, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter2.FailedNativeTokenTransfer.selector, address(recipient_)));
        recipient_.execute(adapter, tokenIn, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterForceApproveHandlesZeroFirstToken() public {
        ZeroFirstERC20 zeroFirst_ = new ZeroFirstERC20();
        zeroFirst_.mint(address(adapter), TOKEN_IN_AMOUNT);
        zeroFirst_.seedAllowance(address(adapter), address(metaSwap), 1);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(zeroFirst_, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        adapter.swap(zeroFirst_, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        assertEq(zeroFirst_.balanceOf(address(adapter)), 0);
        assertEq(zeroFirst_.allowance(address(adapter), address(metaSwap)), 0);
        assertEq(tokenOut.balanceOf(address(this)), ACTUAL_TOKEN_OUT);
    }

    function test_adapterRevertsExpiredQuote() public {
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);
        vm.warp(quote_.expiration);

        vm.expectRevert(DelegationMetaSwapAdapter2.ApiQuoteExpired.selector);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterRevertsInvalidSignature() public {
        (, uint256 wrongKey_) = makeAddrAndKey("wrong-signer");
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, wrongKey_);

        vm.expectRevert(DelegationMetaSwapAdapter2.InvalidApiSignature.selector);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterRevertsZeroInputAmount() public {
        DelegationMetaSwapAdapter2.ApiQuote memory quote_;

        vm.expectRevert(DelegationMetaSwapAdapter2.InvalidZeroAmount.selector);
        adapter.swap(tokenIn, tokenOut, 0, MIN_TOKEN_OUT, quote_);

        vm.expectRevert(DelegationMetaSwapAdapter2.InvalidZeroAmount.selector);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, 0, quote_);
    }

    function test_adapterRevertsUnexpectedInputBalance() public {
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT + 1);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.expectRevert(
            abi.encodeWithSelector(DelegationMetaSwapAdapter2.UnexpectedInputBalance.selector, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT + 1)
        );
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterRevertsInvalidApiSelector() public {
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ = _signedQuote(hex"deadbeef", apiSignerKey);

        vm.expectRevert(DelegationMetaSwapAdapter2.InvalidApiData.selector);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterRevertsEmptyAggregatorId() public {
        bytes memory swapData_ = _swapData(tokenIn, tokenOut, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false);
        bytes memory apiData_ = abi.encodeWithSelector(IMetaSwap.swap.selector, "", tokenIn, TOKEN_IN_AMOUNT, swapData_);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ = _signedQuote(apiData_, apiSignerKey);

        vm.expectRevert(DelegationMetaSwapAdapter2.InvalidApiData.selector);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterRevertsOuterTokenMismatch() public {
        BasicERC20 wrongToken_ = new BasicERC20(address(this), "Wrong", "WRONG", 0);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(wrongToken_, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.expectRevert(DelegationMetaSwapAdapter2.TokenInMismatch.selector);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterRevertsOuterAmountMismatch() public {
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT - 1, TOKEN_IN_AMOUNT - 1, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.expectRevert(DelegationMetaSwapAdapter2.AmountInMismatch.selector);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterRevertsInnerTokenOutMismatch() public {
        BasicERC20 wrongToken_ = new BasicERC20(address(this), "Wrong", "WRONG", 0);
        bytes memory swapData_ = _swapData(tokenIn, wrongToken_, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _signedQuote(_apiData(tokenIn, TOKEN_IN_AMOUNT, swapData_), apiSignerKey);

        vm.expectRevert(DelegationMetaSwapAdapter2.TokenOutMismatch.selector);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterRevertsInnerTokenInMismatch() public {
        BasicERC20 wrongToken_ = new BasicERC20(address(this), "Wrong", "WRONG", 0);
        bytes memory swapData_ = _swapData(wrongToken_, tokenOut, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _signedQuote(_apiData(tokenIn, TOKEN_IN_AMOUNT, swapData_), apiSignerKey);

        vm.expectRevert(DelegationMetaSwapAdapter2.TokenInMismatch.selector);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterRevertsInputFeeMismatch() public {
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT - 2, ACTUAL_TOKEN_OUT, 1, false, apiSignerKey);

        vm.expectRevert(DelegationMetaSwapAdapter2.AmountInMismatch.selector);
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterAllowsFeeFromOutput() public {
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT - 2, ACTUAL_TOKEN_OUT, 1, true, apiSignerKey);

        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
        assertEq(tokenOut.balanceOf(address(this)), ACTUAL_TOKEN_OUT);
    }

    function test_adapterRevertsQuotedOutputBelowMinimum() public {
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT - 1, 0, false, apiSignerKey);

        vm.expectRevert(
            abi.encodeWithSelector(DelegationMetaSwapAdapter2.InsufficientOutput.selector, MIN_TOKEN_OUT, MIN_TOKEN_OUT - 1)
        );
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterRevertsActualOutputBelowMinimum() public {
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        metaSwap.setBehavior(true, false, true, MIN_TOKEN_OUT - 1);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.expectRevert(
            abi.encodeWithSelector(DelegationMetaSwapAdapter2.InsufficientOutput.selector, MIN_TOKEN_OUT, MIN_TOKEN_OUT - 1)
        );
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterRevertsRemainingAllowance() public {
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        metaSwap.setBehavior(false, false, false, 0);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter2.RemainingAllowance.selector, TOKEN_IN_AMOUNT));
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_adapterRevertsRemainingInputBalance() public {
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        metaSwap.setBehavior(true, true, false, 0);
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.expectRevert(abi.encodeWithSelector(DelegationMetaSwapAdapter2.RemainingInputBalance.selector, 1));
        adapter.swap(tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_enforcerRejectsInvalidBatchLength() public {
        (bytes memory terms_, bytes memory execution_) = _validOrder(MIN_TOKEN_OUT, ACTUAL_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(execution_, (Execution[]));
        Execution[] memory oneExecution_ = new Execution[](1);
        oneExecution_[0] = executions_[0];

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidBatchLength.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(oneExecution_), keccak256("test"), address(0), address(0)
        );
    }

    function test_enforcerTermsHelpers() public {
        MetaSwapTransferSwapEnforcer.Terms memory expected_ = MetaSwapTransferSwapEnforcer.Terms({
            adapter: address(adapter),
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            tokenInAmount: TOKEN_IN_AMOUNT,
            minTokenOut: MIN_TOKEN_OUT
        });

        bytes memory encoded_ = enforcer.encodeTerms(expected_);
        MetaSwapTransferSwapEnforcer.Terms memory decoded_ = enforcer.getTermsInfo(encoded_);

        assertEq(decoded_.adapter, expected_.adapter);
        assertEq(decoded_.tokenIn, expected_.tokenIn);
        assertEq(decoded_.tokenOut, expected_.tokenOut);
        assertEq(decoded_.tokenInAmount, expected_.tokenInAmount);
        assertEq(decoded_.minTokenOut, expected_.minTokenOut);
    }

    function test_enforcerRejectsInvalidTerms() public {
        (bytes memory terms_, bytes memory execution_) = _validOrder(MIN_TOKEN_OUT, ACTUAL_TOKEN_OUT);
        MetaSwapTransferSwapEnforcer.Terms memory termsData_ = abi.decode(terms_, (MetaSwapTransferSwapEnforcer.Terms));

        termsData_.adapter = address(0);
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidZeroAddress.selector);
        _beforeHook(abi.encode(termsData_), batchDefaultMode, execution_, keccak256("zero-adapter"));

        termsData_.adapter = address(adapter);
        termsData_.minTokenOut = 0;
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidZeroAmount.selector);
        _beforeHook(abi.encode(termsData_), batchDefaultMode, execution_, keccak256("zero-output"));

        termsData_.minTokenOut = MIN_TOKEN_OUT;
        termsData_.tokenOut = address(tokenIn);
        vm.expectRevert(MetaSwapTransferSwapEnforcer.IdenticalTokens.selector);
        _beforeHook(abi.encode(termsData_), batchDefaultMode, execution_, keccak256("identical"));
    }

    function test_enforcerRejectsTryExecutionMode() public {
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        _beforeHook(hex"", batchTryMode, hex"", keccak256("try-mode"));
    }

    function test_enforcerAllowsNativeInputSingleCall() public {
        (bytes memory terms_, bytes memory execution_) = _nativeInputOrder(TOKEN_IN_AMOUNT);
        _beforeHook(terms_, singleDefaultMode, execution_, keccak256("native-single"));
    }

    function test_enforcerRejectsWrongCallTypeForNativeAndErc20() public {
        (bytes memory nativeTerms_, bytes memory nativeExecution_) = _nativeInputOrder(TOKEN_IN_AMOUNT);
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidCallType.selector);
        _beforeHook(nativeTerms_, batchDefaultMode, nativeExecution_, keccak256("native-batch"));

        (bytes memory erc20Terms_, bytes memory erc20Execution_) = _validOrder(MIN_TOKEN_OUT, ACTUAL_TOKEN_OUT);
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidCallType.selector);
        _beforeHook(erc20Terms_, singleDefaultMode, erc20Execution_, keccak256("erc20-single"));
    }

    function test_enforcerRejectsWrongNativeExecutionValue() public {
        (bytes memory terms_, bytes memory execution_) = _nativeInputOrder(TOKEN_IN_AMOUNT - 1);
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidSwapCall.selector);
        _beforeHook(terms_, singleDefaultMode, execution_, keccak256("native-value"));
    }

    function test_enforcerRejectsZeroAmountTerms() public {
        (bytes memory terms_, bytes memory execution_) = _validOrder(MIN_TOKEN_OUT, ACTUAL_TOKEN_OUT);
        MetaSwapTransferSwapEnforcer.Terms memory termsData_ = abi.decode(terms_, (MetaSwapTransferSwapEnforcer.Terms));
        termsData_.tokenInAmount = 0;

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidZeroAmount.selector);
        enforcer.beforeHook(abi.encode(termsData_), hex"", batchDefaultMode, execution_, keccak256("test"), address(0), address(0));
    }

    function test_enforcerRejectsInvalidTransfer() public {
        (bytes memory terms_, bytes memory execution_) = _validOrder(MIN_TOKEN_OUT, ACTUAL_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(execution_, (Execution[]));
        executions_[0].callData = abi.encodeCall(IERC20.transfer, (address(adapter), TOKEN_IN_AMOUNT - 1));

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidTransferCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_enforcerRejectsMalformedTransferExecutions() public {
        (bytes memory terms_, bytes memory execution_) = _validOrder(MIN_TOKEN_OUT, ACTUAL_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(execution_, (Execution[]));

        executions_[0].target = address(tokenOut);
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidTransferCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("transfer-target"));

        executions_[0].target = address(tokenIn);
        executions_[0].value = 1;
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidTransferCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("transfer-value"));

        executions_[0].value = 0;
        executions_[0].callData = hex"1234";
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidTransferCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("transfer-length"));

        executions_[0].callData = abi.encodeCall(IERC20.approve, (address(adapter), TOKEN_IN_AMOUNT));
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidTransferCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("transfer-selector"));

        executions_[0].callData = abi.encodeCall(IERC20.transfer, (address(this), TOKEN_IN_AMOUNT));
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidTransferCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("transfer-recipient"));
    }

    function test_enforcerRejectsInvalidSwapBounds() public {
        (bytes memory terms_, bytes memory execution_) = _validOrder(MIN_TOKEN_OUT, ACTUAL_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(execution_, (Execution[]));
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);
        executions_[1].callData = abi.encodeCall(adapter.swap, (tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT - 1, quote_));

        vm.prank(address(delegationManager));
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidSwapCall.selector);
        enforcer.beforeHook(
            terms_, hex"", batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("test"), address(0), address(0)
        );
    }

    function test_enforcerRejectsMalformedSwapExecutions() public {
        (bytes memory terms_, bytes memory execution_) = _validOrder(MIN_TOKEN_OUT, ACTUAL_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(execution_, (Execution[]));
        bytes memory validCallData_ = executions_[1].callData;

        executions_[1].target = address(metaSwap);
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidSwapCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("swap-target"));

        executions_[1].target = address(adapter);
        executions_[1].value = 1;
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidSwapCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("swap-value"));

        executions_[1].value = 0;
        executions_[1].callData = hex"1234";
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidSwapCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("swap-length"));

        executions_[1].callData = abi.encodeCall(IERC20.transfer, (address(adapter), TOKEN_IN_AMOUNT));
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidSwapCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("swap-selector"));

        executions_[1].callData = validCallData_;
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("swap-valid"));
    }

    /// @notice Ensures the enforcer requires a complete canonical ABI head while leaving quote-body decoding to the adapter.
    function test_enforcerRejectsMalformedQuoteHead() public {
        (bytes memory terms_, bytes memory execution_) = _validOrder(MIN_TOKEN_OUT, ACTUAL_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(execution_, (Execution[]));

        executions_[1].callData = abi.encodePacked(
            adapter.swap.selector, abi.encode(address(tokenIn), address(tokenOut), TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, uint256(160))
        );
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidSwapCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("quote-truncated"));

        executions_[1].callData = abi.encodePacked(
            adapter.swap.selector,
            abi.encode(address(tokenIn), address(tokenOut), TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, uint256(0)),
            new bytes(96)
        );
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidSwapCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("quote-offset"));
    }

    function test_enforcerRejectsMismatchedSwapArguments() public {
        (bytes memory terms_, bytes memory execution_) = _validOrder(MIN_TOKEN_OUT, ACTUAL_TOKEN_OUT);
        Execution[] memory executions_ = abi.decode(execution_, (Execution[]));
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        executions_[1].callData = abi.encodeCall(adapter.swap, (tokenOut, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_));
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidSwapCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("swap-token-in"));

        executions_[1].callData = abi.encodeCall(adapter.swap, (tokenIn, tokenIn, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_));
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidSwapCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("swap-token-out"));

        executions_[1].callData = abi.encodeCall(adapter.swap, (tokenIn, tokenOut, TOKEN_IN_AMOUNT - 1, MIN_TOKEN_OUT, quote_));
        vm.expectRevert(MetaSwapTransferSwapEnforcer.InvalidSwapCall.selector);
        _beforeHook(terms_, batchDefaultMode, ExecutionLib.encodeBatch(executions_), keccak256("swap-amount"));
    }

    function test_integrationRevertsWhenAdapterUnderpays() public {
        (bytes memory terms_, bytes memory execution_) = _validOrder(MIN_TOKEN_OUT, ACTUAL_TOKEN_OUT);
        Delegation memory delegation_ = _buildDelegation(automation, terms_, 80);
        metaSwap.setBehavior(true, false, true, MIN_TOKEN_OUT - 1);

        vm.expectRevert(
            abi.encodeWithSelector(DelegationMetaSwapAdapter2.InsufficientOutput.selector, MIN_TOKEN_OUT, MIN_TOKEN_OUT - 1)
        );
        _redeem(delegation_, execution_, automation);
    }

    function test_integrationHappyPath() public {
        (Delegation memory delegation_, bytes memory execution_) = _delegation(automation);

        _redeem(delegation_, execution_, automation);

        assertEq(tokenIn.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), ACTUAL_TOKEN_OUT);
        assertEq(tokenIn.balanceOf(address(adapter)), 0);
        assertEq(tokenIn.allowance(address(adapter), address(metaSwap)), 0);
    }

    function test_integrationNativeInputHappyPath() public {
        (bytes memory terms_, bytes memory execution_) = _nativeInputOrder(TOKEN_IN_AMOUNT);
        Delegation memory delegation_ = _buildDelegation(automation, terms_, 78);
        vm.deal(address(users.alice.deleGator), TOKEN_IN_AMOUNT);

        _redeemWithMode(delegation_, execution_, automation, ModeLib.encodeSimpleSingle());

        assertEq(address(users.alice.deleGator).balance, 0);
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), ACTUAL_TOKEN_OUT);
    }

    function test_integrationNativeOutputHappyPath() public {
        (bytes memory terms_, bytes memory execution_) = _nativeOutputOrder();
        Delegation memory delegation_ = _buildDelegation(automation, terms_, 79);
        uint256 nativeBefore_ = address(users.alice.deleGator).balance;

        _redeemWithMode(delegation_, execution_, automation, ModeLib.encodeSimpleBatch());

        assertEq(tokenIn.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(address(users.alice.deleGator).balance - nativeBefore_, ACTUAL_TOKEN_OUT);
    }

    function test_integrationRejectsUnauthorizedRedeemer() public {
        (Delegation memory delegation_, bytes memory execution_) = _delegation(ANY_DELEGATE);

        vm.expectRevert("RedeemerEnforcer:unauthorized-redeemer");
        _redeem(delegation_, execution_, users.bob.addr);
    }

    function test_integrationRejectsReplay() public {
        (Delegation memory delegation_, bytes memory execution_) = _delegation(automation);
        _redeem(delegation_, execution_, automation);

        vm.expectRevert(MetaSwapTransferSwapEnforcer.DelegationAlreadyUsed.selector);
        _redeem(delegation_, execution_, automation);
    }

    function _delegation(address _delegate) private view returns (Delegation memory delegation_, bytes memory execution_) {
        (bytes memory terms_, bytes memory order_) = _validOrder(MIN_TOKEN_OUT, ACTUAL_TOKEN_OUT);
        delegation_ = _buildDelegation(_delegate, terms_, 77);
        execution_ = order_;
    }

    function _buildDelegation(
        address _delegate,
        bytes memory _terms,
        uint256 _salt
    )
        private
        view
        returns (Delegation memory delegation_)
    {
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({ enforcer: address(enforcer), terms: _terms, args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(redeemerEnforcer), terms: abi.encodePacked(automation), args: hex"" });

        delegation_ = signDelegation(
            users.alice,
            Delegation({
                delegate: _delegate,
                delegator: address(users.alice.deleGator),
                authority: ROOT_AUTHORITY,
                caveats: caveats_,
                salt: _salt,
                signature: hex""
            })
        );
    }

    function _validOrder(
        uint256 _minOutput,
        uint256 _quotedOutput
    )
        private
        view
        returns (bytes memory terms_, bytes memory execution_)
    {
        MetaSwapTransferSwapEnforcer.Terms memory termsData_ = MetaSwapTransferSwapEnforcer.Terms({
            adapter: address(adapter),
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            tokenInAmount: TOKEN_IN_AMOUNT,
            minTokenOut: MIN_TOKEN_OUT
        });
        terms_ = abi.encode(termsData_);

        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, _quotedOutput, 0, false, apiSignerKey);
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.transfer, (address(adapter), TOKEN_IN_AMOUNT))
        });
        executions_[1] = Execution({
            target: address(adapter),
            value: 0,
            callData: abi.encodeCall(adapter.swap, (tokenIn, tokenOut, TOKEN_IN_AMOUNT, _minOutput, quote_))
        });
        execution_ = ExecutionLib.encodeBatch(executions_);
    }

    function _nativeInputOrder(uint256 _executionValue) private view returns (bytes memory terms_, bytes memory execution_) {
        IERC20 nativeToken_ = IERC20(address(0));
        terms_ = abi.encode(
            MetaSwapTransferSwapEnforcer.Terms({
                adapter: address(adapter),
                tokenIn: address(0),
                tokenOut: address(tokenOut),
                tokenInAmount: TOKEN_IN_AMOUNT,
                minTokenOut: MIN_TOKEN_OUT
            })
        );
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(nativeToken_, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);
        execution_ = ExecutionLib.encodeSingle(
            address(adapter),
            _executionValue,
            abi.encodeCall(adapter.swap, (nativeToken_, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_))
        );
    }

    function _nativeOutputOrder() private view returns (bytes memory terms_, bytes memory execution_) {
        IERC20 nativeToken_ = IERC20(address(0));
        terms_ = abi.encode(
            MetaSwapTransferSwapEnforcer.Terms({
                adapter: address(adapter),
                tokenIn: address(tokenIn),
                tokenOut: address(0),
                tokenInAmount: TOKEN_IN_AMOUNT,
                minTokenOut: MIN_TOKEN_OUT
            })
        );
        DelegationMetaSwapAdapter2.ApiQuote memory quote_ =
            _quote(tokenIn, nativeToken_, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.transfer, (address(adapter), TOKEN_IN_AMOUNT))
        });
        executions_[1] = Execution({
            target: address(adapter),
            value: 0,
            callData: abi.encodeCall(adapter.swap, (tokenIn, nativeToken_, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_))
        });
        execution_ = ExecutionLib.encodeBatch(executions_);
    }

    function _beforeHook(bytes memory _terms, ModeCode _mode, bytes memory _execution, bytes32 _hash) private {
        vm.prank(address(delegationManager));
        enforcer.beforeHook(_terms, hex"", _mode, _execution, _hash, address(users.alice.deleGator), address(0));
    }

    function _quote(
        IERC20 _outerTokenIn,
        IERC20 _innerTokenOut,
        uint256 _outerAmountIn,
        uint256 _innerAmountIn,
        uint256 _quotedOutput,
        uint256 _fee,
        bool _feeFromOutput,
        uint256 _signerKey
    )
        private
        view
        returns (DelegationMetaSwapAdapter2.ApiQuote memory)
    {
        bytes memory swapData_ = _swapData(_outerTokenIn, _innerTokenOut, _innerAmountIn, _quotedOutput, _fee, _feeFromOutput);
        return _signedQuote(_apiData(_outerTokenIn, _outerAmountIn, swapData_), _signerKey);
    }

    function _signedQuote(
        bytes memory _apiDataValue,
        uint256 _signerKey
    )
        private
        view
        returns (DelegationMetaSwapAdapter2.ApiQuote memory quote_)
    {
        quote_.apiData = _apiDataValue;
        quote_.expiration = block.timestamp + 5 minutes;
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(_signerKey, adapter.getQuoteDigest(quote_.apiData, quote_.expiration));
        quote_.signature = abi.encodePacked(r_, s_, v_);
    }

    function _apiData(IERC20 _token, uint256 _amount, bytes memory _swapDataValue) private pure returns (bytes memory) {
        return abi.encodeWithSelector(IMetaSwap.swap.selector, "mock-aggregator", _token, _amount, _swapDataValue);
    }

    function _swapData(
        IERC20 _input,
        IERC20 _output,
        uint256 _amountIn,
        uint256 _amountOut,
        uint256 _fee,
        bool _feeFromOutput
    )
        private
        pure
        returns (bytes memory)
    {
        return abi.encode(_input, _output, _amountIn, _amountOut, hex"", _fee, address(0), _feeFromOutput);
    }

    function _redeem(Delegation memory _delegationValue, bytes memory _execution, address _redeemer) private {
        _redeemWithMode(_delegationValue, _execution, _redeemer, ModeLib.encodeSimpleBatch());
    }

    function _redeemWithMode(
        Delegation memory _delegationValue,
        bytes memory _execution,
        address _redeemer,
        ModeCode _mode
    )
        private
    {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _delegationValue;
        bytes[] memory contexts_ = new bytes[](1);
        contexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = _mode;
        bytes[] memory executions_ = new bytes[](1);
        executions_[0] = _execution;

        vm.prank(_redeemer);
        delegationManager.redeemDelegations(contexts_, modes_, executions_);
    }
}
