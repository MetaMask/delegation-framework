// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";

import { DelegationManager } from "../src/DelegationManager.sol";
import { MultiSigDeleGator } from "../src/MultiSigDeleGator.sol";
import { HybridDeleGator } from "../src/HybridDeleGator.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";

/**
 * @title DeployDelegationFramework
 * @notice Deploys the required contracts for the delegation framework to function.
 * @dev These contracts are likely already deployed on a testnet or mainnet as many are singletons.
 * @dev run the script with:
 * forge script script/DeployDelegationFramework.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
 */
contract DeployDelegationFramework is Script {
    bytes32 salt;
    IEntryPoint entryPoint;
    address deployer;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        entryPoint = IEntryPoint(vm.envAddress("ENTRYPOINT_ADDRESS"));
        deployer = msg.sender;
        console2.log("~~~");
        console2.log("Deployer: %s", address(deployer));
        console2.log("Entry Point: %s", address(entryPoint));
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        address deployedAddress;

        // Deploy Delegation Framework Contracts
        address delegationManager = address(new DelegationManager{ salt: salt }(deployer));
        console2.log("DelegationManager: %s", address(delegationManager));

        deployedAddress = address(new MultiSigDeleGator{ salt: salt }(IDelegationManager(delegationManager), entryPoint));
        console2.log("MultiSigDeleGatorImpl: %s", deployedAddress);

        deployedAddress = address(new HybridDeleGator{ salt: salt }(IDelegationManager(delegationManager), entryPoint));
        console2.log("HybridDeleGatorImpl: %s", deployedAddress);

        vm.stopBroadcast();
    }
}
