// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

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
 * @title Redemption Batch Size Limits Test
 * @dev Tests to explore the practical limits of batch sizes when redeeming delegations
 */
contract RedemptionBatchSizeLimitsTest is BaseTest {
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
        singleMode[0] = singleDefaultMode;
    }

    // Test redeeming delegations with increasing batch sizes
    function test_batchSizeLimits() public {
        // Create a basic delegation from Alice to Bob
        Delegation memory baseDelegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        baseDelegation_ = signDelegation(users.alice, baseDelegation_);

        // Create execution to increment counter
        Execution memory execution_ =
            Execution({ target: address(aliceCounter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector) });

        // Test with different batch sizes
        _testBatchSize(baseDelegation_, execution_, 1); // Single operation
        _testBatchSize(baseDelegation_, execution_, 5); // Small batch
        _testBatchSize(baseDelegation_, execution_, 10); // Medium batch
        _testBatchSize(baseDelegation_, execution_, 20); // Large batch
        _testBatchSize(baseDelegation_, execution_, 50); // Very large batch
            // Tests with even larger batches may be added but might exceed block gas limits
    }

    // Test with a batch size that includes delegations with multiple caveats
    function test_batchSizeWithCaveats() public {
        // Create a delegation with caveats
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(aliceCounter)) });
        caveats_[1] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(Counter.increment.selector) });

        Delegation memory delegationWithCaveats_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        delegationWithCaveats_ = signDelegation(users.alice, delegationWithCaveats_);

        // Create execution to increment counter
        Execution memory execution_ =
            Execution({ target: address(aliceCounter), value: 0, callData: abi.encodeWithSelector(Counter.increment.selector) });

        // Test with different batch sizes using a delegation with caveats
        _testBatchSize(delegationWithCaveats_, execution_, 1); // Single operation
        _testBatchSize(delegationWithCaveats_, execution_, 5); // Small batch
        _testBatchSize(delegationWithCaveats_, execution_, 10); // Medium batch
    }

    function createAndSubmitUserOp(TestUser memory _user, address _sender, bytes memory _callData) external returns (bool) {
        PackedUserOperation memory userOp_ = createAndSignUserOp(_user, _sender, _callData);
        submitUserOp_Bundler(userOp_);
        return true;
    }

    // Helper function to test a specific batch size
    function _testBatchSize(Delegation memory _delegation, Execution memory _execution, uint256 _batchSize) internal {
        uint256 initialCount_ = aliceCounter.count();

        // Create batch arrays
        bytes[] memory permissionContexts_ = new bytes[](_batchSize);
        ModeCode[] memory modes_ = new ModeCode[](_batchSize);
        bytes[] memory executionCallDatas_ = new bytes[](_batchSize);

        // Fill arrays with the same delegation and execution repeated
        for (uint256 i = 0; i < _batchSize; i++) {
            Delegation[] memory delegations_ = new Delegation[](1);
            delegations_[0] = _delegation;

            permissionContexts_[i] = abi.encode(delegations_);
            modes_[i] = singleDefaultMode;
            executionCallDatas_[i] = ExecutionLib.encodeSingle(_execution.target, _execution.value, _execution.callData);
        }

        // Create and sign userOp
        bytes memory userOpCallData_ =
            abi.encodeWithSelector(users.bob.deleGator.redeemDelegations.selector, permissionContexts_, modes_, executionCallDatas_);

        PackedUserOperation memory userOp_ = createAndSignUserOp(users.bob, address(users.bob.deleGator), userOpCallData_);

        uint256 startGas_ = gasleft();

        // Submit userOp
        submitUserOp_Bundler(userOp_);

        uint256 gasUsed_ = startGas_ - gasleft();

        // Verify all operations were executed
        uint256 finalCount_ = aliceCounter.count();
        assertEq(finalCount_, initialCount_ + _batchSize, "Not all operations executed");

        // Log gas usage for analysis
        console.log("Batch size:", _batchSize);
        console.log("Gas used:", gasUsed_);
        console.log("Gas per op:", gasUsed_ / _batchSize);
    }
}
