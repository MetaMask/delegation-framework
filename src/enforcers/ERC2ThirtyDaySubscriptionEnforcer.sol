// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";

/**
 * @title ERC2 Thirty Day Subscription Enforcer Contract
 * @dev
 */
contract ERC2ThirtyDaySubscriptionEnforcer {
    ////////////////////////////// State //////////////////////////////

    mapping(uint256 => bool) public periodCallsClaimed;
    uint256 public immutable START_TIMESTAMP;

    event Subscribed(address indexed user, uint256 nextAllowedTime);
    event FulfilMissedSubscribed(address indexed user, uint256 missedPeriod);

    ////////////////////////////// External Methods //////////////////////////////

    constructor(uint256 _startTimestamp) {
        START_TIMESTAMP = _startTimestamp;
    }

    function canSubscribe() public view returns (bool) {
        return block.timestamp >= getNextValidTimestamp();
    }

    function getCurrentPeriod() public view returns (uint256) {
        return (block.timestamp - START_TIMESTAMP) / 30 days;
    }

    function getNextValidTimestamp() public view returns (uint256) {
        uint256 elapsedTime = block.timestamp - START_TIMESTAMP;
        uint256 periodsPassed = elapsedTime / 30 days;
        return START_TIMESTAMP + (periodsPassed + 1) * 30 days;
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
