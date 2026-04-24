// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title IDeleGatorModule
 * @notice Minimal interface for a DeleGator implemented as a Safe Module.
 * @dev Used by DelegationMetaSwapAdapter to resolve the swap recipient (the underlying Safe).
 */
interface IDeleGatorModule {
    /**
     * @notice Returns the address of the Safe that this module is attached to.
     */
    function safe() external view returns (address);
}
