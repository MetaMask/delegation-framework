// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC20PeriodicClaimEnforcer } from "../../src/enforcers/ERC20PeriodicClaimEnforcer.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ERC20PeriodicClaimEnforcerTest is CaveatEnforcerBaseTest {
    using ModeLib for ModeCode;

    ////////////////////////////// State //////////////////////////////
    ERC20PeriodicClaimEnforcer public erc20PeriodicClaimEnforcer;
    BasicERC20 public basicERC20;
    ModeCode public singleMode = ModeLib.encodeSimpleSingle();
    address public alice;
    address public bob;

    bytes32 delegationHash = keccak256("test-delegation");
    address redeemer = address(0x123);

    // Parameters for the periodic allowance.
    uint256 periodAmount = 1000;
    uint256 periodDuration = 1 days; // 86400 seconds
    uint256 startDate;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        erc20PeriodicClaimEnforcer = new ERC20PeriodicClaimEnforcer();
        vm.label(address(erc20PeriodicClaimEnforcer), "ERC20 Periodic Claim Enforcer");

        alice = address(users.alice.deleGator);
        bob = address(users.bob.deleGator);

        basicERC20 = new BasicERC20(alice, "TestToken", "TestToken", 100 ether);

        startDate = block.timestamp; // set startDate to current block time
    }

    //////////////////// Error / Revert Tests //////////////////////

    /**
     * @notice Ensures it reverts if `_terms.length != 148`.
     */
    function testInvalidTermsLength() public {
        bytes memory invalidTerms = new bytes(115); // one byte short
        vm.expectRevert("ERC20PeriodicClaimEnforcer:invalid-terms-length");
        erc20PeriodicClaimEnforcer.getTermsInfo(invalidTerms);
    }

    function testInvalidZeroStartDate() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, uint256(0));
        vm.expectRevert("ERC20PeriodicClaimEnforcer:invalid-zero-start-date");
        erc20PeriodicClaimEnforcer.beforeHook(terms, "", singleMode, hex"", delegationHash, address(0), redeemer);
    }

    function testInvalidZeroPeriodDuration() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, uint256(0), startDate);
        vm.expectRevert("ERC20PeriodicClaimEnforcer:invalid-zero-period-duration");
        erc20PeriodicClaimEnforcer.beforeHook(terms, "", singleMode, hex"", delegationHash, address(0), redeemer);
    }

    function testInvalidZeroPeriodAmount() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), uint256(0), periodDuration, startDate);
        vm.expectRevert("ERC20PeriodicClaimEnforcer:invalid-zero-period-amount");
        erc20PeriodicClaimEnforcer.beforeHook(terms, "", singleMode, hex"", delegationHash, address(0), redeemer);
    }

    function testClaimNotStarted() public {
        uint256 futureStart = block.timestamp + 100;
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, futureStart);

        bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
        bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

        vm.expectRevert("ERC20PeriodicClaimEnforcer:claim-not-started");
        erc20PeriodicClaimEnforcer.beforeHook(terms, "", singleMode, execData_, delegationHash, address(0), redeemer);
    }

    function testInvalidExecutionLength() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        // Create call data with invalid length (not 68 bytes)
        bytes memory invalidExecCallData = new bytes(67);
        vm.expectRevert("ERC20PeriodicClaimEnforcer:invalid-execution-length");
        erc20PeriodicClaimEnforcer.beforeHook(terms, "", singleMode, invalidExecCallData, delegationHash, address(0), redeemer);
    }

    function testInvalidContract() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        bytes memory callData = abi.encodeWithSelector(basicERC20.transfer.selector, redeemer, 500);
        // Create execution call data with a wrong target (simulate by prepending a different address)
        bytes memory invalidExecCallData = abi.encodePacked(address(0xdead), callData);

        bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
        bytes memory execData_ = _encodeSingleExecution(address(0xdead), 0, callData_);

        vm.expectRevert("ERC20PeriodicClaimEnforcer:invalid-contract");
        erc20PeriodicClaimEnforcer.beforeHook(terms, "", singleMode, invalidExecCallData, delegationHash, address(0), redeemer);
    }

    function testInvalidMethod() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        // Create call data with an invalid function selector (not IERC20.transfer.selector)
        bytes memory invalidCallData = abi.encodeWithSelector(IERC20.transferFrom.selector, redeemer, 500);
        bytes memory execCallData = abi.encodePacked(address(basicERC20), invalidCallData);
        vm.expectRevert("ERC20PeriodicClaimEnforcer:invalid-method");
        erc20PeriodicClaimEnforcer.beforeHook(terms, "", singleMode, execCallData, delegationHash, address(0), redeemer);
    }

    function testClaimAmountExceeded() public {
        bytes memory terms = abi.encodePacked(address(basicERC20), periodAmount, periodDuration, startDate);
        // First claim: 800 tokens
        bytes memory execCallData1 = _encodeSingleExecution(address(basicERC20), _encodeERC20Transfer(800));
        erc20PeriodicClaimEnforcer.beforeHook(terms, "", singleMode, execCallData1, delegationHash, address(0), redeemer);

        // Second claim: attempt to claim 300 tokens, which exceeds the remaining 200 tokens.
        bytes memory execCallData2 = _encodeSingleExecution(address(basicERC20), _encodeERC20Transfer(300));
        vm.expectRevert("ERC20PeriodicClaimEnforcer:claim-amount-exceeded");
        erc20PeriodicClaimEnforcer.beforeHook(terms, "", singleMode, execCallData2, delegationHash, address(0), redeemer);
    }

    // /**
    //  * @notice Checks revert if `maxAmount < initialAmount`.
    //  */
    // function test_invalidMaxAmount() public {
    //     // initial=100, max=50 => revert
    //     bytes memory terms = encodeTerms(
    //         address(basicERC20),
    //         100 ether, // initial
    //         50 ether, // max < initial
    //         1 ether,
    //         block.timestamp + 10
    //     );

    //     bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
    //     bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

    //     vm.expectRevert(bytes("ERC20PeriodicClaimEnforcer:invalid-max-amount"));
    //     erc20PeriodicClaimEnforcer.beforeHook(terms, bytes(""), mode, execData_, bytes32(0), address(0), alice);
    // }

    // /**
    //  * @notice Test that it reverts if startTime == 0.
    //  */
    // function test_invalidZeroStartTime() public {
    //     // Prepare valid basicERC20 and amounts, but zero start time
    //     uint256 startTime_ = 0;
    //     bytes memory terms_ = encodeTerms(address(basicERC20), 10 ether, 100 ether, 1 ether, startTime_);

    //     bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
    //     bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

    //     vm.expectRevert(bytes("ERC20PeriodicClaimEnforcer:invalid-zero-start-time"));
    //     erc20PeriodicClaimEnforcer.beforeHook(terms_, bytes(""), mode, execData_, bytes32(0), address(0), alice);
    // }

    // /**
    //  * @notice Test that it reverts with `ERC20PeriodicClaimEnforcer:allowance-exceeded`
    //  *         if the transfer request exceeds the currently unlocked amount.
    //  */
    // function test_allowanceExceeded() public {
    //     // Start in the future => 0 available now
    //     uint256 start_ = block.timestamp + 100;
    //     bytes memory terms_ = encodeTerms(address(basicERC20), 10 ether, 50 ether, 1 ether, start_);

    //     // Trying to transfer more than is available (which is 0 if we call now).
    //     bytes memory callData_ = _encodeERC20Transfer(bob, 50 ether);
    //     bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

    //     vm.expectRevert(bytes("ERC20PeriodicClaimEnforcer:allowance-exceeded"));
    //     erc20PeriodicClaimEnforcer.beforeHook(terms_, bytes(""), mode, execData_, bytes32(0), address(0), alice);
    // }

    // /**
    //  * @notice Test chunk logic revert if `initialAmount` > 0 but `amountPerSecond=0`.
    //  */
    // function test_zeroAmountPerSecondChunkLogic() public {
    //     bytes memory terms_ = encodeTerms(
    //         address(basicERC20),
    //         100 ether, // initial
    //         500 ether, // max
    //         0, // amountPerSecond=0
    //         block.timestamp
    //     );

    //     // The call data is valid
    //     bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
    //     bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

    //     // Because initialAmount > 0 and amountPerSecond = 0, chunk logic triggers the revert
    //     vm.warp(block.timestamp + 1);
    //     vm.expectRevert(bytes("ERC20PeriodicClaimEnforcer:zero-amount-per-second"));
    //     erc20PeriodicClaimEnforcer.beforeHook(terms_, bytes(""), mode, execData_, bytes32(0), address(0), alice);
    // }

    // /// @notice Test chunk logic revert if initialAmount < amountPerSecond.
    // function test_initialAmountTooLow() public {
    //     // initial=1, rate=2 => revert
    //     bytes memory terms_ = encodeTerms(address(basicERC20), 1 ether, 10 ether, 2 ether, block.timestamp);

    //     bytes memory callData_ = _encodeERC20Transfer(bob, 1 ether);
    //     bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

    //     vm.expectRevert(bytes("ERC20PeriodicClaimEnforcer:initial-amount-is-too-low"));
    //     erc20PeriodicClaimEnforcer.beforeHook(terms_, bytes(""), mode, execData_, bytes32(0), address(0), alice);
    // }

    // /// @notice Test that it reverts with `ERC20PeriodicClaimEnforcer:invalid-execution-length` if the callData_ is not 68 bytes.
    // function test_invalidExecutionLength() public {
    //     // valid `_terms`
    //     bytes memory terms_ = encodeTerms(address(basicERC20), 100 ether, 1 ether, 1 ether, block.timestamp + 10);
    //     // Provide some random data that is not exactly 68 bytes
    //     bytes memory callData_ = new bytes(40);
    //     // _encodeSingleExecution
    //     bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

    //     vm.expectRevert(bytes("ERC20PeriodicClaimEnforcer:invalid-execution-length"));
    //     erc20PeriodicClaimEnforcer.beforeHook(terms_, bytes(""), mode, execData_, bytes32(0), address(0), alice);
    // }

    // /// @notice Test that it reverts with `ERC20PeriodicClaimEnforcer:invalid-method` if the selector isn't `transfer`.
    // function test_invalidMethodSelector() public {
    //     bytes memory terms_ = encodeTerms(address(basicERC20), 100 ether, 100 ether, 1 ether, block.timestamp + 10);

    //     // Calling transferFrom() method instead of the valid transfer method
    //     bytes memory badCallData_ = abi.encodeWithSelector(IERC20.transferFrom.selector, bob, 10 ether);

    //     bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, badCallData_);

    //     vm.expectRevert(bytes("ERC20PeriodicClaimEnforcer:invalid-method"));
    //     erc20PeriodicClaimEnforcer.beforeHook(terms_, bytes(""), mode, execData_, bytes32(0), address(0), alice);
    // }

    // /// @notice Test that it reverts with `ERC20PeriodicClaimEnforcer:invalid-contract` if the basicERC20 address doesn't match
    // the
    // /// target.
    // function test_invalidContract() public {
    //     // Terms says the basicERC20 is `basicERC20`, but we call a different target in `execData_`
    //     bytes memory terms_ = encodeTerms(address(basicERC20), 100 ether, 100 ether, 1 ether, block.timestamp + 10);

    //     // Encode callData_ with correct selector but to a different contract address
    //     BasicERC20 otherToken_ = new BasicERC20(alice, "TestToken2", "TestToken2", 100 ether);
    //     bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
    //     bytes memory execData_ = _encodeSingleExecution(address(otherToken_), 0, callData_);

    //     vm.expectRevert(bytes("ERC20PeriodicClaimEnforcer:invalid-contract"));
    //     erc20PeriodicClaimEnforcer.beforeHook(terms_, bytes(""), mode, execData_, bytes32(0), address(0), alice);
    // }

    // //////////////////// Valid cases //////////////////////

    // /// @notice Test that getTermsInfo() decodes valid 148-byte terms correctly.
    // function test_getTermsInfoHappyPath() public {
    //     address token_ = address(basicERC20);
    //     uint256 initialAmount_ = 100 ether;
    //     uint256 maxAmount_ = 50 ether;
    //     uint256 amountPerSecond_ = 1 ether;
    //     uint256 startTime_ = block.timestamp + 100;

    //     bytes memory termsData_ = encodeTerms(token_, initialAmount_, maxAmount_, amountPerSecond_, startTime_);

    //     (
    //         address decodedToken_,
    //         uint256 decodedInitialAmount_,
    //         uint256 decodedMaxAmount_,
    //         uint256 decodedAmountPerSecond_,
    //         uint256 decodedStartTime_
    //     ) = erc20PeriodicClaimEnforcer.getTermsInfo(termsData_);

    //     assertEq(decodedToken_, token_, "Token mismatch");
    //     assertEq(decodedInitialAmount_, initialAmount_, "Initial amount mismatch");
    //     assertEq(decodedMaxAmount_, maxAmount_, "Max amount mismatch");
    //     assertEq(decodedAmountPerSecond_, amountPerSecond_, "Amount per second mismatch");
    //     assertEq(decodedStartTime_, startTime_, "Start time mismatch");
    // }

    // /// @notice Test that getTermsInfo() reverts with `ERC20PeriodicClaimEnforcer:invalid-terms-length` if `_terms` is not 148
    // /// bytes.
    // function test_getTermsInfoInvalidLength() public {
    //     // Create an array shorter than 1 bytes
    //     bytes memory shortTermsData = new bytes(100);

    //     // Expect the specific revert
    //     vm.expectRevert(bytes("ERC20PeriodicClaimEnforcer:invalid-terms-length"));
    //     erc20PeriodicClaimEnforcer.getTermsInfo(shortTermsData);
    // }

    // /**
    //  * @notice Confirms the `IncreasedSpentMap` event is emitted for a valid transfer.
    //  */
    // function test_increasedSpentMapEvent() public {
    //     uint256 initialAmount_ = 1 ether;
    //     uint256 maxAmount_ = 10 ether;
    //     uint256 amountPerSecond_ = 1 ether;
    //     uint256 startTime_ = block.timestamp;
    //     bytes memory terms_ = encodeTerms(address(basicERC20), initialAmount_, maxAmount_, amountPerSecond_, startTime_);

    //     // Transfer 0.5 ether, which is below the allowance so it should succeed.
    //     uint256 transferAmount_ = 0.5 ether;
    //     bytes memory callData_ = _encodeERC20Transfer(bob, transferAmount_);
    //     bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

    //     vm.expectEmit(true, true, true, true, address(erc20PeriodicClaimEnforcer));
    //     emit ERC20PeriodicClaimEnforcer.IncreasedSpentMap(
    //         address(this), // sender = this test contract is calling beforeHook()
    //         alice, // redeemer = alice is the original message sender in this scenario
    //         bytes32(0), // example delegationHash (we're using 0 here)
    //         address(basicERC20), // basicERC20
    //         initialAmount_,
    //         maxAmount_,
    //         amountPerSecond_,
    //         startTime_,
    //         transferAmount_, // spent amount after this transfer
    //         block.timestamp // lastUpdateTimestamp (the event uses current block timestamp)
    //     );

    //     erc20PeriodicClaimEnforcer.beforeHook(
    //         terms_,
    //         bytes(""), // no additional data
    //         mode, // single execution mode
    //         execData_,
    //         bytes32(0), // example delegation hash
    //         address(0), // extra param (unused here)
    //         alice // redeemer
    //     );

    //     // Verify final storage
    //     (uint256 storedInitial_, uint256 storedMax, uint256 storedRate_, uint256 storedStart_, uint256 storedSpent_) =
    //         erc20PeriodicClaimEnforcer.streamingAllowances(address(this), bytes32(0));

    //     assertEq(storedInitial_, initialAmount_, "Should store the correct initialAmount");
    //     assertEq(storedMax, maxAmount_, "Should store correct max");
    //     assertEq(storedRate_, amountPerSecond_, "Should store the correct amountPerSecond");
    //     assertEq(storedStart_, startTime_, "Should store the correct startTime");
    //     assertEq(storedSpent_, transferAmount_, "Should record the correct spent");
    // }

    // ////////////////////// Valid cases //////////////////////

    // /// @notice Tests that no tokens are available before the configured start time.
    // function test_getAvailableAmountBeforeStartTime() public {
    //     // This start time is in the future
    //     uint256 futureStart_ = block.timestamp + 1000;
    //     bytes memory terms_ = encodeTerms(address(basicERC20), 50 ether, 100 ether, 1 ether, futureStart_);

    //     // Prepare a valid IERC20.transfer call
    //     bytes memory callData_ = _encodeERC20Transfer(bob, 10 ether);
    //     bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);

    //     // Calls beforeHook expecting no tokens to be spendable => must revert
    //     vm.expectRevert("ERC20PeriodicClaimEnforcer:allowance-exceeded");
    //     erc20PeriodicClaimEnforcer.beforeHook(terms_, bytes(""), mode, execData_, bytes32(0), address(0), alice);

    //     // Checking getAvailableAmount directly also returns 0
    //     uint256 available_ = erc20PeriodicClaimEnforcer.getAvailableAmount(bytes32(0), address(this));
    //     assertEq(available_, 0, "Expected 0 tokens available before start time");
    // }

    // /**
    //  * @notice Demonstrates a linear streaming scenario (initial=0, max>0, rate>0).
    //  */
    // function test_linearStreamingHappyPath() public {
    //     // initial=0 => purely linear, max=5, rate=1, start=now
    //     bytes memory terms_ = encodeTerms(address(basicERC20), 0, 5 ether, 1 ether, block.timestamp);

    //     // Warp forward 3 seconds => 3 unlocked, but clamp at max=5
    //     vm.warp(block.timestamp + 3);

    //     // Transfer 2 => should succeed
    //     bytes memory callData_ = _encodeERC20Transfer(bob, 2 ether);
    //     bytes memory execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
    //     erc20PeriodicClaimEnforcer.beforeHook(terms_, bytes(""), mode, execData_, bytes32(0), address(0), alice);

    //     // 3 were available, 2 spent => 1 remains
    //     uint256 available_ = erc20PeriodicClaimEnforcer.getAvailableAmount(bytes32(0), address(this));
    //     assertEq(available_, 1 ether, "1 ether left after spending 2 of 3");

    //     // Warp forward 10 seconds => total unlocked=13, but clamp by max=5 => totalUnlocked=5
    //     // Spent=2 => 3 remain
    //     vm.warp(block.timestamp + 10);
    //     available_ = erc20PeriodicClaimEnforcer.getAvailableAmount(bytes32(0), address(this));
    //     assertEq(available_, 3 ether, "Clamped at 5 total unlocked, 2 spent => 3 remain");

    //     // Transfer 3 => should succeed
    //     callData_ = _encodeERC20Transfer(bob, 3 ether);
    //     execData_ = _encodeSingleExecution(address(basicERC20), 0, callData_);
    //     erc20PeriodicClaimEnforcer.beforeHook(terms_, bytes(""), mode, execData_, bytes32(0), address(0), alice);

    //     // No available amount
    //     available_ = erc20PeriodicClaimEnforcer.getAvailableAmount(bytes32(0), address(this));
    //     assertEq(available_, 0, "Available amount should be 0");
    // }

    // /**
    //  * @notice Demonstrates chunk streaming scenario (initial>0) with partial spending
    //  *         and hitting maxAmount clamp.
    //  */
    // function test_chunkStreamingHitsMaxAmount() public {
    //     // initial=10, max=25, rate=5 => chunkDuration=10/5=2 seconds
    //     // 1st chunk=10 at start, 2nd chunk after 2 sec, 3rd chunk after 4 sec, etc.
    //     bytes memory terms = encodeTerms(address(basicERC20), 10 ether, 25 ether, 5 ether, block.timestamp);

    //     // Transfer 10 right away => chunk #1
    //     bytes memory callData1_ = _encodeERC20Transfer(bob, 10 ether);
    //     bytes memory execData1_ = _encodeSingleExecution(address(basicERC20), 0, callData1_);
    //     erc20PeriodicClaimEnforcer.beforeHook(terms, bytes(""), mode, execData1_, bytes32(0), address(0), alice);

    //     // spent=10 => 0 remain from first chunk
    //     // Warp 2 sec => chunk #2 => totalUnlocked=20 => spent=10 => 10 remain
    //     vm.warp(block.timestamp + 2);
    //     uint256 availNow_ = erc20PeriodicClaimEnforcer.getAvailableAmount(bytes32(0), address(this));
    //     assertEq(availNow_, 10 ether, "Second chunk unlocked => total=20, spent=10 => 10 remain");

    //     // Transfer 10 => spent=20 => 0 remain
    //     bytes memory callData2_ = _encodeERC20Transfer(bob, 10 ether);
    //     bytes memory execData2_ = _encodeSingleExecution(address(basicERC20), 0, callData2_);
    //     erc20PeriodicClaimEnforcer.beforeHook(terms, bytes(""), mode, execData2_, bytes32(0), address(0), alice);

    //     // Warp 2 more sec => chunk #3 => totalUnlocked=30 => clamp to max=25 => spent=20 => 5 remain
    //     vm.warp(block.timestamp + 2);
    //     uint256 availClamped_ = erc20PeriodicClaimEnforcer.getAvailableAmount(bytes32(0), address(this));
    //     assertEq(availClamped_, 5 ether, "Clamped at max=25, spent=20 => 5 left");
    // }

    ////////////////////// Helper fucntions //////////////////////

    // /**
    //  * @notice Builds a 148-byte `_terms` data for the new streaming logic:
    //  *   [0..20]   = basicERC20 address
    //  *   [20..52]  = initial amount
    //  *   [52..84]  = max amount
    //  *   [84..116] = amount per second
    //  *   [116..148]= start time
    //  */
    // function encodeTerms(
    //     address basicERC20,
    //     uint256 initialAmount,
    //     uint256 maxAmount,
    //     uint256 amountPerSecond,
    //     uint256 startTime
    // )
    //     internal
    //     pure
    //     returns (bytes memory)
    // {
    //     return abi.encodePacked(
    //         bytes20(basicERC20), bytes32(initialAmount), bytes32(maxAmount), bytes32(amountPerSecond), bytes32(startTime)
    //     );
    // }

    /**
     * @dev Construct the callData_ for `IERC20.transfer(address,uint256)`.
     * @param to Recipient of the transfer
     * @param amount Amount to transfer
     */
    function _encodeERC20Transfer(address to, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC20.transfer.selector, to, amount);
    }

    /**
     * @dev Construct the callData_ for `IERC20.transfer(address,uint256)`.
     * @param amount Amount to transfer
     */
    function _encodeERC20Transfer(uint256 amount) internal view returns (bytes memory) {
        return abi.encodeWithSelector(IERC20.transfer.selector, redeemer, amount);
    }

    function _encodeSingleExecution(address target, uint256 value, bytes memory callData_) internal pure returns (bytes memory) {
        return abi.encodePacked(target, value, callData_);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(erc20PeriodicClaimEnforcer));
    }
}
