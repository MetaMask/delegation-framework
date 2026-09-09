// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";
import { Counter } from "../utils/Counter.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ChainlinkPriceRuleEnforcer } from "../../src/enforcers/ChainlinkPriceRuleEnforcer.sol";
import { ChainlinkPriceRuleLib } from "../../src/libraries/ChainlinkPriceRuleLib.sol";
import { MockChainlinkAggregator } from "../utils/MockChainlinkAggregator.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ChainlinkPriceRuleEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////// State //////////////////////

    ChainlinkPriceRuleEnforcer public chainlinkEnforcer;
    MockChainlinkAggregator public mockFeed;

    address public priceFeed;
    uint32 public windowSeconds = 3600;
    uint16 public thresholdBps = 1000;
    uint32 public maxStaleSeconds = 120;
    uint32 public minGapSeconds = 60;
    int256 public triggerPrice = 0;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        chainlinkEnforcer = new ChainlinkPriceRuleEnforcer();
        vm.label(address(chainlinkEnforcer), "Chainlink Price Rule Enforcer");

        mockFeed = new MockChainlinkAggregator();
        vm.label(address(mockFeed), "Mock Chainlink Aggregator");
        priceFeed = address(mockFeed);

        // Advance to a realistic timestamp so `block.timestamp - windowSeconds` doesn't underflow.
        skip(2 hours);
    }

    ////////////////////// Helpers //////////////////////

    function _terms(
        uint8 _ruleKind,
        uint32 _windowSeconds,
        uint16 _thresholdBps,
        int256 _triggerPrice,
        uint32 _minGapSeconds
    )
        internal
        view
        returns (bytes memory)
    {
        ChainlinkPriceRuleLib.Terms memory t_ = ChainlinkPriceRuleLib.Terms({
            priceFeed: priceFeed,
            ruleKind: _ruleKind,
            expectedDecimals: 8,
            windowSeconds: _windowSeconds,
            thresholdBps: _thresholdBps,
            maxStaleSeconds: maxStaleSeconds,
            minGapSeconds: _minGapSeconds,
            triggerPrice: _triggerPrice
        });
        return ChainlinkPriceRuleLib.encodeTerms(t_);
    }

    function _args(uint80 _referenceRoundId) internal pure returns (bytes memory) {
        return abi.encode(_referenceRoundId);
    }

    function _executionCalldata() internal view returns (bytes memory) {
        Execution memory execution_ = Execution({
            target: address(aliceDeleGatorCounter),
            value: 0,
            callData: abi.encodeWithSelector(Counter.increment.selector)
        });
        return ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
    }

    function _setLatestRound(int256 _price, uint256 _updatedAt) internal {
        uint80 roundId_ = mockFeed.latestRoundId() + 1;
        mockFeed.setRound(roundId_, _price, _updatedAt);
    }

    function _setReferenceRound(uint80 _roundId, int256 _price, uint256 _updatedAt) internal {
        mockFeed.setRound(_roundId, _price, _updatedAt);
    }

    function _callEnforcer(bytes memory t_, bytes memory a_) internal {
        vm.prank(address(delegationManager));
        chainlinkEnforcer.beforeHook(
            t_,
            a_,
            singleDefaultMode,
            _executionCalldata(),
            keccak256(""),
            address(0),
            address(0)
        );
    }

    ////////////////////// Valid cases — DIP //////////////////////

    function test_dipPassesAtExactThreshold() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(900, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        _callEnforcer(terms_, _args(1));
    }

    function test_dipPassesAboveThreshold() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(850, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        _callEnforcer(terms_, _args(1));
    }

    ////////////////////// Valid cases — RISE //////////////////////

    function test_risePassesAtExactThreshold() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(1100, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_RISE, windowSeconds, thresholdBps, 0, minGapSeconds);
        _callEnforcer(terms_, _args(1));
    }

    function test_risePassesAboveThreshold() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(1200, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_RISE, windowSeconds, thresholdBps, 0, minGapSeconds);
        _callEnforcer(terms_, _args(1));
    }

    ////////////////////// Valid cases — ABSOLUTE //////////////////////

    function test_absoluteGtePasses() public {
        _setLatestRound(5000, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_ABSOLUTE_GTE, 0, 0, 4000, 0);
        _callEnforcer(terms_, _args(0));
    }

    function test_absoluteLtePasses() public {
        _setLatestRound(3000, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_ABSOLUTE_LTE, 0, 0, 4000, 0);
        _callEnforcer(terms_, _args(0));
    }

    function test_absoluteGtePassesAtExactTrigger() public {
        _setLatestRound(4000, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_ABSOLUTE_GTE, 0, 0, 4000, 0);
        _callEnforcer(terms_, _args(0));
    }

    function test_absoluteLtePassesAtExactTrigger() public {
        _setLatestRound(4000, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_ABSOLUTE_LTE, 0, 0, 4000, 0);
        _callEnforcer(terms_, _args(0));
    }

    ////////////////////// Invalid cases — DIP/RISE fail //////////////////////

    function test_dipFailsBelowThreshold() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(950, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:price-rule-not-met");
        _callEnforcer(terms_, _args(1));
    }

    function test_dipFailsWhenPriceRose() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(1100, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:price-rule-not-met");
        _callEnforcer(terms_, _args(1));
    }

    function test_riseFailsBelowThreshold() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(1050, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_RISE, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:price-rule-not-met");
        _callEnforcer(terms_, _args(1));
    }

    function test_riseFailsWhenPriceFell() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(900, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_RISE, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:price-rule-not-met");
        _callEnforcer(terms_, _args(1));
    }

    ////////////////////// Invalid cases — ABSOLUTE fail //////////////////////

    function test_absoluteGteFails() public {
        _setLatestRound(3000, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_ABSOLUTE_GTE, 0, 0, 4000, 0);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:price-rule-not-met");
        _callEnforcer(terms_, _args(0));
    }

    function test_absoluteLteFails() public {
        _setLatestRound(5000, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_ABSOLUTE_LTE, 0, 0, 4000, 0);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:price-rule-not-met");
        _callEnforcer(terms_, _args(0));
    }

    ////////////////////// Invalid cases — staleness //////////////////////

    function test_revertStaleCurrentPrice() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(900, block.timestamp - maxStaleSeconds - 1);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:stale-current-price");
        _callEnforcer(terms_, _args(1));
    }

    function test_revertZeroCurrentPrice() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(0, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:invalid-current-price");
        _callEnforcer(terms_, _args(1));
    }

    function test_revertNegativeCurrentPrice() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(-1, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:invalid-current-price");
        _callEnforcer(terms_, _args(1));
    }

    function test_revertZeroReferencePrice() public {
        _setReferenceRound(1, 0, block.timestamp - 1800);
        _setLatestRound(900, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:invalid-reference-price");
        _callEnforcer(terms_, _args(1));
    }

    function test_revertNegativeReferencePrice() public {
        _setReferenceRound(1, -5, block.timestamp - 1800);
        _setLatestRound(900, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:invalid-reference-price");
        _callEnforcer(terms_, _args(1));
    }

    ////////////////////// Invalid cases — window / minGap //////////////////////

    function test_revertReferenceOutsideWindow() public {
        _setReferenceRound(1, 1000, block.timestamp - windowSeconds - 1);
        _setLatestRound(900, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:reference-outside-window");
        _callEnforcer(terms_, _args(1));
    }

    function test_revertReferenceTooRecent() public {
        _setReferenceRound(1, 1000, block.timestamp - 30);
        _setLatestRound(900, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:reference-too-recent");
        _callEnforcer(terms_, _args(1));
    }

    function test_minGapZeroStillBlocksFutureTimestamp() public {
        // minGap=0 now means "only block future timestamps", not "disabled"
        _setReferenceRound(1, 1000, block.timestamp - 10);
        _setLatestRound(900, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, 0);
        _callEnforcer(terms_, _args(1));
    }

    function test_revertZeroReferenceRoundId() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(900, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:invalid-reference-round-id");
        _callEnforcer(terms_, _args(0));
    }

    ////////////////////// Invalid cases — terms validation //////////////////////

    function test_revertInvalidTermsLength() public {
        bytes memory terms_ = abi.encodePacked(uint32(1));
        vm.expectRevert("ChainlinkPriceRuleLib:invalid-terms-length");
        _callEnforcer(terms_, _args(1));
    }

    function test_revertZeroPriceFeed() public {
        ChainlinkPriceRuleLib.Terms memory t_ = ChainlinkPriceRuleLib.Terms({
            priceFeed: address(0),
            ruleKind: ChainlinkPriceRuleLib.RULE_KIND_DIP,
            expectedDecimals: 8,
            windowSeconds: windowSeconds,
            thresholdBps: thresholdBps,
            maxStaleSeconds: maxStaleSeconds,
            minGapSeconds: minGapSeconds,
            triggerPrice: 0
        });
        bytes memory terms_ = ChainlinkPriceRuleLib.encodeTerms(t_);
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(900, block.timestamp);
        vm.expectRevert("ChainlinkPriceRuleLib:invalid-zero-price-feed");
        _callEnforcer(terms_, _args(1));
    }

    function test_revertInvalidRuleKind() public {
        bytes memory terms_ = abi.encodePacked(
            priceFeed,
            uint8(99),
            uint8(8),
            uint32(0),
            uint16(0),
            maxStaleSeconds,
            uint32(0),
            int256(0)
        );
        _setLatestRound(900, block.timestamp);
        vm.expectRevert("ChainlinkPriceRuleLib:invalid-rule-kind");
        _callEnforcer(terms_, _args(0));
    }

    function test_revertZeroMaxStale() public {
        bytes memory terms_ = abi.encodePacked(
            priceFeed,
            uint8(ChainlinkPriceRuleLib.RULE_KIND_ABSOLUTE_GTE),
            uint8(8),
            uint32(0),
            uint16(0),
            uint32(0),
            uint32(0),
            int256(4000)
        );
        _setLatestRound(5000, block.timestamp);
        vm.expectRevert("ChainlinkPriceRuleLib:invalid-zero-max-stale");
        _callEnforcer(terms_, _args(0));
    }

    function test_revertRelativeRuleZeroWindow() public {
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, 0, thresholdBps, 0, minGapSeconds);
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(900, block.timestamp);
        vm.expectRevert("ChainlinkPriceRuleLib:invalid-zero-window");
        _callEnforcer(terms_, _args(1));
    }

    function test_revertAbsoluteRuleZeroTrigger() public {
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_ABSOLUTE_GTE, 0, 0, 0, 0);
        _setLatestRound(5000, block.timestamp);
        vm.expectRevert("ChainlinkPriceRuleLib:invalid-zero-trigger");
        _callEnforcer(terms_, _args(0));
    }

    function test_revertInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        chainlinkEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// New security fix tests (#2-#7) //////////////////////

    // #2: answeredInRound == 0 on current round reverts
    function test_revertStaleCurrentRound() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        // Set latest round with answeredInRound = 0 (incomplete)
        mockFeed.setRoundWithAnswered(2, 900, block.timestamp, 0);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:stale-current-round");
        _callEnforcer(terms_, _args(1));
    }

    // #2: answeredInRound == 0 on reference round reverts
    function test_revertStaleReferenceRound() public {
        // Reference round with answeredInRound = 0
        mockFeed.setRoundWithAnswered(1, 1000, block.timestamp - 1800, 0);
        _setLatestRound(900, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:stale-reference-round");
        _callEnforcer(terms_, _args(1));
    }

    // #4: updatedAtNow == 0 reverts
    function test_revertUpdatedAtNowZero() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        // Set latest round with updatedAt = 0
        mockFeed.setRoundWithAnswered(2, 900, 0, 2);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:invalid-updated-at-now");
        _callEnforcer(terms_, _args(1));
    }

    // #5: referenceRoundId >= latestRoundId reverts
    function test_revertReferenceNotOlder() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(900, block.timestamp);
        // latest round is 2; pass referenceRoundId = 2 (same as latest)
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:reference-not-older");
        _callEnforcer(terms_, _args(2));
    }

    // #5: referenceRoundId > latestRoundId reverts (non-existent future round)
    function test_revertReferenceNewerThanLatest() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(900, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:reference-not-older");
        _callEnforcer(terms_, _args(99));
    }

    // #7: feed.decimals() != expectedDecimals reverts
    function test_revertDecimalsMismatch() public {
        _setReferenceRound(1, 1000, block.timestamp - 1800);
        _setLatestRound(900, block.timestamp);
        // Set mock feed decimals to 6, but terms expect 8
        mockFeed.setDecimals(6);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, minGapSeconds);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:decimals-mismatch");
        _callEnforcer(terms_, _args(1));
    }

    // #7: expectedDecimals == 0 reverts in validateTerms
    function test_revertInvalidDecimalsZero() public {
        bytes memory terms_ = abi.encodePacked(
            priceFeed,
            uint8(ChainlinkPriceRuleLib.RULE_KIND_ABSOLUTE_GTE),
            uint8(0), // expectedDecimals = 0
            uint32(0),
            uint16(0),
            maxStaleSeconds,
            uint32(0),
            int256(4000)
        );
        _setLatestRound(5000, block.timestamp);
        vm.expectRevert("ChainlinkPriceRuleLib:invalid-decimals");
        _callEnforcer(terms_, _args(0));
    }

    // #7: expectedDecimals > 18 reverts in validateTerms
    function test_revertInvalidDecimalsTooHigh() public {
        bytes memory terms_ = abi.encodePacked(
            priceFeed,
            uint8(ChainlinkPriceRuleLib.RULE_KIND_ABSOLUTE_GTE),
            uint8(19), // expectedDecimals = 19 (> 18)
            uint32(0),
            uint16(0),
            maxStaleSeconds,
            uint32(0),
            int256(4000)
        );
        _setLatestRound(5000, block.timestamp);
        vm.expectRevert("ChainlinkPriceRuleLib:invalid-decimals");
        _callEnforcer(terms_, _args(0));
    }

    // #6: future updatedAtRef reverts even when minGapSeconds == 0
    function test_revertFutureUpdatedAtRefMinGapZero() public {
        _setReferenceRound(1, 1000, block.timestamp + 100); // future timestamp
        _setLatestRound(900, block.timestamp);
        bytes memory terms_ = _terms(ChainlinkPriceRuleLib.RULE_KIND_DIP, windowSeconds, thresholdBps, 0, 0);
        vm.expectRevert("ChainlinkPriceRuleEnforcer:reference-too-recent");
        _callEnforcer(terms_, _args(1));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(chainlinkEnforcer));
    }
}
