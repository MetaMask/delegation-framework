// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { MetaSwapOrderDelegationManager } from "../../../src/MetaSwapOrderDelegationManager.sol";
import { Caveat, Delegation, ModeCode } from "../../../src/utils/Types.sol";
import { ExactGasComparison, LimitGasComparison } from "./GasComparisonFixture.t.sol";

/// @notice `MetaSwapOrderDelegationManager`: flexible settlement for limit, `ExactBatch` for exact.
contract OrderDelegationManagerGasTest is LimitGasComparison, ExactGasComparison {
    uint256 private constant ORDER_ID = 1;

    MetaSwapOrderDelegationManager private orderManager;

    function _comparisonName() internal pure override returns (string memory) {
        return "OrderDelegationManager";
    }

    function _installComparison() internal override {
        orderManager = new MetaSwapOrderDelegationManager();
        _installUser(address(orderManager));
    }

    function _armLater(Shape shape_) internal override {
        _prepareLaterFill(shape_, address(orderManager), 3, false);
    }

    function _run(Shape shape_) internal override returns (uint256) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(orderManager), terms: _terms(shape_), args: hex"" });
        Delegation[] memory chains_ = new Delegation[](1);
        chains_[0] =
            _signRoot(orderManager.ANY_DELEGATE(), orderManager.ROOT_AUTHORITY(), orderManager.getDomainHash(), caveats_, 1);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = orderManager.SIMPLE_BATCH_MODE();
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeBatch(_executions(shape_));
        return _redeemDelegations(address(orderManager), chains_, modes_, executionCallDatas_, shape_);
    }

    function _terms(Shape shape_) private view returns (bytes memory) {
        (address tokenIn_, address tokenOut_, uint8 mode_) = _fields(shape_);
        return abi.encodePacked(
            uint8(MetaSwapOrderDelegationManager.Intent.FlexibleSettlement),
            address(metaSwap),
            tokenIn_,
            TOKEN_IN_AMOUNT,
            mode_,
            tokenOut_,
            user,
            TOKEN_OUT_MIN,
            uint128(0),
            expiresAt,
            ORDER_ID,
            _redeemerTerms()
        );
    }

    function _fields(Shape shape_) private view returns (address tokenIn_, address tokenOut_, uint8 mode_) {
        if (shape_ == Shape.NativeToErc20) {
            return (address(0), address(tokenOut), uint8(MetaSwapOrderDelegationManager.ApprovalMode.None));
        }
        tokenIn_ = address(tokenIn);
        tokenOut_ = shape_ == Shape.Erc20ToNative ? address(0) : address(tokenOut);
        mode_ = uint8(MetaSwapOrderDelegationManager.ApprovalMode.Approve);
    }

    function _armLaterExact(Shape shape_) internal override {
        _prepareLaterGaslessBalances(shape_);
    }

    /// @dev Terms are `intent | validAfter | validUntil | keccak256(batch) | four redeemers`.
    ///      `ANY_DELEGATE` leaves the redeemer list as the caller check. A later order is a new delegation hash.
    function _runExact(Shape shape_) internal override returns (uint256) {
        bytes memory batch_ = ExecutionLib.encodeBatch(_gaslessExecutions(shape_));
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            enforcer: address(orderManager),
            terms: abi.encodePacked(
                uint8(MetaSwapOrderDelegationManager.Intent.ExactBatch), uint128(0), expiresAt, keccak256(batch_), _redeemerTerms()
            ),
            args: hex""
        });
        Delegation[] memory chains_ = new Delegation[](1);
        chains_[0] =
            _signRoot(orderManager.ANY_DELEGATE(), orderManager.ROOT_AUTHORITY(), orderManager.getDomainHash(), caveats_, 1);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = orderManager.SIMPLE_BATCH_MODE();
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = batch_;
        return _redeemDelegationsGasless(address(orderManager), chains_, modes_, executionCallDatas_, shape_);
    }
}
