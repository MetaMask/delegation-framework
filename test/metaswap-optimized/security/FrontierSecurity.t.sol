// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MetaSwapManager as FinalManager } from "../../../src/metaswap/final/MetaSwapManager.sol";
import { MetaSwapManager as DirectRouteManager } from "../../../src/metaswap/direct-route/MetaSwapManager.sol";
import { OptimizedHarness, ReentrantMetaSwapMock } from "../utils/OptimizedHarness.t.sol";

/**
 * @notice Frontier security for DirectRoute. Standalone: signature/domain binding, replay/cancel,
 *         output shortfall, nested fills, malformed routes, account-without-code, payload fuzz.
 */
contract FrontierSecurityTest is OptimizedHarness {
    DirectRouteManager internal directMgr;
    ReentrantMetaSwapMock internal reentrantMetaSwap;

    uint256 private constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function _setUpSuite() internal override {
        directMgr = new DirectRouteManager();
        reentrantMetaSwap = new ReentrantMetaSwapMock();
        tokenOut.mint(address(reentrantMetaSwap), 100_000 ether);
        vm.deal(address(reentrantMetaSwap), 100_000 ether);
    }

    function _deployManager() internal override returns (address) {
        return address(new DirectRouteManager());
    }

    function _variantName() internal pure override returns (string memory) {
        return "frontier-security";
    }

    function _exactDigest(address manager_, ExactOrder memory order_) internal view override returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(
            FinalManager(manager_).getDomainHash(),
            FinalManager(manager_).hashExactBatch(order_.delegator, order_.nonce, keccak256(order_.batch))
        );
    }

    function _exactCalldata(
        address,
        ExactOrder memory order_,
        bytes memory signature_
    )
        internal
        pure
        override
        returns (bytes memory)
    {
        return abi.encodePacked(FinalManager.redeemExactBatch.selector, order_.delegator, order_.nonce, signature_, order_.batch);
    }

    function _limitDigest(address, LimitParams memory) internal pure override returns (bytes32) {
        return bytes32(0);
    }

    function _limitCalldata(address, LimitParams memory, bytes memory) internal pure override returns (bytes memory) {
        return "";
    }

    function _cancelExact(ExactOrder memory order_) internal override {
        vm.prank(order_.delegator);
        DirectRouteManager(manager).invalidateExactBatchNonce(order_.nonce);
    }

    function _cancelLimit(LimitParams memory params_) internal override {
        vm.prank(params_.delegator);
        DirectRouteManager(manager).invalidateLimitOrderNonce(params_.nonce);
    }

    function _burnNonce(address delegator_, uint256 nonce_) internal override {
        vm.prank(delegator_);
        DirectRouteManager(manager).invalidateExactBatchNonce(nonce_);
        vm.prank(delegator_);
        DirectRouteManager(manager).invalidateLimitOrderNonce(nonce_);
    }

    function _route(Shape shape_, uint256 amountOut_) private view returns (bytes memory) {
        address tokenOut_ = shape_ == Shape.Erc20ToNative ? address(0) : address(tokenOut);
        if (shape_ == Shape.NativeToErc20) tokenOut_ = address(tokenOut);
        bytes memory data_ = abi.encode(IERC20(tokenOut_), amountOut_, routeData);
        bytes memory agg_ = bytes(AGGREGATOR_ID);
        return bytes.concat(bytes1(uint8(agg_.length)), agg_, bytes2(uint16(data_.length)), data_);
    }

    function _directLimit(LimitParams memory p_, bytes memory route_) private view returns (bytes memory) {
        DirectRouteManager.LimitOrder memory order_ = DirectRouteManager.LimitOrder({
            delegator: p_.delegator,
            nonce: p_.nonce,
            metaSwap: p_.metaSwap,
            tokenIn: p_.tokenIn,
            tokenInAmount: p_.tokenInAmount,
            approvalMode: p_.approvalMode,
            tokenOut: p_.tokenOut,
            recipient: p_.recipient,
            tokenOutMin: p_.tokenOutMin,
            validAfter: p_.validAfter,
            validUntil: p_.validUntil,
            redeemers: p_.redeemers
        });
        bytes32 digest_ = MessageHashUtils.toTypedDataHash(directMgr.getDomainHash(), directMgr.hashLimitOrder(order_));
        bytes memory head_ = abi.encodePacked(
            DirectRouteManager.redeemLimitOrder.selector,
            p_.delegator,
            p_.nonce,
            p_.metaSwap,
            p_.tokenIn,
            p_.tokenInAmount,
            p_.approvalMode
        );
        bytes memory mid_ =
            abi.encodePacked(p_.tokenOut, p_.recipient, p_.tokenOutMin, p_.validAfter, p_.validUntil, uint8(p_.redeemers.length));
        return bytes.concat(head_, mid_, _packAddresses(p_.redeemers), _sign(p_.key, digest_), route_);
    }

    function _ok(address target_, bytes memory data_) private {
        vm.prank(relayer);
        (bool ok_,) = target_.call(data_);
        require(ok_, "expected success");
    }

    function _fail(address target_, bytes memory data_) private {
        vm.prank(relayer);
        (bool ok_,) = target_.call(data_);
        require(!ok_, "expected failure");
    }

    function _failAs(address caller_, address target_, bytes memory data_) private {
        vm.prank(caller_);
        (bool ok_,) = target_.call(data_);
        require(!ok_, "expected failure");
    }

    ////////////////////////////// A DirectRoute //////////////////////////////

    function test_direct_exact_redeemsAndRejectsReplay() public {
        ExactOrder memory o_ = _defaultExact(Shape.Erc20ToErc20);
        bytes memory data_ = _exactCalldata(address(directMgr), o_, _sign(o_.key, _exactDigest(address(directMgr), o_)));
        _installAccount(orderAlice, address(directMgr));
        _ok(address(directMgr), data_);
        _fail(address(directMgr), data_);
    }

    function test_direct_limit_redeemsShapesAndRejectsReplay() public {
        for (uint256 i_; i_ < 4; ++i_) {
            LimitParams memory p_ = _defaultLimit(Shape(i_));
            p_.nonce = 10 + i_;
            bytes memory data_ = _directLimit(p_, _route(Shape(i_), TOKEN_OUT_AMOUNT));
            _installAccount(orderAlice, address(directMgr));
            _ok(address(directMgr), data_);
            _fail(address(directMgr), data_);
        }
    }

    function test_direct_limit_rejectsWrongSignerAndHighS() public {
        LimitParams memory p_ = _defaultLimit(Shape.Erc20ToErc20);
        p_.key = WRONG_KEY;
        _installAccount(orderAlice, address(directMgr));
        _fail(address(directMgr), _directLimit(p_, _route(Shape.Erc20ToErc20, TOKEN_OUT_AMOUNT)));

        p_ = _defaultLimit(Shape.Erc20ToErc20);
        p_.nonce = 99;
        DirectRouteManager.LimitOrder memory order_ = DirectRouteManager.LimitOrder({
            delegator: p_.delegator,
            nonce: p_.nonce,
            metaSwap: p_.metaSwap,
            tokenIn: p_.tokenIn,
            tokenInAmount: p_.tokenInAmount,
            approvalMode: p_.approvalMode,
            tokenOut: p_.tokenOut,
            recipient: p_.recipient,
            tokenOutMin: p_.tokenOutMin,
            validAfter: p_.validAfter,
            validUntil: p_.validUntil,
            redeemers: p_.redeemers
        });
        bytes32 digest_ = MessageHashUtils.toTypedDataHash(directMgr.getDomainHash(), directMgr.hashLimitOrder(order_));
        bytes memory sig_ = _sign(p_.key, digest_);
        // malleate
        bytes32 r_;
        bytes32 s_;
        uint8 v_ = uint8(sig_[64]);
        assembly {
            r_ := mload(add(sig_, 0x20))
            s_ := mload(add(sig_, 0x40))
        }
        sig_ = abi.encodePacked(r_, bytes32(SECP256K1_N - uint256(s_)), v_ == 27 ? uint8(28) : uint8(27));
        bytes memory head_ = abi.encodePacked(
            DirectRouteManager.redeemLimitOrder.selector,
            p_.delegator,
            p_.nonce,
            p_.metaSwap,
            p_.tokenIn,
            p_.tokenInAmount,
            p_.approvalMode
        );
        bytes memory mid_ =
            abi.encodePacked(p_.tokenOut, p_.recipient, p_.tokenOutMin, p_.validAfter, p_.validUntil, uint8(p_.redeemers.length));
        _fail(
            address(directMgr),
            bytes.concat(head_, mid_, _packAddresses(p_.redeemers), sig_, _route(Shape.Erc20ToErc20, TOKEN_OUT_AMOUNT))
        );
    }

    function test_direct_limit_rejectsInsufficientOutputAndCancel() public {
        LimitParams memory p_ = _defaultLimit(Shape.Erc20ToErc20);
        _installAccount(orderAlice, address(directMgr));
        _fail(address(directMgr), _directLimit(p_, _route(Shape.Erc20ToErc20, TOKEN_OUT_MIN - 1)));

        p_.nonce = 5;
        vm.prank(orderAlice);
        directMgr.invalidateLimitOrderNonce(p_.nonce);
        _fail(address(directMgr), _directLimit(p_, _route(Shape.Erc20ToErc20, TOKEN_OUT_AMOUNT)));
    }

    function test_direct_limit_rejectsUnlistedRedeemerAndMalformedRoute() public {
        LimitParams memory p_ = _defaultLimit(Shape.Erc20ToErc20);
        p_.redeemers = new address[](1);
        p_.redeemers[0] = signerA;
        _installAccount(orderAlice, address(directMgr));
        _fail(address(directMgr), _directLimit(p_, _route(Shape.Erc20ToErc20, TOKEN_OUT_AMOUNT)));

        p_ = _defaultLimit(Shape.Erc20ToErc20);
        p_.nonce = 6;
        _fail(address(directMgr), _directLimit(p_, hex"0100"));
    }

    function test_direct_limit_rejectsCodelessAccount() public {
        LimitParams memory p_ = _defaultLimit(Shape.Erc20ToErc20);
        address eoa_ = vm.addr(0xC0DE);
        p_.delegator = eoa_;
        p_.key = 0xC0DE;
        tokenIn.mint(eoa_, 1_000 ether);
        _fail(address(directMgr), _directLimit(p_, _route(Shape.Erc20ToErc20, TOKEN_OUT_AMOUNT)));
    }

    /// @dev No nested-fill lock: an ExactBatch nested in the route can pad the outer minOut (MM trust assumption).
    function test_direct_nestedExactInsideLimitDocumentsTrustGap() public {
        ExactOrder memory inner_ = _defaultExact(Shape.NativeToErc20);
        inner_.nonce = 2;
        bytes memory innerData_ =
            _exactCalldata(address(directMgr), inner_, _sign(inner_.key, _exactDigest(address(directMgr), inner_)));
        reentrantMetaSwap.setReentry(address(directMgr), innerData_);

        LimitParams memory outer_ = _defaultLimit(Shape.Erc20ToErc20);
        outer_.metaSwap = address(reentrantMetaSwap);
        outer_.redeemers = new address[](1);
        outer_.redeemers[0] = relayer;
        _installAccount(orderAlice, address(directMgr));
        // Build before prank: `_directLimit` calls the manager (would consume a one-shot prank).
        bytes memory data_ = _directLimit(outer_, _route(Shape.Erc20ToErc20, 0));
        // Unpaid outer swap; nested ExactBatch pays recipient → outer minOut passes without a lock.
        _ok(address(directMgr), data_);
        assertTrue(reentrantMetaSwap.reentrySucceeded());
        assertTrue(directMgr.isLimitOrderNonceUsed(orderAlice, outer_.nonce));
        assertTrue(directMgr.isExactBatchNonceUsed(orderAlice, inner_.nonce));
    }
}
