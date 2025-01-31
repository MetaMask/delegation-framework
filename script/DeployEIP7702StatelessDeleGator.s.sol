// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";

import { EIP7702StatelessDeleGator } from "../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";

/**
 * @title DeployEIP7702StatelessDeleGator.s.sol
 * @notice Deploys the required contracts for the EIP7702 StatelessDeleGator to function.
 * @dev These contracts are likely already deployed on a testnet or mainnet as many are singletons.
 * @dev run the script with:
 * forge script script/DeployEIP7702StatelessDeleGator.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
 */
contract DeployEIP7702StatelessDeleGator is Script {
    bytes32 salt;
    IEntryPoint entryPoint;
    IDelegationManager delegationManager;
    address deployer;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        entryPoint = IEntryPoint(vm.envAddress("ENTRYPOINT_ADDRESS"));
        delegationManager = IDelegationManager(vm.envAddress("DELEGATION_MANAGER_ADDRESS"));
        deployer = msg.sender;
        console2.log("~~~");
        console2.log("Deployer: %s", address(deployer));
        console2.log("Entry Point: %s", address(entryPoint));
        console2.log("Delegation Manager: %s", address(delegationManager));
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        address deployedAddress;

        // Deploy EIP7702StatelessDeleGator

        deployedAddress = address(new EIP7702StatelessDeleGator{ salt: salt }(IDelegationManager(delegationManager), entryPoint));
        console2.log("EIP7702StatelessDeleGatorImpl: %s", deployedAddress);

        vm.stopBroadcast();
    }
}
