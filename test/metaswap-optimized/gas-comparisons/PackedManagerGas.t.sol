// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { ModeCode } from "../../../src/utils/Types.sol";
import { MetaSwapManager as FinalManager } from "../../../src/metaswap/final/MetaSwapManager.sol";
import { MetaSwapManager as Eip7710FinalManager } from "../../../src/metaswap/eip7710-final/MetaSwapManager.sol";
import { ExactGasComparison, LimitGasComparison } from "./GasComparisonFixture.t.sol";

struct PackedLimitOrder {
    address delegator;
    uint256 nonce;
    address metaSwap;
    address tokenIn;
    uint256 tokenInAmount;
    uint8 approvalMode;
    address tokenOut;
    address recipient;
    uint256 tokenOutMin;
    uint128 validAfter;
    uint128 validUntil;
    address[] redeemers;
}

interface IPackedHashes {
    function getDomainHash() external view returns (bytes32);
    function hashExactBatch(
        address delegator,
        uint256 nonce,
        uint128 validAfter,
        uint128 validUntil,
        address[] calldata redeemers,
        bytes32 executionHash
    )
        external
        view
        returns (bytes32);
    function hashLimitOrder(PackedLimitOrder calldata order) external view returns (bytes32);
    function SIMPLE_BATCH_MODE() external view returns (ModeCode);
}

/**
 * @notice Packed managers. Exact is `redeemExactBatch`. Limit is the limit order.
 * @dev Same six shapes as the limit baselines, cold and as a later transaction. Direct-route limit
 *      sends route bytes. The others send the approve + swap batch. Nonce 1 is measured. Bit 200 is the sibling.
 */
abstract contract PackedManagerGasTest is LimitGasComparison, ExactGasComparison {
    uint256 private constant EXACT_NONCE_SLOT = 2;
    uint256 private constant LIMIT_NONCE_SLOT = 3;

    address internal mgr;

    function _deploy() internal virtual returns (address);
    function _limitUsesRoute() internal pure virtual returns (bool);
    function _usesRedeemDelegations() internal pure virtual returns (bool);

    function _installComparison() internal override {
        mgr = _deploy();
        _installUser(mgr);
    }

    function _armLater(Shape shape_) internal override {
        _prepareLaterFill(shape_, mgr, LIMIT_NONCE_SLOT, false);
    }

    function _run(Shape shape_) internal override returns (uint256) {
        return _measure(mgr, _limitCall(shape_), shape_);
    }

    function _armLaterExact(Shape shape_) internal override {
        _prepareLaterGaslessFill(shape_, mgr, EXACT_NONCE_SLOT);
    }

    function _runExact(Shape shape_) internal override returns (uint256) {
        return _measureGasless(mgr, _exactCall(shape_), shape_);
    }

    function _exactCall(Shape shape_) private view returns (bytes memory) {
        bytes memory batch_ = ExecutionLib.encodeBatch(_gaslessExecutions(shape_));
        address[] memory redeemers_ = _redeemers();
        bytes memory head_ =
            abi.encodePacked(user, MEASURED_NONCE, uint128(0), expiresAt, uint8(redeemers_.length), _packRedeemers(redeemers_));
        bytes memory signature_ = _sign(
            USER_KEY,
            MessageHashUtils.toTypedDataHash(
                IPackedHashes(mgr).getDomainHash(),
                IPackedHashes(mgr).hashExactBatch(user, MEASURED_NONCE, 0, expiresAt, redeemers_, keccak256(batch_))
            )
        );
        if (_usesRedeemDelegations()) {
            bytes[] memory contexts_ = new bytes[](1);
            contexts_[0] = abi.encodePacked(bytes1(uint8(0)), head_, signature_);
            ModeCode[] memory modes_ = new ModeCode[](1);
            modes_[0] = IPackedHashes(mgr).SIMPLE_BATCH_MODE();
            bytes[] memory executionCallDatas_ = new bytes[](1);
            executionCallDatas_[0] = batch_;
            return abi.encodeCall(Eip7710FinalManager.redeemDelegations, (contexts_, modes_, executionCallDatas_));
        }
        return bytes.concat(abi.encodePacked(FinalManager.redeemExactBatch.selector), head_, signature_, batch_);
    }

    function _limitCall(Shape shape_) private view returns (bytes memory) {
        PackedLimitOrder memory order_ = _limitOrder(shape_);
        bytes memory signature_ = _sign(
            USER_KEY,
            MessageHashUtils.toTypedDataHash(IPackedHashes(mgr).getDomainHash(), IPackedHashes(mgr).hashLimitOrder(order_))
        );
        if (_usesRedeemDelegations()) {
            bytes[] memory contexts_ = new bytes[](1);
            contexts_[0] = bytes.concat(bytes1(uint8(1)), _limitHead(order_), signature_);
            ModeCode[] memory modes_ = new ModeCode[](1);
            modes_[0] = IPackedHashes(mgr).SIMPLE_BATCH_MODE();
            bytes[] memory executionCallDatas_ = new bytes[](1);
            executionCallDatas_[0] = _limitUsesRoute() ? _routeBytes(shape_) : ExecutionLib.encodeBatch(_executions(shape_));
            return abi.encodeCall(Eip7710FinalManager.redeemDelegations, (contexts_, modes_, executionCallDatas_));
        }
        bytes memory tail_ = _limitUsesRoute() ? _routeBytes(shape_) : ExecutionLib.encodeBatch(_executions(shape_));
        return bytes.concat(abi.encodePacked(FinalManager.redeemLimitOrder.selector), _limitHead(order_), signature_, tail_);
    }

    function _limitOrder(Shape shape_) private view returns (PackedLimitOrder memory order_) {
        order_.delegator = user;
        order_.nonce = MEASURED_NONCE;
        order_.metaSwap = address(metaSwap);
        order_.tokenInAmount = TOKEN_IN_AMOUNT;
        order_.recipient = user;
        order_.tokenOutMin = TOKEN_OUT_MIN;
        order_.validUntil = expiresAt;
        order_.redeemers = _redeemers();
        if (shape_ == Shape.NativeToErc20) {
            order_.tokenOut = address(tokenOut);
        } else {
            order_.tokenIn = address(tokenIn);
            order_.tokenOut = shape_ == Shape.Erc20ToNative ? address(0) : address(tokenOut);
            order_.approvalMode = 2;
        }
    }

    function _limitHead(PackedLimitOrder memory order_) private pure returns (bytes memory) {
        return abi.encodePacked(
            order_.delegator,
            order_.nonce,
            order_.metaSwap,
            order_.tokenIn,
            order_.tokenInAmount,
            order_.approvalMode,
            order_.tokenOut,
            order_.recipient,
            order_.tokenOutMin,
            order_.validAfter,
            order_.validUntil,
            uint8(order_.redeemers.length),
            _packRedeemers(order_.redeemers)
        );
    }

    function _packRedeemers(address[] memory redeemers_) private pure returns (bytes memory packed_) {
        for (uint256 i_; i_ < redeemers_.length; ++i_) {
            packed_ = bytes.concat(packed_, bytes20(redeemers_[i_]));
        }
    }
}

