// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Script, console2 } from "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { FCL_ecdsa_utils } from "@FCL/FCL_ecdsa_utils.sol";

import { DelegationManager } from "../src/DelegationManager.sol";
import { HybridDeleGator } from "../src/HybridDeleGator.sol";
import { Delegation, Caveat } from "../src/utils/Types.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { SigningUtilsLib } from "../test/utils/SigningUtilsLib.t.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";

/**
 * @title DeployAndTestHybridDeleGator
 * @notice Deploys a HybridDeleGator on Sepolia, signs a delegation with P256, and verifies it
 * @dev This script demonstrates P256 signature verification and detects if precompile was used
 *
 *      Run with:
 *      forge script script/DeployAndTestHybridDeleGator.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
 * -vvv
 */
contract DeployAndTestHybridDeleGator is Script {
    using MessageHashUtils for bytes32;

    // P256 Precompile address
    address constant P256_PRECOMPILE = address(0x100);

    // Get existing deployments from environment variables
    DelegationManager delegationManager;
    address hybridDeleGatorImplAddress;

    function setUp() public {
        delegationManager = DelegationManager(vm.envAddress("DELEGATION_MANAGER_ADDRESS"));
        hybridDeleGatorImplAddress = 0x48dBe696A4D990079e039489bA2053B36E8FFEC4;
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=== Deploy and Test HybridDeleGator on Sepolia ===");
        console2.log("Deployer:", deployer);
        console2.log("Block number:", block.number);

        console2.log("Using existing deployments:");
        console2.log("  DelegationManager:", address(delegationManager));
        console2.log("  HybridDeleGatorImpl:", hybridDeleGatorImplAddress);

        vm.startBroadcast(deployerPrivateKey);

        // // Step 3: Generate P256 key pair
        uint256 privateKey = uint256(keccak256("SepoliaTestKey"));
        (uint256 qx, uint256 qy) = FCL_ecdsa_utils.ecdsa_derivKpub(privateKey);
        string memory keyId = "SepoliaTestKey";

        console2.log("Generated P256 key:");
        console2.log("  Key ID:", keyId);
        console2.log("  Public key Qx:", qx);
        console2.log("  Public key Qy:", qy);

        // Step 4: Deploy HybridDeleGator proxy using existing implementation
        string[] memory keyIds = new string[](1);
        uint256[] memory xValues = new uint256[](1);
        uint256[] memory yValues = new uint256[](1);
        keyIds[0] = keyId;
        xValues[0] = qx;
        yValues[0] = qy;

        address proxy = address(
            new ERC1967Proxy(
                hybridDeleGatorImplAddress,
                abi.encodeWithSignature("initialize(address,string[],uint256[],uint256[])", deployer, keyIds, xValues, yValues)
            )
        );

        // address proxy = 0x896996Ca94931Effe2818a89Bc27AaD89c87b0A7;

        HybridDeleGator hybridDeleGator = HybridDeleGator(payable(proxy));
        console2.log("HybridDeleGator deployed at:", address(hybridDeleGator));

        // // Step 5: Test precompile directly
        // _testPrecompileDirectly(privateKey, qx, qy);

        // Step 6: Create and sign delegation
        (bytes32 typedDataHash, bytes memory signature) = _createAndSignDelegation(hybridDeleGator, keyId, privateKey);

        // Step 7: Verify signature
        _verifySignature(hybridDeleGator, typedDataHash, signature);

        vm.stopBroadcast();
    }

    function _createAndSignDelegation(
        HybridDeleGator hybridDeleGator,
        string memory keyId,
        uint256 privateKey
    )
        internal
        view
        returns (bytes32 typedDataHash, bytes memory signature)
    {
        // Create a delegation
        address delegate = vm.addr(uint256(keccak256("Delegate")));
        Delegation memory delegation = Delegation({
            delegate: delegate,
            delegator: address(hybridDeleGator),
            authority: delegationManager.ROOT_AUTHORITY(),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        typedDataHash =
            MessageHashUtils.toTypedDataHash(delegationManager.getDomainHash(), EncoderLib._getDelegationHash(delegation));

        console2.log("Delegation created:");
        console2.log("  Delegator:", address(hybridDeleGator));
        console2.log("  Delegate:", delegate);
        console2.log("  Typed data hash:");
        console2.logBytes32(typedDataHash);

        // Sign the delegation with P256
        signature = SigningUtilsLib.signHash_P256(keyId, privateKey, typedDataHash);
        console2.log("Delegation signed with P256 key");
        console2.log("Signature:");
        console2.logBytes(signature);
    }

    function _verifySignature(HybridDeleGator hybridDeleGator, bytes32 typedDataHash, bytes memory signature) internal view {
        console2.log("\n=== Verifying Signature via HybridDeleGator ===");

        bytes4 result = hybridDeleGator.isValidSignature(typedDataHash, signature);

        console2.log("Signature verification result:", uint32(result));

        if (result == bytes4(0x1626ba7e)) {
            console2.log("SUCCESS: Signature is valid!");
            console2.log("  If precompile test passed above, the precompile was used");
            console2.log("  If precompile test failed, fallback Solidity implementation was used");
        } else {
            console2.log("ERROR: Signature verification failed");
            console2.log("  Result:", uint32(result));
            console2.log("  Expected: 0x1626ba7e");
        }
    }
}
