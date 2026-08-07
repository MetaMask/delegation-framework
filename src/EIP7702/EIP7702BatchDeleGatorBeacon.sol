// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @notice Upgrade beacon for EIP7702BatchDeleGator implementations.
contract EIP7702BatchDeleGatorBeacon is UpgradeableBeacon {
    constructor(address implementation_, address initialOwner) UpgradeableBeacon(implementation_, initialOwner) { }
}
