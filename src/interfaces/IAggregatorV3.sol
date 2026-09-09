// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title IAggregatorV3
 * @notice Minimal inlined subset of Chainlink `AggregatorV3Interface` for reading price feed rounds.
 * @dev Pin the proxy address (not the underlying aggregator) in caveat terms so upgrades do not affect consumers.
 * Reference: https://docs.chain.link/data-feeds/api-reference
 */
interface IAggregatorV3 {
    /**
     * @notice Returns the decimals of the feed (e.g. 8 for USD pairs).
     */
    function decimals() external view returns (uint8);

    /**
     * @notice Returns the latest round data.
     * @return roundId_ The round ID.
     * @return answer_ The price for the round (scaled by `decimals()`).
     * @return startedAt_ Timestamp when the round started.
     * @return updatedAt_ Timestamp when the round was last updated.
     * @return answeredInRound_ The round ID in which the answer was computed.
     */
    function latestRoundData()
        external
        view
        returns (uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_);

    /**
     * @notice Returns the round data for a specific round ID.
     * @param _roundId The round ID to query.
     * @return roundId_ The round ID.
     * @return answer_ The price for the round (scaled by `decimals()`).
     * @return startedAt_ Timestamp when the round started.
     * @return updatedAt_ Timestamp when the round was last updated.
     * @return answeredInRound_ The round ID in which the answer was computed.
     */
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_);
}
