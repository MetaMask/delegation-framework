// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { Implementation, SignatureType, TestUser } from "./utils/Types.t.sol";
import { Execution, PackedUserOperation, Caveat, Delegation, ModeCode } from "../src/utils/Types.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { Counter } from "./utils/Counter.t.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";

import { AllowedMethodsEnforcer } from "../src/enforcers/AllowedMethodsEnforcer.sol";
import { AllowedTargetsEnforcer } from "../src/enforcers/AllowedTargetsEnforcer.sol";
import "forge-std/console.sol";

/**
 * @title Batch Size Limits Test
 * @dev Tests to explore the practical limits of batch sizes when redeeming delegations
 */
contract BatchSizeLimitsTest is BaseTest {
    using ModeLib for ModeCode;
    using MessageHashUtils for bytes32;

    // Test configuration
    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
    }

    // State variables
    Counter public aliceCounter;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    ModeCode[] public singleMode;

    // Setup for tests
    function setUp() public override {
        super.setUp();

        // Create a counter owned by Alice's DeleGator
        aliceCounter = new Counter(address(users.alice.deleGator));

        // Create enforcers for caveats
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        vm.label(address(allowedMethodsEnforcer), "Allowed Methods Enforcer");
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        vm.label(address(allowedTargetsEnforcer), "Allowed Targets Enforcer");

        // Create mode
        singleMode = new ModeCode[](1);
        singleMode[0] = ModeLib.encodeSimpleSingle();
    }

    // Test redeeming delegations with increasing batch sizes
    function test_batchSizeLimits() public {
        // Create a basic delegation from Alice to Bob
        Delegation memory baseDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        baseDelegation = signDelegation(users.alice, baseDelegation);

        // Create execution to increment counter
        Execution memory execution =
            Execution({ target: address(aliceCounter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector) });

        // Test with different batch sizes
        _testBatchSize(baseDelegation, execution, 1); // Single operation
        _testBatchSize(baseDelegation, execution, 5); // Small batch
        _testBatchSize(baseDelegation, execution, 10); // Medium batch
        _testBatchSize(baseDelegation, execution, 20); // Large batch
        _testBatchSize(baseDelegation, execution, 50); // Very large batch
            // Tests with even larger batches may be added but might exceed block gas limits
    }

    // Helper function to test a specific batch size
    function _testBatchSize(Delegation memory delegation, Execution memory execution, uint256 batchSize) internal {
        uint256 initialCount = aliceCounter.count();

        // Create batch arrays
        bytes[] memory permissionContexts = new bytes[](batchSize);
        ModeCode[] memory modes = new ModeCode[](batchSize);
        bytes[] memory executionCallDatas = new bytes[](batchSize);

        // Fill arrays with the same delegation and execution repeated
        for (uint256 i = 0; i < batchSize; i++) {
            Delegation[] memory delegations = new Delegation[](1);
            delegations[0] = delegation;

            permissionContexts[i] = abi.encode(delegations);
            modes[i] = ModeLib.encodeSimpleSingle();
            executionCallDatas[i] = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);
        }

        // Create and sign userOp
        bytes memory userOpCallData =
            abi.encodeWithSelector(users.bob.deleGator.redeemDelegations.selector, permissionContexts, modes, executionCallDatas);

        uint256 startGas = gasleft();

        PackedUserOperation memory userOp = createAndSignUserOp(users.bob, address(users.bob.deleGator), userOpCallData);

        // Submit userOp
        submitUserOp_Bundler(userOp);

        uint256 gasUsed = startGas - gasleft();

        // Verify all operations were executed
        uint256 finalCount = aliceCounter.count();
        assertEq(finalCount, initialCount + batchSize, "Not all operations executed");

        // Log gas usage for analysis
        console.log("Batch size:", batchSize);
        console.log("Gas used:", gasUsed);
        console.log("Gas per op:", gasUsed / batchSize);
    }

    // Test with a batch size that includes delegations with multiple caveats
    function test_batchSizeWithCaveats() public {
        // Create a delegation with caveats
        Caveat[] memory caveats = new Caveat[](2);
        caveats[0] =
            Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(aliceCounter)) });
        caveats[1] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(Counter.increment.selector) });

        Delegation memory delegationWithCaveats = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        delegationWithCaveats = signDelegation(users.alice, delegationWithCaveats);

        // Create execution to increment counter
        Execution memory execution =
            Execution({ target: address(aliceCounter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector) });

        // Test with different batch sizes using a delegation with caveats
        _testBatchSize(delegationWithCaveats, execution, 1); // Single operation
        _testBatchSize(delegationWithCaveats, execution, 5); // Small batch
        _testBatchSize(delegationWithCaveats, execution, 10); // Medium batch
    }

    function createAndSubmitUserOp(TestUser memory user, address sender, bytes memory callData) external returns (bool) {
        PackedUserOperation memory userOp = createAndSignUserOp(user, sender, callData);
        submitUserOp_Bundler(userOp);
        return true;
    }
}
