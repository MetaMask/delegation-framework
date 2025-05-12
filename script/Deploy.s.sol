// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/HybridDeleGator.sol";
import "../src/DelegationManager.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address sclLib = vm.envAddress("SCL_LIB");
        address delegationManager = vm.envAddress("DELEGATION_MANAGER");
        address entryPoint = vm.envAddress("ENTRY_POINT");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy HybridDeleGator
        HybridDeleGator hybridDeleGator = new HybridDeleGator(IDelegationManager(delegationManager), IEntryPoint(entryPoint));

        vm.stopBroadcast();
    }
}
