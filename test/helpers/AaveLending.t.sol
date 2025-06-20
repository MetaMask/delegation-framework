// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { BaseTest } from "../utils/BaseTest.t.sol";
import { Implementation, SignatureType } from "../utils/Types.t.sol";
import { Execution, Delegation, Caveat, ModeCode } from "../../src/utils/Types.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";
import { AllowedCalldataEnforcer } from "../../src/enforcers/AllowedCalldataEnforcer.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";
import { IPool } from "./interfaces/IAavePool.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// @dev Do not remove this comment below
/// forge-config: default.evm_version = "shanghai"

/**
 * @title AaveLending Test
 * @notice Tests delegation-based lending on Aave v3.
 * @dev Uses a forked Ethereum mainnet environment to test real contract interactions
 */
contract AaveLendingTest is BaseTest {
    using ModeLib for ModeCode;

    IPool public constant AAVE_POOL = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address public constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;

    // Enforcers for delegation restrictions
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    AllowedCalldataEnforcer public allowedCalldataEnforcer;
    ValueLteEnforcer public valueLteEnforcer;

    uint256 public constant MAINNET_FORK_BLOCK = 22734910; // Use latest available block
    uint256 public constant INITIAL_USDC_BALANCE = 10000000000; // 10k USDC
    uint256 public constant DEPOSIT_AMOUNT = 1000000000; // 1k USDC

    ////////////////////// Setup //////////////////////

    function setUp() public override {
        // Create fork from mainnet at specific block
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);

        // Set implementation type
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;

        // Call parent setup to initialize delegation framework
        super.setUp();

        // Deploy enforcers
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        allowedCalldataEnforcer = new AllowedCalldataEnforcer();
        valueLteEnforcer = new ValueLteEnforcer();

        vm.label(address(allowedTargetsEnforcer), "AllowedTargetsEnforcer");
        vm.label(address(allowedMethodsEnforcer), "AllowedMethodsEnforcer");
        vm.label(address(allowedCalldataEnforcer), "AllowedCalldataEnforcer");
        vm.label(address(valueLteEnforcer), "ValueLteEnforcer");
        vm.label(address(AAVE_POOL), "Aave lending");
        vm.label(address(USDC), "USDC");
        vm.label(USDC_WHALE, "USDC Whale");

        vm.deal(address(users.alice.deleGator), 1 ether);

        vm.prank(USDC_WHALE);
        USDC.transfer(address(users.alice.deleGator), INITIAL_USDC_BALANCE); // 10k USDC
    }

    function test_aliceDirectDeposit() public {
        uint256 aliceUSDCInitialBalance = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCInitialBalance, INITIAL_USDC_BALANCE);

        vm.prank(address(users.alice.deleGator));
        USDC.approve(address(AAVE_POOL), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        AAVE_POOL.supply(address(USDC), DEPOSIT_AMOUNT, address(users.alice.deleGator), 0);

        uint256 aliceUSDCBalance = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance, INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT);

        IERC20 aUSDC = IERC20(AAVE_POOL.getReserveAToken(address(USDC)));
        uint256 aliceATokenBalance = aUSDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceATokenBalance, DEPOSIT_AMOUNT);
    }

    function test_aliceDirectWithdraw() public {
        vm.prank(address(users.alice.deleGator));
        USDC.approve(address(AAVE_POOL), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        AAVE_POOL.supply(address(USDC), DEPOSIT_AMOUNT, address(users.alice.deleGator), 0);

        vm.prank(address(users.alice.deleGator));
        AAVE_POOL.withdraw(address(USDC), type(uint256).max, address(users.alice.deleGator));

        uint256 aliceUSDCBalance = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance, INITIAL_USDC_BALANCE);
    }

    function test_aliceDelegatedDeposit() public {
        // Check initial balance
        uint256 aliceUSDCInitialBalance = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCInitialBalance, INITIAL_USDC_BALANCE);

        // Create delegation caveats for approving USDC
        Caveat[] memory approveCaveats_ = new Caveat[](4);

        // Recommended: Restrict to specific contract
        approveCaveats_[0] =
            Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(USDC)) });

        // Recommended: Restrict to deposit function only
        approveCaveats_[1] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(IERC20.approve.selector) });

        // Recommended: Restrict approve amount
        uint256 paramStart_ = abi.encodeWithSelector(IERC20.approve.selector, address(0)).length;
        approveCaveats_[2] = Caveat({
            args: hex"",
            enforcer: address(allowedCalldataEnforcer),
            terms: abi.encodePacked(paramStart_, DEPOSIT_AMOUNT)
        });

        // Recommended: Set value limit to 0
        approveCaveats_[3] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encode(0) });

        // Create delegation for approving USDC
        Delegation memory approveDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: approveCaveats_,
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        approveDelegation = signDelegation(users.alice, approveDelegation);

        // Create proper execution for approving USDC
        Execution memory approveExecution = Execution({
            target: address(USDC),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.approve.selector, address(AAVE_POOL), DEPOSIT_AMOUNT)
        });

        // Execute approve delegation
        Delegation[] memory approveDelegations_ = new Delegation[](1);
        approveDelegations_[0] = approveDelegation;

        invokeDelegation_UserOp(users.bob, approveDelegations_, approveExecution);

        // Create delegation caveats for lending
        Caveat[] memory lendingCaveats_ = new Caveat[](4);

        // Recommended: Restrict to specific contract
        lendingCaveats_[0] =
            Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(AAVE_POOL)) });

        // Recommended: Restrict to deposit function only
        lendingCaveats_[1] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(IPool.supply.selector) });

        // Recommended: Restrict supply argument "onBehalfOf" to alice
        paramStart_ = abi.encodeWithSelector(IPool.supply.selector, address(0), uint256(0)).length;
        lendingCaveats_[2] = Caveat({
            args: hex"",
            enforcer: address(allowedCalldataEnforcer),
            terms: abi.encode(paramStart_, address(users.alice.deleGator))
        });

        // Recommended: Set value limit to 0
        lendingCaveats_[3] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encode(0) });

        // Create delegation for lending
        Delegation memory lendingDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: lendingCaveats_,
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        lendingDelegation = signDelegation(users.alice, lendingDelegation);

        // Create execution for lending
        Execution memory lendingExecution_ = Execution({
            target: address(AAVE_POOL),
            value: 0,
            callData: abi.encodeWithSelector(IPool.supply.selector, address(USDC), DEPOSIT_AMOUNT, address(users.alice.deleGator), 0)
        });

        // Execute delegation
        Delegation[] memory lendingDelegations_ = new Delegation[](1);
        lendingDelegations_[0] = lendingDelegation;

        invokeDelegation_UserOp(users.bob, lendingDelegations_, lendingExecution_);

        // Check state after delegation
        uint256 aliceUSDCBalance = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance, INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT);

        IERC20 aUSDC = IERC20(AAVE_POOL.getReserveAToken(address(USDC)));
        uint256 aliceATokenBalance = aUSDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceATokenBalance, DEPOSIT_AMOUNT);
    }

    function test_aliceDelegatedWithdraw() public {
        // Set initial state of alice having deposited 1k USDC
        vm.prank(address(users.alice.deleGator));
        USDC.approve(address(AAVE_POOL), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        AAVE_POOL.supply(address(USDC), DEPOSIT_AMOUNT, address(users.alice.deleGator), 0);

        // Record initial state
        uint256 aliceInitialUSDCBalance = USDC.balanceOf(address(users.alice.deleGator));
        IERC20 aUSDC = IERC20(AAVE_POOL.getReserveAToken(address(USDC)));
        uint256 aliceInitialATokenBalance = aUSDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceInitialUSDCBalance, INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT);
        assertEq(aliceInitialATokenBalance, DEPOSIT_AMOUNT);

        // Create delegation caveats for lending witdrawal
        Caveat[] memory lendingWithdrawalCaveats_ = new Caveat[](4);

        // Recommended: Restrict to specific contract
        lendingWithdrawalCaveats_[0] =
            Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(AAVE_POOL)) });

        // Recommended: Restrict to deposit function only
        lendingWithdrawalCaveats_[1] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(IPool.withdraw.selector) });

        // Recommended: Restrict withdraw argument "to" to alice
        uint256 paramStart_ = abi.encodeWithSelector(IPool.withdraw.selector, address(0), uint256(0)).length;
        lendingWithdrawalCaveats_[2] = Caveat({
            args: hex"",
            enforcer: address(allowedCalldataEnforcer),
            terms: abi.encode(paramStart_, address(users.alice.deleGator))
        });

        // Recommended: Set value limit to 0
        lendingWithdrawalCaveats_[3] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encode(0) });

        // Create delegation for lending
        Delegation memory lendingWithdrawalDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: lendingWithdrawalCaveats_,
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        lendingWithdrawalDelegation = signDelegation(users.alice, lendingWithdrawalDelegation);

        // Create execution for lending
        Execution memory lendingWithdrawalExecution_ = Execution({
            target: address(AAVE_POOL),
            value: 0,
            callData: abi.encodeWithSelector(IPool.withdraw.selector, address(USDC), type(uint256).max, address(users.alice.deleGator))
        });

        // Execute delegation
        Delegation[] memory lendingWithdrawalDelegations_ = new Delegation[](1);
        lendingWithdrawalDelegations_[0] = lendingWithdrawalDelegation;

        invokeDelegation_UserOp(users.bob, lendingWithdrawalDelegations_, lendingWithdrawalExecution_);

        // Check state after delegation
        uint256 aliceUSDCBalance = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance, INITIAL_USDC_BALANCE);
    }
}
