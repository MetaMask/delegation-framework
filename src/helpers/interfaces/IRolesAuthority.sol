// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title IRolesAuthority
 * @notice Minimal interface for Solmate-style RolesAuthority role checks used by Veda tellers.
 */
interface IRolesAuthority {
    function doesUserHaveRole(address user, uint8 role) external view returns (bool);
}
