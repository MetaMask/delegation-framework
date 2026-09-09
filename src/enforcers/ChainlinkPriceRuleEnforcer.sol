// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ChainlinkPriceRuleLib } from "../libraries/ChainlinkPriceRuleLib.sol";
import { IAggregatorV3 } from "../interfaces/IAggregatorV3.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title ChainlinkPriceRuleEnforcer
 * @notice Gates a delegation's redemption on a Chainlink price condition.
 * @dev Supports four rule kinds (see `ChainlinkPriceRuleLib` RULE_KIND_* constants):
 *        - Dip (0): price fell >= thresholdBps over <= windowSeconds
 *        - Rise (1): price rose >= thresholdBps over <= windowSeconds
 *        - AbsoluteGte (2): current price >= triggerPrice
 *        - AbsoluteLte (3): current price <= triggerPrice
 *
 *      The current price is always read from `latestRoundData()` on `terms.priceFeed` (never from args).
 *      The reference price (for relative rules) is read from `getRoundData(args.referenceRoundId)`,
 *      with `updatedAt` validated against the user-specified time window.
 *
 *      This enforcer operates only in single execution call type and with default execution mode.
 *      `afterHook` is a no-op; the price check is pre-execution only and writes no state.
 *
 * @custom:assumptions
 *      - `msg.sender` is expected to be the DelegationManager (consistent with other enforcers).
 *      - The pinned `priceFeed` must be a trusted Chainlink proxy. v1 does NOT validate the feed address
 *        against a registry. Integrators building delegation-construction UIs MUST hard-verify the feed
 *        address (e.g. against the Chainlink feeds list at https://docs.chain.link/data-feeds/price-feeds/addresses)
 *        before presenting terms to the user for signing. A malicious feed address completely bypasses
 *        all price checks and allows the redeemer to trigger the rule at will.
 *      - On L2s, consider also using a sequencer uptime feed; this enforcer only checks `maxStaleSeconds`.
 */
contract ChainlinkPriceRuleEnforcer is CaveatEnforcer {
    using ChainlinkPriceRuleLib for ChainlinkPriceRuleLib.Terms;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Hook called before execution; reverts if the price rule is not satisfied.
     * @param _terms 68-byte packed terms (see `ChainlinkPriceRuleLib.decodeTerms`).
     * @param _args abi.encode(uint80 referenceRoundId); `referenceRoundId` is ignored for absolute rules.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode _mode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        ChainlinkPriceRuleLib.Terms memory terms_ = ChainlinkPriceRuleLib.decodeTerms(_terms);
        terms_.validateTerms();

        uint80 referenceRoundId_ = abi.decode(_args, (uint80));

        IAggregatorV3 feed_ = IAggregatorV3(terms_.priceFeed);

        // Validate feed decimals match what the delegator pinned in terms.
        require(
            feed_.decimals() == terms_.expectedDecimals,
            "ChainlinkPriceRuleEnforcer:decimals-mismatch"
        );

        (
            uint80 roundIdNow_,
            int256 priceNow_,
            ,
            uint256 updatedAtNow_,
            uint80 answeredInRoundNow_
        ) = feed_.latestRoundData();

        require(priceNow_ > 0, "ChainlinkPriceRuleEnforcer:invalid-current-price");
        require(updatedAtNow_ > 0, "ChainlinkPriceRuleEnforcer:invalid-updated-at-now");
        require(
            block.timestamp - updatedAtNow_ <= terms_.maxStaleSeconds,
            "ChainlinkPriceRuleEnforcer:stale-current-price"
        );
        require(
            answeredInRoundNow_ >= roundIdNow_,
            "ChainlinkPriceRuleEnforcer:stale-current-round"
        );

        if (ChainlinkPriceRuleLib.isRelativeRule(terms_.ruleKind)) {
            _enforceRelativeRule(terms_, feed_, referenceRoundId_, priceNow_, roundIdNow_);
        } else {
            _enforceAbsoluteRule(terms_, priceNow_);
        }
    }

    /**
     * @notice No-op afterHook; price checks are pre-execution only.
     */
    function afterHook(
        bytes calldata,
        bytes calldata,
        ModeCode _mode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    { }

    /**
     * @notice Decodes terms for inspection.
     */
    function getTermsInfo(bytes calldata _terms)
        public
        pure
        returns (ChainlinkPriceRuleLib.Terms memory terms_)
    {
        return ChainlinkPriceRuleLib.decodeTerms(_terms);
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    function _enforceRelativeRule(
        ChainlinkPriceRuleLib.Terms memory _terms,
        IAggregatorV3 _feed,
        uint80 _referenceRoundId,
        int256 _priceNow,
        uint80 _roundIdNow
    )
        private
        view
    {
        require(_referenceRoundId != 0, "ChainlinkPriceRuleEnforcer:invalid-reference-round-id");
        require(
            _referenceRoundId < _roundIdNow,
            "ChainlinkPriceRuleEnforcer:reference-not-older"
        );

        (
            ,
            int256 priceRef_,
            ,
            uint256 updatedAtRef_,
            uint80 answeredInRoundRef_
        ) = _feed.getRoundData(_referenceRoundId);
        require(priceRef_ > 0, "ChainlinkPriceRuleEnforcer:invalid-reference-price");
        require(
            answeredInRoundRef_ >= _referenceRoundId,
            "ChainlinkPriceRuleEnforcer:stale-reference-round"
        );

        // Reference round must be within the user-specified window: updatedAtRef >= now - windowSeconds.
        require(
            updatedAtRef_ >= block.timestamp - _terms.windowSeconds,
            "ChainlinkPriceRuleEnforcer:reference-outside-window"
        );

        // Anti-noise: reference round must be at least minGapSeconds old.
        // When minGapSeconds == 0, this reduces to updatedAtRef <= block.timestamp (blocks future timestamps).
        require(
            updatedAtRef_ <= block.timestamp - _terms.minGapSeconds,
            "ChainlinkPriceRuleEnforcer:reference-too-recent"
        );

        require(
            ChainlinkPriceRuleLib.meetsRelativeRule(_terms.ruleKind, _priceNow, priceRef_, _terms.thresholdBps),
            "ChainlinkPriceRuleEnforcer:price-rule-not-met"
        );
    }

    function _enforceAbsoluteRule(ChainlinkPriceRuleLib.Terms memory _terms, int256 _priceNow) private pure {
        require(
            ChainlinkPriceRuleLib.meetsAbsoluteRule(_terms.ruleKind, _priceNow, _terms.triggerPrice),
            "ChainlinkPriceRuleEnforcer:price-rule-not-met"
        );
    }
}
