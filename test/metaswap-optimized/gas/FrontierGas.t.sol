// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { console2 } from "forge-std/Test.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { IMetaSwap } from "../../../src/helpers/interfaces/IMetaSwap.sol";
import { MetaSwapManager as FinalManager } from "../../../src/metaswap/final/MetaSwapManager.sol";
import { MetaSwapManager as DirectRouteManager } from "../../../src/metaswap/direct-route/MetaSwapManager.sol";
import { OptimizedHarness } from "../utils/OptimizedHarness.t.sol";

/**
 * @notice Cold gas matrix for DirectRoute vs final.
 */
contract FrontierGasTest is OptimizedHarness {
    FinalManager internal finalMgr;
    DirectRouteManager internal directMgr;

    function _setUpSuite() internal override {
        directMgr = new DirectRouteManager();
    }

    function _deployManager() internal override returns (address) {
        finalMgr = new FinalManager();
        return address(finalMgr);
    }

    function _variantName() internal pure override returns (string memory) {
        return "frontier";
    }

    function _exactDigest(address manager_, ExactOrder memory order_) internal view override returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(
            FinalManager(manager_).getDomainHash(),
            FinalManager(manager_)
                .hashExactBatch(
                    order_.delegator, order_.nonce, order_.validAfter, order_.validUntil, order_.redeemers, keccak256(order_.batch)
                )
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
        return bytes.concat(abi.encodePacked(FinalManager.redeemExactBatch.selector), _exactHead(order_), signature_, order_.batch);
    }

    function _limitDigest(address manager_, LimitParams memory params_) internal view override returns (bytes32) {
        FinalManager.LimitOrder memory order_ = FinalManager.LimitOrder({
            delegator: params_.delegator,
            nonce: params_.nonce,
            metaSwap: params_.metaSwap,
            tokenIn: params_.tokenIn,
            tokenInAmount: params_.tokenInAmount,
            approvalMode: params_.approvalMode,
            tokenOut: params_.tokenOut,
            recipient: params_.recipient,
            tokenOutMin: params_.tokenOutMin,
            validAfter: params_.validAfter,
            validUntil: params_.validUntil,
            redeemers: params_.redeemers
        });
        return
            MessageHashUtils.toTypedDataHash(FinalManager(manager_).getDomainHash(), FinalManager(manager_).hashLimitOrder(order_));
    }

    function _limitCalldata(
        address,
        LimitParams memory params_,
        bytes memory signature_
    )
        internal
        pure
        override
        returns (bytes memory)
    {
        return bytes.concat(
            abi.encodePacked(
                FinalManager.redeemLimitOrder.selector,
                params_.delegator,
                params_.nonce,
                params_.metaSwap,
                params_.tokenIn,
                params_.tokenInAmount,
                params_.approvalMode,
                params_.tokenOut,
                params_.recipient,
                params_.tokenOutMin,
                params_.validAfter,
                params_.validUntil,
                uint8(params_.redeemers.length)
            ),
            _packAddresses(params_.redeemers),
            signature_,
            params_.batch
        );
    }

    function _cancelExact(ExactOrder memory order_) internal override {
        vm.prank(order_.delegator);
        finalMgr.invalidateExactBatchNonce(order_.nonce);
    }

    function _cancelLimit(LimitParams memory params_) internal override {
        vm.prank(params_.delegator);
        finalMgr.invalidateLimitOrderNonce(params_.nonce);
    }

    function _burnNonce(address delegator_, uint256 nonce_) internal override {
        vm.prank(delegator_);
        finalMgr.invalidateExactBatchNonce(nonce_);
        vm.prank(delegator_);
        finalMgr.invalidateLimitOrderNonce(nonce_);
    }

    function _log(string memory variant_, string memory flow_, string memory row_, GasMeasurement memory m_) private pure {
        console2.log(
            string.concat(
                "GAS|",
                variant_,
                "|",
                flow_,
                "|",
                row_,
                "|",
                _u(m_.estimatedTransactionGas),
                "|",
                _u(m_.calldataBytes),
                "|",
                _u(m_.executionGas)
            )
        );
    }

    function _u(uint256 v_) private pure returns (string memory) {
        return vm.toString(v_);
    }

    function _routeBytes(Shape shape_) private view returns (bytes memory) {
        address tokenOut_ = shape_ == Shape.Erc20ToNative ? address(0) : address(tokenOut);
        if (shape_ == Shape.NativeToErc20) tokenOut_ = address(tokenOut);
        bytes memory data_ = abi.encode(IERC20(tokenOut_), TOKEN_OUT_AMOUNT, routeData);
        bytes memory agg_ = bytes(AGGREGATOR_ID);
        return bytes.concat(bytes1(uint8(agg_.length)), agg_, bytes2(uint16(data_.length)), data_);
    }

    function _directLimitCall(LimitParams memory p_) private view returns (bytes memory) {
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
        Shape shape_ = p_.tokenIn == address(0)
            ? Shape.NativeToErc20
            : (p_.tokenOut == address(0) ? Shape.Erc20ToNative : (p_.approvalMode == 3 ? Shape.Erc20Reset : Shape.Erc20ToErc20));
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
        return bytes.concat(head_, mid_, _packAddresses(p_.redeemers), _sign(p_.key, digest_), _routeBytes(shape_));
    }

    function _measureOn(address mgr_, bytes memory data_, address account_, Shape shape_) private returns (GasMeasurement memory) {
        _installAccount(account_, mgr_);
        address prev_ = manager;
        manager = mgr_;
        GasMeasurement memory m_ = _measure(data_, account_, shape_);
        manager = prev_;
        return m_;
    }

    ////////////////////////////// Cold single-order matrix //////////////////////////////

    function test_frontier_final_limit_cold_all() public {
        _logShape("final", Shape.NativeToErc20);
        _logShape("final", Shape.Erc20ToNative);
        _logShape("final", Shape.Erc20ToErc20);
        _logShape("final", Shape.Erc20Reset);
    }

    function test_frontier_A_direct_route_cold_all() public {
        _logDirect(Shape.NativeToErc20);
        _logDirect(Shape.Erc20ToNative);
        _logDirect(Shape.Erc20ToErc20);
        _logDirect(Shape.Erc20Reset);
    }

    function test_frontier_final_exact_cold_erc20() public {
        ExactOrder memory o_ = _defaultExact(Shape.Erc20ToErc20);
        _log("final", "exact", "3-token-in-token-out", _measure(_exactCall(o_), orderAlice, Shape.Erc20ToErc20));
    }

    function _logShape(string memory variant_, Shape shape_) private {
        LimitParams memory p_ = _defaultLimit(shape_);
        p_.nonce = uint256(shape_) + 1;
        string memory row_ = _row(shape_);
        if (keccak256(bytes(variant_)) == keccak256("final")) {
            _log(variant_, "limit", row_, _measure(_limitCall(p_), orderAlice, shape_));
        }
    }

    function _logDirect(Shape shape_) private {
        LimitParams memory p_ = _defaultLimit(shape_);
        p_.nonce = 10 + uint256(shape_);
        _log("direct-route", "limit", _row(shape_), _measureOn(address(directMgr), _directLimitCall(p_), orderAlice, shape_));
    }

    function _row(Shape shape_) private pure returns (string memory) {
        if (shape_ == Shape.NativeToErc20) return "1-native-in-token-out";
        if (shape_ == Shape.Erc20ToNative) return "2-token-in-native-out";
        if (shape_ == Shape.Erc20ToErc20) return "3-token-in-token-out";
        return "4-token-in-token-out-reset";
    }
}
