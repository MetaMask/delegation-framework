// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseTest } from "../utils/BaseTest.t.sol";
import { Implementation, SignatureType } from "../utils/Types.t.sol";
import { Execution, Delegation, Caveat, ModeCode } from "../../src/utils/Types.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";
import { AllowedCalldataEnforcer } from "../../src/enforcers/AllowedCalldataEnforcer.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";
import { LogicalOrWrapperEnforcer } from "../../src/enforcers/LogicalOrWrapperEnforcer.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { IAavePool } from "../../src/helpers/interfaces/IAavePool.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { AaveAdapter } from "../../src/helpers/AaveAdapter.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

// @dev Do not remove this comment below
/// forge-config: default.evm_version = "shanghai"

/**
 * @title AaveLending Test
 * @notice Tests delegation-based lending on Aave v3.
 * @dev Uses a forked Ethereum mainnet environment to test real contract interactions.
 *
 * We are testing 2 different approaches to using the delegation framework for Aave v3 lending:
 *
 * 1. Direct delegation: Alice delegates token approval and supply operations on Aave. This can be done with
 *    either 2 separate delegations or a single delegation using LogicalOrWrapperEnforcer. Funds and approvals
 *    flow directly from Alice to USDC/Aave. However, for rebalancing scenarios, Alice would need to over-approve
 *    tokens to allow withdrawals and re-deposits.
 *
 * 2. Adapter pattern: We use a custom "AaveAdapter" contract where Alice delegates only transfer permissions.
 *    The AaveAdapter handles token approvals to Aave and executes lending operations. This approach centralizes
 *    over-approval in the adapter, making it safer, but introduces a middleware contract.
 *
 * The AaveAdapter supports two usage patterns:
 * - supplyByDelegation: More restrictive - Alice creates a transfer delegation to the adapter, then another
 *   delegation to the executor for calling supplyByDelegation. This allows Alice to control who can call the adapter.
 * - supplyByDelegationOpenEnded: Less restrictive - Anyone can call it as long as they have a valid transfer
 *   delegation to the adapter.
 *
 * In both adapter cases, only the creator of the transfer delegation receives aTokens.
 */
contract AaveLendingTest is BaseTest {
    using ModeLib for ModeCode;

    IAavePool public constant AAVE_POOL = IAavePool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 public aUSDC;
    address public constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    address public owner;

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

        owner = makeAddr("AaveAdapter Owner");

        // Deploy enforcers
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        allowedCalldataEnforcer = new AllowedCalldataEnforcer();
        valueLteEnforcer = new ValueLteEnforcer();
        erc20TransferAmountEnforcer = new ERC20TransferAmountEnforcer();

        logicalOrWrapperEnforcer = new LogicalOrWrapperEnforcer(delegationManager);
        aaveAdapter = new AaveAdapter(owner, address(delegationManager), address(AAVE_POOL));

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

        aUSDC = IERC20(AAVE_POOL.getReserveAToken(address(USDC)));
    }

    // Testing directly depositing USDC to Aave to see if everything works on the forked mainnet
    function test_deposit_direct() public {
        uint256 aliceUSDCInitialBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCInitialBalance_, INITIAL_USDC_BALANCE);

        vm.prank(address(users.alice.deleGator));
        USDC.approve(address(AAVE_POOL), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        AAVE_POOL.supply(address(USDC), DEPOSIT_AMOUNT, address(users.alice.deleGator), 0);

        uint256 aliceUSDCBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance_, INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT);

        uint256 aliceATokenBalance_ = aUSDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceATokenBalance_, DEPOSIT_AMOUNT);
    }

    // Testing directly withdrawing USDC from Aave to see if everything works on the forked mainnet
    function test_withdraw_direct() public {
        vm.prank(address(users.alice.deleGator));
        USDC.approve(address(AAVE_POOL), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        AAVE_POOL.supply(address(USDC), DEPOSIT_AMOUNT, address(users.alice.deleGator), 0);

        vm.prank(address(users.alice.deleGator));
        AAVE_POOL.withdraw(address(USDC), type(uint256).max, address(users.alice.deleGator));

        _assertBalances(INITIAL_USDC_BALANCE, 0);
    }

    // Testing delegating approval and supply functions in 2 separate delegations
    function test_deposit_viaDelegation() public {
        _assertBalances(INITIAL_USDC_BALANCE, 0);

        // Create and execute approval delegation
        Delegation memory approveDelegation =
            _createApprovalDelegation(address(users.bob.deleGator), address(AAVE_POOL), DEPOSIT_AMOUNT);

        Execution memory approveExecution = Execution({
            target: address(USDC),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.approve.selector, address(AAVE_POOL), DEPOSIT_AMOUNT)
        });

        Delegation[] memory approveDelegations = new Delegation[](1);
        approveDelegations[0] = approveDelegation;
        invokeDelegation_UserOp(users.bob, approveDelegations, approveExecution);

        // Create and execute supply delegation
        Delegation memory supplyDelegation = _createSupplyDelegation(address(users.bob.deleGator));

        Execution memory supplyExecution = Execution({
            target: address(AAVE_POOL),
            value: 0,
            callData: abi.encodeWithSelector(
                IAavePool.supply.selector, address(USDC), DEPOSIT_AMOUNT, address(users.alice.deleGator), 0
            )
        });

        Delegation[] memory supplyDelegations = new Delegation[](1);
        supplyDelegations[0] = supplyDelegation;
        invokeDelegation_UserOp(users.bob, supplyDelegations, supplyExecution);

        _assertBalances(INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
    }

    // Testing delegating withdrawal function in a single delegation
    function test_withdraw_viaDelegation() public {
        _setupLendingState();
        _assertBalances(INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        // Create and execute withdrawal delegation
        Delegation memory withdrawDelegation = _createWithdrawDelegation(address(users.bob.deleGator));

        Execution memory withdrawExecution = Execution({
            target: address(AAVE_POOL),
            value: 0,
            callData: abi.encodeWithSelector(
                IAavePool.withdraw.selector, address(USDC), type(uint256).max, address(users.alice.deleGator)
            )
        });

        Delegation[] memory withdrawDelegations = new Delegation[](1);
        withdrawDelegations[0] = withdrawDelegation;
        invokeDelegation_UserOp(users.bob, withdrawDelegations, withdrawExecution);

        _assertBalances(INITIAL_USDC_BALANCE, 0);
    }

    // Testing delegating approval and supply functions in a single delegation using LogicalOrWrapperEnforcer
    function test_deposit_viaDelegationWithLogicalOrWrapper() public {
        // Check initial balance
        uint256 aliceUSDCInitialBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCInitialBalance_, INITIAL_USDC_BALANCE);

        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](2);

        // Create delegation caveats for approving USDC
        Caveat[] memory approveCaveats_ = new Caveat[](5);

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

        // Recommended: Restrict approve recipient
        paramStart_ = abi.encodeWithSelector(IERC20.approve.selector).length;
        approveCaveats_[3] =
            Caveat({ args: hex"", enforcer: address(allowedCalldataEnforcer), terms: abi.encode(paramStart_, address(AAVE_POOL)) });

        // Recommended: Set value limit to 0
        approveCaveats_[4] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encode(0) });

        // Create delegation caveats for lending
        Caveat[] memory lendingCaveats_ = new Caveat[](4);

        // Recommended: Restrict to specific contract
        lendingCaveats_[0] =
            Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(AAVE_POOL)) });

        // Recommended: Restrict to deposit function only
        lendingCaveats_[1] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(IAavePool.supply.selector) });

        // Recommended: Restrict supply argument "onBehalfOf" to alice
        paramStart_ = abi.encodeWithSelector(IAavePool.supply.selector, address(0), uint256(0)).length;
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
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: orCaveats_,
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        delegation_ = signDelegation(users.alice, delegation_);

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
            callData: abi.encodeWithSelector(
                IAavePool.supply.selector, address(USDC), DEPOSIT_AMOUNT, address(users.alice.deleGator), 0
            )
        });

        // Execute delegation
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        delegations_[0].caveats[0].args =
            abi.encode(LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: 0, caveatArgs: new bytes[](5) }));
        invokeDelegation_UserOp(users.bob, delegations_, approveExecution_);

        delegations_[0].caveats[0].args =
            abi.encode(LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: 1, caveatArgs: new bytes[](4) }));
        invokeDelegation_UserOp(users.bob, delegations_, lendingExecution_);

        // Check state after delegation
        uint256 aliceUSDCBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance_, INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT);

        uint256 aliceATokenBalance_ = aUSDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceATokenBalance_, DEPOSIT_AMOUNT);
    }

    // Testing delegating transfer to adapter and then supply by delegation
    function test_deposit_viaAdapter() public {
        _assertBalances(INITIAL_USDC_BALANCE, 0);

        // Create transfer delegation to adapter
        Delegation memory delegation_ = _createTransferDelegation(address(aaveAdapter), address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        vm.prank(address(users.alice.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);

        _assertBalances(INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
    }

    // Testing delegating transfer to adapter and then delegating supplyByDelegation
    function test_deposit_viaAdapterDelegation() public {
        _assertBalances(INITIAL_USDC_BALANCE, 0);

        // Create transfer delegation to adapter and target delegation for adapter call
        Delegation memory transferDelegation_ = _createTransferDelegation(address(aaveAdapter), address(USDC), DEPOSIT_AMOUNT);
        Delegation memory adapterDelegation_ = _createTargetRestrictedDelegation(address(users.bob.deleGator), address(aaveAdapter));

        Delegation[] memory transferDelegations_ = new Delegation[](1);
        transferDelegations_[0] = transferDelegation_;

        // Create execution for supply via adapter
        Execution memory supplyExecution_ = Execution({
            target: address(aaveAdapter),
            value: 0,
            callData: abi.encodeWithSelector(
                AaveAdapter.supplyByDelegation.selector, transferDelegations_, address(USDC), DEPOSIT_AMOUNT
            )
        });

        Delegation[] memory adapterDelegations_ = new Delegation[](1);
        adapterDelegations_[0] = adapterDelegation_;

        invokeDelegation_UserOp(users.bob, adapterDelegations_, supplyExecution_);

        _assertBalances(INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
    }

    // Testing delegating transfer to adapter and then calling (can be called by anyone) suppyByDelegationOpenEnded
    function test_deposit_viaOpenEndedAdapterDelegation() public {
        _assertBalances(INITIAL_USDC_BALANCE, 0);

        // Create transfer delegation to adapter
        Delegation memory delegation_ = _createTransferDelegation(address(aaveAdapter), address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        aaveAdapter.supplyByDelegationOpenEnded(delegations_, address(USDC), DEPOSIT_AMOUNT);

        _assertBalances(INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
    }

    // Testing delegating transfer of aTokens to adapter and then withdraw by delegation
    function test_withdraw_viaAdapter() public {
        _setupLendingState();
        _assertBalances(INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        // Create transfer delegation to adapter
        Delegation memory delegation_ = _createTransferDelegation(address(aaveAdapter), address(aUSDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        vm.prank(address(users.alice.deleGator));
        aaveAdapter.withdrawByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);

        _assertBalances(INITIAL_USDC_BALANCE, 0);
    }

    // Testing delegating transfer of aTokens to adapter and then delegating withdrawByDelegation
    function test_withdraw_viaAdapterDelegation() public {
        _setupLendingState();
        _assertBalances(INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        Delegation memory delegation_ = _createTransferDelegation(address(aaveAdapter), address(aUSDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Create delegation caveats for withdrawal
        Caveat[] memory withdrawalCaveats_ = new Caveat[](1);

        // Recommended: Restrict to specific contract
        withdrawalCaveats_[0] =
            Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(aaveAdapter)) });

        // Create delegation for withdrawal
        Delegation memory withdrawalDelegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: withdrawalCaveats_,
            salt: 0,
            signature: hex""
        });

        // Sign delegation
        withdrawalDelegation_ = signDelegation(users.alice, withdrawalDelegation_);

        // Create execution for withdrawal
        Execution memory withdrawalExecution_ = Execution({
            target: address(aaveAdapter),
            value: 0,
            callData: abi.encodeWithSelector(AaveAdapter.withdrawByDelegation.selector, delegations_, address(USDC), DEPOSIT_AMOUNT)
        });

        // Execute delegation
        Delegation[] memory withdrawalDelegations_ = new Delegation[](1);
        withdrawalDelegations_[0] = withdrawalDelegation_;

        invokeDelegation_UserOp(users.bob, withdrawalDelegations_, withdrawalExecution_);

        _assertBalances(INITIAL_USDC_BALANCE, 0);
    }

    // Testing delegating transfer of aTokens to adapter and then calling (can be called by anyone) withdrawByDelegationOpenEnded
    function test_withdraw_viaOpenEndedAdapterDelegation() public {
        _setupLendingState();
        _assertBalances(INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        Delegation memory delegation_ = _createTransferDelegation(address(aaveAdapter), address(aUSDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        aaveAdapter.withdrawByDelegationOpenEnded(delegations_, address(USDC), DEPOSIT_AMOUNT);

        _assertBalances(INITIAL_USDC_BALANCE, 0);
    }

    ////////////////////// Event Tests //////////////////////

    /// @notice Tests that verify events are properly emitted by AaveAdapter functions
    function test_supplyByDelegation_emitsSupplyExecutedEvent() public {
        _assertBalances(INITIAL_USDC_BALANCE, 0);

        // Create transfer delegation to adapter
        Delegation memory delegation_ = _createTransferDelegation(address(aaveAdapter), address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Expect the SupplyExecuted event to be emitted
        vm.expectEmit(true, true, true, true, address(aaveAdapter));
        emit AaveAdapter.SupplyExecuted(
            address(users.alice.deleGator), address(users.alice.deleGator), address(USDC), DEPOSIT_AMOUNT
        );

        vm.prank(address(users.alice.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);

        _assertBalances(INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
    }

    /// @notice Tests that supplyByDelegationOpenEnded emits the correct event when bob supplies on alice's behalf
    function test_supplyByDelegationOpenEnded_emitsSupplyExecutedEvent() public {
        _assertBalances(INITIAL_USDC_BALANCE, 0);

        // Create transfer delegation to adapter
        Delegation memory delegation_ = _createTransferDelegation(address(aaveAdapter), address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Expect the SupplyExecuted event to be emitted with different delegate (bob calling on alice's behalf)
        vm.expectEmit(true, true, true, true, address(aaveAdapter));
        emit AaveAdapter.SupplyExecuted(address(users.alice.deleGator), address(users.bob.deleGator), address(USDC), DEPOSIT_AMOUNT);

        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegationOpenEnded(delegations_, address(USDC), DEPOSIT_AMOUNT);

        _assertBalances(INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
    }

    /// @notice Tests that withdrawByDelegation emits the correct event when alice withdraws her own funds
    function test_withdrawByDelegation_emitsWithdrawExecutedEvent() public {
        _setupLendingState();
        _assertBalances(INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        // Create transfer delegation to adapter
        Delegation memory delegation_ = _createTransferDelegation(address(aaveAdapter), address(aUSDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Expect the WithdrawExecuted event to be emitted
        vm.expectEmit(true, true, true, true, address(aaveAdapter));
        emit AaveAdapter.WithdrawExecuted(
            address(users.alice.deleGator), address(users.alice.deleGator), address(USDC), DEPOSIT_AMOUNT
        );

        vm.prank(address(users.alice.deleGator));
        aaveAdapter.withdrawByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);

        _assertBalances(INITIAL_USDC_BALANCE, 0);
    }

    /// @notice Tests that withdrawByDelegationOpenEnded emits the correct event when bob withdraws on alice's behalf
    function test_withdrawByDelegationOpenEnded_emitsWithdrawExecutedEvent() public {
        _setupLendingState();
        _assertBalances(INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        Delegation memory delegation_ = _createTransferDelegation(address(aaveAdapter), address(aUSDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Expect the WithdrawExecuted event to be emitted with different delegate (bob calling on alice's behalf)
        vm.expectEmit(true, true, true, true, address(aaveAdapter));
        emit AaveAdapter.WithdrawExecuted(
            address(users.alice.deleGator), address(users.bob.deleGator), address(USDC), DEPOSIT_AMOUNT
        );

        vm.prank(address(users.bob.deleGator));
        aaveAdapter.withdrawByDelegationOpenEnded(delegations_, address(USDC), DEPOSIT_AMOUNT);

        _assertBalances(INITIAL_USDC_BALANCE, 0);
    }

    ////////////////////// Error Tests //////////////////////

    /// @notice Tests that verify the custom errors are properly thrown by AaveAdapter functions
    function test_supplyByDelegation_revertsOnInvalidDelegationsLength() public {
        // Create empty delegations array
        Delegation[] memory delegations_ = new Delegation[](0);

        vm.expectRevert(AaveAdapter.InvalidDelegationsLength.selector);
        vm.prank(address(users.alice.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);

        // Create delegations array with 2 elements
        delegations_ = new Delegation[](2);
        delegations_[0] = _createTransferDelegation(address(aaveAdapter), address(USDC), DEPOSIT_AMOUNT);
        delegations_[1] = _createTransferDelegation(address(aaveAdapter), address(USDC), DEPOSIT_AMOUNT);

        vm.expectRevert(AaveAdapter.InvalidDelegationsLength.selector);
        vm.prank(address(users.alice.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);
    }

    /// @notice Tests that supplyByDelegation reverts when called by an unauthorized caller (not the delegator)
    function test_supplyByDelegation_revertsOnUnauthorizedCaller() public {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _createTransferDelegation(address(aaveAdapter), address(USDC), DEPOSIT_AMOUNT);

        vm.expectRevert(AaveAdapter.UnauthorizedCaller.selector);
        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);
    }

    /// @notice Tests that supplyByDelegation reverts when token is zero address
    function test_supplyByDelegation_revertsOnInvalidZeroAddress() public {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _createTransferDelegation(address(aaveAdapter), address(USDC), DEPOSIT_AMOUNT);

        vm.expectRevert(AaveAdapter.InvalidZeroAddress.selector);
        vm.prank(address(users.alice.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(0), DEPOSIT_AMOUNT);
    }

    /// @notice Tests that supplyByDelegationOpenEnded reverts when delegations array length is not exactly 1
    function test_supplyByDelegationOpenEnded_revertsOnInvalidDelegationsLength() public {
        // Create empty delegations array
        Delegation[] memory delegations_ = new Delegation[](0);

        vm.expectRevert(AaveAdapter.InvalidDelegationsLength.selector);
        aaveAdapter.supplyByDelegationOpenEnded(delegations_, address(USDC), DEPOSIT_AMOUNT);

        // Create delegations array with 2 elements
        delegations_ = new Delegation[](2);
        delegations_[0] = _createTransferDelegation(address(aaveAdapter), address(USDC), DEPOSIT_AMOUNT);
        delegations_[1] = _createTransferDelegation(address(aaveAdapter), address(USDC), DEPOSIT_AMOUNT);

        vm.expectRevert(AaveAdapter.InvalidDelegationsLength.selector);
        aaveAdapter.supplyByDelegationOpenEnded(delegations_, address(USDC), DEPOSIT_AMOUNT);
    }

    /// @notice Tests that supplyByDelegationOpenEnded reverts when token is zero address
    function test_supplyByDelegationOpenEnded_revertsOnInvalidZeroAddress() public {
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _createTransferDelegation(address(aaveAdapter), address(USDC), DEPOSIT_AMOUNT);

        vm.expectRevert(AaveAdapter.InvalidZeroAddress.selector);
        aaveAdapter.supplyByDelegationOpenEnded(delegations_, address(0), DEPOSIT_AMOUNT);
    }

    /// @notice Tests that withdrawByDelegation reverts when delegations array length is not exactly 1
    function test_withdrawByDelegation_revertsOnInvalidDelegationsLength() public {
        _setupLendingState();

        // Create empty delegations array
        Delegation[] memory delegations_ = new Delegation[](0);

        vm.expectRevert(AaveAdapter.InvalidDelegationsLength.selector);
        vm.prank(address(users.alice.deleGator));
        aaveAdapter.withdrawByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);

        // Create delegations array with 2 elements
        delegations_ = new Delegation[](2);
        delegations_[0] = _createTransferDelegation(address(aaveAdapter), address(aUSDC), DEPOSIT_AMOUNT);
        delegations_[1] = _createTransferDelegation(address(aaveAdapter), address(aUSDC), DEPOSIT_AMOUNT);

        vm.expectRevert(AaveAdapter.InvalidDelegationsLength.selector);
        vm.prank(address(users.alice.deleGator));
        aaveAdapter.withdrawByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);
    }

    /// @notice Tests that withdrawByDelegation reverts when called by an unauthorized caller (not the delegator)
    function test_withdrawByDelegation_revertsOnUnauthorizedCaller() public {
        _setupLendingState();

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _createTransferDelegation(address(aaveAdapter), address(aUSDC), DEPOSIT_AMOUNT);

        vm.expectRevert(AaveAdapter.UnauthorizedCaller.selector);
        vm.prank(address(users.bob.deleGator));
        aaveAdapter.withdrawByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);
    }

    /// @notice Tests that withdrawByDelegation reverts when token is zero address
    function test_withdrawByDelegation_revertsOnInvalidZeroAddress() public {
        _setupLendingState();

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _createTransferDelegation(address(aaveAdapter), address(aUSDC), DEPOSIT_AMOUNT);

        vm.expectRevert(AaveAdapter.InvalidZeroAddress.selector);
        vm.prank(address(users.alice.deleGator));
        aaveAdapter.withdrawByDelegation(delegations_, address(0), DEPOSIT_AMOUNT);
    }

    /// @notice Tests that withdrawByDelegationOpenEnded reverts when delegations array length is not exactly 1
    function test_withdrawByDelegationOpenEnded_revertsOnInvalidDelegationsLength() public {
        _setupLendingState();

        // Create empty delegations array
        Delegation[] memory delegations_ = new Delegation[](0);

        vm.expectRevert(AaveAdapter.InvalidDelegationsLength.selector);
        aaveAdapter.withdrawByDelegationOpenEnded(delegations_, address(USDC), DEPOSIT_AMOUNT);

        // Create delegations array with 2 elements
        delegations_ = new Delegation[](2);
        delegations_[0] = _createTransferDelegation(address(aaveAdapter), address(aUSDC), DEPOSIT_AMOUNT);
        delegations_[1] = _createTransferDelegation(address(aaveAdapter), address(aUSDC), DEPOSIT_AMOUNT);

        vm.expectRevert(AaveAdapter.InvalidDelegationsLength.selector);
        aaveAdapter.withdrawByDelegationOpenEnded(delegations_, address(USDC), DEPOSIT_AMOUNT);
    }

    /// @notice Tests that withdrawByDelegationOpenEnded reverts when token is zero address
    function test_withdrawByDelegationOpenEnded_revertsOnInvalidZeroAddress() public {
        _setupLendingState();

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = _createTransferDelegation(address(aaveAdapter), address(aUSDC), DEPOSIT_AMOUNT);

        vm.expectRevert(AaveAdapter.InvalidZeroAddress.selector);
        aaveAdapter.withdrawByDelegationOpenEnded(delegations_, address(0), DEPOSIT_AMOUNT);
    }

    ////////////////////// Constructor Error Tests //////////////////////

    /// @notice Tests that constructor reverts when delegation manager is zero address
    function test_constructor_revertsOnZeroDelegationManager() public {
        vm.expectRevert(AaveAdapter.InvalidZeroAddress.selector);
        new AaveAdapter(owner, address(0), address(AAVE_POOL));
    }

    /// @notice Tests that constructor reverts when Aave pool is zero address
    function test_constructor_revertsOnZeroAavePool() public {
        vm.expectRevert(AaveAdapter.InvalidZeroAddress.selector);
        new AaveAdapter(owner, address(delegationManager), address(0));
    }

    /// @notice Tests that constructor reverts when both delegation manager and Aave pool are zero addresses
    function test_constructor_revertsOnBothZeroAddresses() public {
        vm.expectRevert(AaveAdapter.InvalidZeroAddress.selector);
        new AaveAdapter(owner, address(0), address(0));
    }

    /// @notice Tests successful constructor with valid addresses
    function test_constructor_successWithValidAddresses() public {
        AaveAdapter newAdapter_ = new AaveAdapter(owner, address(delegationManager), address(AAVE_POOL));

        assertEq(address(newAdapter_.delegationManager()), address(delegationManager));
        assertEq(address(newAdapter_.aavePool()), address(AAVE_POOL));
    }

    ////////////////////// Edge Case Tests //////////////////////

    /// @notice Tests supplyByDelegation with maximum uint256 amount
    function test_supplyByDelegation_withMaxAmount() public {
        // First, we need to ensure Alice has sufficient balance for a reasonable test
        uint256 testAmount_ = INITIAL_USDC_BALANCE; // Use all her balance

        _assertBalances(INITIAL_USDC_BALANCE, 0);

        // Create transfer delegation to adapter
        Delegation memory delegation_ = _createTransferDelegation(address(aaveAdapter), address(USDC), testAmount_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        vm.prank(address(users.alice.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), testAmount_);

        _assertBalances(0, testAmount_);
    }

    /// @notice Tests withdrawByDelegation with maximum uint256 amount (withdraw all)
    function test_withdrawByDelegation_withMaxAmount() public {
        _setupLendingState();
        _assertBalances(INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        // Get Alice's actual aToken balance and use a high limit for delegation
        uint256 aTokenBalance_ = aUSDC.balanceOf(address(users.alice.deleGator));

        // Create transfer delegation to adapter with very high allowance for max amount withdrawal
        Delegation memory delegation_ = _createTransferDelegation(address(aaveAdapter), address(aUSDC), type(uint128).max);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        vm.prank(address(users.alice.deleGator));
        aaveAdapter.withdrawByDelegation(delegations_, address(USDC), aTokenBalance_);

        _assertBalances(INITIAL_USDC_BALANCE, 0);
    }

    /// @notice Tests that adapter properly handles allowance management
    function test_ensureAllowance_increasesWhenNeeded() public {
        _assertBalances(INITIAL_USDC_BALANCE, 0);

        // Create transfer delegation to adapter
        Delegation memory delegation_ = _createTransferDelegation(address(aaveAdapter), address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Check initial allowance (should be 0)
        uint256 initialAllowance = USDC.allowance(address(aaveAdapter), address(AAVE_POOL));
        assertEq(initialAllowance, 0);

        vm.prank(address(users.alice.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);

        // Check that allowance was increased and then decreased by the transfer amount
        uint256 finalAllowance = USDC.allowance(address(aaveAdapter), address(AAVE_POOL));
        assertEq(finalAllowance, type(uint256).max - DEPOSIT_AMOUNT);

        _assertBalances(INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
    }

    /// @notice Tests multiple supplies with existing allowance (should not increase again)
    function test_ensureAllowance_doesNotIncreaseWhenSufficient() public {
        _assertBalances(INITIAL_USDC_BALANCE, 0);

        // First supply to set allowance with higher amount limit to allow multiple uses
        Delegation memory delegation1_ = _createTransferDelegation(address(aaveAdapter), address(USDC), 2 * DEPOSIT_AMOUNT);
        Delegation[] memory delegations1_ = new Delegation[](1);
        delegations1_[0] = delegation1_;

        vm.prank(address(users.alice.deleGator));
        aaveAdapter.supplyByDelegation(delegations1_, address(USDC), DEPOSIT_AMOUNT);

        uint256 allowanceAfterFirst_ = USDC.allowance(address(aaveAdapter), address(AAVE_POOL));
        assertEq(allowanceAfterFirst_, type(uint256).max - DEPOSIT_AMOUNT);

        // Second supply should not change allowance (reuse same delegation)
        vm.prank(address(users.alice.deleGator));
        aaveAdapter.supplyByDelegation(delegations1_, address(USDC), DEPOSIT_AMOUNT);

        uint256 allowanceAfterSecond_ = USDC.allowance(address(aaveAdapter), address(AAVE_POOL));
        assertEq(allowanceAfterSecond_, type(uint256).max - (2 * DEPOSIT_AMOUNT));

        // Check USDC balance
        uint256 aliceUSDCBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance_, INITIAL_USDC_BALANCE - (2 * DEPOSIT_AMOUNT), "USDC balance mismatch");

        // Check aUSDC balance (allow for small interest accrual)
        uint256 aliceATokenBalance_ = aUSDC.balanceOf(address(users.alice.deleGator));
        assertGe(aliceATokenBalance_, 2 * DEPOSIT_AMOUNT, "aUSDC balance should be at least 2x deposit amount");
        assertLe(aliceATokenBalance_, 2 * DEPOSIT_AMOUNT + 10, "aUSDC balance should not exceed deposit + small interest");
    }

    ////////////////////// Withdraw Function Tests //////////////////////

    /// @notice Tests that only owner can call withdraw function
    function test_withdraw_onlyOwner() public {
        // Create test token and give some balance to the adapter
        BasicERC20 testToken_ = new BasicERC20(owner, "TestToken", "TST", 1000 ether);

        // Mint some tokens to the adapter
        vm.prank(owner);
        testToken_.mint(address(aaveAdapter), 100 ether);

        // Verify adapter has tokens
        assertEq(testToken_.balanceOf(address(aaveAdapter)), 100 ether);

        // Try to call withdraw from non-owner address (should fail)
        vm.prank(address(users.alice.deleGator));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(users.alice.deleGator)));
        aaveAdapter.withdraw(testToken_, 50 ether, address(users.alice.deleGator));

        // Verify balance hasn't changed
        assertEq(testToken_.balanceOf(address(aaveAdapter)), 100 ether);
    }

    /// @notice Tests that withdraw function works correctly when called by owner
    function test_withdraw_functionality() public {
        // Create test token and give some balance to the adapter
        BasicERC20 testToken_ = new BasicERC20(owner, "TestToken", "TST", 1000 ether);

        // Mint some tokens to the adapter
        vm.prank(owner);
        testToken_.mint(address(aaveAdapter), 100 ether);

        // Verify initial balances
        assertEq(testToken_.balanceOf(address(aaveAdapter)), 100 ether);
        assertEq(testToken_.balanceOf(address(users.alice.deleGator)), 0);

        // Expect the event to be emitted
        vm.expectEmit(true, true, true, true, address(aaveAdapter));
        emit AaveAdapter.StuckTokensWithdrawn(testToken_, address(users.alice.deleGator), 50 ether);

        // Call withdraw as owner
        vm.prank(owner);
        aaveAdapter.withdraw(testToken_, 50 ether, address(users.alice.deleGator));

        // Verify balances after withdrawal
        assertEq(testToken_.balanceOf(address(aaveAdapter)), 50 ether);
        assertEq(testToken_.balanceOf(address(users.alice.deleGator)), 50 ether);
    }

    /// @notice Tests withdraw function with full balance
    function test_withdraw_fullBalance() public {
        // Create test token and give some balance to the adapter
        BasicERC20 testToken_ = new BasicERC20(owner, "TestToken", "TST", 1000 ether);

        // Mint some tokens to the adapter
        vm.prank(owner);
        testToken_.mint(address(aaveAdapter), 100 ether);

        // Verify initial balance
        assertEq(testToken_.balanceOf(address(aaveAdapter)), 100 ether);

        // Withdraw full balance
        vm.prank(owner);
        aaveAdapter.withdraw(testToken_, 100 ether, address(users.bob.deleGator));

        // Verify all tokens were withdrawn
        assertEq(testToken_.balanceOf(address(aaveAdapter)), 0);
        assertEq(testToken_.balanceOf(address(users.bob.deleGator)), 100 ether);
    }

    ////////////////////// Helpers //////////////////////

    /// @notice Creates a transfer delegation with ERC20TransferAmountEnforcer
    /// @param _delegate Address that can execute the delegation
    /// @param _token Token to transfer
    /// @param _amount Amount to transfer
    /// @return Signed delegation ready for execution
    function _createTransferDelegation(
        address _delegate,
        address _token,
        uint256 _amount
    )
        internal
        view
        returns (Delegation memory)
    {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: abi.encodePacked(_token, _amount) });

        Delegation memory delegation_ = Delegation({
            delegate: _delegate,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        return signDelegation(users.alice, delegation_);
    }

    /// @notice Creates a target-restricted delegation
    /// @param _delegate Address that can execute the delegation
    /// @param _target Allowed target address
    /// @return Signed delegation ready for execution
    function _createTargetRestrictedDelegation(address _delegate, address _target) internal view returns (Delegation memory) {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(_target) });

        Delegation memory delegation_ = Delegation({
            delegate: _delegate,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        return signDelegation(users.alice, delegation_);
    }

    /// @notice Creates a comprehensive approval delegation with all security restrictions
    /// @param _delegate Address that can execute the delegation
    /// @param _spender Address to approve
    /// @param _amount Amount to approve
    /// @return Signed delegation ready for execution
    function _createApprovalDelegation(
        address _delegate,
        address _spender,
        uint256 _amount
    )
        internal
        view
        returns (Delegation memory)
    {
        Caveat[] memory caveats_ = new Caveat[](5);

        // Restrict to USDC contract
        caveats_[0] = Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(USDC)) });

        // Restrict to approve function
        caveats_[1] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(IERC20.approve.selector) });

        // Restrict approve recipient
        uint256 paramStart_ = abi.encodeWithSelector(IERC20.approve.selector).length;
        caveats_[2] = Caveat({ args: hex"", enforcer: address(allowedCalldataEnforcer), terms: abi.encode(paramStart_, _spender) });

        // Restrict approve amount
        paramStart_ = abi.encodeWithSelector(IERC20.approve.selector, address(0)).length;
        caveats_[3] =
            Caveat({ args: hex"", enforcer: address(allowedCalldataEnforcer), terms: abi.encodePacked(paramStart_, _amount) });

        // Set value limit to 0
        caveats_[4] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encode(0) });

        Delegation memory delegation_ = Delegation({
            delegate: _delegate,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        return signDelegation(users.alice, delegation_);
    }

    /// @notice Creates a supply delegation with all security restrictions
    /// @param _delegate Address that can execute the delegation
    /// @return Signed delegation ready for execution
    function _createSupplyDelegation(address _delegate) internal view returns (Delegation memory) {
        Caveat[] memory caveats_ = new Caveat[](4);

        // Restrict to Aave pool
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(AAVE_POOL)) });

        // Restrict to supply function
        caveats_[1] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(IAavePool.supply.selector) });

        // Restrict onBehalfOf to Alice
        uint256 paramStart_ = abi.encodeWithSelector(IAavePool.supply.selector, address(0), uint256(0)).length;
        caveats_[2] = Caveat({
            args: hex"",
            enforcer: address(allowedCalldataEnforcer),
            terms: abi.encode(paramStart_, address(users.alice.deleGator))
        });

        // Set value limit to 0
        caveats_[3] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encode(0) });

        Delegation memory delegation_ = Delegation({
            delegate: _delegate,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        return signDelegation(users.alice, delegation_);
    }

    /// @notice Creates a withdraw delegation with all security restrictions
    /// @param _delegate Address that can execute the delegation
    /// @return Signed delegation ready for execution
    function _createWithdrawDelegation(address _delegate) internal view returns (Delegation memory) {
        Caveat[] memory caveats_ = new Caveat[](4);

        // Restrict to Aave pool
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(AAVE_POOL)) });

        // Restrict to withdraw function
        caveats_[1] =
            Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(IAavePool.withdraw.selector) });

        // Restrict to parameter to Alice
        uint256 paramStart_ = abi.encodeWithSelector(IAavePool.withdraw.selector, address(0), uint256(0)).length;
        caveats_[2] = Caveat({
            args: hex"",
            enforcer: address(allowedCalldataEnforcer),
            terms: abi.encode(paramStart_, address(users.alice.deleGator))
        });

        // Set value limit to 0
        caveats_[3] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encode(0) });

        Delegation memory delegation_ = Delegation({
            delegate: _delegate,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        return signDelegation(users.alice, delegation_);
    }

    /// @notice Sets up initial lending state (Alice deposits USDC to get aTokens)
    function _setupLendingState() internal {
        vm.prank(address(users.alice.deleGator));
        USDC.approve(address(AAVE_POOL), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        AAVE_POOL.supply(address(USDC), DEPOSIT_AMOUNT, address(users.alice.deleGator), 0);
    }

    /// @notice Asserts Alice's USDC and aUSDC balances
    /// @param expectedUSDC Expected USDC balance
    /// @param expectedAUSDC Expected aUSDC balance
    function _assertBalances(uint256 expectedUSDC, uint256 expectedAUSDC) internal {
        uint256 aliceUSDCBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance_, expectedUSDC, "USDC balance mismatch");

        uint256 aliceATokenBalance_ = aUSDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceATokenBalance_, expectedAUSDC, "aUSDC balance mismatch");
    }
}
