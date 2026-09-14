// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ITransparentUpgradeableProxy } from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { LiFiSwapEnforcer } from "../src/enforcers/LiFiSwapEnforcer.sol";

/**
 * @title UpgradeLiFiSwapEnforcer
 * @notice Upgrades the LiFiSwapEnforcer transparent proxy to a new implementation.
 * @dev The proxy address is deterministic across chains (CREATE2 with PROXY_SALT), so it can be read
 *      from env or hardcoded after the first deploy. The ProxyAdmin address is per-chain (CREATE inside
 *      the proxy constructor), so it MUST be read from env — it was logged by DeployLiFiSwapEnforcer.
 * @dev The new implementation is deployed via CREATE2 with a salt so its address is deterministic across
 *      chains. When a real V2 implementation exists, replace the `LiFiSwapEnforcer` import/usage below
 *      with the V2 contract; the rest of the script is unchanged. Until then this script is useful for
 *      exercising the upgrade flow against a fresh deploy of the current logic.
 * @dev run the script with:
 *      forge script script/UpgradeLiFiSwapEnforcer.s.sol --rpc-url <your_rpc_url> \
 *        --private-key $PROXY_ADMIN_OWNER_KEY --broadcast \
 *        --sender <PROXY_ADMIN_OWNER_EOA>
 *      with env: PROXY_ADMIN=<per-chain ProxyAdmin address> \
 *                LIFI_SWAP_ENFORCER_PROXY=<proxy address> \
 *                IMPL_SALT_V2=<salt for the new implementation>
 */
contract UpgradeLiFiSwapEnforcer is Script {
    bytes32 implSaltV2;

    function setUp() public {
        implSaltV2 = bytes32(abi.encodePacked(vm.envString("IMPL_SALT_V2")));
        console2.log("~~~");
        console2.log("Sender (must be ProxyAdmin owner): %s", msg.sender);
        console2.log("New implementation salt:");
        console2.logBytes32(implSaltV2);
    }

    function run() public {
        address proxy = vm.envAddress("LIFI_SWAP_ENFORCER_PROXY");
        address proxyAdmin = vm.envAddress("PROXY_ADMIN");
        console2.log("~~~");
        console2.log("Proxy:      %s", proxy);
        console2.log("ProxyAdmin:  %s", proxyAdmin);

        vm.startBroadcast();

        // Deploy the new implementation via CREATE2 for a deterministic address.
        // Replace `LiFiSwapEnforcer` with the V2 contract when one exists.
        LiFiSwapEnforcer newImpl = new LiFiSwapEnforcer{ salt: implSaltV2 }();
        console2.log("New implementation: %s", address(newImpl));

        // Upgrade the proxy. The caller (msg.sender) must be the ProxyAdmin owner; ProxyAdmin.upgradeAndCall
        // enforces `onlyOwner` and the transparent proxy only accepts upgradeToAndCall from its admin.
        // Empty `_data` => no init delegatecall (the enforcer has no initializer).
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(payable(proxy)), address(newImpl), "");
        console2.log("Proxy upgraded. Proxy address unchanged: %s", proxy);

        vm.stopBroadcast();
    }
}
