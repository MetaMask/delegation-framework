// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { StreamingERC20Enforcer } from "../../src/enforcers/StreamingERC20Enforcer.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Caveats } from "../../src/libraries/Caveats.sol";

contract StreamingERC20EnforcerTest is CaveatEnforcerBaseTest {
    using ModeLib for ModeCode;

    ////////////////////////////// State //////////////////////////////
    StreamingERC20Enforcer public streamingERC20Enforcer;
    BasicERC20 public basicERC20;
    BasicERC20 public invalidERC20;
    ModeCode public mode = ModeLib.encodeSimpleSingle();

    ////////////////////////////// Events //////////////////////////////
    event IncreasedSpentMap(
        address indexed sender,
        address indexed redeemer,
        bytes32 indexed delegationHash,
        uint256 initialLimit,
        uint256 amountPerSecond,
        uint256 startTime,
        uint256 spent
    );

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        streamingERC20Enforcer = new StreamingERC20Enforcer();
        vm.label(address(streamingERC20Enforcer), "Streaming ERC20 Enforcer");
        basicERC20 = new BasicERC20(address(users.alice.deleGator), "TestToken", "TestToken", 100 ether);
        invalidERC20 = new BasicERC20(address(users.alice.addr), "InvalidToken", "IT", 100 ether);
    }

    //////////////////// Valid cases //////////////////////

    // should SUCCEED to INVOKE transfer BELOW streaming allowance
    function test_transferSucceedsIfCalledBelowAllowance() public {
        uint256 initialLimit = 1 ether;
        uint256 amountPerSecond = 0.1 ether;
        uint256 startTime = block.timestamp;

        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(basicERC20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 0.5 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory inputTerms_ = abi.encodePacked(address(basicERC20), initialLimit, amountPerSecond, startTime);
        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(streamingERC20Enforcer));
        emit IncreasedSpentMap(address(delegationManager), address(0), delegationHash_, initialLimit, amountPerSecond, startTime, 0.5 ether);
        streamingERC20Enforcer.beforeHook(
            inputTerms_, hex"", mode, executionCallData_, delegationHash_, address(0), address(0)
        );

        (,,,, uint256 spent) = streamingERC20Enforcer.streamingAllowances(address(delegationManager), delegationHash_);
        assertEq(spent, 0.5 ether);
    }

    ////////////////////// Invalid cases //////////////////////

    // should FAIL to INVOKE transfer ABOVE streaming allowance
    function test_transferFailsIfCalledAboveAllowance() public {
        uint256 initialLimit = 1 ether;
        uint256 amountPerSecond = 0.1 ether;
        uint256 startTime = block.timestamp;

        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(basicERC20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 1.5 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory inputTerms_ = abi.encodePacked(address(basicERC20), initialLimit, amountPerSecond, startTime);
        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        vm.expectRevert("StreamingERC20Enforcer:allowance-exceeded");
        streamingERC20Enforcer.beforeHook(
            inputTerms_, hex"", mode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    // should FAIL to INVOKE invalid execution data length
    function test_notAllow_invalidExecutionLength() public {
        uint256 initialLimit = 1 ether;
        uint256 amountPerSecond = 0.1 ether;
        uint256 startTime = block.timestamp;

        // Create the execution that would be executed with invalid length
        Execution memory execution_ = Execution({
            target: address(basicERC20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator))
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory inputTerms_ = abi.encodePacked(address(basicERC20), initialLimit, amountPerSecond, startTime);
        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        vm.expectRevert("StreamingERC20Enforcer:invalid-execution-length");
        streamingERC20Enforcer.beforeHook(
            inputTerms_, hex"", mode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    // should FAIL to INVOKE invalid method
    function test_methodFailsIfInvokesInvalidMethod() public {
        uint256 initialLimit = 1 ether;
        uint256 amountPerSecond = 0.1 ether;
        uint256 startTime = block.timestamp;

        // Create the execution that would be executed with invalid method
        Execution memory execution_ = Execution({
            target: address(basicERC20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.approve.selector, address(users.bob.deleGator), 1 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory inputTerms_ = abi.encodePacked(address(basicERC20), initialLimit, amountPerSecond, startTime);
        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        vm.expectRevert("StreamingERC20Enforcer:invalid-method");
        streamingERC20Enforcer.beforeHook(
            inputTerms_, hex"", mode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    ////////////////////// Integration //////////////////////

    // should FAIL to INVOKE invalid ERC20-contract
    function test_methodFailsIfInvokesInvalidContract() public {
        uint256 initialLimit = 1 ether;
        uint256 amountPerSecond = 0.1 ether;
        uint256 startTime = block.timestamp;

        // Create the execution that would be executed
        Execution memory execution_ = Execution({
            target: address(basicERC20),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 0.5 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        bytes memory inputTerms_ = abi.encodePacked(address(invalidERC20), initialLimit, amountPerSecond, startTime);
        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        vm.expectRevert("StreamingERC20Enforcer:invalid-contract");
        streamingERC20Enforcer.beforeHook(
            inputTerms_, hex"", mode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(streamingERC20Enforcer));
    }
}
