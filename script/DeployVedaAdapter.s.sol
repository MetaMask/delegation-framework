// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { VedaAdapter } from "../src/helpers/VedaAdapter.sol";

/**
 * @title DeployVedaAdapter
 * @notice Deploys the VedaAdapter contract.
 * @dev Fill the required variables in the .env file
 * @dev run the script with:
 * forge script script/DeployVedaAdapter.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
 */
contract DeployVedaAdapter is Script {
    bytes32 salt;
    address deployer;
    address vedaAdapterOwner;
    address delegationManager;
    address boringVault;
    address vedaTeller;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        vedaAdapterOwner = vm.envAddress("VEDA_ADAPTER_OWNER_ADDRESS");
        delegationManager = vm.envAddress("DELEGATION_MANAGER_ADDRESS");
        boringVault = vm.envAddress("BORING_VAULT_ADDRESS");
        vedaTeller = vm.envAddress("VEDA_TELLER_ADDRESS");
        deployer = msg.sender;
        console2.log("~~~");
        console2.log("Owner: %s", vedaAdapterOwner);
        console2.log("DelegationManager: %s", delegationManager);
        console2.log("BoringVault: %s", boringVault);
        console2.log("VedaTeller: %s", vedaTeller);
        console2.log("Deployer: %s", deployer);
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        address vedaAdapter = address(new VedaAdapter{ salt: salt }(vedaAdapterOwner, delegationManager, boringVault, vedaTeller));
        console2.log("VedaAdapter: %s", vedaAdapter);

        vm.stopBroadcast();
    }
}
