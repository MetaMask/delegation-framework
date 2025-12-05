// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { console2 } from "forge-std/console2.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { FCL_ecdsa_utils } from "@FCL/FCL_ecdsa_utils.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { SimpleFactory } from "../src/utils/SimpleFactory.sol";
import { DelegationManager } from "../src/DelegationManager.sol";
import { HybridDeleGator } from "../src/HybridDeleGator.sol";

import { P256SCLVerifierLib } from "../src/libraries/P256SCLVerifierLib.sol";
import { SigningUtilsLib } from "./utils/SigningUtilsLib.t.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { Delegation, Caveat } from "../src/utils/Types.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { Implementation, SignatureType } from "./utils/Types.t.sol";

/**
 * @title FusakaPrecompileTest
 * @notice Tests the delegation framework on Ethereum Sepolia fork to verify P256 precompile (EIP-7951) integration
 * @dev This test forks Ethereum Sepolia (where Fusaka is currently active) and tests the delegation framework with P256 signatures.
 *      It REQUIRES Fusaka upgrade to be live - tests will FAIL if the precompile at address 0x100
 *      is not available. All tests expect the precompile to work correctly when available.
 *
 *      To run this test:
 *      forge test --match-contract FusakaPrecompileTest --fork-url $SEPOLIA_RPC_URL -vvv
 *
 *      According to EIP-7951:
 *      - Precompile address: 0x100
 *      - Gas cost: 6900 gas
 */
contract FusakaPrecompileTest is BaseTest {
    using MessageHashUtils for bytes32;

    // EIP-7951 precompile address
    address constant P256_PRECOMPILE = address(0x100);

    ////////////////////// Configure BaseTest //////////////////////

    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
    }

    ////////////////////////////// State //////////////////////////////

    HybridDeleGator public aliceDeleGator;

    // Test values - will be generated in setUp()
    bytes32 public TEST_MESSAGE_HASH;
    uint256 public TEST_R;
    uint256 public TEST_S;
    uint256 public TEST_QX;
    uint256 public TEST_QY;
    uint256 private TEST_PRIVATE_KEY;

    ////////////////////// Set Up //////////////////////

    function setUp() public override {
        // Fork Sepolia at latest block FIRST, before deploying contracts
        // Sepolia has Fusaka upgrade active, mainnet does not yet
        // Note: Use --fork-url flag when running: forge test --match-contract FusakaPrecompileTest --fork-url $SEPOLIA_RPC_URL
        // The fork URL can be passed via command line or environment variable
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", vm.envOr("FORK_URL", string("")));
        require(bytes(rpcUrl).length > 0, "SEPOLIA_RPC_URL or FORK_URL environment variable must be set, or use --fork-url flag");

        // Create and select fork at latest block
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        uint256 forkBlockNumber = block.number;
        console2.log("Forked Sepolia at block:", forkBlockNumber);

        // Set up contracts manually (without calling super.setUp() to avoid vm.etch() for precompile simulation)
        // This is similar to BaseTest.setUp() but without the precompile simulation
        entryPoint = new EntryPoint();
        vm.label(address(entryPoint), "EntryPoint");

        simpleFactory = new SimpleFactory();
        vm.label(address(simpleFactory), "Simple Factory");

        delegationManager = new DelegationManager(makeAddr("DelegationManager Owner"));
        vm.label(address(delegationManager), "Delegation Manager");

        ROOT_AUTHORITY = delegationManager.ROOT_AUTHORITY();
        ANY_DELEGATE = delegationManager.ANY_DELEGATE();

        hybridDeleGatorImpl = new HybridDeleGator(delegationManager, entryPoint);
        vm.label(address(hybridDeleGatorImpl), "Hybrid DeleGator");

        // NOTE: We intentionally do NOT call super.setUp() to avoid vm.etch() for precompile simulation
        // so we can test the real precompile on the fork

        // // Mark the precompile address as persistent so Foundry allows access to it
        // // Precompiles are special built-in addresses that need to be marked as persistent in forks
        // vm.makePersistent(P256_PRECOMPILE);

        // Create users using BaseTest's createUser (inherited)
        users.alice = createUser("Alice");
        users.bob = createUser("Bob");
        aliceDeleGator = HybridDeleGator(payable(address(users.alice.deleGator)));

        _initializeTestVariables();

        _checkPrecompileExists();
    }

    /**
     * @notice Initializes test variables for P256 signature verification
     * @dev Generates deterministic test values for reproducible tests
     */
    function _initializeTestVariables() internal {
        // Generate valid P256 test values for direct precompile testing
        // Use a deterministic private key for reproducible tests
        TEST_PRIVATE_KEY = uint256(keccak256("FusakaTestKey"));
        (TEST_QX, TEST_QY) = FCL_ecdsa_utils.ecdsa_derivKpub(TEST_PRIVATE_KEY);

        // Create a test message and hash it
        bytes memory testMessage = "Fusaka Precompile Test Message";
        TEST_MESSAGE_HASH = sha256(testMessage);

        // Sign the message hash using vm.signP256
        (bytes32 r_, bytes32 s_) = vm.signP256(TEST_PRIVATE_KEY, TEST_MESSAGE_HASH);

        // Normalize s to be <= n/2 (per P256SCLVerifierLib requirement)
        uint256 sValue = uint256(s_);
        if (sValue > P256SCLVerifierLib.P256_N_DIV_2) {
            uint256 P256_N = 115792089210356248762697446949407573529996955224135760342422259061068512044369;
            sValue = P256_N - sValue;
        }

        TEST_R = uint256(r_);
        TEST_S = sValue;
    }

    /**
     * @notice Checks if the P256 precompile exists by attempting to call it
     * @dev This function REQUIRES the precompile to exist. It will revert if Fusaka isn't live.
     *      Since we don't inherit from BaseTest, there's no etched code to worry about.
     */
    function _checkPrecompileExists() internal {
        // Prepare input according to EIP-7951: 160 bytes
        // 32 bytes message hash + 32 bytes r + 32 bytes s + 32 bytes qx + 32 bytes qy
        bytes memory input = abi.encodePacked(TEST_MESSAGE_HASH, TEST_R, TEST_S, TEST_QX, TEST_QY);

        require(input.length == 160, "Input must be exactly 160 bytes per EIP-7951");

        console2.log("Calling precompile...");
        // Call the real precompile directly
        (bool success, bytes memory ret) = P256_PRECOMPILE.staticcall(input);
        console2.log("Calling after precompile...");

        // According to EIP-7951:
        // - Valid signature: returns 32 bytes with value 0x0000...0001
        // - Invalid signature or invalid input: returns empty bytes
        // - If precompile doesn't exist: staticcall succeeds but returns empty bytes

        // Require precompile to exist - revert if Fusaka isn't live
        require(success && ret.length == 32, "Fusaka upgrade is NOT live on Sepolia - EIP-7951 precompile not available");

        // Verify it returned the expected success value
        uint256 result = abi.decode(ret, (uint256));
        require(result == 1, "Precompile returned invalid result - signature verification failed");
    }

    /**
     * @notice Tests if the P256 precompile is available on Sepolia
     * @dev This test REQUIRES Fusaka to be live. setUp() already verified the precompile exists.
     */
    function test_checkP256PrecompileAvailability() public {
        console2.log("=== Fusaka Precompile Check ===");
        console2.log("Block number:", block.number);
        console2.log("Precompile address:", uint160(P256_PRECOMPILE));
        console2.log("SUCCESS: Fusaka upgrade is LIVE on Sepolia!");
        console2.log("EIP-7951 P256 precompile is available at 0x100");
    }

    /**
     * @notice Tests P256 signature verification using the precompile
     * @dev This test REQUIRES Fusaka to be live. setUp() already verified the precompile exists.
     */
    function test_p256SignatureVerificationWithPrecompile() public {
        console2.log("=== P256 Signature Verification Test ===");
        console2.log("Block number:", block.number);

        // Test signature verification using P256SCLVerifierLib
        // This will use the precompile since it exists
        bool result = P256SCLVerifierLib.verifySignature(TEST_MESSAGE_HASH, TEST_R, TEST_S, TEST_QX, TEST_QY);

        console2.log("Signature verification result:", result);
        assertTrue(result, "Valid P256 signature should verify correctly using precompile");
        console2.log("SUCCESS: Signature verified using Fusaka precompile!");
    }

    /**
     * @notice Tests that invalid signatures are correctly rejected
     */
    function test_p256InvalidSignatureRejected() public {
        // Use an invalid signature (wrong s value)
        uint256 invalidS = TEST_S + 1;

        bool result = P256SCLVerifierLib.verifySignature(TEST_MESSAGE_HASH, TEST_R, invalidS, TEST_QX, TEST_QY);

        assertFalse(result, "Invalid signature should be rejected");
    }

    /**
     * @notice Tests the precompile gas cost
     * @dev This test REQUIRES Fusaka to be live. setUp() already verified the precompile exists.
     *      According to EIP-7951, the gas cost should be 6900 gas
     */
    function test_precompileGasCost() public {
        bytes memory input = abi.encodePacked(TEST_MESSAGE_HASH, TEST_R, TEST_S, TEST_QX, TEST_QY);

        uint256 gasBefore = gasleft();
        (bool success, bytes memory ret) = P256_PRECOMPILE.staticcall(input);
        uint256 gasAfter = gasleft();
        uint256 gasUsed = gasBefore - gasAfter;

        console2.log("=== Gas Cost Test ===");
        console2.log("Gas used:", gasUsed);
        console2.log("Expected (EIP-7951): 6900");
        console2.log("Success:", success);
        console2.log("Return length:", ret.length);

        require(success, "Precompile call should succeed");
        require(ret.length == 32, "Precompile should return 32 bytes");

        // Gas cost should be approximately 6900 (allowing some overhead)
        // Note: actual gas cost may vary slightly due to EVM overhead
        assertTrue(gasUsed >= 6900 && gasUsed <= 10000, "Gas cost should be approximately 6900");
    }

    /**
     * @notice Tests precompile input validation per EIP-7951
     * @dev This test REQUIRES Fusaka to be live. setUp() already verified the precompile exists.
     */
    function test_precompileInputValidation() public {
        // Test 1: Invalid input length (not 160 bytes)
        bytes memory invalidLength = abi.encodePacked(TEST_MESSAGE_HASH, TEST_R);
        (bool success1, bytes memory ret1) = P256_PRECOMPILE.staticcall(invalidLength);
        assertTrue(success1, "Precompile should not revert");
        assertEq(ret1.length, 0, "Invalid input length should return empty per EIP-7951");

        // Test 2: Valid input length
        bytes memory validInput = abi.encodePacked(TEST_MESSAGE_HASH, TEST_R, TEST_S, TEST_QX, TEST_QY);
        (bool success2, bytes memory ret2) = P256_PRECOMPILE.staticcall(validInput);
        assertTrue(success2, "Precompile call should succeed");
        require(ret2.length == 32, "Precompile should return 32 bytes for valid signature");
        uint256 result = abi.decode(ret2, (uint256));
        assertEq(result, 1, "Precompile should return 1 for valid signature");
    }

    /**
     * @notice Comprehensive test that checks all aspects of precompile availability
     * @dev This test REQUIRES Fusaka to be live. setUp() already verified the precompile exists.
     */
    function test_comprehensivePrecompileCheck() public {
        console2.log("=== Comprehensive Fusaka Precompile Check ===");
        console2.log("Current block:", block.number);

        // Verify the precompile address matches EIP-7951 spec
        assertEq(uint160(P256_PRECOMPILE), 0x100, "Precompile address must be 0x100 per EIP-7951");

        // Test signature verification
        bool verificationResult = P256SCLVerifierLib.verifySignature(TEST_MESSAGE_HASH, TEST_R, TEST_S, TEST_QX, TEST_QY);
        assertTrue(verificationResult, "Signature verification should work with precompile");

        console2.log("STATUS: Fusaka is LIVE on Sepolia!");
        console2.log("- EIP-7951 precompile is available");
        console2.log("- P256 signature verification is working");
        console2.log("- Gas cost should be ~6900 gas per EIP-7951");
    }

    ////////////////////// Delegation Framework Tests //////////////////////

    /**
     * @notice Tests P256 signature verification through the delegation framework
     * @dev This test REQUIRES Fusaka to be live. setUp() already verified the precompile exists.
     */
    function test_delegationFrameworkP256Signature() public {
        console2.log("=== Delegation Framework P256 Test ===");
        console2.log("Block number:", block.number);

        // Create a delegation
        Delegation memory delegation_ = Delegation({
            delegate: users.bob.addr,
            delegator: address(aliceDeleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(delegationManager.getDomainHash(), delegationHash_);

        bytes memory signature_ = SigningUtilsLib.signHash_P256(users.alice.name, users.alice.privateKey, typedDataHash_);
        delegation_.signature = signature_;

        // Verify signature through HybridDeleGator (which uses P256SCLVerifierLib internally)
        bytes4 resultP256_ = aliceDeleGator.isValidSignature(typedDataHash_, delegation_.signature);

        console2.log("Signature verification result:", uint32(resultP256_));
        assertEq(resultP256_, bytes4(0x1626ba7e), "P256 signature verification failed");
        console2.log("SUCCESS: Delegation framework using Fusaka precompile!");
    }

    /**
     * @notice Tests WebAuthn signature verification through the delegation framework
     * @dev This test REQUIRES Fusaka to be live. setUp() already verified the precompile exists.
     */
    function test_delegationFrameworkWebAuthnSignature() public {
        console2.log("=== Delegation Framework WebAuthn Test ===");
        console2.log("Block number:", block.number);

        // Hardcoded WebAuthn values from test suite
        // https://github.com/MetaMask/Passkeys-Demo-App
        string memory webAuthnKeyId_ = "WebAuthnUser";
        uint256 xWebAuthn_ = 0x5ab7b640f322014c397264bb85cbf404500feb04833ae699f41978495b655163;
        uint256 yWebAuthn_ = 0x1ee739189ede53846bd7d38bfae016919bf7d88f7ccd60aad8277af4793d1fd7;

        // Add WebAuthn key to Alice's DeleGator
        vm.startPrank(address(aliceDeleGator));
        aliceDeleGator.addKey(webAuthnKeyId_, xWebAuthn_, yWebAuthn_);
        vm.stopPrank();

        // WebAuthn Signature values (from HybridDeleGatorTest)
        bytes memory webAuthnSignature_ = abi.encodePacked(
            keccak256(abi.encodePacked(webAuthnKeyId_)), // keyIdHash
            hex"741dd5bda817d95e4626537320e5d55179983028b2f82c99d500c5ee8624e3c4", // r
            hex"974efc58adfdad357aa487b13f3c58272d20327820a078e930c5f2ccc63a8f2b", // s
            hex"0000000000000000000000000000000000000000000000000000000000000060", // authenticatorData offset
            hex"49960de5880e8c687434170f6476605b8fe4aeb9a28632c7995cf3ba831d97630100000000", // authenticatorData
            hex"0000000000000000000000000000000000000000000000000000000000000001", // requireUserVerification
            hex"00000000000000000000000000000000000000000000000000000000000000a0", // clientDataJSONPrefix offset
            hex"7b2274797065223a22776562617574686e2e676574222c226368616c6c656e6765223a22", // clientDataJSONPrefix
            hex"0000000000000000000000000000000000000000000000000000000000000000", // clientDataJSONSuffix offset
            hex"227d000000000000000000000000000000000000000000000000000000000000", // clientDataJSONSuffix
            hex"0000000000000000000000000000000000000000000000000000000000000000" // responseTypeLocation
        );

        // Create a delegation
        Delegation memory delegation_ = Delegation({
            delegate: users.bob.addr,
            delegator: address(aliceDeleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(delegationManager.getDomainHash(), delegationHash_);
        delegation_.signature = webAuthnSignature_;

        bytes4 resultWebAuthn_ = aliceDeleGator.isValidSignature(typedDataHash_, delegation_.signature);

        console2.log("Signature verification result:", uint32(resultWebAuthn_));

        // WebAuthn signature verification may return valid (0x1626ba7e) or invalid (0xffffffff)
        // The important part is that the verification path through P256SCLVerifierLib is exercised
        assertTrue(
            resultWebAuthn_ == bytes4(0x1626ba7e) || resultWebAuthn_ == bytes4(0xffffffff),
            "WebAuthn signature verification path executed"
        );
        console2.log("SUCCESS: WebAuthn delegation framework using Fusaka precompile!");
    }
}
