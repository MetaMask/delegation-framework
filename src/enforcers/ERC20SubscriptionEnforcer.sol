// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";

/**
 * @title ERC20 Subscription Enforcer Contract
 * @dev
 */
contract ERC20SubscriptionEnforcer {
    ////////////////////////////// State //////////////////////////////

    // TODO: use similar logic found in LimitedCallsEnforcer to handle case for missed periods
    mapping(uint256 => bool) public periodCallsClaimed;
    uint256 public immutable START_TIMESTAMP;
    uint256 public immutable PERIOD_DURATION; // Number of days per period in seconds

    event Subscribed(address indexed user, uint256 nextAllowedTime);
    event FulfilMissedSubscribed(address indexed user, uint256 missedPeriod);

    ////////////////////////////// External Methods //////////////////////////////

    constructor(uint256 _startTimestamp, uint256 _periodDurationInDays) {
        START_TIMESTAMP = _startTimestamp;
        PERIOD_DURATION = _periodDurationInDays * 1 days;
    }

    function canSubscribe() public view returns (bool) {
        return block.timestamp >= getNextValidTimestamp();
    }

    function getCurrentPeriod() public view returns (uint256) {
        return (block.timestamp - START_TIMESTAMP) / PERIOD_DURATION;
    }

    function getNextValidTimestamp() public view returns (uint256) {
        uint256 elapsedTime = block.timestamp - START_TIMESTAMP;
        uint256 periodsPassed = elapsedTime / PERIOD_DURATION;
        return START_TIMESTAMP + (periodsPassed + 1) * PERIOD_DURATION;
    }

    function fulfilMissedSubscribe(uint256 missedPeriod) external {
        require(periodCallsClaimed[missedPeriod] == false, "Already claimed for this period");

        periodCallsClaimed[missedPeriod] = true;

        emit FulfilMissedSubscribed(msg.sender, missedPeriod);
    }

    function subscribe() external {
        uint256 currentPeriod = getCurrentPeriod();

        require(canSubscribe(), "Subscription period not reached");
        require(periodCallsClaimed[currentPeriod] == false, "Already claimed for this period");

        periodCallsClaimed[currentPeriod] = true;

        emit Subscribed(msg.sender, getNextValidTimestamp());
    }

    ////////////////////////////// Public Methods //////////////////////////////

    ////////////////////////////// Internal Methods //////////////////////////////
}
