// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Script, console2 } from "forge-std/Script.sol";

import { EIP7702MultiManagerDeleGator } from "../src/EIP7702/EIP7702MultiManagerDeleGator.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";

/**
 * @title DeployEIP7702MultiManagerDeleGator
 * @notice Deterministically deploys the EIP-7702 multi-DelegationManager implementation.
 * @dev Requires SALT, DEFAULT_DELEGATION_MANAGER_1, and DEFAULT_DELEGATION_MANAGER_2 environment variables.
 */
contract DeployEIP7702MultiManagerDeleGator is Script {
    bytes32 internal salt;
    IDelegationManager internal defaultDelegationManager1;
    IDelegationManager internal defaultDelegationManager2;

    /// @notice Loads deterministic deployment inputs from the environment.
    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        defaultDelegationManager1 = IDelegationManager(vm.envAddress("DEFAULT_DELEGATION_MANAGER_1"));
        defaultDelegationManager2 = IDelegationManager(vm.envAddress("DEFAULT_DELEGATION_MANAGER_2"));

        console2.log("~~~");
        console2.log("Deployer: %s", msg.sender);
        console2.log("Default DelegationManager 1: %s", address(defaultDelegationManager1));
        console2.log("Default DelegationManager 2: %s", address(defaultDelegationManager2));
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    /// @notice Deploys the implementation with CREATE2.
    /// @return implementation_ The deployed multi-DelegationManager implementation.
    function run() public returns (EIP7702MultiManagerDeleGator implementation_) {
        vm.startBroadcast();
        implementation_ = new EIP7702MultiManagerDeleGator{ salt: salt }(defaultDelegationManager1, defaultDelegationManager2);
        vm.stopBroadcast();

        console2.log("EIP7702MultiManagerDeleGatorImpl: %s", address(implementation_));
    }
}
