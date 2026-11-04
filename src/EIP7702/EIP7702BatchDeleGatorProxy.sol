// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IBeacon } from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import { Proxy } from "@openzeppelin/contracts/proxy/Proxy.sol";

/**
 * @title EIP7702BatchDeleGatorProxy
 * @notice Stable EIP-7702 delegation target for EIP7702BatchDeleGator implementations.
 * @dev Users authorize this proxy address once. The beacon address is immutable bytecode data,
 *      not account storage, so the proxy can safely run from an EIP-7702 delegated EOA.
 */
contract EIP7702BatchDeleGatorProxy is Proxy {
    IBeacon private immutable _beacon;

    error InvalidBeacon(address beacon);
    error InvalidBeaconImplementation(address implementation);

    constructor(address beacon_) payable {
        if (beacon_.code.length == 0) revert InvalidBeacon(beacon_);

        address implementation_ = IBeacon(beacon_).implementation();
        if (implementation_.code.length == 0) revert InvalidBeaconImplementation(implementation_);

        _beacon = IBeacon(beacon_);
    }

    /// @notice Returns the immutable beacon used by this delegation proxy.
    function beacon() external view returns (address) {
        return address(_beacon);
    }

    /// @notice Returns the implementation currently selected by the beacon.
    function implementation() external view returns (address) {
        return _implementation();
    }

    receive() external payable virtual {
        _fallback();
    }

    function _implementation() internal view override returns (address implementation_) {
        implementation_ = _beacon.implementation();
        if (implementation_.code.length == 0) revert InvalidBeaconImplementation(implementation_);
    }
}
