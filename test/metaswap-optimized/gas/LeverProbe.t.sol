// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { console2 } from "forge-std/Test.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MetaSwapManager as FinalManager } from "../../../src/metaswap/final/MetaSwapManager.sol";
import { MetaSwapManager as DirectRouteManager } from "../../../src/metaswap/direct-route/MetaSwapManager.sol";
import { OptimizedHarness } from "../utils/OptimizedHarness.t.sol";

/**
 * @notice Isolates gas levers: route-rebuild vs batch, and calldata field drops.
 * @dev Logs `LEVER|name|flow|estimated|calldataGas|calldataBytes|exec`.
 */
contract LeverProbeTest is OptimizedHarness {
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
        return "lever";
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

    function _routeBytes() private view returns (bytes memory) {
        bytes memory data_ = abi.encode(IERC20(address(tokenOut)), TOKEN_OUT_AMOUNT, routeData);
        bytes memory agg_ = bytes(AGGREGATOR_ID);
        return bytes.concat(bytes1(uint8(agg_.length)), agg_, bytes2(uint16(data_.length)), data_);
    }

    function _logLever(string memory name_, string memory flow_, GasMeasurement memory m_) private pure {
        console2.log(
            string.concat(
                "LEVER|",
                name_,
                "|",
                flow_,
                "|",
                vm.toString(m_.estimatedTransactionGas),
                "|cdGas=",
                vm.toString(m_.calldataGas),
                "|cdBytes=",
                vm.toString(m_.calldataBytes),
                "|exec=",
                vm.toString(m_.executionGas)
            )
        );
    }

    function _calldataOnly(string memory name_, bytes memory data_) private pure {
        uint256 cdGas_;
        for (uint256 i_; i_ < data_.length; ++i_) {
            cdGas_ += data_[i_] == 0 ? 4 : 16;
        }
        console2.log(
            string.concat("LEVER|", name_, "|calldata-only|cdGas=", vm.toString(cdGas_), "|cdBytes=", vm.toString(data_.length))
        );
    }

    /// @dev Same signed fields; only trailing payload differs (full batch vs route). Isolates rebuild.
    function test_lever_rebuild_vs_batch_same_fields() public {
        LimitParams memory warm_ = _defaultLimit(Shape.Erc20ToErc20);
        warm_.nonce = 0;
        warm_.redeemers = new address[](1);
        warm_.redeemers[0] = relayer;
        _measure(_limitCall(warm_), orderAlice, Shape.Erc20ToErc20);

        LimitParams memory p_ = _defaultLimit(Shape.Erc20ToErc20);
        p_.nonce = 1;
        p_.redeemers = warm_.redeemers;

        GasMeasurement memory final_ = _measure(_limitCall(p_), orderAlice, Shape.Erc20ToErc20);
        _logLever("final-1redeemer-batch-warm", "limit", final_);

        LimitParams memory warmD_ = _defaultLimit(Shape.Erc20ToErc20);
        warmD_.redeemers = warm_.redeemers;
        warmD_.nonce = 10;
        LimitParams memory directP_ = _defaultLimit(Shape.Erc20ToErc20);
        directP_.redeemers = warm_.redeemers;
        directP_.nonce = 11;
        _installAccount(orderAlice, address(directMgr));
        {
            address prev0_ = manager;
            manager = address(directMgr);
            _measure(_directCall(warmD_), orderAlice, Shape.Erc20ToErc20);
            manager = prev0_;
        }
        address prev_ = manager;
        manager = address(directMgr);
        GasMeasurement memory direct_ = _measure(_directCall(directP_), orderAlice, Shape.Erc20ToErc20);
        manager = prev_;
        _logLever("direct-1redeemer-route-warm", "limit", direct_);

        console2.log(
            string.concat(
                "LEVER|delta-rebuild-warm|limit|est=",
                vm.toString(int256(final_.estimatedTransactionGas) - int256(direct_.estimatedTransactionGas)),
                "|cdGas=",
                vm.toString(int256(final_.calldataGas) - int256(direct_.calldataGas)),
                "|exec=",
                vm.toString(int256(final_.executionGas) - int256(direct_.executionGas))
            )
        );
    }

    function test_lever_calldata_field_drops() public view {
        LimitParams memory p_ = _defaultLimit(Shape.Erc20ToErc20);
        p_.redeemers = new address[](1);
        p_.redeemers[0] = relayer;
        bytes memory sig_ = new bytes(65);

        _calldataOnly("limit-full-header+batch", _packLimit(true, sig_, p_.batch));
        _calldataOnly("limit-no-recipient+batch", _packLimit(false, sig_, p_.batch));
        _calldataOnly("limit-no-recipient+route", _packLimit(false, sig_, _routeBytes()));

        ExactOrder memory o_ = _defaultExact(Shape.Erc20ToErc20);
        _calldataOnly(
            "exact-header+batch",
            bytes.concat(abi.encodePacked(FinalManager.redeemExactBatch.selector), _exactHead(o_), sig_, o_.batch)
        );
    }

    function _directCall(LimitParams memory p_) private view returns (bytes memory) {
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
        return bytes.concat(head_, mid_, _packAddresses(p_.redeemers), _sign(p_.key, digest_), _routeBytes());
    }

    function _packLimit(bool withRecipient_, bytes memory sig_, bytes memory tail_) private view returns (bytes memory) {
        LimitParams memory p_ = _defaultLimit(Shape.Erc20ToErc20);
        bytes memory head_ = abi.encodePacked(
            FinalManager.redeemLimitOrder.selector,
            p_.delegator,
            p_.nonce,
            p_.metaSwap,
            p_.tokenIn,
            p_.tokenInAmount,
            p_.approvalMode
        );
        bytes memory mid_ = withRecipient_
            ? abi.encodePacked(p_.tokenOut, p_.recipient, p_.tokenOutMin, p_.validAfter, p_.validUntil)
            : abi.encodePacked(p_.tokenOut, p_.tokenOutMin, p_.validAfter, p_.validUntil);
        return bytes.concat(head_, mid_, bytes1(uint8(1)), bytes20(relayer), sig_, tail_);
    }
}
