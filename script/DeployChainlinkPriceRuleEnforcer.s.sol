// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { ChainlinkPriceRuleEnforcer } from "../src/enforcers/ChainlinkPriceRuleEnforcer.sol";

/**
 * @title DeployChainlinkPriceRuleEnforcer
 * @notice Deploys ChainlinkPriceRuleEnforcer via CREATE2 for deterministic cross-chain addresses.
 * @dev run the script with:
 * forge script script/DeployChainlinkPriceRuleEnforcer.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
 */
contract DeployChainlinkPriceRuleEnforcer is Script {
    bytes32 salt;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        console2.log("~~~");
        console2.log("Deployer: %s", msg.sender);
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        address deployedAddress = address(new ChainlinkPriceRuleEnforcer{ salt: salt }());
        console2.log("ChainlinkPriceRuleEnforcer: %s", deployedAddress);

        vm.stopBroadcast();
    }
}
