// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { AaveAdapter } from "../src/helpers/AaveAdapter.sol";

/**
 * @title DeployAaveAdapter
 * @notice Deploys the AaveAdapter contract.
 * @dev These contracts are likely already deployed on a testnet or mainnet as many are singletons.
 * @dev Update the hardcoded addresses below before deploying.
 * @dev Fill the SALT variable in the .env file
 * @dev run the script with:
 * forge script script/DeployAaveAdapter.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
 */
contract DeployAaveAdapter is Script {
    // Hardcoded constructor parameters - update these before deploying
    address constant OWNER = address(0x76A60394EF70c8FE78999AB1C441278fD02C4093);
    address constant DELEGATION_MANAGER = address(0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3);
    address constant AAVE_POOL = address(0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27);

    bytes32 salt;
    address deployer;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        deployer = msg.sender;
        console2.log("~~~");
        console2.log("Owner: %s", OWNER);
        console2.log("DelegationManager: %s", DELEGATION_MANAGER);
        console2.log("AavePool: %s", AAVE_POOL);
        console2.log("Deployer: %s", deployer);
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        address aaveAdapter = address(new AaveAdapter{ salt: salt }(OWNER, DELEGATION_MANAGER, AAVE_POOL));
        console2.log("AaveAdapter: %s", aaveAdapter);

        vm.stopBroadcast();
    }
}
