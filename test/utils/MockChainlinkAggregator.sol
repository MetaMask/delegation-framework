// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";

/**
 * @title MockChainlinkAggregator
 * @notice Test-only mock of a Chainlink `AggregatorV3` proxy. Stores rounds in storage and returns them
 *        via `latestRoundData` / `getRoundData`. Prices are int256 (feed decimals handled by caller).
 */
contract MockChainlinkAggregator is IAggregatorV3 {
    struct Round {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    uint8 public decimals = 8;
    uint80 public latestRoundId;
    mapping(uint80 => Round) public rounds;

    event RoundSet(uint80 indexed roundId, int256 answer, uint256 updatedAt);

    /**
     * @notice Sets a round and marks it as the latest.
     * @param _roundId   Round identifier (caller-controlled).
     * @param _answer    Price answer (feed decimals).
     * @param _updatedAt Timestamp the round was updated.
     */
    function setRound(uint80 _roundId, int256 _answer, uint256 _updatedAt) external {
        rounds[_roundId] = Round({
            roundId: _roundId,
            answer: _answer,
            startedAt: _updatedAt,
            updatedAt: _updatedAt,
            answeredInRound: _roundId
        });
        if (_roundId > latestRoundId) {
            latestRoundId = _roundId;
        }
        emit RoundSet(_roundId, _answer, _updatedAt);
    }

    /**
     * @notice Sets a round with a custom `answeredInRound` value (use 0 to simulate an incomplete/stale round).
     */
    function setRoundWithAnswered(
        uint80 _roundId,
        int256 _answer,
        uint256 _updatedAt,
        uint80 _answeredInRound
    )
        external
    {
        rounds[_roundId] = Round({
            roundId: _roundId,
            answer: _answer,
            startedAt: _updatedAt,
            updatedAt: _updatedAt,
            answeredInRound: _answeredInRound
        });
        if (_roundId > latestRoundId) {
            latestRoundId = _roundId;
        }
        emit RoundSet(_roundId, _answer, _updatedAt);
    }

    /**
     * @notice Sets the latest round id without adding a new round (useful for testing stale/latest edge cases).
     */
    function setLatestRoundId(uint80 _roundId) external {
        latestRoundId = _roundId;
    }

    function setDecimals(uint8 _decimals) external {
        decimals = _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
    {
        Round memory r_ = rounds[latestRoundId];
        return (r_.roundId, r_.answer, r_.startedAt, r_.updatedAt, r_.answeredInRound);
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
    {
        Round memory r_ = rounds[_roundId];
        require(r_.roundId != 0 || _roundId == 0, "MockChainlinkAggregator:round-not-found");
        return (r_.roundId, r_.answer, r_.startedAt, r_.updatedAt, r_.answeredInRound);
    }
}
