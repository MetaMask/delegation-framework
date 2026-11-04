// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Caveat, Delegation, ModeCode } from "../../../src/utils/Types.sol";
import { MetaSwapFlexibleSettlementEnforcer } from "../baseline/vendor/MetaSwapFlexibleSettlementEnforcer.sol";
import { GasComparisonFixture, LimitGasComparison } from "./GasComparisonFixture.t.sol";

/// @notice One delegation. `MetaSwapFlexibleSettlementEnforcer` checks the whole limit order.
contract FlexibleSettlementEnforcerGasTest is LimitGasComparison {
    uint256 private constant ORDER_ID = 1;

    MetaSwapFlexibleSettlementEnforcer private flexible;

    function _comparisonName() internal pure override returns (string memory) {
        return "FlexibleSettlementEnforcer";
    }

    function _installComparison() internal override {
        flexible = new MetaSwapFlexibleSettlementEnforcer();
        _installUser(address(delegationManager));
    }

    function _armLater(Shape shape_) internal override {
        _prepareLaterFill(shape_, address(flexible), 0, true);
    }

    function _run(Shape shape_) internal override returns (uint256) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ enforcer: address(flexible), terms: _terms(shape_), args: hex"" });
        Delegation[] memory chains_ = new Delegation[](1);
        chains_[0] = _signRoot(ANY_DELEGATE, ROOT_AUTHORITY, delegationManager.getDomainHash(), caveats_, 1);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = _batchMode();
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeBatch(_executions(shape_));
        return _redeemDelegations(address(delegationManager), chains_, modes_, executionCallDatas_, shape_);
    }

    function _terms(Shape shape_) private view returns (bytes memory) {
        (address tokenIn_, address tokenOut_, uint8 mode_) = _fields(shape_);
        return abi.encodePacked(
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
            return (address(0), address(tokenOut), uint8(MetaSwapFlexibleSettlementEnforcer.ApprovalMode.None));
        }
        tokenIn_ = address(tokenIn);
        tokenOut_ = shape_ == Shape.Erc20ToNative ? address(0) : address(tokenOut);
        mode_ = uint8(MetaSwapFlexibleSettlementEnforcer.ApprovalMode.Approve);
    }
}
