// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { MetaSwapOrderDelegationManager } from "../src/MetaSwapOrderDelegationManager.sol";

/**
 * @title DeployMetaSwapOrderDelegationManager
 * @notice Deploys the experimental MetaSwap order delegation manager.
 * @dev Experimental. EIP-7702 accounts must be wired to this manager address.
 *
 * forge script script/DeployMetaSwapOrderDelegationManager.s.sol --rpc-url <rpc> --private-key $PRIVATE_KEY --broadcast
 *
 * Env:
 * - SALT
 */
contract DeployMetaSwapOrderDelegationManager is Script {
    bytes32 salt;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));

        console2.log("~~~");
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
