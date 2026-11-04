// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";

import { EIP7702BatchDeleGator } from "../src/EIP7702/EIP7702BatchDeleGator.sol";
import { EIP7702BatchDeleGatorBeacon } from "../src/EIP7702/EIP7702BatchDeleGatorBeacon.sol";
import { EIP7702BatchDeleGatorProxy } from "../src/EIP7702/EIP7702BatchDeleGatorProxy.sol";
import { DeleGatorBatchRelayCoordinator } from "../src/DeleGatorBatchRelayCoordinator.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";

/**
 * @title DeployEIP7702BatchDeleGator
 * @notice Deploys EIP7702BatchDeleGator, optional beacon/proxy, and the batch relay coordinator.
 * @dev Does not broadcast by default. Run with `--broadcast` only when ready to deploy.
 * @dev Required env:
 *      - SALT
 *      - ENTRYPOINT_ADDRESS
 *      - DELEGATION_MANAGER_ADDRESS
 * @dev Optional env:
 *      - BEACON_OWNER (defaults to deployer)
 *      - DEPLOY_PROXY=true|false (defaults to true)
 */
contract DeployEIP7702BatchDeleGator is Script {
    bytes32 internal salt;
    IEntryPoint internal entryPoint;
    IDelegationManager internal delegationManager;
    address internal deployer;
    address internal beaconOwner;
    bool internal deployProxy;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        entryPoint = IEntryPoint(vm.envAddress("ENTRYPOINT_ADDRESS"));
        delegationManager = IDelegationManager(vm.envAddress("DELEGATION_MANAGER_ADDRESS"));
        deployer = msg.sender;
        beaconOwner = vm.envOr("BEACON_OWNER", deployer);
        deployProxy = vm.envOr("DEPLOY_PROXY", true);

        console2.log("~~~ DeployEIP7702BatchDeleGator ~~~");
        console2.log("Deployer: %s", deployer);
        console2.log("Entry Point: %s", address(entryPoint));
        console2.log("Delegation Manager: %s", address(delegationManager));
        console2.log("Beacon Owner: %s", beaconOwner);
        console2.log("Deploy Proxy: %s", deployProxy);
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        vm.startBroadcast();

        address implementation = address(
            new EIP7702BatchDeleGator{ salt: salt }(delegationManager, entryPoint)
        );
        console2.log("EIP7702BatchDeleGatorImpl: %s", implementation);

        address authorizationTarget = implementation;
        address beacon;
        address proxy;

        if (deployProxy) {
            beacon = address(new EIP7702BatchDeleGatorBeacon{ salt: salt }(implementation, beaconOwner));
            console2.log("EIP7702BatchDeleGatorBeacon: %s", beacon);

            proxy = address(new EIP7702BatchDeleGatorProxy{ salt: salt }(beacon));
            console2.log("EIP7702BatchDeleGatorProxy: %s", proxy);

            authorizationTarget = proxy;
        }

        address coordinator = address(new DeleGatorBatchRelayCoordinator{ salt: salt }());
        console2.log("DeleGatorBatchRelayCoordinator: %s", coordinator);

        console2.log("~~~ Release Metadata ~~~");
        console2.log("authorizationTarget: %s", authorizationTarget);
        console2.log("implementation: %s", implementation);
        console2.log("beacon: %s", beacon);
        console2.log("proxy: %s", proxy);
        console2.log("coordinator: %s", coordinator);
        console2.log("eip712Name: EIP7702BatchDeleGator");
        console2.log("eip712Version: 1");
        console2.log("contractVersion: %s", EIP7702BatchDeleGator(payable(implementation)).VERSION());

        vm.stopBroadcast();
    }
}
