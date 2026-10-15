// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { MetaSwapOrderDelegationManager } from "../src/MetaSwapOrderDelegationManager.sol";

/**
 * @title DeployMetaSwapOrderDelegationManager.s.sol
 * @notice Deploys MetaSwapOrderDelegationManager.
 * @dev EIP-7702 accounts that redeem through this manager must use it as their delegation manager.
 * @dev run the script with:
 * forge script script/DeployMetaSwapOrderDelegationManager.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
 */
contract DeployMetaSwapOrderDelegationManager is Script {
    bytes32 salt;
    address deployer;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        deployer = msg.sender;

        console2.log("~~~");
        console2.log("Deployer: %s", deployer);
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        address deployedAddress = address(new MetaSwapOrderDelegationManager{ salt: salt }());
        console2.log("MetaSwapOrderDelegationManager: %s", deployedAddress);

        vm.stopBroadcast();
    }
}
