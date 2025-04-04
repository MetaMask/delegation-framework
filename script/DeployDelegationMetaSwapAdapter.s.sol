// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { DelegationMetaSwapAdapter } from "../src/helpers/DelegationMetaSwapAdapter.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { IMetaSwap } from "../src/helpers/interfaces/IMetaSwap.sol";

/**
 * @title DeployDelegationMetaSwapAdapter
 * @notice Deploys the delegationMetaSwapAdapter contract.
 * @dev These contracts are likely already deployed on a testnet or mainnet as many are singletons.
 * @dev Fill the required variables in the .env file
 * @dev run the script with:
 * forge script script/DeployDelegationMetaSwapAdapter.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
 */
contract DeployDelegationMetaSwapAdapter is Script {
    bytes32 salt;
    address deployer;
    address metaSwapAdapterOwner;
    address swapApiSignerEnforcer;
    IDelegationManager delegationManager;
    IMetaSwap metaSwap;
    address argsEqualityCheckEnforcer;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        metaSwapAdapterOwner = vm.envAddress("META_SWAP_ADAPTER_OWNER_ADDRESS");
        delegationManager = IDelegationManager(vm.envAddress("DELEGATION_MANAGER_ADDRESS"));
        metaSwap = IMetaSwap(vm.envAddress("METASWAP_ADDRESS"));
        swapApiSignerEnforcer = vm.envAddress("SWAPS_API_SIGNER_ADDRESS");
        argsEqualityCheckEnforcer = vm.envAddress("ARGS_EQUALITY_CHECK_ENFORCER_ADDRESS");
        deployer = msg.sender;
        console2.log("~~~");
        console2.log("Deployer: %s", address(deployer));
        console2.log("DelegationMetaSwapAdapter Owner %s", address(metaSwapAdapterOwner));
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        address delegationMetaSwapAdapter = address(
            new DelegationMetaSwapAdapter{ salt: salt }(
                metaSwapAdapterOwner, swapApiSignerEnforcer, delegationManager, metaSwap, argsEqualityCheckEnforcer
            )
        );
        console2.log("DelegationMetaSwapAdapter: %s", delegationMetaSwapAdapter);

        vm.stopBroadcast();
    }
}
