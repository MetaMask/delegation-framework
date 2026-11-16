// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { MetaSwapOrderDelegationManager } from "../../../src/MetaSwapOrderDelegationManager.sol";
import { Caveat, Delegation, ModeCode } from "../../../src/utils/Types.sol";
import { MetaSwapManager } from "../../../src/metaswap/final/MetaSwapManager.sol";
import { NonceBitmap } from "../../../src/metaswap/final/NonceBitmap.sol";
import { OptimizedHarness } from "./OptimizedHarness.t.sol";

/// @dev The ERC-7710-shaped surface shared by `MetaSwapOrderDelegationManager`.
interface IDelegationStyleManager {
    function redeemDelegations(bytes[] calldata, ModeCode[] calldata, bytes[] calldata) external;
    function getDelegationHash(Delegation calldata) external view returns (bytes32);
    function getDomainHash() external view returns (bytes32);
    function disableDelegation(Delegation calldata) external;
}

interface IDomainHash {
    function getDomainHash() external view returns (bytes32);
}

/**
 * @notice `redeemDelegations` with one single-caveat `Delegation`: `MetaSwapOrderDelegationManager`.
 */
abstract contract DelegationStyleAdapter is OptimizedHarness {
    /// @dev Order manager carries an id in limit-order terms.
    function _limitTermsHaveId() internal pure virtual returns (bool) {
        return true;
    }

    function _exactDelegation(address manager_, ExactOrder memory order_) internal pure returns (Delegation memory) {
        return _delegation(
            manager_,
            order_.delegate,
            order_.delegator,
            order_.nonce,
            abi.encodePacked(
                uint8(0), order_.validAfter, order_.validUntil, keccak256(order_.batch), _packAddresses(order_.redeemers)
            )
        );
    }

    function _limitDelegation(address manager_, LimitParams memory params_) internal pure returns (Delegation memory) {
        return _delegation(manager_, params_.delegate, params_.delegator, params_.nonce, _limitTerms(params_));
    }

    function _limitTerms(LimitParams memory params_) internal pure returns (bytes memory) {
        bytes memory head_ = abi.encodePacked(
            uint8(1), params_.metaSwap, params_.tokenIn, params_.tokenInAmount, params_.approvalMode, params_.tokenOut
        );
        bytes memory tail_ = abi.encodePacked(params_.recipient, params_.tokenOutMin, params_.validAfter, params_.validUntil);
        bytes memory id_ = _limitTermsHaveId() ? abi.encodePacked(params_.nonce) : bytes("");
        return bytes.concat(head_, tail_, id_, _packAddresses(params_.redeemers));
    }

    function _delegation(
        address manager_,
        address delegate_,
        address delegator_,
        uint256 salt_,
        bytes memory terms_
    )
        internal
        pure
        returns (Delegation memory)
    {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: manager_, terms: terms_, args: hex"" });
        return Delegation({
            delegate: delegate_,
            delegator: delegator_,
            authority: bytes32(type(uint256).max),
            caveats: caveats_,
            salt: salt_,
            signature: hex""
        });
    }

    function _delegationDigest(address manager_, Delegation memory delegation_) internal view returns (bytes32) {
        IDelegationStyleManager manager__ = IDelegationStyleManager(manager_);
        return MessageHashUtils.toTypedDataHash(manager__.getDomainHash(), manager__.getDelegationHash(delegation_));
    }

    function _redeemDelegationsCalldata(Delegation memory delegation_, bytes memory batch_) internal pure returns (bytes memory) {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory contexts_ = new bytes[](1);
        contexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeCode.wrap(0x0100000000000000000000000000000000000000000000000000000000000000);
        bytes[] memory executions_ = new bytes[](1);
        executions_[0] = batch_;
        return abi.encodeCall(IDelegationStyleManager.redeemDelegations, (contexts_, modes_, executions_));
    }

    function _exactDigest(address manager_, ExactOrder memory order_) internal view virtual override returns (bytes32) {
        return _delegationDigest(manager_, _exactDelegation(manager_, order_));
    }

    function _exactCalldata(
        address manager_,
        ExactOrder memory order_,
        bytes memory signature_
    )
        internal
        pure
        virtual
        override
        returns (bytes memory)
    {
        Delegation memory delegation_ = _exactDelegation(manager_, order_);
        delegation_.signature = signature_;
        return _redeemDelegationsCalldata(delegation_, order_.batch);
    }

    function _limitDigest(address manager_, LimitParams memory params_) internal view virtual override returns (bytes32) {
        return _delegationDigest(manager_, _limitDelegation(manager_, params_));
    }

    function _limitCalldata(
        address manager_,
        LimitParams memory params_,
        bytes memory signature_
    )
        internal
        pure
        virtual
        override
        returns (bytes memory)
    {
        Delegation memory delegation_ = _limitDelegation(manager_, params_);
        delegation_.signature = signature_;
        return _redeemDelegationsCalldata(delegation_, params_.batch);
    }

    function _cancelExact(ExactOrder memory order_) internal virtual override {
        vm.prank(order_.delegator);
        IDelegationStyleManager(manager).disableDelegation(_exactDelegation(manager, order_));
    }

    function _cancelLimit(LimitParams memory params_) internal virtual override {
        vm.prank(params_.delegator);
        IDelegationStyleManager(manager).disableDelegation(_limitDelegation(manager, params_));
    }

    function _burnNonce(address, uint256) internal virtual override {
        revert("variant-has-no-bitmap");
    }
}

function invalidateExactBatchNonce(address manager_, uint256 nonce_) {
    NonceBitmap(manager_).invalidateExactBatchNonce(nonce_);
}

function invalidateLimitOrderNonce(address manager_, uint256 nonce_) {
    NonceBitmap(manager_).invalidateLimitOrderNonce(nonce_);
}

abstract contract OrderManagerAdapter is DelegationStyleAdapter {
    function _deployManager() internal override returns (address) {
        return address(new MetaSwapOrderDelegationManager());
    }

    function _variantName() internal pure override returns (string memory) {
        return "order-manager";
    }
}

/**
 * @notice The final manager: packed calldata, flow-specific typed data, nonce bitmap, assembly hot path.
 */
abstract contract FinalAdapterBase is OptimizedHarness {
    constructor() {
        hasBitmap = true;
        supportsErc1271 = false;
        openExactSubmission = false;
        signsDelegate = false;
        hasLock = false;
    }

    /// @dev Warms both flow bitmaps (used by `warmWord` setUp). Cancel paths use flow-specific helpers.
    function _burnNonce(address delegator_, uint256 nonce_) internal override {
        vm.prank(delegator_);
        invalidateExactBatchNonce(manager, nonce_);
        vm.prank(delegator_);
        invalidateLimitOrderNonce(manager, nonce_);
    }

    function _exactDigest(address manager_, ExactOrder memory order_) internal view override returns (bytes32) {
        bytes32 structHash_ = MetaSwapManager(manager_)
            .hashExactBatch(
                order_.delegator, order_.nonce, order_.validAfter, order_.validUntil, order_.redeemers, keccak256(order_.batch)
            );
        return MessageHashUtils.toTypedDataHash(IDomainHash(manager_).getDomainHash(), structHash_);
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
        return
            bytes.concat(abi.encodePacked(MetaSwapManager.redeemExactBatch.selector), _exactHead(order_), signature_, order_.batch);
    }

    function _limitDigest(address manager_, LimitParams memory params_) internal view override returns (bytes32) {
        MetaSwapManager.LimitOrder memory order_ = MetaSwapManager.LimitOrder({
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
            MessageHashUtils.toTypedDataHash(
                IDomainHash(manager_).getDomainHash(), MetaSwapManager(manager_).hashLimitOrder(order_)
            );
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
        bytes memory head_ = abi.encodePacked(
            MetaSwapManager.redeemLimitOrder.selector,
            params_.delegator,
            params_.nonce,
            params_.metaSwap,
            params_.tokenIn,
            params_.tokenInAmount,
            params_.approvalMode
        );
        bytes memory terms_ = abi.encodePacked(
            params_.tokenOut,
            params_.recipient,
            params_.tokenOutMin,
            params_.validAfter,
            params_.validUntil,
            uint8(params_.redeemers.length)
        );
        return bytes.concat(head_, terms_, _packAddresses(params_.redeemers), signature_, params_.batch);
    }

    function _cancelExact(ExactOrder memory order_) internal override {
        vm.prank(order_.delegator);
        invalidateExactBatchNonce(manager, order_.nonce);
    }

    function _cancelLimit(LimitParams memory params_) internal override {
        vm.prank(params_.delegator);
        invalidateLimitOrderNonce(manager, params_.nonce);
    }
}

abstract contract FinalAdapter is FinalAdapterBase {
    function _deployManager() internal override returns (address) {
        return address(new MetaSwapManager());
    }

    function _variantName() internal pure override returns (string memory) {
        return "final-combined";
    }
}
