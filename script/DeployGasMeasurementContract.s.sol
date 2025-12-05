// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Script, console2 } from "forge-std/Script.sol";
import { GasMeasurementContract } from "./GasMeasurementContract.sol";

/**
 * @title DeployGasMeasurementContract
 * @notice Deploys GasMeasurementContract and tests gas consumption of isValidSignature
 * @dev This script:
 *      1. Deploys GasMeasurementContract
 *      2. Calls measureGas with test data from DeployAndTestHybridDeleGator
 *      3. Logs the gas consumption results
 *
 *      NOTE: This script tests on the actual network where the precompile exists.
 *      For local testing, you would need to enable the precompile separately.
 *
 *      Run with:
 *      forge script script/DeployGasMeasurementContract.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
 * -vvv
 */
contract DeployGasMeasurementContract is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=== Deploy GasMeasurementContract ===");
        console2.log("Deployer:", deployer);
        console2.log("Block number:", block.number);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy GasMeasurementContract
        // console2.log("Deploying GasMeasurementContract...");
        // GasMeasurementContract gasMeasurer = new GasMeasurementContract();
        GasMeasurementContract gasMeasurer = GasMeasurementContract(0x02A5CC4Ed628e4CA9D31B6628d184EcC7A4503Cd);

        console2.log("GasMeasurementContract deployed at:", address(gasMeasurer));
        console2.log("");

        // Test data from DeployAndTestHybridDeleGator logs
        // Ethereum Mainnet
        address hybridDeleGatorAddress = 0x931706Ece1D25E12B6dd087d0bbe5acAc59Aae5A;
        bytes32 messageHash = 0xd0884093dd7893d9bb626ec5a81b3fe55b288b8664fffea90109634f73557f69;
        bytes memory signature =
            hex"377e8c913442ea733e32c0dcfb183d3f6603195c77ed8219dfd82e79315484093748b20bf7bf53d8aff604cc57e79aea06c70ae121bcb1563f7aa3d22eb536322e9cae63761eef160e290612de38bf56ef13b866a69f8f29569148b3d1ab73b7";

        // Ethereum Sepolia
        // address hybridDeleGatorAddress = 0x896996Ca94931Effe2818a89Bc27AaD89c87b0A7; // Ethereum Sepolia
        // bytes32 messageHash = 0x8c0b1eef198c5c9cbbbd9234586b1a50dfb0b4125761f68830bbc085c0016d02;
        // bytes memory signature =
        //
        // hex"377e8c913442ea733e32c0dcfb183d3f6603195c77ed8219dfd82e79315484091a4107337fbe871d86dcbf711d1f0304b361aee5c86e7e0a2ba41b7eec63e20f1458ea389221e5109fb745de27ca807c6498502317b3325db2f091f1308b4e9c";

        console2.log("Test data:");
        console2.log("  HybridDeleGator address:", hybridDeleGatorAddress);
        console2.log("  Message hash:");
        console2.logBytes32(messageHash);
        console2.log("  Signature length:", signature.length);
        console2.log("  Signature:");
        console2.logBytes(signature);
        console2.log("");

        // Measure gas consumption
        console2.log("=== Measuring Gas Consumption ===");
        (bytes4 result, uint256 gasUsed) = gasMeasurer.measureGas(hybridDeleGatorAddress, messageHash, signature);

        console2.log("");
        console2.log("=== Gas Measurement Results ===");
        console2.log("Result:", uint32(result));
        console2.log("Gas used:", gasUsed);
        console2.log("");

        if (result == bytes4(0x1626ba7e)) {
            console2.log("SUCCESS: Signature is valid!");
            console2.log("");
            console2.log("Gas Analysis:");
            console2.log("  - Precompile (EIP-7951): ~6900 gas");
            console2.log("  - Solidity fallback: ~100k+ gas");
            console2.log("  - Measured:", gasUsed, "gas");
            console2.log("");

            if (gasUsed < 15000) {
                console2.log("  -> Precompile was likely used (gas < 15k)");
            } else {
                console2.log("  -> Fallback Solidity implementation was used (gas > 15k)");
            }
        } else {
            console2.log("WARNING: Signature validation failed");
            console2.log("  Result:", uint32(result));
            console2.log("  Expected: 0x1626ba7e");
        }

        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("GasMeasurementContract:", address(gasMeasurer));
        console2.log("HybridDeleGator:", hybridDeleGatorAddress);
        console2.log("Gas used for isValidSignature:", gasUsed);

        vm.stopBroadcast();
    }
}

