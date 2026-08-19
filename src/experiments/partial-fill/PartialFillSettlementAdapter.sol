// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { IDelegationManager } from "../../interfaces/IDelegationManager.sol";
import { Delegation, ModeCode } from "../../utils/Types.sol";
import { OrderTermsLib } from "./OrderTermsLib.sol";
import { PartialFillRfqEnforcer } from "./PartialFillRfqEnforcer.sol";

/**
 * @title PartialFillSettlementAdapter
 * @notice P1 minimal settlement helper for direct bilateral partial-fill RFQs.
 * @dev Solvers must call {IDelegationManager.redeemDelegations} themselves so they remain `msg.sender`.
 *      This contract only validates order shape and encodes redemption calldata. Buy-side payment is pulled
 *      by {PartialFillRfqEnforcer} during redemption hooks.
 */
contract PartialFillSettlementAdapter {
    using OrderTermsLib for OrderTermsLib.OrderTerms;

    /// @dev Matches {DelegationManager}.ANY_DELEGATE.
    address internal constant ANY_DELEGATE = address(0xa11);

    IDelegationManager public immutable delegationManager;
    PartialFillRfqEnforcer public immutable partialFillEnforcer;

    error InvalidEmptyDelegations();
    error InvalidRootCaveat();
    error NotLeafDelegate();

    constructor(IDelegationManager _delegationManager, PartialFillRfqEnforcer _partialFillEnforcer) {
        delegationManager = _delegationManager;
        partialFillEnforcer = _partialFillEnforcer;
    }

    /// @notice Computes the minimum buy amount owed for a fill.
    function requiredBuyAmount(
        OrderTermsLib.OrderTerms calldata _terms,
        uint256 _fillSellAmount
    )
        external
        pure
        returns (uint256 buyAmount_)
    {
        buyAmount_ = OrderTermsLib.minBuyAmount(_terms, _fillSellAmount);
    }

    /// @notice Encodes the maker sell transfer execution expected by the enforcer.
    function encodeSellExecution(
        address _sellToken,
        address _solver,
        uint256 _fillSellAmount
    )
        external
        pure
        returns (bytes memory executionCalldata_)
    {
        executionCalldata_ = ExecutionLib.encodeSingle(_sellToken, 0, abi.encodeCall(IERC20.transfer, (_solver, _fillSellAmount)));
    }

    /**
     * @notice Builds canonical-manager redemption calldata for a partial fill.
     * @dev The solver must submit the returned arrays via {IDelegationManager.redeemDelegations} so it remains
     *      the redeemer for delegate checks and buy-side `transferFrom`.
     * @param _delegations Single root delegation ordered leaf-to-root.
     * @param _fillSellAmount Sell-side fill size for this redemption.
     * @param _solver Expected redeemer; must match the leaf delegate unless `ANY_DELEGATE`.
     */
    function buildFillRedemption(
        Delegation[] memory _delegations,
        uint256 _fillSellAmount,
        address _solver
    )
        external
        view
        returns (bytes[] memory permissionContexts_, ModeCode[] memory modes_, bytes[] memory executionCallDatas_)
    {
        uint256 length_ = _delegations.length;
        if (length_ == 0) revert InvalidEmptyDelegations();

        Delegation memory root_ = _delegations[length_ - 1];
        if (root_.caveats.length == 0 || root_.caveats[0].enforcer != address(partialFillEnforcer)) {
            revert InvalidRootCaveat();
        }

        if (root_.delegate != ANY_DELEGATE && root_.delegate != _solver) {
            revert NotLeafDelegate();
        }

        (OrderTermsLib.OrderTerms memory terms_,) = OrderTermsLib.decodeTerms(root_.caveats[0].terms);
        terms_.validateTerms();

        root_.caveats[0].args = abi.encode(_fillSellAmount);
        _delegations[length_ - 1] = root_;

        permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);
        modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleSingle();
        executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] =
            ExecutionLib.encodeSingle(terms_.sellToken, 0, abi.encodeCall(IERC20.transfer, (_solver, _fillSellAmount)));
    }
}
