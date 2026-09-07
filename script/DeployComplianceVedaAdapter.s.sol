// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { ComplianceVedaAdapter } from "../src/helpers/ComplianceVedaAdapter.sol";

/**
 * @title DeployComplianceVedaAdapter
 * @notice Deploys ComplianceVedaAdapter deterministically with CREATE2.
 * @dev Run with:
 * forge script script/DeployComplianceVedaAdapter.s.sol --rpc-url <rpc_url> --private-key $PRIVATE_KEY --broadcast
 * Monad simulations may require --skip-simulation because its mUSD contract uses post-London opcodes.
 */
contract DeployComplianceVedaAdapter is Script {
    bytes32 internal salt;
    address internal vedaAdapterOwner;
    address internal delegationManager;
    address internal boringVault;
    address internal vedaTeller;
    address internal depositToken;

    function setUp() public {
        salt = bytes32(abi.encodePacked(vm.envString("SALT")));
        vedaAdapterOwner = vm.envAddress("VEDA_ADAPTER_OWNER_ADDRESS");
        delegationManager = vm.envAddress("DELEGATION_MANAGER_ADDRESS");
        boringVault = vm.envAddress("VEDA_BORING_VAULT_ADDRESS");
        vedaTeller = vm.envAddress("VEDA_TELLER_ADDRESS");
        depositToken = vm.envAddress("VEDA_DEPOSIT_TOKEN_ADDRESS");

        console2.log("~~~");
        console2.log("Owner: %s", vedaAdapterOwner);
        console2.log("DelegationManager: %s", delegationManager);
        console2.log("BoringVault: %s", boringVault);
        console2.log("VedaTeller: %s", vedaTeller);
        console2.log("DepositToken: %s", depositToken);
        console2.log("Salt:");
        console2.logBytes32(salt);
    }

    function run() public {
        vm.startBroadcast();

        // Foundry's fork mode cannot interact with mUSD on Monad (NotActivated in revm).
        // Mock the approve call so simulation passes; the real broadcast executes the
        // actual constructor on-chain where the token works correctly.
        // vm.mockCall(depositToken, abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))), abi.encode(true));

        address deployed = address(
            new ComplianceVedaAdapter{ salt: salt }(vedaAdapterOwner, delegationManager, boringVault, vedaTeller, depositToken)
        );

        vm.stopBroadcast();
        console2.log("ComplianceVedaAdapter: %s", deployed);

        // vm.clearMockedCalls();
    }
}
