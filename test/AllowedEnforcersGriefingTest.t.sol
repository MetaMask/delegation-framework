// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { Implementation, SignatureType, TestUser } from "./utils/Types.t.sol";
import { Execution, PackedUserOperation, Caveat, Delegation, ModeCode, ModePayload } from "../src/utils/Types.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { CALLTYPE_SINGLE, EXECTYPE_DEFAULT, MODE_DEFAULT } from "../src/utils/Constants.sol";

// Enforcers
import { AllowedMethodsEnforcer } from "../src/enforcers/AllowedMethodsEnforcer.sol";
import { AllowedTargetsEnforcer } from "../src/enforcers/AllowedTargetsEnforcer.sol";
import { AllowedCalldataEnforcer } from "../src/enforcers/AllowedCalldataEnforcer.sol";

// Test contracts
import { Counter } from "./utils/Counter.t.sol";
import { GasReporter } from "./utils/GasReporter.t.sol";
import "forge-std/console.sol";

/**
 * @title Enforcer Griefing Test
 * @dev Tests potential griefing attacks in enforcers that check for allowed methods/targets
 * @dev uses duplicate entries in allowedMethodsEnforcer or allowedTargetsEnforcer to increase gas costs
 */
contract AllowedEnforcersGriefingTest is BaseTest {
    using MessageHashUtils for bytes32;
    using ModeLib for ModeCode;

    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    AllowedCalldataEnforcer public allowedCalldataEnforcer;

    // Test targets
    Counter public aliceCounter;
    Counter public bobCounter;
    GasReporter public gasReporter;

    // Test data for AllowedMethods
    bytes4 public constant INCREMENT_SELECTOR = bytes4(keccak256("increment()"));
    bytes4 public constant DECREMENT_SELECTOR = bytes4(keccak256("decrement()"));
    bytes4 public constant GET_COUNT_SELECTOR = bytes4(keccak256("count()"));
    bytes4 public constant UNSAFE_INCREMENT_SELECTOR = bytes4(keccak256("unsafeIncrement()"));

    // Common variables
    ModeCode mode;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();

        // Deploy enforcers
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        allowedCalldataEnforcer = new AllowedCalldataEnforcer();

        // Deploy test targets
        aliceCounter = new Counter(address(users.alice.deleGator));
        bobCounter = new Counter(address(users.bob.deleGator));
        gasReporter = new GasReporter();

        // Set up common variables
        mode = ModeLib.encode(CALLTYPE_SINGLE, EXECTYPE_DEFAULT, MODE_DEFAULT, ModePayload.wrap(0x00));
    }

    //////////////////////////////////
    // AllowedMethods Griefing Tests
    //////////////////////////////////

    function test_AllowedMethods_RegularUse() public {
        // Single method allowed
        bytes memory terms = abi.encodePacked(INCREMENT_SELECTOR);

        // Create execution to increment counter
        Execution memory execution =
            Execution({ target: address(aliceCounter), value: 0, callData: abi.encodeWithSelector(INCREMENT_SELECTOR) });

        // Create delegation with allowed methods caveat
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ enforcer: address(allowedMethodsEnforcer), terms: terms, args: "" });

        // Create and sign the delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        delegation = signDelegation(users.alice, delegation);

        // Execute the delegation through Bob
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        invokeDelegation_UserOp(users.bob, delegations, execution);

        // Verify that increment worked
        assertEq(aliceCounter.count(), 1);
    }

    function test_AllowedMethods_DuplicateMethodsGriefing() public {
        // Create terms with a high number of duplicated methods to increase gas costs
        bytes memory terms = createDuplicateMethodsTerms(INCREMENT_SELECTOR, 100);

        // Create execution to increment counter
        Execution memory execution =
            Execution({ target: address(aliceCounter), value: 0, callData: abi.encodeWithSelector(INCREMENT_SELECTOR) });

        // Create delegation with allowed methods caveat
        Caveat[] memory caveats = new Caveat[](1);
        caveats[0] = Caveat({ enforcer: address(allowedMethodsEnforcer), terms: terms, args: "" });

        // Create and sign the delegation
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        delegation = signDelegation(users.alice, delegation);

        // Measure gas usage with many duplicate methods
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        uint256 gasUsed = uint256(
            bytes32(
                gasReporter.measureGas(
                    address(users.bob.deleGator),
                    address(delegationManager),
                    abi.encodeWithSelector(
                        delegationManager.redeemDelegations.selector,
                        createPermissionContexts(delegation),
                        createModes(),
                        createExecutionCallDatas(execution)
                    )
                )
            )
        );

        console.log("Gas used with 100 duplicate methods:", gasUsed);

        // Now compare to normal case with just one method
        terms = abi.encodePacked(INCREMENT_SELECTOR);
        caveats[0].terms = terms;

        delegation.caveats = caveats;
        delegation = signDelegation(users.alice, delegation);

        delegations[0] = delegation;

        uint256 gasUsedNormal = uint256(
            bytes32(
                gasReporter.measureGas(
                    address(users.bob.deleGator),
                    address(delegationManager),
                    abi.encodeWithSelector(
                        delegationManager.redeemDelegations.selector,
                        createPermissionContexts(delegation),
                        createModes(),
                        createExecutionCallDatas(execution)
                    )
                )
            )
        );

        console.log("Gas used with 1 method:", gasUsedNormal);
        console.log("Gas diff:", gasUsed - gasUsedNormal);

        assertGt(gasUsed, gasUsedNormal, "Griefing with duplicate methods should use more gas");
    }

    function createDuplicateMethodsTerms(bytes4 selector, uint256 count) internal pure returns (bytes memory) {
        bytes memory terms = new bytes(count * 4);
        for (uint256 i = 0; i < count; i++) {
            bytes4 methodSig = selector;
            for (uint256 j = 0; j < 4; j++) {
                terms[i * 4 + j] = methodSig[j];
            }
        }
        return terms;
    }

    function createPermissionContexts(Delegation memory del) internal pure returns (bytes[] memory) {
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = del;

        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegations);

        return permissionContexts;
    }

    function createExecutionCallDatas(Execution memory execution) internal pure returns (bytes[] memory) {
        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);
        return executionCallDatas;
    }

    function createModes() internal view returns (ModeCode[] memory) {
        ModeCode[] memory modes = new ModeCode[](1);
        modes[0] = mode;
        return modes;
    }
}
