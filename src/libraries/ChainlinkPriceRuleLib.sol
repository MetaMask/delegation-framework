// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title ChainlinkPriceRuleLib
 * @notice Shared types and helpers for Chainlink price-rule caveat enforcers.
 * @dev Terms are packed via `abi.encodePacked` and signed by the delegator at grant time.
 *      The enforcer reads the current price from `latestRoundData()` (never from args) and the
 *      reference price from `getRoundData(args.referenceRoundId)`, validating the reference
 *      round's `updatedAt` against the user-specified time window.
 */
library ChainlinkPriceRuleLib {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant TERMS_LENGTH = 68;

    /**
     * @notice Rule kind controlling how prices are compared.
     * @dev Values are stored as `uint8` at terms offset 20. Using `uint8` (not the enum) in `Terms` avoids
     *      reverts during `decodeTerms` when an out-of-range value is supplied; `validateTerms` checks the range.
     */
    uint8 internal constant RULE_KIND_DIP = 0;
    uint8 internal constant RULE_KIND_RISE = 1;
    uint8 internal constant RULE_KIND_ABSOLUTE_GTE = 2;
    uint8 internal constant RULE_KIND_ABSOLUTE_LTE = 3;

    /**
     * @notice Packed terms (68 bytes) pinned by the delegator at grant time.
     * @dev Layout:
     *      offset 0   : priceFeed        (20 bytes, address)
     *      offset 20  : ruleKind         (1 byte,  uint8) — see RULE_KIND_* constants
     *      offset 21  : expectedDecimals  (1 byte,  uint8) — must match feed.decimals()
     *      offset 22  : windowSeconds    (4 bytes, uint32)
     *      offset 26  : thresholdBps    (2 bytes, uint16)
     *      offset 28  : maxStaleSeconds  (4 bytes, uint32)
     *      offset 32  : minGapSeconds   (4 bytes, uint32)
     *      offset 36  : triggerPrice    (32 bytes, int256)
     */
    struct Terms {
        address priceFeed;
        uint8 ruleKind;
        uint8 expectedDecimals;
        uint32 windowSeconds;
        uint16 thresholdBps;
        uint32 maxStaleSeconds;
        uint32 minGapSeconds;
        int256 triggerPrice;
    }

    function encodeTerms(Terms memory _terms) internal pure returns (bytes memory terms_) {
        terms_ = abi.encodePacked(
            _terms.priceFeed,
            uint8(_terms.ruleKind),
            uint8(_terms.expectedDecimals),
            _terms.windowSeconds,
            _terms.thresholdBps,
            _terms.maxStaleSeconds,
            _terms.minGapSeconds,
            _terms.triggerPrice
        );
    }

    function decodeTerms(bytes calldata _terms) internal pure returns (Terms memory terms_) {
        require(_terms.length == TERMS_LENGTH, "ChainlinkPriceRuleLib:invalid-terms-length");

        terms_.priceFeed = address(bytes20(_terms[0:20]));
        terms_.ruleKind = uint8(_terms[20]);
        terms_.expectedDecimals = uint8(_terms[21]);
        terms_.windowSeconds = uint32(bytes4(_terms[22:26]));
        terms_.thresholdBps = uint16(bytes2(_terms[26:28]));
        terms_.maxStaleSeconds = uint32(bytes4(_terms[28:32]));
        terms_.minGapSeconds = uint32(bytes4(_terms[32:36]));
        terms_.triggerPrice = int256(uint256(bytes32(_terms[36:68])));
    }

    /**
     * @notice Validates terms at grant and execution time.
     * @dev Reverts on invalid configuration. Relative rules require a positive window and threshold;
     *      absolute rules require a non-zero trigger price; `maxStaleSeconds` must be positive.
     */
    function validateTerms(Terms memory _terms) internal pure {
        require(_terms.priceFeed != address(0), "ChainlinkPriceRuleLib:invalid-zero-price-feed");
        require(_terms.ruleKind <= RULE_KIND_ABSOLUTE_LTE, "ChainlinkPriceRuleLib:invalid-rule-kind");
        require(_terms.maxStaleSeconds > 0, "ChainlinkPriceRuleLib:invalid-zero-max-stale");
        require(
            _terms.expectedDecimals > 0 && _terms.expectedDecimals <= 18,
            "ChainlinkPriceRuleLib:invalid-decimals"
        );

        if (_terms.ruleKind == RULE_KIND_DIP || _terms.ruleKind == RULE_KIND_RISE) {
            require(_terms.windowSeconds > 0, "ChainlinkPriceRuleLib:invalid-zero-window");
            require(_terms.thresholdBps > 0, "ChainlinkPriceRuleLib:invalid-zero-threshold");
            require(
                _terms.thresholdBps < BPS_DENOMINATOR,
                "ChainlinkPriceRuleLib:invalid-threshold-bps"
            );
        } else {
            require(_terms.triggerPrice > 0, "ChainlinkPriceRuleLib:invalid-zero-trigger");
        }
    }

    /**
     * @notice Returns true if `priceNow` satisfies the relative rule vs `priceRef`.
     * @dev Caller must ensure `priceRef > 0`. Uses unsigned math on int256 values known to be positive.
     */
    function meetsRelativeRule(
        uint8 _ruleKind,
        int256 _priceNow,
        int256 _priceRef,
        uint16 _thresholdBps
    )
        internal
        pure
        returns (bool)
    {
        uint256 priceNow_ = uint256(_priceNow);
        uint256 priceRef_ = uint256(_priceRef);

        if (_ruleKind == RULE_KIND_DIP) {
            if (priceNow_ >= priceRef_) return false;
            uint256 dropBps_ = ((priceRef_ - priceNow_) * BPS_DENOMINATOR) / priceRef_;
            return dropBps_ >= uint256(_thresholdBps);
        } else if (_ruleKind == RULE_KIND_RISE) {
            if (priceNow_ <= priceRef_) return false;
            uint256 riseBps_ = ((priceNow_ - priceRef_) * BPS_DENOMINATOR) / priceRef_;
            return riseBps_ >= uint256(_thresholdBps);
        }
        return false;
    }

    /**
     * @notice Returns true if `priceNow` satisfies the absolute rule vs `triggerPrice`.
     */
    function meetsAbsoluteRule(uint8 _ruleKind, int256 _priceNow, int256 _triggerPrice) internal pure returns (bool) {
        if (_ruleKind == RULE_KIND_ABSOLUTE_GTE) {
            return _priceNow >= _triggerPrice;
        } else if (_ruleKind == RULE_KIND_ABSOLUTE_LTE) {
            return _priceNow <= _triggerPrice;
        }
        return false;
    }

    function isRelativeRule(uint8 _ruleKind) internal pure returns (bool) {
        return _ruleKind == RULE_KIND_DIP || _ruleKind == RULE_KIND_RISE;
    }
}
