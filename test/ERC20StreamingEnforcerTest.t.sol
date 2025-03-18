// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Implementation, SignatureType } from "./utils/Types.t.sol";
import { BaseTest } from "./utils/BaseTest.t.sol";
import { Execution, PackedUserOperation, Caveat, Delegation, ModeCode } from "../src/utils/Types.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    CALLTYPE_SINGLE,
    CALLTYPE_BATCH,
    EXECTYPE_DEFAULT,
    EXECTYPE_TRY,
    MODE_DEFAULT,
    ModePayload,
    ModeLib
} from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ERC20StreamingEnforcer } from "../src/enforcers/ERC20StreamingEnforcer.sol";
import { AllowedTargetsEnforcer } from "../src/enforcers/AllowedTargetsEnforcer.sol";
import { AllowedMethodsEnforcer } from "../src/enforcers/AllowedMethodsEnforcer.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";

// A mock token that allows us to simulate failed transfers
contract MockERC20 is ERC20 {
    // Flag to make transfers fail
    bool public haltTransfers;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        haltTransfers = false;
    }

    function setHaltTransfer(bool _halt) external {
        haltTransfers = _halt;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (haltTransfers) {
            return false; // Fail silently
        }
        return super.transfer(to, amount);
    }
}

/**
 * @title ERC20 Streaming Enforcer Test in EXECTYPE_TRY mode
 * @notice This test was failing - now passes after the latest commit
 */
contract ERC20StreamingEnforcerTest is BaseTest {
    using MessageHashUtils for bytes32;
    using ModeLib for ModeCode;

    // Enforcer contracts
    ERC20StreamingEnforcer public streamingEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;

    // Mock token
    MockERC20 public mockToken;

    // Test parameters
    uint256 constant INITIAL_AMOUNT = 10 ether;
    uint256 constant MAX_AMOUNT = 100 ether;
    uint256 constant AMOUNT_PER_SECOND = 1 ether;

    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
    }

    function setUp() public override {
        super.setUp();

        // Deploy the enforcers
        streamingEnforcer = new ERC20StreamingEnforcer();
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();

        // Deploy the mock token
        mockToken = new MockERC20("Mock Token", "MOCK");

        // Mint tokens to Alice's wallet
        mockToken.mint(address(users.alice.deleGator), 200 ether);

        // Fund the wallets with ETH for gas
        vm.deal(address(users.alice.deleGator), 10 ether);
        vm.deal(address(users.bob.deleGator), 10 ether);

        // Labels
        vm.label(address(streamingEnforcer), "ERC20StreamingEnforcer");
        vm.label(address(allowedTargetsEnforcer), "AllowedTargetsEnforcer");
        vm.label(address(allowedMethodsEnforcer), "AllowedMethodsEnforcer");
        vm.label(address(mockToken), "MockToken");
    }

    function test_streamingAllowanceDrainWithFailedTransfers() public {
        // Create streaming terms that define:
        // - initialAmount = 10 ether (available immediately at startTime)
        // - maxAmount = 100 ether (total streaming cap)
        // - amountPerSecond = 1 ether (streaming rate)
        // - startTime = current block timestamp (start streaming now)
        uint256 startTime = block.timestamp;
        bytes memory streamingTerms = abi.encodePacked(
            address(mockToken), // token address (20 bytes)
            uint256(INITIAL_AMOUNT), // initial amount (32 bytes)
            uint256(MAX_AMOUNT), // max amount (32 bytes)
            uint256(AMOUNT_PER_SECOND), // amount per second (32 bytes)
            uint256(startTime) // start time (32 bytes)
        );

        Caveat[] memory caveats = new Caveat[](3);

        // Allowed Targets Enforcer - only allow the token
        caveats[0] = Caveat({ enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(mockToken)), args: hex"" });

        // Allowed Methods Enforcer - only allow transfer
        caveats[1] =
            Caveat({ enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(IERC20.transfer.selector), args: hex"" });

        // ERC20 Streaming Enforcer - with the streaming terms
        caveats[2] = Caveat({ enforcer: address(streamingEnforcer), terms: streamingTerms, args: hex"" });

        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        // Sign the delegation
        delegation = signDelegation(users.alice, delegation);
        bytes32 delegationHash = EncoderLib._getDelegationHash(delegation);

        // Initial balances
        uint256 aliceInitialBalance = mockToken.balanceOf(address(users.alice.deleGator));
        uint256 bobInitialBalance = mockToken.balanceOf(address(users.bob.addr));
        console.log("Alice initial balance:", aliceInitialBalance / 1e18);
        console.log("Bob initial balance:", bobInitialBalance / 1e18);

        // Amount to transfer
        uint256 amountToTransfer = 5 ether;

        // Create the mode for try execution (which will NOT revert on failures)
        ModeCode tryExecuteMode = ModeLib.encode(CALLTYPE_SINGLE, EXECTYPE_TRY, MODE_DEFAULT, ModePayload.wrap(bytes22(0x00)));
        ModeCode defaultExecuteMode =
            ModeLib.encode(CALLTYPE_SINGLE, EXECTYPE_DEFAULT, MODE_DEFAULT, ModePayload.wrap(bytes22(0x00)));

        // First test - Successful transfer with default execution type
        {
            console.log("\n--- TEST 1: SUCCESSFUL TRANSFER ---");

            // Make sure token transfers will succeed
            mockToken.setHaltTransfer(false);

            // Prepare a transfer execution
            Execution memory execution = Execution({
                target: address(mockToken),
                value: 0,
                callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.addr), amountToTransfer)
            });

            // Execute the delegation using try mode
            execute_UserOp(
                users.bob,
                abi.encodeWithSelector(
                    delegationManager.redeemDelegations.selector,
                    createPermissionContexts(delegation),
                    createModes(defaultExecuteMode),
                    createExecutionCallDatas(execution)
                )
            );

            // Check balances after successful transfer
            uint256 aliceBalanceAfterSuccess = mockToken.balanceOf(address(users.alice.deleGator));
            uint256 bobBalanceAfterSuccess = mockToken.balanceOf(address(users.bob.addr));
            console.log("Alice balance after successful transfer:", aliceBalanceAfterSuccess / 1e18);
            console.log("Bob balance after successful transfer:", bobBalanceAfterSuccess / 1e18);

            // Check streaming allowance state
            (,,,, uint256 storedSpent) = streamingEnforcer.streamingAllowances(address(delegationManager), delegationHash);

            console.log("Spent amount:", storedSpent / 1e18);

            // uint256 availableAfterSuccess = streamingEnforcer.getAvailableAmount(address(delegationManager), delegationHash);
            // console.log("Available amount:", availableAfterSuccess / 1e18);

            // Verify the spent amount was updated
            assertEq(storedSpent, amountToTransfer, "Spent amount should be updated after successful transfer");

            // Verify tokens were actually transferred
            assertEq(aliceBalanceAfterSuccess, aliceInitialBalance - amountToTransfer, "Alice balance should decrease");
            assertEq(bobBalanceAfterSuccess, bobInitialBalance + amountToTransfer, "Bob balance should increase");
        }

        // Second test - Failed transfer in try execution mode (not allowed after latest commit)
        {
            console.log("\n--- TEST 2: FAILED TRANSFER ---");

            // Make token transfers fail
            mockToken.setHaltTransfer(true);

            // Prepare the same transfer execution
            Execution memory execution = Execution({
                target: address(mockToken),
                value: 0,
                callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.addr), amountToTransfer)
            });

            // Record spent amount before the failed transfer
            (,,,, uint256 spentBeforeFailure) = streamingEnforcer.streamingAllowances(address(delegationManager), delegationHash);
            console.log("Spent amount before failed transfer:", spentBeforeFailure / 1e18);

            // Execute the delegation (will use try mode so execution continues despite transfer failure)
            execute_UserOp(
                users.bob,
                abi.encodeWithSelector(
                    delegationManager.redeemDelegations.selector,
                    createPermissionContexts(delegation),
                    createModes(tryExecuteMode),
                    createExecutionCallDatas(execution)
                )
            );

            // Check balances after failed transfer
            uint256 aliceBalanceAfterFailure = mockToken.balanceOf(address(users.alice.deleGator));
            uint256 bobBalanceAfterFailure = mockToken.balanceOf(address(users.bob.addr));
            console.log("Alice balance after failed transfer:", aliceBalanceAfterFailure / 1e18);
            console.log("Bob balance after failed transfer:", bobBalanceAfterFailure / 1e18);

            // Check spent amount after failed transfer
            (,,,, uint256 spentAfterFailure) = streamingEnforcer.streamingAllowances(address(delegationManager), delegationHash);
            console.log("Spent amount after failed transfer:", spentAfterFailure / 1e18);

            // uint256 availableAfterFailure = streamingEnforcer.getAvailableAmount(address(delegationManager), delegationHash);
            // console.log("Available amount after failure:", availableAfterFailure / 1e18);

            // THE KEY TEST: The spent amount increased even though the transfer failed!
            // assertEq(
            //     spentAfterFailure, spentBeforeFailure + amountToTransfer, "Spent amount should increase even with failed
            // transfer"
            // );

            // THE KEY TEST: The spent amount should not increase even though the transfer failed!
            assertEq(spentAfterFailure, spentBeforeFailure, "Spent amount should increase even with failed transfer");

            // Verify tokens weren't actually transferred
            assertEq(
                aliceBalanceAfterFailure,
                aliceInitialBalance - amountToTransfer, // Only reduced by the first successful transfer
                "Alice balance should not change after failed transfer"
            );
            assertEq(
                bobBalanceAfterFailure,
                bobInitialBalance + amountToTransfer, // Only increased by the first successful transfer
                "Bob balance should not change after failed transfer"
            );
        }
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

    function createModes(ModeCode _mode) internal pure returns (ModeCode[] memory) {
        ModeCode[] memory modes = new ModeCode[](1);
        modes[0] = _mode;
        return modes;
    }
}
