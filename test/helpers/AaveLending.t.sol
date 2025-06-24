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
import { LogicalOrWrapperEnforcer } from "../../src/enforcers/LogicalOrWrapperEnforcer.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { IPool } from "./interfaces/IAavePool.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";

// @dev Do not remove this comment below
/// forge-config: default.evm_version = "shanghai"

/**
 * @title AaveLending Test
 * @notice Tests delegation-based lending on Aave v3.
 * @dev Uses a forked Ethereum mainnet environment to test real contract interactions.
 * We are testing 2 different ways of using delegation framework to enable lending on Aave v3.
 * 1. Alice delegates token approval on USDC and supply on Aave. This can be done in 2 seperate delegations
 * or in a single delegation using LogicalOrWrapperEnforcer. This way the funds and approval are going
 * directly from alice to USDC/Aave. But if we want to do rebalancing this means that alice would need to over
 * approve tokens so that we can withdraw and deposit again.
 * 2. We use a custom contract "AaveAdapter" to which alice delegates with only transfer balance. AaveAdapter
 * is then the one that takes care of approving tokens to Aave and doing the lending. This way the adapter is the
 * one that over approves tokens. Making it safer. But this introduces a middleware contract.
 * Also there are 2 different ways of using the AaveAdapter:
 * - supplyByDelegation - this is a more restrictive way where alice needs to create a transfer delegation to the adapter,
 * then another delegation to the executor for him to call supplyByDelegation. This way alice can restrict who can call
 * the aaveAdapter.
 * - supplyByDelegationOpenEnded - this is less restrictive since anyone can call it as long as they have a valid transfer
 * delegation
 * to the adapter.
 *
 * In both cases only the creator of the transfer delegation can receive aTokens.
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
    LogicalOrWrapperEnforcer public logicalOrWrapperEnforcer;
    ERC20TransferAmountEnforcer public erc20TransferAmountEnforcer;
    AaveAdapter public aaveAdapter;

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
        erc20TransferAmountEnforcer = new ERC20TransferAmountEnforcer();

        logicalOrWrapperEnforcer = new LogicalOrWrapperEnforcer(delegationManager);
        aaveAdapter = new AaveAdapter(address(delegationManager), address(AAVE_POOL));

        vm.label(address(allowedTargetsEnforcer), "AllowedTargetsEnforcer");
        vm.label(address(allowedMethodsEnforcer), "AllowedMethodsEnforcer");
        vm.label(address(allowedCalldataEnforcer), "AllowedCalldataEnforcer");
        vm.label(address(valueLteEnforcer), "ValueLteEnforcer");
        vm.label(address(logicalOrWrapperEnforcer), "LogicalOrWrapperEnforcer");
        vm.label(address(erc20TransferAmountEnforcer), "ERC20TransferAmountEnforcer");
        vm.label(address(AAVE_POOL), "Aave lending");
        vm.label(address(USDC), "USDC");
        vm.label(USDC_WHALE, "USDC Whale");
        vm.label(address(aaveAdapter), "AaveAdapter");

        vm.deal(address(users.alice.deleGator), 1 ether);

        vm.prank(USDC_WHALE);
        USDC.transfer(address(users.alice.deleGator), INITIAL_USDC_BALANCE); // 10k USDC
    }

    // Testing directly depositing USDC to Aave to see if everything works on the forked mainnet
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

    // Testing directly withdrawing USDC from Aave to see if everything works on the forked mainnet
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

    // Testing delegating approval and supply functions in 2 separate delegations
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

    // Testing delegating withdrawal function in a single delegation
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

    // Testing delegating approval and supply functions in a single delegation using LogicalOrWrapperEnforcer
    function test_aliceDelegatedDepositWithLogicalOrWrapper() public {
        // Check initial balance
        uint256 aliceUSDCInitialBalance = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCInitialBalance, INITIAL_USDC_BALANCE);

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](2);

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

        groups_[0] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: approveCaveats_ });
        groups_[1] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: lendingCaveats_ });

        Caveat[] memory orCaveats_ = new Caveat[](1);
        orCaveats_[0] = Caveat({ args: hex"", enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        // Create delegation for lending
        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: orCaveats_,
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        delegation = signDelegation(users.alice, delegation);

        // Create proper execution for approving USDC
        Execution memory approveExecution_ = Execution({
            target: address(USDC),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.approve.selector, address(AAVE_POOL), DEPOSIT_AMOUNT)
        });

        // Create execution for lending
        Execution memory lendingExecution_ = Execution({
            target: address(AAVE_POOL),
            value: 0,
            callData: abi.encodeWithSelector(IPool.supply.selector, address(USDC), DEPOSIT_AMOUNT, address(users.alice.deleGator), 0)
        });

        // Execute delegation
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation;

        delegations_[0].caveats[0].args =
            abi.encode(LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: 0, caveatArgs: new bytes[](4) }));
        invokeDelegation_UserOp(users.bob, delegations_, approveExecution_);

        delegations_[0].caveats[0].args =
            abi.encode(LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: 1, caveatArgs: new bytes[](4) }));
        invokeDelegation_UserOp(users.bob, delegations_, lendingExecution_);

        // Check state after delegation
        uint256 aliceUSDCBalance = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance, INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT);

        IERC20 aUSDC = IERC20(AAVE_POOL.getReserveAToken(address(USDC)));
        uint256 aliceATokenBalance = aUSDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceATokenBalance, DEPOSIT_AMOUNT);
    }

    // Testing delegating transfer to adapter and then supply by delegation
    function test_aliceDelegatedDepositViaAdapter() public {
        // Check initial balance
        uint256 aliceUSDCInitialBalance = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCInitialBalance, INITIAL_USDC_BALANCE);

        // Create delegation for transferring USDC to adapter
        Caveat[] memory transferCaveats_ = new Caveat[](1);

        transferCaveats_[0] = Caveat({
            args: hex"",
            enforcer: address(erc20TransferAmountEnforcer),
            terms: abi.encodePacked(address(USDC), DEPOSIT_AMOUNT)
        });

        // Create delegation for transfer
        Delegation memory delegation = Delegation({
            delegate: address(aaveAdapter),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: transferCaveats_,
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        delegation = signDelegation(users.alice, delegation);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation;

        vm.prank(address(users.alice.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);

        // Check state after delegation
        uint256 aliceUSDCBalance = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance, INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT);

        IERC20 aUSDC = IERC20(AAVE_POOL.getReserveAToken(address(USDC)));
        uint256 aliceATokenBalance = aUSDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceATokenBalance, DEPOSIT_AMOUNT);
    }

    // Testing delegating transfer to adapter and then delegating supplyByDelegation
    function test_aliceDelegatedDepositViaAdapterDelegation() public {
        // Check initial balance
        uint256 aliceUSDCInitialBalance = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCInitialBalance, INITIAL_USDC_BALANCE);

        // Create delegation for transferring USDC to adapter
        Caveat[] memory transferCaveats_ = new Caveat[](1);

        transferCaveats_[0] = Caveat({
            args: hex"",
            enforcer: address(erc20TransferAmountEnforcer),
            terms: abi.encodePacked(address(USDC), DEPOSIT_AMOUNT)
        });

        // Create delegation for transfer
        Delegation memory delegation = Delegation({
            delegate: address(aaveAdapter),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: transferCaveats_,
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        delegation = signDelegation(users.alice, delegation);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation;

        // Create delegation caveats for lending
        Caveat[] memory supplyCaveats_ = new Caveat[](1);

        // Recommended: Restrict to specific contract
        supplyCaveats_[0] =
            Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(aaveAdapter)) });

        // Create delegation for supply
        Delegation memory supplyDelegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: supplyCaveats_,
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        supplyDelegation = signDelegation(users.alice, supplyDelegation);

        // Create execution for supply
        Execution memory supplyExecution_ = Execution({
            target: address(aaveAdapter),
            value: 0,
            callData: abi.encodeWithSelector(AaveAdapter.supplyByDelegation.selector, delegations_, address(USDC), DEPOSIT_AMOUNT)
        });

        // Execute delegation
        Delegation[] memory supplyDelegations_ = new Delegation[](1);
        supplyDelegations_[0] = supplyDelegation;

        invokeDelegation_UserOp(users.bob, supplyDelegations_, supplyExecution_);

        // Check state after delegation
        uint256 aliceUSDCBalance = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance, INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT);

        IERC20 aUSDC = IERC20(AAVE_POOL.getReserveAToken(address(USDC)));
        uint256 aliceATokenBalance = aUSDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceATokenBalance, DEPOSIT_AMOUNT);
    }

    // Testing delegating transfer to adapter and then calling (can be called by anyone) suppyByDelegationOpenEnded
    function test_aliceDelegatedDepositViaOpenEndedAdapterDelegation() public {
        // Check initial balance
        uint256 aliceUSDCInitialBalance = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCInitialBalance, INITIAL_USDC_BALANCE);

        // Create delegation for transferring USDC to adapter
        Caveat[] memory transferCaveats_ = new Caveat[](1);

        transferCaveats_[0] = Caveat({
            args: hex"",
            enforcer: address(erc20TransferAmountEnforcer),
            terms: abi.encodePacked(address(USDC), DEPOSIT_AMOUNT)
        });

        // Create delegation for transfer
        Delegation memory delegation = Delegation({
            delegate: address(aaveAdapter),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: transferCaveats_,
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        delegation = signDelegation(users.alice, delegation);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation;

        aaveAdapter.supplyByDelegationOpenEnded(delegations_, address(USDC), DEPOSIT_AMOUNT);

        // Check state after delegation
        uint256 aliceUSDCBalance = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance, INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT);

        IERC20 aUSDC = IERC20(AAVE_POOL.getReserveAToken(address(USDC)));
        uint256 aliceATokenBalance = aUSDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceATokenBalance, DEPOSIT_AMOUNT);
    }
}

// This is a POC for the AaveAdapter contract.
contract AaveAdapter {
    IDelegationManager public immutable delegationManager;
    IPool public immutable aavePool;

    constructor(address _delegationManager, address _aavePool) {
        delegationManager = IDelegationManager(_delegationManager);
        aavePool = IPool(_aavePool);
    }

    // This function redeems the delegation then approves and supplies the token to Aave.
    function supplyByDelegation(Delegation[] memory _delegations, address _token, uint256 _amount) external {
        require(_delegations.length == 1, "Wrong number of delegations");
        require(_delegations[0].delegator == msg.sender, "Not allowed");

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);

        bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), _amount));
        executionCallDatas_[0] = ExecutionLib.encodeSingle(address(_token), 0, encodedTransfer_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        IERC20(_token).approve(address(aavePool), _amount);
        aavePool.supply(_token, _amount, msg.sender, 0);
    }

    // This function redeems the delegation then approves and supplies the token to Aave.
    function supplyByDelegationOpenEnded(Delegation[] memory _delegations, address _token, uint256 _amount) external {
        require(_delegations.length == 1, "Wrong number of delegations");

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory encodedModes_ = new ModeCode[](1);
        encodedModes_[0] = ModeLib.encodeSimpleSingle();

        bytes[] memory executionCallDatas_ = new bytes[](1);

        bytes memory encodedTransfer_ = abi.encodeCall(IERC20.transfer, (address(this), _amount));
        executionCallDatas_[0] = ExecutionLib.encodeSingle(address(_token), 0, encodedTransfer_);

        delegationManager.redeemDelegations(permissionContexts_, encodedModes_, executionCallDatas_);

        IERC20(_token).approve(address(aavePool), _amount);
        aavePool.supply(_token, _amount, _delegations[0].delegator, 0);
    }
}
