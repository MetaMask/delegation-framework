// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MetaSwapDelegationManagerBase } from "./MetaSwapDelegationManagerBase.sol";

/**
 * @title MetaSwapFlexibleSettlementManagerBase
 * @notice Shared flexible MetaSwap settlement decoding and min-output enforcement.
 * @dev Used by the hookless and execution-builder prototype managers.
 */
abstract contract MetaSwapFlexibleSettlementManagerBase is MetaSwapDelegationManagerBase {
    enum ApprovalMode {
        None,
        SkipApproval,
        Approve,
        ResetApprove
    }

    struct Terms {
        address metaSwap;
        address tokenIn;
        uint256 tokenInAmount;
        ApprovalMode approvalMode;
        address tokenOut;
        address recipient;
        uint256 tokenOutMin;
    }

    uint256 internal constant TERMS_LENGTH = 145;

    constructor(string memory name_, SignatureMode signatureMode_) MetaSwapDelegationManagerBase(name_, signatureMode_) { }

    /**
     * @notice Decodes and validates packed settlement terms.
     * @param terms_ Packed settlement terms.
     */
    function getTermsInfo(bytes memory terms_) public pure returns (Terms memory termsInfo_) {
        if (terms_.length != TERMS_LENGTH) revert InvalidTerms();

        // Terms are tightly packed. Loading their fixed offsets directly avoids allocating seven temporary byte arrays.
        assembly ("memory-safe") {
            let termsData_ := add(terms_, 0x20)
            mstore(termsInfo_, shr(96, mload(termsData_)))
            mstore(add(termsInfo_, 0x20), shr(96, mload(add(termsData_, 20))))
            mstore(add(termsInfo_, 0x40), mload(add(termsData_, 40)))
            mstore(add(termsInfo_, 0x80), shr(96, mload(add(termsData_, 73))))
            mstore(add(termsInfo_, 0xa0), shr(96, mload(add(termsData_, 93))))
            mstore(add(termsInfo_, 0xc0), mload(add(termsData_, 113)))
        }
        uint8 approvalMode_ = uint8(terms_[72]);

        if (
            termsInfo_.metaSwap == address(0) || termsInfo_.tokenInAmount == 0 || termsInfo_.recipient == address(0)
                || termsInfo_.tokenOutMin == 0 || termsInfo_.tokenIn == termsInfo_.tokenOut
        ) {
            revert InvalidTerms();
        }
        if (approvalMode_ > uint8(ApprovalMode.ResetApprove)) revert InvalidApprovalMode();
        termsInfo_.approvalMode = ApprovalMode(approvalMode_);
    }

    function _executeIntent(address delegator_, bytes memory terms_, bytes calldata executionContext_) internal override {
        Terms memory termsInfo_ = getTermsInfo(terms_);
        uint256 balanceBefore_ = _balanceOf(termsInfo_.tokenOut, termsInfo_.recipient);

        _executeSettlement(delegator_, executionContext_, termsInfo_);

        uint256 balanceAfter_ = _balanceOf(termsInfo_.tokenOut, termsInfo_.recipient);
        if (balanceAfter_ < balanceBefore_ || balanceAfter_ - balanceBefore_ < termsInfo_.tokenOutMin) {
            revert InsufficientOutput();
        }
    }

    function _executeSettlement(address delegator_, bytes calldata executionContext_, Terms memory termsInfo_) internal virtual;
}
