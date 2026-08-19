// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title OrderTermsLib
 * @notice Shared signed limit-order terms for partial-fill RFQ experiments (P1/P2).
 */
library OrderTermsLib {
    struct OrderTerms {
        address sellToken;
        address buyToken;
        address receiver;
        uint256 totalSell;
        uint256 minTotalBuy;
        uint256 minFillSell;
        uint64 validAfter;
        uint64 validUntil;
        uint64 epoch;
        bool allowPartial;
    }

    error InvalidOrderTerms();
    error ZeroFillAmount();
    error FillExceedsRemaining(uint256 requested, uint256 remaining);
    error PartialFillNotAllowed();
    error FillBelowMinimum(uint256 fillSell, uint256 minFillSell);
    error LeavesDustRemainder(uint256 remainder, uint256 minFillSell);

    /// @dev Encodes order terms plus the settlement adapter bound into enforcer caveat terms.
    function encodeTerms(OrderTerms memory _terms, address _settlementAdapter) internal pure returns (bytes memory terms_) {
        terms_ = abi.encode(_terms, _settlementAdapter);
    }

    /// @dev Encodes order terms for integrated-manager (P2) caveats without an external adapter binding.
    function encodeTermsOnly(OrderTerms memory _terms) internal pure returns (bytes memory terms_) {
        terms_ = abi.encode(_terms);
    }

    function decodeTermsOnly(bytes memory _terms) internal pure returns (OrderTerms memory terms_) {
        terms_ = abi.decode(_terms, (OrderTerms));
    }

    function decodeTermsOnlyCalldata(bytes calldata _terms) internal pure returns (OrderTerms memory terms_) {
        terms_ = abi.decode(_terms, (OrderTerms));
    }

    function decodeTerms(bytes memory _terms) internal pure returns (OrderTerms memory terms_, address settlementAdapter_) {
        (terms_, settlementAdapter_) = abi.decode(_terms, (OrderTerms, address));
    }

    function decodeTermsCalldata(bytes calldata _terms)
        internal
        pure
        returns (OrderTerms memory terms_, address settlementAdapter_)
    {
        (terms_, settlementAdapter_) = abi.decode(_terms, (OrderTerms, address));
    }

    /// @notice Maker-favoring ceil pricing: minimum buy required for a sell fill size.
    function minBuyAmount(OrderTerms memory _terms, uint256 _fillSell) internal pure returns (uint256 buyAmount_) {
        buyAmount_ = Math.mulDiv(_terms.minTotalBuy, _fillSell, _terms.totalSell, Math.Rounding.Ceil);
    }

    function validateTerms(OrderTerms memory _terms) internal pure {
        if (_terms.sellToken == address(0) || _terms.buyToken == address(0)) revert InvalidOrderTerms();
        if (_terms.receiver == address(0)) revert InvalidOrderTerms();
        if (_terms.totalSell == 0 || _terms.minTotalBuy == 0) revert InvalidOrderTerms();
        if (_terms.validUntil != 0 && _terms.validUntil <= _terms.validAfter) revert InvalidOrderTerms();
    }

    /// @notice Validates a proposed fill against remaining sell capacity and partial-fill rules.
    function validateFill(OrderTerms memory _terms, uint256 _filledSell, uint256 _fillSell) internal pure {
        if (_fillSell == 0) revert ZeroFillAmount();

        uint256 remaining_ = _terms.totalSell - _filledSell;
        if (_fillSell > remaining_) revert FillExceedsRemaining(_fillSell, remaining_);

        if (!_terms.allowPartial && _fillSell != remaining_) revert PartialFillNotAllowed();

        uint256 newRemaining_ = remaining_ - _fillSell;
        if (newRemaining_ > 0) {
            if (_fillSell < _terms.minFillSell) revert FillBelowMinimum(_fillSell, _terms.minFillSell);
            if (newRemaining_ < _terms.minFillSell) revert LeavesDustRemainder(newRemaining_, _terms.minFillSell);
        }
    }
}
