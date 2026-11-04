// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution } from "../../../src/utils/Types.sol";
import { NonceBitmap } from "../../../src/metaswap/final/NonceBitmap.sol";
import { Optimized1271Account, OptimizedHarness, ReentrantMetaSwapMock } from "../utils/OptimizedHarness.t.sol";

/**
 * @notice Security parity checklist, run unchanged against every variant through its adapter.
 * @dev Tests that only apply to some variants branch on the adapter's capability flags and assert what the
 *      variant actually does, so a weaker variant documents its gap instead of silently skipping.
 */
abstract contract OptimizedSecuritySuite is OptimizedHarness {
    /// @dev secp256k1 group order.
    uint256 private constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    ReentrantMetaSwapMock internal reentrantMetaSwap;
    Optimized1271Account internal account1271;
    Optimized1271Account internal otherAccount1271;

    modifier onlyExact() {
        if (!supportsExact) return;
        _;
    }

    modifier onlyLimit() {
        if (!supportsLimit) return;
        _;
    }

    function _setUpSuite() internal override {
        reentrantMetaSwap = new ReentrantMetaSwapMock();
        tokenOut.mint(address(reentrantMetaSwap), 100_000 ether);
        vm.deal(address(reentrantMetaSwap), 100_000 ether);

        account1271 = new Optimized1271Account();
        otherAccount1271 = new Optimized1271Account();
        tokenIn.mint(address(account1271), 1_000 ether);
        vm.deal(address(account1271), 1_000 ether);
        tokenIn.mint(address(otherAccount1271), 1_000 ether);
        vm.deal(address(otherAccount1271), 1_000 ether);
    }

    ////////////////////////////// Exact batch //////////////////////////////

    function test_exact_redeemsEveryShape() public onlyExact {
        for (uint256 i_; i_ < 4; ++i_) {
            ExactOrder memory order_ = _defaultExact(Shape(i_));
            order_.nonce = 10 + i_;
            _measure(_exactCall(order_), orderAlice, Shape(i_));
        }
    }

    function test_exact_rejectsReplay() public onlyExact {
        bytes memory data_ = _exactCall(_defaultExact(Shape.Erc20ToErc20));
        _redeemOk(data_);
        _redeemFails(data_);
        if (hasBitmap) assertTrue(NonceBitmap(manager).isExactBatchNonceUsed(orderAlice, DEFAULT_NONCE));
    }

    function test_exact_rejectsChangedBatchByte() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.Erc20ToErc20);
        bytes memory signature_ = _sign(order_.key, _exactDigest(manager, order_));
        bytes memory batch_ = order_.batch;
        batch_[batch_.length - 1] = bytes1(uint8(batch_[batch_.length - 1]) ^ 1);
        _redeemFails(_exactCalldata(manager, order_, signature_));
    }

    function test_exact_rejectsChangedTarget() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.NativeToErc20);
        bytes memory signature_ = _sign(order_.key, _exactDigest(manager, order_));
        order_.batch = ExecutionLib.encodeBatch(_executions(Shape.NativeToErc20, address(reentrantMetaSwap), TOKEN_OUT_AMOUNT));
        _redeemFails(_exactCalldata(manager, order_, signature_));
    }

    function test_exact_rejectsChangedValue() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.NativeToErc20);
        bytes memory signature_ = _sign(order_.key, _exactDigest(manager, order_));
        Execution[] memory executions_ = _executions(Shape.NativeToErc20, address(metaSwap), TOKEN_OUT_AMOUNT);
        executions_[0].value += 1;
        order_.batch = ExecutionLib.encodeBatch(executions_);
        _redeemFails(_exactCalldata(manager, order_, signature_));
    }

    function test_exact_rejectsWrongSigner() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.Erc20ToErc20);
        order_.key = WRONG_KEY;
        _redeemFails(_exactCall(order_));
    }

    function test_exact_rejectsWrongSignerOnCodelessEOA() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.Erc20ToErc20);
        order_.delegator = vm.addr(0xC0DE1E55);
        order_.key = WRONG_KEY;
        _redeemFails(_exactCall(order_));
    }

    function test_exact_rejectsZeroDelegator() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.Erc20ToErc20);
        order_.delegator = address(0);
        _redeemFails(_exactCalldata(manager, order_, new bytes(65)));
    }

    function test_exact_rejectsHighS() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.Erc20ToErc20);
        _redeemFails(_exactCalldata(manager, order_, _malleate(_sign(order_.key, _exactDigest(manager, order_)))));
    }

    function test_exact_rejectsBadV() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.Erc20ToErc20);
        bytes memory signature_ = _sign(order_.key, _exactDigest(manager, order_));
        signature_[64] = bytes1(uint8(29));
        _redeemFails(_exactCalldata(manager, order_, signature_));
    }

    function test_exact_rejectsNormalizedV() public onlyExact {
        // Wallets sometimes emit v in {0,1}; lib requires {27,28}.
        ExactOrder memory order_ = _defaultExact(Shape.Erc20ToErc20);
        bytes memory signature_ = _sign(order_.key, _exactDigest(manager, order_));
        signature_[64] = bytes1(uint8(uint8(signature_[64]) - 27));
        _redeemFails(_exactCalldata(manager, order_, signature_));
    }

    function test_exact_rejectsAllZeroSignature() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.Erc20ToErc20);
        _redeemFails(_exactCalldata(manager, order_, new bytes(65)));
    }

    function test_exact_malleationWouldPassRawEcrecover() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.Erc20ToErc20);
        bytes32 digest_ = _exactDigest(manager, order_);
        bytes memory good_ = _sign(order_.key, digest_);
        bytes memory bad_ = _malleate(good_);
        (bytes32 r_, bytes32 s_, uint8 v_) = _splitSig(bad_);
        assertEq(ecrecover(digest_, v_, r_, s_), order_.delegator, "raw ecrecover accepts malleation");
        _redeemFails(_exactCalldata(manager, order_, bad_));
    }

    function test_exact_rejectsOtherCaller() public onlyExact {
        bytes memory data_ = _exactCall(_defaultExact(Shape.Erc20ToErc20));
        if (openExactSubmission) {
            _redeemOkAs(signerA, data_);
        } else {
            _redeemFailsAs(signerA, data_);
        }
    }

    function test_exact_anyDelegateAllowsAnyCaller() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.Erc20ToErc20);
        order_.delegate = ANY;
        _redeemOkAs(signerA, _exactCall(order_));
    }

    function test_exact_rejectsCrossManagerReplay() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.NativeToErc20);
        bytes memory data_;
        if (supportsErc1271) {
            order_.delegator = address(account1271);
            data_ = _exactCalldata(manager, order_, abi.encodePacked(_exactDigest(manager, order_)));
        } else {
            data_ = _exactCall(order_);
        }
        address otherManager_ = _deployManager();
        vm.prank(relayer);
        (bool success_,) = otherManager_.call(data_);
        assertFalse(success_, "replayed on another manager");
        _redeemOk(data_);
    }

    function test_exact_rejectsSignatureForOtherAccount() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.NativeToErc20);
        bytes memory signature_;
        if (supportsErc1271) {
            order_.delegator = address(account1271);
            signature_ = abi.encodePacked(_exactDigest(manager, order_));
            order_.delegator = address(otherAccount1271);
        } else {
            signature_ = _sign(ORDER_ALICE_KEY, _exactDigest(manager, order_));
            order_.delegator = signerA;
        }
        _redeemFails(_exactCalldata(manager, order_, signature_));
    }

    function test_exact_cancelBlocksRedemption() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.Erc20ToErc20);
        _cancelExact(order_);
        _redeemFails(_exactCall(order_));
    }

    function test_exact_siblingWithSameNonce() public onlyExact {
        ExactOrder memory first_ = _defaultExact(Shape.Erc20ToErc20);
        ExactOrder memory sibling_ = _defaultExact(Shape.NativeToErc20);
        _redeemOk(_exactCall(first_));
        (bool success_,) = _callAs(relayer, _exactCall(sibling_));
        // Hash one-shots only stop the same batch. The bitmap stops every order that shares the nonce.
        assertEq(success_, !hasBitmap);
    }

    function test_exact_erc1271Fallback() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.NativeToErc20);
        order_.delegator = address(account1271);
        bytes memory data_ = _exactCalldata(manager, order_, abi.encodePacked(_exactDigest(manager, order_)));
        if (supportsErc1271) {
            uint256 before_ = tokenOut.balanceOf(address(account1271));
            _redeemOk(data_);
            assertEq(tokenOut.balanceOf(address(account1271)), before_ + TOKEN_OUT_AMOUNT);
        } else {
            // Final managers are 7702 EOA / ECDSA only.
            _redeemFails(data_);
        }
    }

    function test_exact_rejectsInvalidErc1271() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.NativeToErc20);
        order_.delegator = address(account1271);
        bytes32 digest_ = _exactDigest(manager, order_);
        _redeemFails(_exactCalldata(manager, order_, abi.encodePacked(bytes32(uint256(digest_) ^ 1))));
    }

    function test_exact_rollsBackOnFailedExecution() public onlyExact {
        bytes memory data_ = _exactCall(_defaultExact(Shape.Erc20ToErc20));
        deal(address(tokenOut), address(metaSwap), 0);
        _redeemFails(data_);
        deal(address(tokenOut), address(metaSwap), 100_000 ether);
        _redeemOk(data_);
    }

    function test_exact_reentrantReplayRejected() public onlyExact {
        ExactOrder memory order_ = _defaultExact(Shape.NativeToErc20);
        order_.delegate = ANY;
        order_.batch = ExecutionLib.encodeBatch(_executions(Shape.NativeToErc20, address(reentrantMetaSwap), TOKEN_OUT_AMOUNT));
        bytes memory data_ = _exactCall(order_);
        reentrantMetaSwap.setReentry(manager, data_);
        _redeemOk(data_);
        assertTrue(reentrantMetaSwap.reentryAttempted());
        assertFalse(reentrantMetaSwap.reentrySucceeded());
    }

    /// @dev Without a lock, an exact batch nested in a limit order's route is counted toward its minimum output.
    function test_exact_nestedInsideLimitOrder() public onlyExact onlyLimit {
        ExactOrder memory inner_ = _defaultExact(Shape.NativeToErc20);
        inner_.delegate = ANY;
        inner_.nonce = 2;
        reentrantMetaSwap.setReentry(manager, _exactCall(inner_));

        (bool success_,) = _callAs(relayer, _limitCall(_unpaidLimitOrderOnReentrantMock()));
        _assertNestedFillOutcome(success_);
    }

    ////////////////////////////// Limit order //////////////////////////////

    function test_limit_redeemsEveryShape() public onlyLimit {
        for (uint256 i_; i_ < 4; ++i_) {
            LimitParams memory params_ = _defaultLimit(Shape(i_));
            params_.nonce = 10 + i_;
            _measure(_limitCall(params_), orderAlice, Shape(i_));
        }
    }

    function test_limit_skipApproval() public onlyLimit {
        vm.prank(orderAlice);
        tokenIn.approve(address(metaSwap), TOKEN_IN_AMOUNT);
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.approvalMode = 1;
        Execution[] memory executions_ = new Execution[](1);
        executions_[0] = _swap(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, 0, address(tokenOut), TOKEN_OUT_AMOUNT);
        params_.batch = ExecutionLib.encodeBatch(executions_);
        _redeemOk(_limitCall(params_));
    }

    function test_limit_acceptsRelayerChosenRoute() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        bytes memory signature_ = _sign(params_.key, _limitDigest(manager, params_));
        routeData = hex"deadbeef";
        params_.batch = ExecutionLib.encodeBatch(_executions(Shape.Erc20ToErc20, address(metaSwap), TOKEN_OUT_MIN));
        _redeemOk(_limitCalldata(manager, params_, signature_));
    }

    function test_limit_rollsBackOnInsufficientOutput() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.batch = ExecutionLib.encodeBatch(_executions(Shape.Erc20ToErc20, address(metaSwap), TOKEN_OUT_MIN - 1));
        _redeemFails(_limitCall(params_));
        params_.batch = ExecutionLib.encodeBatch(_executions(Shape.Erc20ToErc20, address(metaSwap), TOKEN_OUT_MIN));
        _redeemOk(_limitCall(params_));
    }

    function test_limit_rejectsReplay() public onlyLimit {
        bytes memory data_ = _limitCall(_defaultLimit(Shape.Erc20ToErc20));
        _redeemOk(data_);
        _redeemFails(data_);
        if (hasBitmap) assertTrue(NonceBitmap(manager).isLimitOrderNonceUsed(orderAlice, DEFAULT_NONCE));
    }

    /// @dev Exact and limit bitmaps are independent: the same numeric nonce can be used once in each flow.
    function test_exactAndLimit_sameNonceIndependent() public {
        if (!supportsExact || !supportsLimit || !hasBitmap) return;
        ExactOrder memory exact_ = _defaultExact(Shape.Erc20ToErc20);
        exact_.nonce = DEFAULT_NONCE;
        LimitParams memory limit_ = _defaultLimit(Shape.Erc20ToErc20);
        limit_.nonce = DEFAULT_NONCE;
        _redeemOk(_exactCall(exact_));
        _redeemOk(_limitCall(limit_));
        assertTrue(NonceBitmap(manager).isExactBatchNonceUsed(orderAlice, DEFAULT_NONCE));
        assertTrue(NonceBitmap(manager).isLimitOrderNonceUsed(orderAlice, DEFAULT_NONCE));
    }

    function test_limit_rejectsSiblingWithSameNonce() public onlyLimit {
        LimitParams memory first_ = _defaultLimit(Shape.Erc20ToErc20);
        LimitParams memory sibling_ = _defaultLimit(Shape.Erc20ToErc20);
        sibling_.tokenOutMin = TOKEN_OUT_MIN - 1;
        _redeemOk(_limitCall(first_));
        _redeemFails(_limitCall(sibling_));
    }

    function test_limit_cancelBlocksRedemption() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        _cancelLimit(params_);
        _redeemFails(_limitCall(params_));
    }

    function test_limit_validAfterIsExclusive() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.validAfter = uint128(block.timestamp + 100);
        bytes memory data_ = _limitCall(params_);
        _redeemFails(data_);
        vm.warp(params_.validAfter);
        _redeemFails(data_);
        vm.warp(params_.validAfter + 1);
        _redeemOk(data_);
    }

    function test_limit_validUntilIsExclusive() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.validUntil = uint128(block.timestamp + 100);
        bytes memory data_ = _limitCall(params_);
        vm.warp(params_.validUntil);
        _redeemFails(data_);
        vm.warp(params_.validUntil - 1);
        _redeemOk(data_);
    }

    function test_limit_zeroBoundsAreOpen() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.validUntil = 0;
        bytes memory data_ = _limitCall(params_);
        vm.warp(block.timestamp + 3650 days);
        _redeemOk(data_);
    }

    function test_limit_rejectsUnlistedRedeemer() public onlyLimit {
        _redeemFailsAs(makeAddr("Stranger"), _limitCall(_defaultLimit(Shape.Erc20ToErc20)));
    }

    function test_limit_allowsZeroAddressRedeemer() public onlyLimit {
        _redeemOkAs(address(0), _limitCall(_defaultLimit(Shape.Erc20ToErc20)));
    }

    function test_limit_zeroAddressEntryDoesNotAuthorizeOthers() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.redeemers = new address[](1);
        _redeemFails(_limitCall(params_));
    }

    function test_limit_rejectsEmptyRedeemers() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.redeemers = new address[](0);
        _redeemFails(_limitCall(params_));
    }

    function test_limit_specificDelegateStillApplies() public onlyLimit {
        if (!signsDelegate) return;
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.delegate = signerA;
        bytes memory data_ = _limitCall(params_);
        _redeemFails(data_);
        _redeemOkAs(signerA, data_);
    }

    function test_limit_outputMustReachRecipient() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.recipient = signerB;
        _redeemFails(_limitCall(params_));
    }

    function test_limit_rejectsBadApprovalShapes() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        Execution memory swap_ = _swap(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, 0, address(tokenOut), TOKEN_OUT_AMOUNT);

        _expectBatchFails(params_, _pair(_approval(signerA, TOKEN_IN_AMOUNT), swap_));
        _expectBatchFails(params_, _pair(_approval(address(metaSwap), TOKEN_IN_AMOUNT - 1), swap_));
        _expectBatchFails(params_, _pair(_approval(address(metaSwap), TOKEN_IN_AMOUNT), _approval(address(metaSwap), 0)));

        Execution[] memory extra_ = new Execution[](3);
        extra_[0] = _approval(address(metaSwap), TOKEN_IN_AMOUNT);
        extra_[1] = swap_;
        extra_[2] = swap_;
        _expectBatchFails(params_, extra_);

        Execution[] memory swapOnly_ = new Execution[](1);
        swapOnly_[0] = swap_;
        _expectBatchFails(params_, swapOnly_);
    }

    function test_limit_rejectsBadResetShape() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20Reset);
        Execution[] memory executions_ = _executions(Shape.Erc20Reset, address(metaSwap), TOKEN_OUT_AMOUNT);
        executions_[0] = _approval(address(metaSwap), 1);
        _expectBatchFails(params_, executions_);
    }

    function test_limit_rejectsBadSwaps() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        Execution memory approval_ = _approval(address(metaSwap), TOKEN_IN_AMOUNT);

        _expectBatchFails(
            params_,
            _pair(
                approval_,
                _swap(address(reentrantMetaSwap), address(tokenIn), TOKEN_IN_AMOUNT, 0, address(tokenOut), TOKEN_OUT_AMOUNT)
            )
        );
        _expectBatchFails(
            params_,
            _pair(
                approval_, _swap(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT - 1, 0, address(tokenOut), TOKEN_OUT_AMOUNT)
            )
        );
        _expectBatchFails(
            params_,
            _pair(approval_, _swap(address(metaSwap), address(tokenOut), TOKEN_IN_AMOUNT, 0, address(tokenOut), TOKEN_OUT_AMOUNT))
        );
        _expectBatchFails(
            params_,
            _pair(approval_, _swap(address(metaSwap), address(tokenIn), TOKEN_IN_AMOUNT, 1, address(tokenOut), TOKEN_OUT_AMOUNT))
        );
        _expectBatchFails(
            params_,
            _pair(
                approval_,
                Execution({ target: address(metaSwap), value: 0, callData: abi.encodeCall(IERC20.approve, (relayer, 1)) })
            )
        );
    }

    function test_limit_rejectsNativeSwapWithWrongValue() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.NativeToErc20);
        Execution[] memory executions_ = new Execution[](1);
        executions_[0] =
            _swap(address(metaSwap), address(0), TOKEN_IN_AMOUNT, TOKEN_IN_AMOUNT - 1, address(tokenOut), TOKEN_OUT_AMOUNT);
        _expectBatchFails(params_, executions_);
    }

    function test_limit_rejectsInvalidTerms() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.tokenOutMin = 0;
        _redeemFails(_limitCall(params_));

        params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.recipient = address(0);
        _redeemFails(_limitCall(params_));

        params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.tokenIn = address(tokenOut);
        _redeemFails(_limitCall(params_));

        params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.approvalMode = 4;
        _redeemFails(_limitCall(params_));

        params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.approvalMode = 0;
        _redeemFails(_limitCall(params_));

        params_ = _defaultLimit(Shape.NativeToErc20);
        params_.approvalMode = 2;
        _redeemFails(_limitCall(params_));
    }

    function test_limit_rejectsWrongSigner() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.key = WRONG_KEY;
        _redeemFails(_limitCall(params_));
    }

    function test_limit_rejectsHighS() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        _redeemFails(_limitCalldata(manager, params_, _malleate(_sign(params_.key, _limitDigest(manager, params_)))));
    }

    function test_limit_rejectsBadV() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        bytes memory signature_ = _sign(params_.key, _limitDigest(manager, params_));
        signature_[64] = bytes1(uint8(29));
        _redeemFails(_limitCalldata(manager, params_, signature_));
    }

    function test_limit_rejectsZeroDelegator() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.delegator = address(0);
        _redeemFails(_limitCalldata(manager, params_, new bytes(65)));
    }

    function test_limit_rejectsAllZeroSignature() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        _redeemFails(_limitCalldata(manager, params_, new bytes(65)));
    }

    function test_limit_rejectsSignatureForOtherAccount() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        bytes memory signature_ = _sign(ORDER_ALICE_KEY, _limitDigest(manager, params_));
        params_.delegator = signerA;
        _redeemFails(_limitCalldata(manager, params_, signature_));
    }

    function test_limit_erc1271Fallback() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.NativeToErc20);
        params_.delegator = address(account1271);
        params_.recipient = address(account1271);
        bytes memory data_ = _limitCalldata(manager, params_, abi.encodePacked(_limitDigest(manager, params_)));
        if (supportsErc1271) {
            _redeemOk(data_);
            assertEq(tokenOut.balanceOf(address(account1271)), TOKEN_OUT_AMOUNT);
        } else {
            _redeemFails(data_);
        }
    }

    function test_limit_rejectsCrossManagerReplay() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.NativeToErc20);
        bytes memory data_;
        if (supportsErc1271) {
            params_.delegator = address(account1271);
            params_.recipient = address(account1271);
            data_ = _limitCalldata(manager, params_, abi.encodePacked(_limitDigest(manager, params_)));
        } else {
            data_ = _limitCall(params_);
        }
        address otherManager_ = _deployManager();
        vm.prank(relayer);
        (bool success_,) = otherManager_.call(data_);
        assertFalse(success_, "replayed on another manager");
        _redeemOk(data_);
    }

    function test_limit_reentrantReplayRejected() public onlyLimit {
        LimitParams memory params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.metaSwap = address(reentrantMetaSwap);
        params_.redeemers[0] = address(reentrantMetaSwap);
        params_.batch = ExecutionLib.encodeBatch(_executions(Shape.Erc20ToErc20, address(reentrantMetaSwap), TOKEN_OUT_AMOUNT));
        bytes memory data_ = _limitCall(params_);
        reentrantMetaSwap.setReentry(manager, data_);
        _redeemOk(data_);
        assertTrue(reentrantMetaSwap.reentryAttempted());
        assertFalse(reentrantMetaSwap.reentrySucceeded());
    }

    /// @dev Without a lock, a sibling fill nested in the route is counted toward the outer order's minimum.
    function test_limit_nestedFillAcrossOrders() public onlyLimit {
        LimitParams memory inner_ = _defaultLimit(Shape.NativeToErc20);
        inner_.nonce = 2;
        inner_.redeemers = new address[](1);
        inner_.redeemers[0] = address(reentrantMetaSwap);
        reentrantMetaSwap.setReentry(manager, _limitCall(inner_));

        (bool success_,) = _callAs(relayer, _limitCall(_unpaidLimitOrderOnReentrantMock()));
        _assertNestedFillOutcome(success_);
    }

    ////////////////////////////// Helpers //////////////////////////////

    /// @dev Token-in/token-out order routed through the reentrant mock, which pays nothing for it.
    function _unpaidLimitOrderOnReentrantMock() internal view returns (LimitParams memory params_) {
        params_ = _defaultLimit(Shape.Erc20ToErc20);
        params_.metaSwap = address(reentrantMetaSwap);
        params_.batch = ExecutionLib.encodeBatch(_executions(Shape.Erc20ToErc20, address(reentrantMetaSwap), 0));
    }

    function _assertNestedFillOutcome(bool outerSucceeded_) internal {
        if (hasLock) {
            assertFalse(outerSucceeded_, "nested fill must not satisfy the outer order");
        } else {
            // Documents the gap: the inner fill's output paid for the outer order too.
            assertTrue(outerSucceeded_);
            assertTrue(reentrantMetaSwap.reentrySucceeded());
        }
    }

    function _expectBatchFails(LimitParams memory params_, Execution[] memory executions_) internal {
        bytes memory original_ = params_.batch;
        params_.batch = ExecutionLib.encodeBatch(executions_);
        _redeemFails(_limitCall(params_));
        params_.batch = original_;
    }

    function _pair(Execution memory first_, Execution memory second_) internal pure returns (Execution[] memory executions_) {
        executions_ = new Execution[](2);
        executions_[0] = first_;
        executions_[1] = second_;
    }

    /// @dev Same signer, `s' = n - s` and the flipped `v`: valid for raw `ecrecover`, rejected by the low-s rule.
    function _malleate(bytes memory signature_) internal pure returns (bytes memory) {
        bytes32 r_;
        bytes32 s_;
        uint8 v_ = uint8(signature_[64]);
        assembly {
            r_ := mload(add(signature_, 0x20))
            s_ := mload(add(signature_, 0x40))
        }
        return abi.encodePacked(r_, bytes32(SECP256K1_N - uint256(s_)), v_ == 27 ? uint8(28) : uint8(27));
    }

    function _splitSig(bytes memory signature_) internal pure returns (bytes32 r_, bytes32 s_, uint8 v_) {
        v_ = uint8(signature_[64]);
        assembly {
            r_ := mload(add(signature_, 0x20))
            s_ := mload(add(signature_, 0x40))
        }
    }
}

/**
 * @notice Bounds checks for packed calldata entries (Optimized manager).
 */
abstract contract OptimizedPackedParsingSuite is OptimizedHarness {
    /// @dev Absolute calldata offset where the signature starts in an exact batch (`SIGNATURE_EXACT_OFFSET`).
    uint256 internal constant EXACT_SIGNATURE_OFFSET = 56;
    /// @dev When true, wire is `sigLength(2) | sig`. Optimized / DirectRoute use a fixed 65-byte ECDSA signature.
    bool internal usesLengthPrefixedSignature = true;

    function _limitRedeemerCountOffset() internal pure virtual returns (uint256);

    function _setUpSuite() internal override { }

    function test_packed_rejectsTruncatedHeader() public {
        bytes memory data_ = _exactCall(_defaultExact(Shape.Erc20ToErc20));
        _redeemFails(_slice(data_, 30));
    }

    function test_packed_rejectsUnknownDelegateMode() public {
        bytes memory data_ = _exactCall(_defaultExact(Shape.Erc20ToErc20));
        data_[4] = 0x02;
        _redeemFails(data_);
    }

    function test_packed_rejectsSignatureLengthPastEnd() public {
        bytes memory data_ = _exactCall(_defaultExact(Shape.Erc20ToErc20));
        if (usesLengthPrefixedSignature) {
            data_[EXACT_SIGNATURE_OFFSET] = 0xff;
            data_[EXACT_SIGNATURE_OFFSET + 1] = 0xff;
            _redeemFails(data_);
        } else {
            // Fixed 65-byte signature: cutting mid-signature must fail.
            _redeemFails(_slice(data_, EXACT_SIGNATURE_OFFSET + 32));
        }
    }

    function test_packed_rejectsCutBeforeSignatureLength() public {
        bytes memory data_ = _exactCall(_defaultExact(Shape.Erc20ToErc20));
        _redeemFails(_slice(data_, EXACT_SIGNATURE_OFFSET + 1));
    }

    function test_packed_trailingByteChangesSignedBatch() public {
        bytes memory data_ = _exactCall(_defaultExact(Shape.Erc20ToErc20));
        _redeemFails(bytes.concat(data_, hex"00"));
        _redeemOk(data_);
    }

    function test_packed_rejectsZeroRedeemerCount() public {
        bytes memory data_ = _limitCall(_defaultLimit(Shape.Erc20ToErc20));
        data_[_limitRedeemerCountOffset()] = 0x00;
        _redeemFails(data_);
    }

    function test_packed_rejectsRedeemerCountPastEnd() public {
        bytes memory data_ = _limitCall(_defaultLimit(Shape.Erc20ToErc20));
        data_[_limitRedeemerCountOffset()] = 0xff;
        _redeemFails(data_);
    }

    function test_packed_redeemerCountIsSigned() public {
        bytes memory data_ = _limitCall(_defaultLimit(Shape.Erc20ToErc20));
        // Dropping the last listed redeemer shifts the tail; the signed redeemer list must catch it.
        data_[_limitRedeemerCountOffset()] = 0x03;
        _redeemFails(data_);
    }

    function test_packed_rejectsTruncatedLimitTerms() public {
        bytes memory data_ = _limitCall(_defaultLimit(Shape.Erc20ToErc20));
        _redeemFails(_slice(data_, _limitRedeemerCountOffset()));
    }

    function _slice(bytes memory data_, uint256 length_) internal pure returns (bytes memory sliced_) {
        sliced_ = new bytes(length_);
        for (uint256 i_; i_ < length_; ++i_) {
            sliced_[i_] = data_[i_];
        }
    }
}
