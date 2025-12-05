// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { FCL_ecdsa_utils } from "@FCL/FCL_ecdsa_utils.sol";

/**
 * @title SimpleFusakaTest
 * @notice Simple test to verify P256 precompile (EIP-7951) on Sepolia fork
 * @dev This is a minimal test that just checks if the precompile works
 *
 *      To run this test:
 *      forge test --match-contract SimpleFusakaTest --fork-url $SEPOLIA_RPC_URL -vvv
 */
contract SimpleFusakaTest is Test {
    // EIP-7951 precompile address
    address constant P256_PRECOMPILE = address(0x100);

    // Test values
    bytes32 public TEST_MESSAGE_HASH;
    uint256 public TEST_R;
    uint256 public TEST_S;
    uint256 public TEST_QX;
    uint256 public TEST_QY;
    uint256 private TEST_PRIVATE_KEY;

    function setUp() public {
        // Fork Sepolia at latest block
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", vm.envOr("FORK_URL", string("")));
        require(bytes(rpcUrl).length > 0, "SEPOLIA_RPC_URL or FORK_URL environment variable must be set, or use --fork-url flag");

        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        uint256 forkBlockNumber = block.number;
        console2.log("Forked Sepolia at block:", forkBlockNumber);

        // Generate test values
        TEST_PRIVATE_KEY = uint256(keccak256("SimpleFusakaTest"));
        (TEST_QX, TEST_QY) = FCL_ecdsa_utils.ecdsa_derivKpub(TEST_PRIVATE_KEY);

        bytes memory testMessage = "Simple Fusaka Test";
        TEST_MESSAGE_HASH = sha256(testMessage);

        (bytes32 r_, bytes32 s_) = vm.signP256(TEST_PRIVATE_KEY, TEST_MESSAGE_HASH);

        // Normalize s to be <= n/2
        uint256 sValue = uint256(s_);
        uint256 P256_N_DIV_2 = 57896044605178124381348723474701786764998477612067880171211029530534256022184;
        if (sValue > P256_N_DIV_2) {
            uint256 P256_N = 115792089210356248762697446949407573529996955224135760342422259061068512044369;
            sValue = P256_N - sValue;
        }

        TEST_R = uint256(r_);
        TEST_S = sValue;
    }

    /**
     * @notice Simple test to check if P256 precompile works on Sepolia
     * @dev Note: Foundry recognizes precompiles in range 0x00-0xff, but P256 is at 0x100
     *      This means Foundry may not recognize it as a precompile, but it should still work
     */
    function test_p256PrecompileWorks() public {
        console2.log("=== Simple P256 Precompile Test ===");
        console2.log("Block number:", block.number);
        console2.log("Precompile address:", uint160(P256_PRECOMPILE));
        console2.log("Note: 0x100 is outside Foundry's recognized precompile range (0x00-0xff)");

        // Prepare input according to EIP-7951: 160 bytes
        bytes memory input = abi.encodePacked(TEST_MESSAGE_HASH, TEST_R, TEST_S, TEST_QX, TEST_QY);
        require(input.length == 160, "Input must be exactly 160 bytes per EIP-7951");

        console2.log("Calling precompile...");

        // Call the precompile directly
        // Note: Even if Foundry doesn't recognize 0x100 as a precompile, the EVM should handle it
        (bool success, bytes memory ret) = P256_PRECOMPILE.staticcall(input);

        console2.log("Precompile call success:", success);
        console2.log("Return length:", ret.length);

        if (!success) {
            console2.log("ERROR: Precompile call failed");
            fail("Precompile call failed");
        }

        if (ret.length == 0) {
            console2.log("WARNING: Precompile returned empty bytes - Fusaka may not be active on Sepolia");
            console2.log("This could mean:");
            console2.log("  1. Fusaka upgrade is not yet active on Sepolia");
            console2.log("  2. Foundry fork doesn't support this precompile");
            fail("Precompile returned empty bytes - Fusaka may not be active");
        }

        if (ret.length != 32) {
            console2.log("ERROR: Precompile returned unexpected length:", ret.length);
            fail("Precompile returned unexpected length");
        }

        uint256 result = abi.decode(ret, (uint256));
        console2.log("Precompile result:", result);

        if (result != 1) {
            console2.log("ERROR: Precompile returned invalid result (expected 1, got", result, ")");
            fail("Precompile returned invalid result");
        }

        console2.log("SUCCESS: P256 precompile is working on Sepolia!");
        assertTrue(true, "Precompile test passed");
    }
}
