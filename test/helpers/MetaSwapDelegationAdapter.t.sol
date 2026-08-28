// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { NativeTokenTransferAmountEnforcer } from "../../src/enforcers/NativeTokenTransferAmountEnforcer.sol";
import { RedeemerEnforcer } from "../../src/enforcers/RedeemerEnforcer.sol";
import { MetaSwapDelegationAdapter } from "../../src/helpers/MetaSwapDelegationAdapter.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Caveat, Delegation } from "../../src/utils/Types.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { CaveatEnforcerBaseTest } from "../enforcers/CaveatEnforcerBaseTest.t.sol";

contract MetaSwapDelegationAdapterMock is IMetaSwap {
    using SafeERC20 for IERC20;

    bool internal pullInput = true;
    bool internal returnOneInput;
    bool internal usePayoutOverride;
    uint256 internal payoutOverride;

    receive() external payable { }

    function setBehavior(bool _pullInput, bool _returnOneInput, bool _usePayoutOverride, uint256 _payoutOverride) external {
        pullInput = _pullInput;
        returnOneInput = _returnOneInput;
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
            if (returnOneInput) {
                (bool success_,) = msg.sender.call{ value: 1 }("");
                require(success_, "native-refund-failed");
            }
        } else {
            require(msg.value == 0, "unexpected-value");
            if (pullInput) _tokenIn.safeTransferFrom(msg.sender, address(this), _amountIn);
            if (returnOneInput) _tokenIn.safeTransfer(msg.sender, 1);
        }

        uint256 payout_ = usePayoutOverride ? payoutOverride : quotedOutput_;
        if (address(tokenOut_) == address(0)) {
            (bool success_,) = msg.sender.call{ value: payout_ }("");
            require(success_, "native-payout-failed");
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

contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") { }

    function mint(address _recipient, uint256 _amount) external {
        _mint(_recipient, _amount);
    }

    function _update(address _from, address _to, uint256 _amount) internal override {
        if (_from == address(0) || _amount == 0) {
            super._update(_from, _to, _amount);
            return;
        }

        super._update(_from, _to, _amount - 1);
        super._update(_from, address(0), 1);
    }
}

contract RejectNativeTransfer {
    receive() external payable {
        revert();
    }
}

contract MetaSwapDelegationAdapterTest is CaveatEnforcerBaseTest {
    uint256 internal constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 internal constant MIN_TOKEN_OUT = 190 ether;
    uint256 internal constant ACTUAL_TOKEN_OUT = 200 ether;

    BasicERC20 internal tokenIn;
    BasicERC20 internal tokenOut;
    MetaSwapDelegationAdapterMock internal metaSwap;
    MetaSwapDelegationAdapter internal adapter;
    ERC20TransferAmountEnforcer internal erc20TransferEnforcer;
    NativeTokenTransferAmountEnforcer internal nativeTransferEnforcer;
    RedeemerEnforcer internal redeemerEnforcer;

    address internal apiSigner;
    uint256 internal apiSignerKey;
    address internal executor;

    function setUp() public override {
        super.setUp();

        tokenIn = new BasicERC20(address(this), "Token In", "TIN", 0);
        tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 0);
        metaSwap = new MetaSwapDelegationAdapterMock();
        erc20TransferEnforcer = new ERC20TransferAmountEnforcer();
        nativeTransferEnforcer = new NativeTokenTransferAmountEnforcer();
        redeemerEnforcer = new RedeemerEnforcer();
        (apiSigner, apiSignerKey) = makeAddrAndKey("api-signer");
        executor = makeAddr("executor");

        adapter = new MetaSwapDelegationAdapter(address(this), apiSigner, delegationManager, metaSwap);

        tokenIn.mint(address(users.alice.deleGator), TOKEN_IN_AMOUNT * 10);
        tokenOut.mint(address(metaSwap), ACTUAL_TOKEN_OUT * 20);
        vm.deal(address(users.alice.deleGator), TOKEN_IN_AMOUNT * 10);
        vm.deal(address(metaSwap), ACTUAL_TOKEN_OUT * 20);
    }

    receive() external payable { }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(erc20TransferEnforcer));
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert();
        new MetaSwapDelegationAdapter(address(0), apiSigner, delegationManager, metaSwap);

        vm.expectRevert(MetaSwapDelegationAdapter.InvalidZeroAddress.selector);
        new MetaSwapDelegationAdapter(address(this), address(0), delegationManager, metaSwap);

        vm.expectRevert(MetaSwapDelegationAdapter.InvalidZeroAddress.selector);
        new MetaSwapDelegationAdapter(address(this), apiSigner, IDelegationManager(address(0)), metaSwap);

        vm.expectRevert(MetaSwapDelegationAdapter.InvalidZeroAddress.selector);
        new MetaSwapDelegationAdapter(address(this), apiSigner, delegationManager, IMetaSwap(address(0)));
    }

    function test_swapRedeemsErc20AndPaysRootDelegator() public {
        Delegation[] memory delegations_ = _delegationChain(tokenIn, TOKEN_IN_AMOUNT, false, 1);
        MetaSwapDelegationAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.prank(executor);
        uint256 received_ = adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        assertEq(received_, ACTUAL_TOKEN_OUT);
        assertEq(tokenIn.balanceOf(address(users.alice.deleGator)), TOKEN_IN_AMOUNT * 9);
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), ACTUAL_TOKEN_OUT);
        assertEq(tokenOut.balanceOf(executor), 0);
        assertEq(tokenIn.balanceOf(address(adapter)), 0);
        assertEq(tokenIn.allowance(address(adapter), address(metaSwap)), 0);
    }

    function test_swapEmitsExecutionDetails() public {
        Delegation[] memory delegations_ = _delegationChain(tokenIn, TOKEN_IN_AMOUNT, false, 2);
        MetaSwapDelegationAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);
        bytes32 digest_ = keccak256(abi.encode(quote_.apiData, quote_.expiration, MIN_TOKEN_OUT));

        vm.expectEmit(true, true, true, true, address(adapter));
        emit MetaSwapDelegationAdapter.SwapExecuted(
            executor, address(users.alice.deleGator), tokenIn, tokenOut, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, digest_
        );
        vm.prank(executor);
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_swapRedeemsNativeInput() public {
        IERC20 nativeToken_ = IERC20(address(0));
        Delegation[] memory delegations_ = _delegationChain(nativeToken_, TOKEN_IN_AMOUNT, true, 3);
        MetaSwapDelegationAdapter.ApiQuote memory quote_ =
            _quote(nativeToken_, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);
        uint256 aliceBalanceBefore_ = address(users.alice.deleGator).balance;

        vm.prank(executor);
        adapter.swap(delegations_, nativeToken_, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        assertEq(aliceBalanceBefore_ - address(users.alice.deleGator).balance, TOKEN_IN_AMOUNT);
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), ACTUAL_TOKEN_OUT);
        assertEq(address(adapter).balance, 0);
    }

    function test_swapPaysNativeOutputToRootDelegator() public {
        IERC20 nativeToken_ = IERC20(address(0));
        Delegation[] memory delegations_ = _delegationChain(tokenIn, TOKEN_IN_AMOUNT, false, 4);
        MetaSwapDelegationAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, nativeToken_, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);
        uint256 aliceBalanceBefore_ = address(users.alice.deleGator).balance;

        vm.prank(executor);
        adapter.swap(delegations_, tokenIn, nativeToken_, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        assertEq(address(users.alice.deleGator).balance - aliceBalanceBefore_, ACTUAL_TOKEN_OUT);
        assertEq(address(adapter).balance, 0);
    }

    function test_swapPreservesPreexistingInputAndOutputDust() public {
        uint256 inputDust_ = 7 ether;
        uint256 outputDust_ = 11 ether;
        tokenIn.mint(address(adapter), inputDust_);
        tokenOut.mint(address(adapter), outputDust_);
        Delegation[] memory delegations_ = _delegationChain(tokenIn, TOKEN_IN_AMOUNT, false, 5);
        MetaSwapDelegationAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        assertEq(tokenIn.balanceOf(address(adapter)), inputDust_);
        assertEq(tokenOut.balanceOf(address(adapter)), outputDust_);
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), ACTUAL_TOKEN_OUT);
    }

    function test_swapRejectsInvalidDelegationLengths() public {
        Delegation[] memory empty_;
        MetaSwapDelegationAdapter.ApiQuote memory quote_;

        vm.expectRevert(MetaSwapDelegationAdapter.InvalidDelegationsLength.selector);
        adapter.swap(empty_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        Delegation[] memory fullChain_ = _delegationChain(tokenIn, TOKEN_IN_AMOUNT, false, 6);
        Delegation[] memory single_ = new Delegation[](1);
        single_[0] = fullChain_[1];

        vm.expectRevert(MetaSwapDelegationAdapter.InvalidDelegationsLength.selector);
        adapter.swap(single_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_swapRejectsZeroAmountsAndIdenticalTokens() public {
        Delegation[] memory delegations_ = _delegationChain(tokenIn, TOKEN_IN_AMOUNT, false, 7);
        MetaSwapDelegationAdapter.ApiQuote memory quote_;

        vm.expectRevert(MetaSwapDelegationAdapter.InvalidZeroAmount.selector);
        adapter.swap(delegations_, tokenIn, tokenOut, 0, MIN_TOKEN_OUT, quote_);

        vm.expectRevert(MetaSwapDelegationAdapter.InvalidZeroAmount.selector);
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, 0, quote_);

        vm.expectRevert(MetaSwapDelegationAdapter.IdenticalTokens.selector);
        adapter.swap(delegations_, tokenIn, tokenIn, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_swapRejectsExpiredAndInvalidSignatures() public {
        Delegation[] memory delegations_ = _delegationChain(tokenIn, TOKEN_IN_AMOUNT, false, 8);
        MetaSwapDelegationAdapter.ApiQuote memory expiredQuote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);
        vm.warp(expiredQuote_.expiration);

        vm.expectRevert(MetaSwapDelegationAdapter.ApiQuoteExpired.selector);
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, expiredQuote_);

        (, uint256 wrongKey_) = makeAddrAndKey("wrong-signer");
        MetaSwapDelegationAdapter.ApiQuote memory invalidQuote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, wrongKey_);

        vm.expectRevert(MetaSwapDelegationAdapter.InvalidApiSignature.selector);
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, invalidQuote_);
    }

    function test_swapCannotLowerSignedMinimumOutput() public {
        Delegation[] memory delegations_ = _delegationChain(tokenIn, TOKEN_IN_AMOUNT, false, 80);
        MetaSwapDelegationAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.expectRevert(MetaSwapDelegationAdapter.InvalidApiSignature.selector);
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT - 1, quote_);
    }

    function test_swapRejectsMalformedAndMismatchedApiData() public {
        Delegation[] memory delegations_ = _delegationChain(tokenIn, TOKEN_IN_AMOUNT, false, 9);
        MetaSwapDelegationAdapter.ApiQuote memory invalidSelector_ = _signedQuote(hex"deadbeef", MIN_TOKEN_OUT, apiSignerKey);

        vm.expectRevert(MetaSwapDelegationAdapter.InvalidApiData.selector);
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, invalidSelector_);

        BasicERC20 wrongToken_ = new BasicERC20(address(this), "Wrong", "WRONG", 0);
        MetaSwapDelegationAdapter.ApiQuote memory wrongOuterToken_ =
            _quote(wrongToken_, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.expectRevert(MetaSwapDelegationAdapter.TokenInMismatch.selector);
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, wrongOuterToken_);

        MetaSwapDelegationAdapter.ApiQuote memory wrongOuterAmount_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT - 1, TOKEN_IN_AMOUNT - 1, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.expectRevert(MetaSwapDelegationAdapter.AmountInMismatch.selector);
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, wrongOuterAmount_);
    }

    function test_swapRejectsInnerRouteMismatches() public {
        Delegation[] memory delegations_ = _delegationChain(tokenIn, TOKEN_IN_AMOUNT, false, 10);
        BasicERC20 wrongToken_ = new BasicERC20(address(this), "Wrong", "WRONG", 0);

        bytes memory wrongInputData_ = _swapData(wrongToken_, tokenOut, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false);
        MetaSwapDelegationAdapter.ApiQuote memory wrongInput_ =
            _signedQuote(_apiData(tokenIn, TOKEN_IN_AMOUNT, wrongInputData_), MIN_TOKEN_OUT, apiSignerKey);
        vm.expectRevert(MetaSwapDelegationAdapter.TokenInMismatch.selector);
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, wrongInput_);

        bytes memory wrongOutputData_ = _swapData(tokenIn, wrongToken_, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false);
        MetaSwapDelegationAdapter.ApiQuote memory wrongOutput_ =
            _signedQuote(_apiData(tokenIn, TOKEN_IN_AMOUNT, wrongOutputData_), MIN_TOKEN_OUT, apiSignerKey);
        vm.expectRevert(MetaSwapDelegationAdapter.TokenOutMismatch.selector);
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, wrongOutput_);

        MetaSwapDelegationAdapter.ApiQuote memory wrongFeeAccounting_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT - 2, ACTUAL_TOKEN_OUT, 1, false, apiSignerKey);
        vm.expectRevert(MetaSwapDelegationAdapter.AmountInMismatch.selector);
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, wrongFeeAccounting_);
    }

    function test_swapAllowsFeeFromOutput() public {
        Delegation[] memory delegations_ = _delegationChain(tokenIn, TOKEN_IN_AMOUNT, false, 11);
        MetaSwapDelegationAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT - 1, ACTUAL_TOKEN_OUT, 1, true, apiSignerKey);

        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), ACTUAL_TOKEN_OUT);
    }

    function test_swapRejectsQuotedOrActualOutputBelowMinimum() public {
        Delegation[] memory delegations_ = _delegationChain(tokenIn, TOKEN_IN_AMOUNT, false, 12);
        MetaSwapDelegationAdapter.ApiQuote memory lowQuote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT - 1, 0, false, apiSignerKey);

        vm.expectRevert(
            abi.encodeWithSelector(MetaSwapDelegationAdapter.InsufficientOutput.selector, MIN_TOKEN_OUT, MIN_TOKEN_OUT - 1)
        );
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, lowQuote_);

        metaSwap.setBehavior(true, false, true, MIN_TOKEN_OUT - 1);
        MetaSwapDelegationAdapter.ApiQuote memory validQuote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.expectRevert(
            abi.encodeWithSelector(MetaSwapDelegationAdapter.InsufficientOutput.selector, MIN_TOKEN_OUT, MIN_TOKEN_OUT - 1)
        );
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, validQuote_);
    }

    function test_swapRejectsFeeOnTransferInput() public {
        FeeOnTransferToken feeToken_ = new FeeOnTransferToken();
        feeToken_.mint(address(users.alice.deleGator), TOKEN_IN_AMOUNT);
        Delegation[] memory delegations_ = _delegationChain(feeToken_, TOKEN_IN_AMOUNT, false, 13);
        MetaSwapDelegationAdapter.ApiQuote memory quote_ =
            _quote(feeToken_, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.expectRevert(
            abi.encodeWithSelector(MetaSwapDelegationAdapter.IncorrectInputReceived.selector, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT - 1)
        );
        adapter.swap(delegations_, feeToken_, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_swapRejectsUnconsumedOrReturnedInput() public {
        Delegation[] memory delegations_ = _delegationChain(tokenIn, TOKEN_IN_AMOUNT, false, 14);
        MetaSwapDelegationAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        metaSwap.setBehavior(false, false, false, 0);
        vm.expectRevert(abi.encodeWithSelector(MetaSwapDelegationAdapter.RemainingAllowance.selector, TOKEN_IN_AMOUNT));
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        metaSwap.setBehavior(true, true, false, 0);
        vm.expectRevert(abi.encodeWithSelector(MetaSwapDelegationAdapter.RemainingInputBalance.selector, 1));
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_swapRejectsReplay() public {
        Delegation[] memory delegations_ = _delegationChain(tokenIn, TOKEN_IN_AMOUNT, false, 15);
        MetaSwapDelegationAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);

        vm.expectRevert("ERC20TransferAmountEnforcer:allowance-exceeded");
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_swapRejectsChainNotDelegatedToAdapter() public {
        Delegation[] memory delegations_ = _delegationChain(tokenIn, TOKEN_IN_AMOUNT, false, 16);
        delegations_[0].delegate = executor;
        delegations_[0] = signDelegation(users.bob, delegations_[0]);
        MetaSwapDelegationAdapter.ApiQuote memory quote_ =
            _quote(tokenIn, tokenOut, TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT, ACTUAL_TOKEN_OUT, 0, false, apiSignerKey);

        vm.expectRevert(IDelegationManager.InvalidDelegate.selector);
        adapter.swap(delegations_, tokenIn, tokenOut, TOKEN_IN_AMOUNT, MIN_TOKEN_OUT, quote_);
    }

    function test_withdrawRecoversErc20AndNative() public {
        address recipient_ = makeAddr("recipient");
        tokenIn.mint(address(adapter), TOKEN_IN_AMOUNT);
        vm.deal(address(adapter), TOKEN_IN_AMOUNT);

        adapter.withdraw(tokenIn, recipient_, TOKEN_IN_AMOUNT);
        adapter.withdraw(IERC20(address(0)), recipient_, TOKEN_IN_AMOUNT);

        assertEq(tokenIn.balanceOf(recipient_), TOKEN_IN_AMOUNT);
        assertEq(recipient_.balance, TOKEN_IN_AMOUNT);
    }

    function test_withdrawRejectsInvalidRecipientNonOwnerAndFailedNativeTransfer() public {
        vm.expectRevert(MetaSwapDelegationAdapter.InvalidZeroAddress.selector);
        adapter.withdraw(tokenIn, address(0), 1);

        vm.prank(executor);
        vm.expectRevert();
        adapter.withdraw(tokenIn, address(this), 1);

        RejectNativeTransfer recipient_ = new RejectNativeTransfer();
        vm.deal(address(adapter), 1);
        vm.expectRevert(abi.encodeWithSelector(MetaSwapDelegationAdapter.FailedNativeTokenTransfer.selector, address(recipient_)));
        adapter.withdraw(IERC20(address(0)), address(recipient_), 1);
    }

    function _delegationChain(
        IERC20 _token,
        uint256 _amount,
        bool _native,
        uint256 _salt
    )
        private
        view
        returns (Delegation[] memory delegations_)
    {
        address transferEnforcer_ = _native ? address(nativeTransferEnforcer) : address(erc20TransferEnforcer);
        bytes memory transferTerms_ = _native ? abi.encode(_amount) : abi.encodePacked(address(_token), _amount);

        Caveat[] memory rootCaveats_ = new Caveat[](2);
        rootCaveats_[0] = Caveat({ enforcer: transferEnforcer_, terms: transferTerms_, args: hex"" });
        rootCaveats_[1] = Caveat({ enforcer: address(redeemerEnforcer), terms: abi.encodePacked(address(adapter)), args: hex"" });

        Delegation memory root_ = signDelegation(
            users.alice,
            Delegation({
                delegate: address(users.bob.deleGator),
                delegator: address(users.alice.deleGator),
                authority: ROOT_AUTHORITY,
                caveats: rootCaveats_,
                salt: _salt,
                signature: hex""
            })
        );

        Caveat[] memory leafCaveats_ = new Caveat[](1);
        leafCaveats_[0] = Caveat({ enforcer: transferEnforcer_, terms: transferTerms_, args: hex"" });
        Delegation memory leaf_ = signDelegation(
            users.bob,
            Delegation({
                delegate: address(adapter),
                delegator: address(users.bob.deleGator),
                authority: EncoderLib._getDelegationHash(root_),
                caveats: leafCaveats_,
                salt: _salt,
                signature: hex""
            })
        );

        delegations_ = new Delegation[](2);
        delegations_[0] = leaf_;
        delegations_[1] = root_;
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
        returns (MetaSwapDelegationAdapter.ApiQuote memory)
    {
        bytes memory swapData_ = _swapData(_outerTokenIn, _innerTokenOut, _innerAmountIn, _quotedOutput, _fee, _feeFromOutput);
        return _signedQuote(_apiData(_outerTokenIn, _outerAmountIn, swapData_), MIN_TOKEN_OUT, _signerKey);
    }

    function _signedQuote(
        bytes memory _apiDataValue,
        uint256 _minTokenOut,
        uint256 _signerKey
    )
        private
        view
        returns (MetaSwapDelegationAdapter.ApiQuote memory quote_)
    {
        quote_.apiData = _apiDataValue;
        quote_.expiration = block.timestamp + 5 minutes;
        (uint8 v_, bytes32 r_, bytes32 s_) =
            vm.sign(_signerKey, adapter.getQuoteDigest(quote_.apiData, quote_.expiration, _minTokenOut));
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
}
