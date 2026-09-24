// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { VaultMigrationHelper } from "../src/helpers/VaultMigrationHelper.sol";

/**
 * @title DeployVaultMigrationHelper
 * @notice Deploys VaultMigrationHelper deterministically with CREATE2.
 */
contract DeployVaultMigrationHelper is Script {
    bytes32 internal salt;
    address internal owner;
    address internal baseAdapter;
    address internal premiumAdapter;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        owner = vm.envAddress("VAULT_MIGRATION_HELPER_OWNER_ADDRESS");
        baseAdapter = vm.envAddress("BASE_VEDA_ADAPTER_ADDRESS");
        premiumAdapter = vm.envAddress("PREMIUM_VEDA_ADAPTER_ADDRESS");

        console2.log("~~~");
        console2.log("Owner: %s", owner);
        console2.log("BaseAdapter: %s", baseAdapter);
        console2.log("PremiumAdapter: %s", premiumAdapter);
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        vm.startBroadcast();
        address deployed = address(new VaultMigrationHelper{ salt: salt }(owner, baseAdapter, premiumAdapter));
        vm.stopBroadcast();

        console2.log("VaultMigrationHelper: %s", deployed);
    }
}
