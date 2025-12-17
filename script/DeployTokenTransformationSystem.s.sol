// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";
import { TokenTransformationEnforcer } from "../src/enforcers/TokenTransformationEnforcer.sol";
import { AdapterManager } from "../src/helpers/adapters/AdapterManager.sol";

/**
 * @title DeployTokenTransformationSystem
 * @notice Deploys TokenTransformationEnforcer and AdapterManager together
 * @dev Resolves circular dependency by deploying in correct order:
 *      1. Deploy AdapterManager first (no enforcer in constructor)
 *      2. Deploy TokenTransformationEnforcer with AdapterManager address
 *      3. Owner sets enforcer in AdapterManager
 * @dev Run the script with:
 *      forge script script/DeployTokenTransformationSystem.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast
 */
contract DeployTokenTransformationSystem is Script {
    bytes32 salt;
    IDelegationManager delegationManager;
    address owner;
    address deployer;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        delegationManager = IDelegationManager(vm.envAddress("DELEGATION_MANAGER_ADDRESS"));
        owner = vm.envAddress("OWNER_ADDRESS");
        deployer = msg.sender;
        
        console2.log("~~~");
        console2.log("Deployer: %s", address(deployer));
        console2.log("Owner: %s", address(owner));
        console2.log("DelegationManager: %s", address(delegationManager));
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        console2.log("~~~");
        console2.log("Deploying Token Transformation System...");
        vm.startBroadcast();

        // Step 1: Deploy AdapterManager first (no enforcer in constructor)
        address adapterManager = address(new AdapterManager{ salt: salt }(owner, delegationManager));
        console2.log("AdapterManager: %s", adapterManager);

        // Step 2: Deploy TokenTransformationEnforcer with the real AdapterManager address
        address tokenTransformationEnforcer = address(
            new TokenTransformationEnforcer{ salt: salt }(adapterManager)
        );
        console2.log("TokenTransformationEnforcer: %s", tokenTransformationEnforcer);

        vm.stopBroadcast();

        // Step 3: Set the enforcer in AdapterManager (as owner)
        // If deployer is the owner, set it now. Otherwise, owner must call setTokenTransformationEnforcer separately
        if (deployer == owner) {
            vm.startBroadcast();
            AdapterManager(payable(adapterManager)).setTokenTransformationEnforcer(
                TokenTransformationEnforcer(tokenTransformationEnforcer)
            );
            vm.stopBroadcast();
            console2.log("Enforcer set in AdapterManager");
        } else {
            console2.log("WARNING: Deployer is not the owner.");
            console2.log("Owner must call setTokenTransformationEnforcer separately:");
            console2.log("  AdapterManager(%s).setTokenTransformationEnforcer(TokenTransformationEnforcer(%s))", adapterManager, tokenTransformationEnforcer);
        }

        // Step 4: Verify the deployment (read-only, no broadcast needed)
        require(
            TokenTransformationEnforcer(tokenTransformationEnforcer).adapterManager() == adapterManager,
            "DeployTokenTransformationSystem: enforcer adapterManager mismatch"
        );
        if (deployer == owner) {
            require(
                address(AdapterManager(payable(adapterManager)).tokenTransformationEnforcer()) == tokenTransformationEnforcer,
                "DeployTokenTransformationSystem: adapterManager enforcer mismatch"
            );
            console2.log("Deployment verified successfully");
        } else {
            console2.log("Note: Enforcer not yet set. Verification will pass after owner calls setTokenTransformationEnforcer.");
        }

        console2.log("~~~");
        console2.log("Token Transformation System deployed successfully!");
        console2.log("AdapterManager: %s", adapterManager);
        console2.log("TokenTransformationEnforcer: %s", tokenTransformationEnforcer);

        vm.stopBroadcast();
    }
}

