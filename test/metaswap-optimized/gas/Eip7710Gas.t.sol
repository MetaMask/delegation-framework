// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { console2 } from "forge-std/Test.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ModeCode } from "../../../src/utils/Types.sol";
import { MetaSwapManager as FinalManager } from "../../../src/metaswap/final/MetaSwapManager.sol";
import { MetaSwapManager as DirectRouteManager } from "../../../src/metaswap/direct-route/MetaSwapManager.sol";
import { MetaSwapManager as Eip7710FinalManager } from "../../../src/metaswap/eip7710-final/MetaSwapManager.sol";
import { MetaSwapManager as Eip7710DirectRouteManager } from "../../../src/metaswap/eip7710-direct-route/MetaSwapManager.sol";
import { OptimizedHarness } from "../utils/OptimizedHarness.t.sol";

/**
 * @notice Gas compare: packed Final/DirectRoute vs EIP-7710 `redeemDelegations` variants.
 * @dev The comparison matrix lives in `test/metaswap-optimized/gas-comparisons/`.
 *      This file remains as a quick EIP-vs-packed lever probe.
 */
contract Eip7710GasTest is OptimizedHarness {
    FinalManager internal finalMgr;
    DirectRouteManager internal directMgr;
    Eip7710FinalManager internal eipFinal;
    Eip7710DirectRouteManager internal eipDirect;

    function _setUpSuite() internal override {
        directMgr = new DirectRouteManager();
        eipFinal = new Eip7710FinalManager();
        eipDirect = new Eip7710DirectRouteManager();
    }

    function _deployManager() internal override returns (address) {
        finalMgr = new FinalManager();
        return address(finalMgr);
    }

    function _variantName() internal pure override returns (string memory) {
        return "eip7710-gas";
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

    function _packLimitAuth(LimitParams memory p_, bytes memory signature_) private pure returns (bytes memory) {
        return bytes.concat(
            bytes1(uint8(1)),
            abi.encodePacked(
                p_.delegator,
                p_.nonce,
                p_.metaSwap,
                p_.tokenIn,
                p_.tokenInAmount,
                p_.approvalMode,
                p_.tokenOut,
                p_.recipient,
                p_.tokenOutMin,
                p_.validAfter,
                p_.validUntil,
                uint8(p_.redeemers.length)
            ),
            _packAddresses(p_.redeemers),
            signature_
        );
    }

    function _eipExactCall(address mgr_, ExactOrder memory order_) private view returns (bytes memory) {
        bytes memory signature_ = _sign(order_.key, _eipExactDigest(mgr_, order_));
        bytes memory ctx_ = abi.encodePacked(bytes1(uint8(0)), _exactHead(order_), signature_);
        return _redeemCall(mgr_, ctx_, order_.batch);
    }

    function _eipLimitCall(address mgr_, LimitParams memory p_, bytes memory execution_) private view returns (bytes memory) {
        bytes memory signature_ = _sign(p_.key, _eipLimitDigest(mgr_, p_));
        return _redeemCall(mgr_, _packLimitAuth(p_, signature_), execution_);
    }

    function _eipExactDigest(address mgr_, ExactOrder memory order_) private view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(
            Eip7710FinalManager(mgr_).getDomainHash(),
            Eip7710FinalManager(mgr_)
                .hashExactBatch(
                    order_.delegator, order_.nonce, order_.validAfter, order_.validUntil, order_.redeemers, keccak256(order_.batch)
                )
        );
    }

    function _eipLimitDigest(address mgr_, LimitParams memory p_) private view returns (bytes32) {
        Eip7710FinalManager.LimitOrder memory order_ = Eip7710FinalManager.LimitOrder({
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
        return MessageHashUtils.toTypedDataHash(
            Eip7710FinalManager(mgr_).getDomainHash(), Eip7710FinalManager(mgr_).hashLimitOrder(order_)
        );
    }

    function _redeemCall(address mgr_, bytes memory ctx_, bytes memory execution_) private view returns (bytes memory) {
        bytes[] memory contexts_ = new bytes[](1);
        contexts_[0] = ctx_;
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = Eip7710FinalManager(mgr_).SIMPLE_BATCH_MODE();
        bytes[] memory executions_ = new bytes[](1);
        executions_[0] = execution_;
        return abi.encodeCall(Eip7710FinalManager.redeemDelegations, (contexts_, modes_, executions_));
    }

    function _log(string memory name_, string memory flow_, GasMeasurement memory m_) private pure {
        console2.log(
            string.concat(
                "EIP7710|",
                name_,
                "|",
                flow_,
                "|est=",
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

    function _delta(string memory label_, GasMeasurement memory a_, GasMeasurement memory b_) private pure {
        console2.log(
            string.concat(
                "EIP7710|delta|",
                label_,
                "|est=",
                vm.toString(int256(b_.estimatedTransactionGas) - int256(a_.estimatedTransactionGas)),
                "|cdGas=",
                vm.toString(int256(b_.calldataGas) - int256(a_.calldataGas)),
                "|exec=",
                vm.toString(int256(b_.executionGas) - int256(a_.executionGas))
            )
        );
    }

    function test_eip7710_vs_packed_warm() public {
        address[] memory redeemers_ = new address[](1);
        redeemers_[0] = relayer;

        // Warm packed Final.
        {
            ExactOrder memory warmE_ = _defaultExact(Shape.Erc20ToErc20);
            warmE_.nonce = 0;
            _measure(_exactCall(warmE_), orderAlice, Shape.Erc20ToErc20);
            LimitParams memory warmL_ = _defaultLimit(Shape.Erc20ToErc20);
            warmL_.nonce = 0;
            warmL_.redeemers = redeemers_;
            _measure(_limitCall(warmL_), orderAlice, Shape.Erc20ToErc20);
        }

        ExactOrder memory exact_ = _defaultExact(Shape.Erc20ToErc20);
        exact_.nonce = 1;
        GasMeasurement memory packedExact_ = _measure(_exactCall(exact_), orderAlice, Shape.Erc20ToErc20);
        _log("packed-final", "exact", packedExact_);

        LimitParams memory limit_ = _defaultLimit(Shape.Erc20ToErc20);
        limit_.nonce = 1;
        limit_.redeemers = redeemers_;
        GasMeasurement memory packedLimit_ = _measure(_limitCall(limit_), orderAlice, Shape.Erc20ToErc20);
        _log("packed-final", "limit", packedLimit_);

        // EIP-7710 Final (account must trust this manager).
        _installAccount(orderAlice, address(eipFinal));
        manager = address(eipFinal);
        {
            ExactOrder memory warmE_ = _defaultExact(Shape.Erc20ToErc20);
            warmE_.nonce = 10;
            _measure(_eipExactCall(address(eipFinal), warmE_), orderAlice, Shape.Erc20ToErc20);
            LimitParams memory warmL_ = _defaultLimit(Shape.Erc20ToErc20);
            warmL_.nonce = 10;
            warmL_.redeemers = redeemers_;
            _measure(_eipLimitCall(address(eipFinal), warmL_, warmL_.batch), orderAlice, Shape.Erc20ToErc20);
        }

        ExactOrder memory eipExact_ = _defaultExact(Shape.Erc20ToErc20);
        eipExact_.nonce = 11;
        GasMeasurement memory eipExactM_ = _measure(_eipExactCall(address(eipFinal), eipExact_), orderAlice, Shape.Erc20ToErc20);
        _log("eip7710-final", "exact", eipExactM_);

        LimitParams memory eipLimit_ = _defaultLimit(Shape.Erc20ToErc20);
        eipLimit_.nonce = 11;
        eipLimit_.redeemers = redeemers_;
        GasMeasurement memory eipLimitM_ =
            _measure(_eipLimitCall(address(eipFinal), eipLimit_, eipLimit_.batch), orderAlice, Shape.Erc20ToErc20);
        _log("eip7710-final", "limit", eipLimitM_);

        _delta("final-exact-packed-to-eip7710", packedExact_, eipExactM_);
        _delta("final-limit-packed-to-eip7710", packedLimit_, eipLimitM_);

        // Packed DirectRoute.
        _installAccount(orderAlice, address(directMgr));
        manager = address(directMgr);
        LimitParams memory dWarm_ = _defaultLimit(Shape.Erc20ToErc20);
        dWarm_.nonce = 20;
        dWarm_.redeemers = redeemers_;
        LimitParams memory dLimit_ = _defaultLimit(Shape.Erc20ToErc20);
        dLimit_.nonce = 21;
        dLimit_.redeemers = redeemers_;
        _measure(_directPacked(dWarm_), orderAlice, Shape.Erc20ToErc20);
        GasMeasurement memory packedDirect_ = _measure(_directPacked(dLimit_), orderAlice, Shape.Erc20ToErc20);
        _log("packed-direct", "limit", packedDirect_);

        // EIP-7710 DirectRoute.
        _installAccount(orderAlice, address(eipDirect));
        manager = address(eipDirect);
        LimitParams memory eWarm_ = _defaultLimit(Shape.Erc20ToErc20);
        eWarm_.nonce = 30;
        eWarm_.redeemers = redeemers_;
        LimitParams memory eLimit_ = _defaultLimit(Shape.Erc20ToErc20);
        eLimit_.nonce = 31;
        eLimit_.redeemers = redeemers_;
        _measure(_eipLimitCall(address(eipDirect), eWarm_, _routeBytes()), orderAlice, Shape.Erc20ToErc20);
        GasMeasurement memory eipDirectM_ =
            _measure(_eipLimitCall(address(eipDirect), eLimit_, _routeBytes()), orderAlice, Shape.Erc20ToErc20);
        _log("eip7710-direct", "limit", eipDirectM_);
        _delta("direct-limit-packed-to-eip7710", packedDirect_, eipDirectM_);
    }

    function _directPacked(LimitParams memory p_) private view returns (bytes memory) {
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
}
