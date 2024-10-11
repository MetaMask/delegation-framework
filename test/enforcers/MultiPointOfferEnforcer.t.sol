// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { MultiPointOfferEnforcer } from "../../src/enforcers/MultiPointOfferEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Caveats } from "../../src/libraries/Caveats.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";

contract MultiPointOfferEnforcerTest is CaveatEnforcerBaseTest {
    using ModeLib for ModeCode;

    MultiPointOfferEnforcer public multiPointOfferEnforcer;
    ERC20TransferAmountEnforcer public erc20TransferAmountEnforcer;
    ModeCode public modeSimpleSingle = ModeLib.encodeSimpleSingle();
    address public constant TOKEN_IN = address(0x1);
    address public constant TOKEN_OUT = address(0x2);
    address public RECIPIENT = address(users.alice.deleGator);

    function setUp() public override {
        super.setUp();
        multiPointOfferEnforcer = new MultiPointOfferEnforcer();
        vm.label(address(multiPointOfferEnforcer), "Multi Point Offer Enforcer");
        erc20TransferAmountEnforcer = new ERC20TransferAmountEnforcer();
        vm.label(address(erc20TransferAmountEnforcer), "ERC20 Transfer Amount Enforcer");
    }

    function test_validMultiPointOffer() public {
        MultiPointOfferEnforcer.Amount[] memory amounts = new MultiPointOfferEnforcer.Amount[](2);
        amounts[0] = MultiPointOfferEnforcer.Amount({
            tokenInPerTokenOut: 2 ether,
            time: block.timestamp
        });
        amounts[1] = MultiPointOfferEnforcer.Amount({
            tokenInPerTokenOut: 3 ether,
            time: block.timestamp + 1 hours
        });

        Caveat memory multiPointOfferCaveat = Caveats.createMultiPointOfferCaveat(
            address(multiPointOfferEnforcer),
            TOKEN_IN,
            TOKEN_OUT,
            amounts,
            RECIPIENT
        );

        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        delegation.caveats[0] = multiPointOfferCaveat;
        delegation = signDelegation(users.alice, delegation);

        // Create a delegation from Bob to allow the MultiPointOfferEnforcer to transfer tokenIn
        Caveat memory erc20TransferCaveat = Caveats.createERC20TransferAmountCaveat(
            address(erc20TransferAmountEnforcer),
            address(TOKEN_IN),
            10 ether  // The amount Bob is willing to transfer
        );

        Delegation memory bobDelegation = Delegation({
            delegate: address(multiPointOfferEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        bobDelegation.caveats[0] = Caveats.createERC20TransferAmountCaveat(
            address(erc20TransferAmountEnforcer),
            address(TOKEN_IN),
            10 ether
        );
        bobDelegation = signDelegation(users.bob, bobDelegation);

        delegation.caveats[0].args = abi.encode(MultiPointOfferEnforcer.SwapOfferArgs({
            offeredAmount: 2 ether,
            delegationManager: IDelegationManager(address(delegationManager)),
            permissionContext: abi.encode(bobDelegation)
        }));

        bytes memory executionCallData = ExecutionLib.encodeSingle(
            TOKEN_OUT,
            0,
            abi.encodeWithSelector(IERC20.transfer.selector, RECIPIENT, 1 ether)
        );

        vm.prank(address(delegationManager));
        multiPointOfferEnforcer.beforeHook(
            multiPointOfferCaveat.terms,
            delegation.caveats[0].args,
            modeSimpleSingle,
            executionCallData,
            keccak256(abi.encode(delegation)),
            address(0),
            address(users.bob.deleGator)
        );
    }

    function test_invalidToken() public {
        MultiPointOfferEnforcer.Amount[] memory amounts = new MultiPointOfferEnforcer.Amount[](2);
        amounts[0] = MultiPointOfferEnforcer.Amount({
            tokenInPerTokenOut: 2 ether,
            time: block.timestamp
        });
        amounts[1] = MultiPointOfferEnforcer.Amount({
            tokenInPerTokenOut: 3 ether,
            time: block.timestamp + 1 hours
        });

        Caveat memory multiPointOfferCaveat = Caveats.createMultiPointOfferCaveat(
            address(multiPointOfferEnforcer),
            TOKEN_IN,
            TOKEN_OUT,
            amounts,
            RECIPIENT
        );

        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        delegation.caveats[0] = multiPointOfferCaveat;
        delegation = signDelegation(users.alice, delegation);

        Delegation memory bobDelegation = Delegation({
            delegate: address(multiPointOfferEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        bobDelegation.caveats[0] = Caveats.createERC20TransferAmountCaveat(
            address(erc20TransferAmountEnforcer),
            TOKEN_IN,
            10 ether
        );
        bobDelegation = signDelegation(users.bob, bobDelegation);

        delegation.caveats[0].args = abi.encode(MultiPointOfferEnforcer.SwapOfferArgs({
            offeredAmount: 2 ether,
            delegationManager: IDelegationManager(address(delegationManager)),
            permissionContext: abi.encode(bobDelegation)
        }));

        bytes memory executionCallData = ExecutionLib.encodeSingle(
            address(0x4), // Invalid token
            0,
            abi.encodeWithSelector(IERC20.transfer.selector, RECIPIENT, 1 ether)
        );

        vm.prank(address(delegationManager));
        vm.expectRevert("MultiPointOfferEnforcer:invalid-target");
        multiPointOfferEnforcer.beforeHook(
            multiPointOfferCaveat.terms,
            delegation.caveats[0].args,
            modeSimpleSingle,
            executionCallData,
            keccak256(abi.encode(delegation)),
            address(0),
            address(users.bob.deleGator)
        );
    }

    function test_invalidMethod() public {
        MultiPointOfferEnforcer.Amount[] memory amounts = new MultiPointOfferEnforcer.Amount[](2);
        amounts[0] = MultiPointOfferEnforcer.Amount({
            tokenInPerTokenOut: 2 ether,
            time: block.timestamp
        });
        amounts[1] = MultiPointOfferEnforcer.Amount({
            tokenInPerTokenOut: 3 ether,
            time: block.timestamp + 1 hours
        });

        Caveat memory multiPointOfferCaveat = Caveats.createMultiPointOfferCaveat(
            address(multiPointOfferEnforcer),
            TOKEN_IN,
            TOKEN_OUT,
            amounts,
            RECIPIENT
        );

        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        delegation.caveats[0] = multiPointOfferCaveat;
        delegation = signDelegation(users.alice, delegation);

        Delegation memory bobDelegation = Delegation({
            delegate: address(multiPointOfferEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        bobDelegation.caveats[0] = Caveats.createERC20TransferAmountCaveat(
            address(erc20TransferAmountEnforcer),
            TOKEN_IN,
            10 ether
        );
        bobDelegation = signDelegation(users.bob, bobDelegation);

        delegation.caveats[0].args = abi.encode(MultiPointOfferEnforcer.SwapOfferArgs({
            offeredAmount: 2 ether,
            delegationManager: IDelegationManager(address(delegationManager)),
            permissionContext: abi.encode(bobDelegation)
        }));

        bytes memory executionCallData = ExecutionLib.encodeSingle(
            TOKEN_OUT,
            0,
            abi.encodeWithSelector(IERC20.approve.selector, RECIPIENT, 1 ether) // Invalid method
        );

        vm.prank(address(delegationManager));
        vm.expectRevert("MultiPointOfferEnforcer:invalid-method");
        multiPointOfferEnforcer.beforeHook(
            multiPointOfferCaveat.terms,
            delegation.caveats[0].args,
            modeSimpleSingle,
            executionCallData,
            keccak256(abi.encode(delegation)),
            address(0),
            address(users.bob.deleGator)
        );
    }

    function test_integrationMultiPointOfferFulfillment() public {
        // Deploy two ERC20 tokens for the swap
        BasicERC20 tokenIn = new BasicERC20(address(this), "Token In", "TIN", 1000 ether);
        BasicERC20 tokenOut = new BasicERC20(address(this), "Token Out", "TOUT", 1000 ether);

        // Transfer tokens to Alice and Bob
        tokenOut.transfer(address(users.alice.deleGator), 100 ether);
        tokenIn.transfer(address(users.bob.deleGator), 10 ether);

        // Create the caveat for the multi-point offer
        MultiPointOfferEnforcer.Amount[] memory amounts = new MultiPointOfferEnforcer.Amount[](2);
        amounts[0] = MultiPointOfferEnforcer.Amount({
            tokenInPerTokenOut: 2 ether,
            time: block.timestamp
        });
        amounts[1] = MultiPointOfferEnforcer.Amount({
            tokenInPerTokenOut: 3 ether,
            time: block.timestamp + 1 hours
        });

        Caveat memory multiPointOfferCaveat = Caveats.createMultiPointOfferCaveat(
            address(multiPointOfferEnforcer),
            address(tokenIn),
            address(tokenOut),
            amounts,
            address(users.alice.deleGator)
        );

        // Create and sign the delegation from Alice to Bob
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        delegation.caveats[0] = multiPointOfferCaveat;
        delegation = signDelegation(users.alice, delegation);

        // Create a delegation from Bob to allow the MultiPointOfferEnforcer to transfer tokenIn
        Delegation memory bobDelegation = Delegation({
            delegate: address(multiPointOfferEnforcer),
            delegator: address(users.bob.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](1),
            salt: 0,
            signature: hex""
        });
        bobDelegation.caveats[0] = Caveats.createERC20TransferAmountCaveat(
            address(erc20TransferAmountEnforcer),
            address(tokenIn),
            10 ether
        );
        bobDelegation = signDelegation(users.bob, bobDelegation);

        // Prepare the execution for the swap
        Execution memory execution = Execution({
            target: address(tokenOut),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 5 ether)
        });

        // Prepare the args for the MultiPointOfferEnforcer
        delegation.caveats[0].args = abi.encode(MultiPointOfferEnforcer.SwapOfferArgs({
            offeredAmount: 10 ether,
            delegationManager: IDelegationManager(address(delegationManager)),
            permissionContext: abi.encode(bobDelegation)
        }));

        // Record initial balances
        uint256 aliceTokenInBalanceBefore = tokenIn.balanceOf(address(users.alice.deleGator));
        uint256 aliceTokenOutBalanceBefore = tokenOut.balanceOf(address(users.alice.deleGator));
        uint256 bobTokenInBalanceBefore = tokenIn.balanceOf(address(users.bob.deleGator));
        uint256 bobTokenOutBalanceBefore = tokenOut.balanceOf(address(users.bob.deleGator));

        // Execute the swap
        vm.prank(address(users.bob.deleGator));
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = delegation;
        invokeDelegation_UserOp(users.bob, delegations, execution);

        // Verify the swap results
        assertEq(tokenIn.balanceOf(address(users.alice.deleGator)), aliceTokenInBalanceBefore + 10 ether, "Alice's tokenIn balance incorrect");
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), aliceTokenOutBalanceBefore - 5 ether, "Alice's tokenOut balance incorrect");
        assertEq(tokenIn.balanceOf(address(users.bob.deleGator)), bobTokenInBalanceBefore - 10 ether, "Bob's tokenIn balance incorrect");
        assertEq(tokenOut.balanceOf(address(users.bob.deleGator)), bobTokenOutBalanceBefore + 5 ether, "Bob's tokenOut balance incorrect");
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(multiPointOfferEnforcer));
    }
}
