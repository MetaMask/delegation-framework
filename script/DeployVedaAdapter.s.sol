// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { VedaAdapter } from "../src/helpers/VedaAdapter.sol";

/**
 * @title DeployVedaAdapter
 * @notice Deploys the VedaAdapter contract.
 * @dev Update the hardcoded addresses below before deploying.
 * @dev Fill the SALT variable in the .env file
 * @dev run the script with:
 * forge script script/DeployVedaAdapter.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
 */
contract DeployVedaAdapter is Script {
    // Hardcoded constructor parameters - update these before deploying
    address constant OWNER = address(0x0000000000000000000000000000000000000000);
    address constant DELEGATION_MANAGER = address(0x0000000000000000000000000000000000000000);
    address constant BORING_VAULT = address(0x0000000000000000000000000000000000000000);
    address constant VEDA_TELLER = address(0x0000000000000000000000000000000000000000);

    bytes32 salt;
    address deployer;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        deployer = msg.sender;
        console2.log("~~~");
        console2.log("Owner: %s", OWNER);
        console2.log("DelegationManager: %s", DELEGATION_MANAGER);
        console2.log("BoringVault: %s", BORING_VAULT);
        console2.log("VedaTeller: %s", VEDA_TELLER);
        console2.log("Deployer: %s", deployer);
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        address vedaAdapter = address(new VedaAdapter{ salt: salt }(OWNER, DELEGATION_MANAGER, BORING_VAULT, VEDA_TELLER));
        console2.log("VedaAdapter: %s", vedaAdapter);

        vm.stopBroadcast();
    }
}
