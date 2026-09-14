// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { TransparentUpgradeableProxy } from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { LiFiSwapEnforcer } from "../src/enforcers/LiFiSwapEnforcer.sol";

/**
 * @title DeployLiFiSwapEnforcer
 * @notice Deploys LiFiSwapEnforcer behind an OpenZeppelin TransparentUpgradeableProxy via CREATE2 for
 *         deterministic cross-chain addresses.
 * @dev The implementation and the proxy are both deployed via CREATE2 with distinct salts so that the
 *      proxy address (the address delegations must reference as their `enforcer`) is identical on every
 *      chain given the same deployer, salts, and bytecode. The ProxyAdmin is deployed internally by the
 *      proxy constructor via CREATE, so its address is per-chain and is logged here for use by the upgrade
 *      script.
 * @dev run the script with:
 *      forge script script/DeployLiFiSwapEnforcer.s.sol --rpc-url <your_rpc_url> \
 *        --private-key $PRIVATE_KEY --broadcast \
 *        --sender <PROXY_ADMIN_OWNER_EOA>
 */
contract DeployLiFiSwapEnforcer is Script {
    /// @dev keccak256("eip1967.proxy.admin") - 1; the slot holding the ProxyAdmin address.
    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    bytes32 implSalt;
    bytes32 proxySalt;

    function setUp() public {
        implSalt = bytes32(abi.encodePacked(vm.envString("IMPL_SALT")));
        proxySalt = bytes32(abi.encodePacked(vm.envString("PROXY_SALT")));
        console2.log("~~~");
        console2.log("Deployer / ProxyAdmin owner: %s", msg.sender);
        console2.log("Implementation salt:");
        console2.logBytes32(implSalt);
        console2.log("Proxy salt:");
        console2.logBytes32(proxySalt);
    }

    function run() public {
        console2.log("~~~");
        vm.startBroadcast();

        // 1. Deploy the implementation. No constructor / initializer — the enforcer is stateless on
        //    deployment, so the proxy is created with empty `_data` (no init delegatecall).
        LiFiSwapEnforcer impl = new LiFiSwapEnforcer{ salt: implSalt }();
        console2.log("LiFiSwapEnforcer impl: %s", address(impl));

        // 2. Deploy the transparent proxy. `msg.sender` becomes the ProxyAdmin owner (the only account
        //    that can call `upgradeAndCall`). Keep this EOA distinct from the DelegationManager address,
        //    or every hook call will revert with ProxyDeniedAdminAccess.
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy{ salt: proxySalt }(address(impl), msg.sender, "");
        console2.log("LiFiSwapEnforcer PROXY: %s", address(proxy));

        // 3. The ProxyAdmin is deployed via CREATE inside the proxy constructor, so its address is
        //    per-chain (nonce-dependent). Read it from the EIP-1967 admin slot and log it for the upgrade
        //    script, which reads it from env.
        address proxyAdmin = address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT))));
        console2.log("ProxyAdmin (per-chain, save for upgrades): %s", proxyAdmin);

        vm.stopBroadcast();
    }
}
