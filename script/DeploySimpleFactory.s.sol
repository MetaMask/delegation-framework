// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";

import { SimpleFactory } from "../src/utils/SimpleFactory.sol";

/**
 * @title DeploySimpleFactory
 * @notice Deploys the SimpleFactory contract.
 * @dev run the script with:
 * forge script script/DeploySimpleFactory.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
 */
contract DeploySimpleFactory is Script {
    bytes32 salt;
    IEntryPoint entryPoint;
    address deployer;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        deployer = msg.sender;
        console2.log("~~~");
        console2.log("Deployer: %s", address(deployer));
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        // Deploy SimpleFactory
        address simpleFactory = address(new SimpleFactory{ salt: salt }());
        console2.log("SimpleFactory: %s", address(simpleFactory));

        vm.stopBroadcast();
    }
}
