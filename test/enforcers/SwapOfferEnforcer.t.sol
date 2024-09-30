// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { SwapOfferEnforcer } from "../../src/enforcers/SwapOfferEnforcer.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Caveats } from "../../src/libraries/Caveats.sol";
import { ArgsEqualityCheckEnforcer } from "../../src/enforcers/ArgsEqualityCheckEnforcer.sol";

contract SwapOfferEnforcerTest is CaveatEnforcerBaseTest {
    using ModeLib for ModeCode;

    SwapOfferEnforcer public swapOfferEnforcer;
    ERC20TransferAmountEnforcer public erc20TransferAmountEnforcer;
    ArgsEqualityCheckEnforcer public argsEqualityCheckEnforcer;
    BasicERC20 public tokenIn;
    BasicERC20 public tokenOut;
    ModeCode public mode = ModeLib.encodeSimpleSingle();

    uint256 constant AMOUNT_IN = 1000 ether;
    uint256 constant AMOUNT_OUT = 500 ether;

    function setUp() public override {
        super.setUp();
        swapOfferEnforcer = new SwapOfferEnforcer();
        erc20TransferAmountEnforcer = new ERC20TransferAmountEnforcer();
        argsEqualityCheckEnforcer = new ArgsEqualityCheckEnforcer();
        tokenIn = new BasicERC20(address(users.alice.deleGator), "Token In", "TIN", AMOUNT_IN);
        tokenOut = new BasicERC20(address(users.bob.deleGator), "Token Out", "TOUT", AMOUNT_OUT);

        vm.label(address(swapOfferEnforcer), "Swap Offer Enforcer");
        vm.label(address(erc20TransferAmountEnforcer), "ERC20 Transfer Amount Enforcer");
        vm.label(address(argsEqualityCheckEnforcer), "Args Equality Check Enforcer");
        vm.label(address(tokenIn), "Token In");
        vm.label(address(tokenOut), "Token Out");
    }

    function test_swapOfferEnforcer() public {
        uint256 initialAliceBalanceIn = tokenIn.balanceOf(address(users.alice.deleGator));
        uint256 initialBobBalanceOut = tokenOut.balanceOf(address(users.bob.deleGator));

        // Create swap offer caveat
        Caveat memory swapOfferCaveat = Caveats.createSwapOfferCaveat(
            address(swapOfferEnforcer),
            address(tokenIn),
            address(tokenOut),
            AMOUNT_IN,
            AMOUNT_OUT,
            address(users.alice.deleGator)
        );

        // Create ERC20 transfer amount caveat for payment
        Caveat memory erc20TransferCaveat = Caveats.createERC20TransferAmountCaveat(
            address(erc20TransferAmountEnforcer),
            address(tokenIn),
            AMOUNT_IN
        );

        Caveat[] memory caveats = new Caveat[](2);
        caveats[0] = swapOfferCaveat;
        caveats[1] = erc20TransferCaveat;

        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        delegation = signDelegation(users.alice, delegation);

        // Create the execution for token transfer
        Execution memory execution = Execution({
            target: address(tokenOut),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.alice.deleGator), AMOUNT_OUT)
        });

        // Create the allowance delegation for payment
        Caveat[] memory allowanceCaveats = new Caveat[](1);
        allowanceCaveats[0] = Caveat({
            enforcer: address(argsEqualityCheckEnforcer),
            terms: hex"",
            args: abi.encodePacked(keccak256(abi.encode(delegation)), address(users.bob.deleGator))
        });

        Delegation memory allowanceDelegation = Delegation({
            delegate: address(delegationManager),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: allowanceCaveats,
            salt: 0,
            signature: hex""
        });

        allowanceDelegation = signDelegation(users.bob, allowanceDelegation);

        // Prepare the arguments for the swap
        bytes memory args = abi.encode(AMOUNT_IN, delegationManager, abi.encode(new Delegation[](1)));

        // Execute Bob's UserOp
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        vm.prank(address(users.bob.deleGator));
        invokeDelegation_UserOp(users.bob, delegations, execution, args);

        // Check balances after swap
        uint256 finalAliceBalanceIn = tokenIn.balanceOf(address(users.alice.deleGator));
        uint256 finalBobBalanceOut = tokenOut.balanceOf(address(users.bob.deleGator));

        assertEq(finalAliceBalanceIn, initialAliceBalanceIn + AMOUNT_IN, "Alice should receive the correct amount of tokenIn");
        assertEq(finalBobBalanceOut, initialBobBalanceOut - AMOUNT_OUT, "Bob should send the correct amount of tokenOut");
    }

    function test_swapOfferEnforcer_partialFill() public {
        uint256 partialAmountIn = AMOUNT_IN / 2;
        uint256 partialAmountOut = AMOUNT_OUT / 2;

        // Create swap offer caveat
        Caveat memory swapOfferCaveat = Caveats.createSwapOfferCaveat(
            address(swapOfferEnforcer),
            address(tokenIn),
            address(tokenOut),
            AMOUNT_IN,
            AMOUNT_OUT,
            address(users.alice.deleGator)
        );

        // Create ERC20 transfer amount caveat for payment
        Caveat memory erc20TransferCaveat = Caveats.createERC20TransferAmountCaveat(
            address(erc20TransferAmountEnforcer),
            address(tokenIn),
            AMOUNT_IN
        );

        Caveat[] memory caveats = new Caveat[](2);
        caveats[0] = swapOfferCaveat;
        caveats[1] = erc20TransferCaveat;

        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        delegation = signDelegation(users.alice, delegation);

        // Create the execution for token transfer (partial amount)
        Execution memory execution = Execution({
            target: address(tokenOut),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.alice.deleGator), partialAmountOut)
        });

        // Create the allowance delegation for payment
        Caveat[] memory allowanceCaveats = new Caveat[](1);
        allowanceCaveats[0] = Caveat({
            enforcer: address(argsEqualityCheckEnforcer),
            terms: hex"",
            args: abi.encodePacked(keccak256(abi.encode(delegation)), address(users.bob.deleGator))
        });

        Delegation memory allowanceDelegation = Delegation({
            delegate: address(delegationManager),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: allowanceCaveats,
            salt: 0,
            signature: hex""
        });

        allowanceDelegation = signDelegation(users.bob, allowanceDelegation);

        // Prepare the arguments for the swap (partial amount)
        bytes memory args = abi.encode(partialAmountIn, delegationManager, abi.encode(new Delegation[](1)));

        // Execute Bob's UserOp
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        vm.prank(address(users.bob.deleGator));
        invokeDelegation_UserOp(users.bob, delegations, execution, args);

        // Check balances after partial swap
        uint256 aliceBalanceIn = tokenIn.balanceOf(address(users.alice.deleGator));
        uint256 bobBalanceOut = tokenOut.balanceOf(address(users.bob.deleGator));

        assertEq(aliceBalanceIn, AMOUNT_IN + partialAmountIn, "Alice should receive the correct partial amount of tokenIn");
        assertEq(bobBalanceOut, AMOUNT_OUT - partialAmountOut, "Bob should send the correct partial amount of tokenOut");

        // Execute the remaining part of the swap
        vm.prank(address(users.bob.deleGator));
        invokeDelegation_UserOp(users.bob, delegations, execution, args);

        // Check final balances
        aliceBalanceIn = tokenIn.balanceOf(address(users.alice.deleGator));
        bobBalanceOut = tokenOut.balanceOf(address(users.bob.deleGator));

        assertEq(aliceBalanceIn, AMOUNT_IN * 2, "Alice should receive the full amount of tokenIn");
        assertEq(bobBalanceOut, 0, "Bob should send the full amount of tokenOut");
    }

    function test_swapOfferEnforcer_invalidAmount() public {
        // Create swap offer caveat
        Caveat memory swapOfferCaveat = Caveats.createSwapOfferCaveat(
            address(swapOfferEnforcer),
            address(tokenIn),
            address(tokenOut),
            AMOUNT_IN,
            AMOUNT_OUT,
            address(users.alice.deleGator)
        );

        // Create ERC20 transfer amount caveat for payment
        Caveat memory erc20TransferCaveat = Caveats.createERC20TransferAmountCaveat(
            address(erc20TransferAmountEnforcer),
            address(tokenIn),
            AMOUNT_IN
        );

        Caveat[] memory caveats = new Caveat[](2);
        caveats[0] = swapOfferCaveat;
        caveats[1] = erc20TransferCaveat;

        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        delegation = signDelegation(users.alice, delegation);

        // Create the execution for token transfer with invalid amount
        Execution memory execution = Execution({
            target: address(tokenOut),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.alice.deleGator), AMOUNT_OUT + 1 ether)
        });

        // Create the allowance delegation for payment
        Caveat[] memory allowanceCaveats = new Caveat[](1);
        allowanceCaveats[0] = Caveat({
            enforcer: address(argsEqualityCheckEnforcer),
            terms: hex"",
            args: abi.encodePacked(keccak256(abi.encode(delegation)), address(users.bob.deleGator))
        });

        Delegation memory allowanceDelegation = Delegation({
            delegate: address(delegationManager),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: allowanceCaveats,
            salt: 0,
            signature: hex""
        });

        allowanceDelegation = signDelegation(users.bob, allowanceDelegation);

        // Prepare the arguments for the swap
        bytes memory args = abi.encode(AMOUNT_IN, delegationManager, abi.encode(new Delegation[](1)));

        // Execute Bob's UserOp
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert("SwapOfferEnforcer:exceeds-output-amount");
        invokeDelegation_UserOp(users.bob, delegations, execution, args);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(swapOfferEnforcer));
    }
}
