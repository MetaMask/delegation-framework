// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import "../../src/utils/Types.sol";
import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { ERC20BalanceChangeEnforcer } from "../../src/enforcers/ERC20BalanceChangeEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { ExactCalldataEnforcer } from "../../src/enforcers/ExactCalldataEnforcer.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";

contract BalancePaymentTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC20TransferAmountEnforcer public transferAmountEnforcer;
    ERC20BalanceChangeEnforcer public balanceChangeEnforcer;
    ExactCalldataEnforcer public exactCalldataEnforcer;
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    ValueLteEnforcer public valueLteEnforcer;
    BasicERC20 public tokenA;
    BasicERC20 public tokenB;
    SwapMock public swapMock;
    address someUser;
    address delegator;
    address delegate;
    address dm;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();

        // Deploy SwapMock and set it as the delegate
        swapMock = new SwapMock(delegationManager);
        dm = address(delegationManager);
        delegator = address(users.alice.deleGator);
        delegate = address(swapMock);
        vm.label(delegate, "Swap Mock");
        someUser = makeAddr("someUser");
        vm.label(someUser, "Some User");

        // Deploy test tokens
        tokenA = new BasicERC20(delegator, "TokenA", "TKA", 1 ether);
        tokenB = new BasicERC20(delegate, "TokenB", "TKB", 2 ether);
        vm.label(address(tokenA), "Token A");
        vm.label(address(tokenB), "Token B");
        swapMock.setTokens(address(tokenA), address(tokenB));

        // Deploy enforcers
        transferAmountEnforcer = new ERC20TransferAmountEnforcer();
        balanceChangeEnforcer = new ERC20BalanceChangeEnforcer();
        exactCalldataEnforcer = new ExactCalldataEnforcer();
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        valueLteEnforcer = new ValueLteEnforcer();
        vm.label(address(transferAmountEnforcer), "ERC20 Transfer Amount Enforcer");
        vm.label(address(balanceChangeEnforcer), "ERC20 Balance Change Enforcer");
        vm.label(address(exactCalldataEnforcer), "Exact Calldata Enforcer");
        vm.label(address(allowedTargetsEnforcer), "Allowed Targets Enforcer");
        vm.label(address(valueLteEnforcer), "Value Lte Enforcer");
    }

    ////////////////////// Test Cases //////////////////////

    /// @notice Tests that the balance change enforcer reverts when the required payment in TokenB is not received
    /// after sending TokenA. This simulates a failed swap where TokenB is not sent back to the delegator.
    function test_failWhenPaymentNotReceived() public {
        // Create delegation from Alice to SwapMock allowing transfer of 1 ETH worth of TokenA
        bytes memory transferTerms_ = abi.encodePacked(address(tokenA), uint256(1 ether));
        bytes memory balanceTerms_ = abi.encodePacked(false, address(tokenB), address(delegator), uint256(2 ether));

        Caveat[] memory caveats_ = new Caveat[](2);
        // Allows to transfer 1 ETH worth of TokenA
        caveats_[0] = Caveat({ args: hex"", enforcer: address(transferAmountEnforcer), terms: transferTerms_ });
        // Requires the balance of the recipient to increase by 2 ETH worth of TokenB
        caveats_[1] = Caveat({ args: hex"", enforcer: address(balanceChangeEnforcer), terms: balanceTerms_ });

        Delegation memory delegation = Delegation({
            delegate: delegate,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation = signDelegation(users.alice, delegation);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation;

        vm.expectRevert("ERC20BalanceChangeEnforcer:insufficient-balance-increase");
        swapMock.swap(delegations_, 1 ether);
    }

    /// @notice Tests nested delegations for a token swap with strict parameter validation
    ///
    /// Flow:
    /// 1. Inner delegation: Alice -> SwapMock
    ///    - Allows SwapMock to transfer TokenA from Alice
    ///
    /// 2. Outer delegation: Alice -> SomeUser
    ///    - Enforces exact swap parameters:
    ///      - Exact calldata for swap function
    ///      - Only allows calling SwapMock contract
    ///      - No ETH value allowed
    ///      - Requires receiving TokenB back
    ///
    /// Note: This test demonstrates parameter validation but does not test
    /// access control (e.g. if swap function requires specific callers)
    /// NOTES:
    /// This approach works but it assumes that the function swap can be called by anyone.
    /// The delegation should be needed in a context where the caller is restricted and this wouldn't work.
    function test_nestedDelegationsWithExactParameters() public {
        // Create first delegation from Alice to SwapMock allowing transfer of 1 ETH worth of TokenA
        bytes memory transferTerms_ = abi.encodePacked(address(tokenA), uint256(1 ether));

        Caveat[] memory innerCaveats_ = new Caveat[](1);
        // Allows to transfer 1 ETH worth of TokenA
        innerCaveats_[0] = Caveat({ args: hex"", enforcer: address(transferAmountEnforcer), terms: transferTerms_ });

        Delegation memory innerDelegation_ = Delegation({
            delegate: delegate,
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: innerCaveats_,
            salt: 0,
            signature: hex""
        });

        innerDelegation_ = signDelegation(users.alice, innerDelegation_);

        Delegation[] memory innerDelegations_ = new Delegation[](1);
        innerDelegations_[0] = innerDelegation_;

        // Create second delegation with exact calldata for swap function
        bytes memory balanceTerms_ = abi.encodePacked(false, address(tokenB), address(delegator), uint256(2 ether));
        Caveat[] memory outerCaveats_ = new Caveat[](4);
        outerCaveats_[0] = Caveat({
            args: hex"",
            enforcer: address(exactCalldataEnforcer),
            terms: abi.encodeWithSelector(SwapMock.swap.selector, innerDelegations_, 1 ether)
        });
        outerCaveats_[1] =
            Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(swapMock)) });
        outerCaveats_[2] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encodePacked(uint256(0)) });
        outerCaveats_[3] = Caveat({ args: hex"", enforcer: address(balanceChangeEnforcer), terms: balanceTerms_ });

        Delegation memory outerDelegation_ = Delegation({
            delegate: address(someUser),
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: outerCaveats_,
            salt: 1,
            signature: hex""
        });

        outerDelegation_ = signDelegation(users.alice, outerDelegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = outerDelegation_;

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeSingle(
            address(swapMock), 0, abi.encodeWithSelector(SwapMock.swap.selector, innerDelegations_, 1 ether)
        );

        assertEq(tokenA.balanceOf(address(delegator)), 1 ether, "TokenA balance of delegator should be 1 ether");
        assertEq(tokenB.balanceOf(address(delegator)), 0 ether, "TokenB balance of delegator should be 0 ether");
        assertEq(tokenA.balanceOf(address(swapMock)), 0 ether, "TokenA balance of swapMock should be 0 ether");
        assertEq(tokenB.balanceOf(address(swapMock)), 2 ether, "TokenB balance of swapMock should be 2 ether");

        vm.prank(someUser);
        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        assertEq(tokenA.balanceOf(address(delegator)), 0, "TokenA balance of delegator should be 0");
        assertEq(tokenB.balanceOf(address(delegator)), 2 ether, "TokenB balance of delegator should be 2 ether");
        assertEq(tokenA.balanceOf(address(swapMock)), 1 ether, "TokenA balance of swapMock should be 1 ether");
        assertEq(tokenB.balanceOf(address(swapMock)), 0, "TokenB balance of swapMock should be 0");
    }

    // Override helper from BaseTest
    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(transferAmountEnforcer));
    }
}

contract SwapMock {
    IDelegationManager public delegationManager;
    IERC20 public tokenIn;
    IERC20 public tokenOut;

    constructor(IDelegationManager _delegationManager) {
        delegationManager = _delegationManager;
    }

    function setTokens(address _tokenIn, address _tokenOut) public {
        tokenIn = IERC20(_tokenIn);
        tokenOut = IERC20(_tokenOut);
    }

    // This contract swaps X amount of tokensIn for double amount of tokensOut
    function swap(Delegation[] memory _delegations, uint256 _amountIn) public {
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] =
            ExecutionLib.encodeSingle(address(tokenIn), 0, abi.encodeCall(IERC20.transfer, (address(this), _amountIn)));

        // This will revert because even when the exection is succesful and the tokens get transferred to the SwapMock,
        // this contract doesn't have a change to pay Alice with the tokensOut.
        // Immediately after the execution the balance of Alice should increase and that can't happen here since it needs the
        // redemption to finish to then pay the tokensOut.
        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        // Some condition representing the need for the ERC20 tokensIn at this point
        uint256 balanceTokenIn_ = tokenIn.balanceOf(address(this));
        require(balanceTokenIn_ >= _amountIn, "SwapMock:insufficient-balance-in");

        // Transfer the double amount of tokensOut to the caller after receiving the tokensIn
        tokenOut.transfer(msg.sender, _amountIn * 2);
    }
}
