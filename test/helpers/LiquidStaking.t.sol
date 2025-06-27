// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { BaseTest } from "../utils/BaseTest.t.sol";
import { Implementation, SignatureType, TestUser } from "../utils/Types.t.sol";
import { Delegation, Caveat, Execution } from "../../src/utils/Types.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { LogicalOrWrapperEnforcer } from "../../src/enforcers/LogicalOrWrapperEnforcer.sol";
import { ILiquidStakingAggregator } from "./interfaces/ILiquidStakingAggregator.sol";
import { LiquidStakingAdapter } from "../../src/helpers/LiquidStakingAdapter.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { IWithdrawalQueue } from "../../src/helpers/interfaces/IWithdrawalQueue.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { EIP7702StatelessDeleGator } from "../../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { ERC1271Lib } from "../../src/libraries/ERC1271Lib.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { console2 } from "forge-std/console2.sol";
import "forge-std/Test.sol";

/// @notice Interface for Lido's stETH token
interface IstETH {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Interface for Rocket Pool's rETH token
interface IrETH {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Burn rETH for ETH (when deposit pool has liquidity)
    function burn(uint256 _rethAmount) external;

    /// @notice Get the current ETH value of an amount of rETH
    function getEthValue(uint256 _rethAmount) external view returns (uint256);
}

// @dev Do not remove this comment below
/// forge-config: default.evm_version = "shanghai"

/**
 * @title LiquidStakingTest
 * @notice Tests for MetaMask's liquid staking functionality including both
 *         direct interactions and delegation-based interactions
 */
contract LiquidStakingTest is BaseTest {
    ////////////////////////////// State & Constants //////////////////////////////

    // MetaMask Liquid Staking contract address on mainnet
    address public constant LIQUID_STAKING_AGGREGATOR = 0x1f6692E78dDE07FF8da75769B6d7c716215bC7D0;

    // Token addresses on mainnet
    address public constant STETH_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant RETH_ADDRESS = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address public constant WSTETH_ADDRESS = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    // Real mainnet addresses that have interacted with the vault
    address private constant LIDO_WITHDRAWAL_REQUESTER_ADDRESS = 0xBBE3188a1e6Bfe7874F069a9164A923725B8Bd68;
    address private constant LIDO_WITHDRAWAL_CLAIMER_ADDRESS = 0x95c79a359835C7471969A67d6bE35EE2B5d46ea8;

    address private constant ROCKET_POOL_WITHDRAWAL_BURNER_ADDRESS = 0xBA9deC4B0c3485F3509Ab2f582F9387094f04Fb5;

    // Lido withdrawal queue
    address public constant LIDO_WITHDRAWAL_QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

    ILiquidStakingAggregator public liquidStaking;
    IstETH public stETH;
    IrETH public rETH;
    IWithdrawalQueue public withdrawalQueue;

    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    ValueLteEnforcer public valueLteEnforcer;
    ERC20TransferAmountEnforcer public erc20TransferAmountEnforcer;
    LogicalOrWrapperEnforcer public logicalOrWrapperEnforcer;

    TestUser public alice;
    TestUser public bob;

    uint256 public constant DEPOSIT_AMOUNT = 1 ether;
    uint256 public constant MAX_FEE_RATE = 0;
    // uint256 public constant MAX_FEE_RATE = 1000; // 10% in basis points * 10

    // Group indices for different liquid staking operations
    uint256 private constant LIDO_DEPOSIT_GROUP = 0;
    uint256 private constant ROCKETPOOL_DEPOSIT_GROUP = 1;
    uint256 private constant LIDO_WITHDRAWAL_REQUEST_GROUP = 2;
    uint256 private constant LIDO_WITHDRAWAL_CLAIM_GROUP = 3;
    uint256 private constant ROCKETPOOL_WITHDRAWAL_GROUP = 4;

    //////////////////////// Setup ////////////////////////

    function setUpContracts() public {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;

        super.setUp();

        // Set up contract interfaces
        liquidStaking = ILiquidStakingAggregator(LIQUID_STAKING_AGGREGATOR);
        stETH = IstETH(STETH_ADDRESS);
        rETH = IrETH(RETH_ADDRESS);
        withdrawalQueue = IWithdrawalQueue(LIDO_WITHDRAWAL_QUEUE);

        // Deploy enforcers
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        valueLteEnforcer = new ValueLteEnforcer();
        erc20TransferAmountEnforcer = new ERC20TransferAmountEnforcer();
        logicalOrWrapperEnforcer = new LogicalOrWrapperEnforcer(delegationManager);

        vm.label(address(allowedTargetsEnforcer), "AllowedTargetsEnforcer");
        vm.label(address(allowedMethodsEnforcer), "AllowedMethodsEnforcer");
        vm.label(address(valueLteEnforcer), "ValueLteEnforcer");
        vm.label(address(erc20TransferAmountEnforcer), "ERC20TransferAmountEnforcer");
        vm.label(address(logicalOrWrapperEnforcer), "LogicalOrWrapperEnforcer");
        vm.label(address(LIQUID_STAKING_AGGREGATOR), "Liquid Staking Aggregator");
        vm.label(STETH_ADDRESS, "stETH");
        vm.label(RETH_ADDRESS, "rETH");
        vm.label(LIDO_WITHDRAWAL_QUEUE, "Lido Withdrawal Queue");

        // Set up test users with ETH
        alice = users.alice;
        bob = users.bob;

        vm.deal(address(alice.deleGator), 100 ether);
        vm.deal(address(bob.deleGator), 100 ether);
    }

    //////////////////////// Direct Interaction Tests ////////////////////////

    function test_depositToLido_direct() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22791160);
        setUpContracts();

        uint256 initialBalance_ = address(alice.deleGator).balance;
        uint256 initialStETHBalance_ = stETH.balanceOf(address(alice.deleGator));

        vm.prank(address(alice.deleGator));
        liquidStaking.depositToLido{ value: DEPOSIT_AMOUNT }(MAX_FEE_RATE);

        // Check ETH was deducted
        assertEq(address(alice.deleGator).balance, initialBalance_ - DEPOSIT_AMOUNT);

        // Check stETH was received (approximately equal due to fees and exchange rate)
        uint256 finalStETHBalance_ = stETH.balanceOf(address(alice.deleGator));
        assertGt(finalStETHBalance_, initialStETHBalance_);
        assertApproxEqRel(finalStETHBalance_, DEPOSIT_AMOUNT, 0.05e18); // 5% tolerance for fees
    }

    function test_depositToRocketPool_direct() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22791160);
        setUpContracts();

        uint256 initialBalance_ = address(alice.deleGator).balance;
        uint256 initialRETHBalance_ = rETH.balanceOf(address(alice.deleGator));

        vm.prank(address(alice.deleGator));
        liquidStaking.depositToRP{ value: DEPOSIT_AMOUNT }(MAX_FEE_RATE);

        // Check ETH was deducted
        assertEq(address(alice.deleGator).balance, initialBalance_ - DEPOSIT_AMOUNT);

        // Check rETH was received
        uint256 finalRETHBalance_ = rETH.balanceOf(address(alice.deleGator));
        assertGt(finalRETHBalance_, initialRETHBalance_);

        // rETH is repricing token, so amount received will be less than 1:1
        assertLt(finalRETHBalance_, DEPOSIT_AMOUNT);
        assertGt(finalRETHBalance_, 0);
    }

    //////////////////////// Withdrawal Tests ////////////////////////

    /// @notice Test Lido withdrawal request creation
    /// @dev This tests the withdrawal request creation process including NFT minting
    function test_lidoWithdrawalRequest_direct() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22791044);
        setUpContracts();

        uint256 stETHBalance_ = stETH.balanceOf(LIDO_WITHDRAWAL_REQUESTER_ADDRESS);
        assertGt(stETHBalance_, 0, "LIDO_WITHDRAWAL_REQUESTER_ADDRESS should have stETH balance");

        // Request withdrawal (using Lido's withdrawal queue)
        uint256[] memory amounts_ = new uint256[](1);
        amounts_[0] = 1000 ether;
        address _owner = LIDO_WITHDRAWAL_REQUESTER_ADDRESS;
        IWithdrawalQueue.PermitInput memory permit_ = IWithdrawalQueue.PermitInput({
            value: 1000 ether,
            deadline: 1751056511,
            v: 28,
            r: 0x1ba4bbbaad41d68132e71af04cf876db76b8459e555e41c368f6389d951a5990,
            s: 0x635830efd45ef7057e5ef4b95b9e7c23db9893c04bf2928b11aea51a699d2483
        });

        vm.prank(LIDO_WITHDRAWAL_REQUESTER_ADDRESS);
        uint256[] memory requestIds_ = withdrawalQueue.requestWithdrawalsWithPermit(amounts_, _owner, permit_);

        assertEq(requestIds_.length, 1, "Should return exactly one request ID");
        assertEq(requestIds_[0], 84433, "Request ID mismatch");

        IWithdrawalQueue.WithdrawalRequestStatus[] memory statuses_ = withdrawalQueue.getWithdrawalStatus(requestIds_);
        assertEq(statuses_[0].amountOfStETH, 1000 ether, "stETH amount mismatch");
        assertGt(statuses_[0].amountOfShares, 0, "shares amount mismatch");
        assertEq(statuses_[0].owner, LIDO_WITHDRAWAL_REQUESTER_ADDRESS, "owner address mismatch");
        assertEq(statuses_[0].timestamp, block.timestamp, "timestamp mismatch");
        assertEq(statuses_[0].isFinalized, false, "withdrawal should not be finalized");
        assertEq(statuses_[0].isClaimed, false, "withdrawal should not be claimed");
    }

    /// @notice Test Lido withdrawal completion
    /// @dev This tests the actual withdrawal process after being in the queue
    function test_lidoWithdrawalCompletion_direct() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22791243);
        setUpContracts();

        // Simulate user having a withdrawal request that's ready to be claimed
        uint256[] memory requestIds_ = new uint256[](1);
        requestIds_[0] = 68185; // Known finalized request ID

        // Get withdrawal status to verify it's ready
        IWithdrawalQueue.WithdrawalRequestStatus[] memory statuses_ = withdrawalQueue.getWithdrawalStatus(requestIds_);
        assertEq(statuses_[0].isFinalized, true, "Withdrawal should be finalized");
        assertEq(statuses_[0].isClaimed, false, "Withdrawal should not be claimed yet");
        assertGt(statuses_[0].amountOfStETH, 0, "Should have stETH to withdraw");

        uint256 initialETHBalance_ = LIDO_WITHDRAWAL_CLAIMER_ADDRESS.balance;

        // Calculate hints for efficient withdrawal (in practice, this would come from an oracle)
        uint256[] memory hints_ = new uint256[](1);
        hints_[0] = 618; // Simplified hint for testing

        // Execute the withdrawal claim
        vm.prank(LIDO_WITHDRAWAL_CLAIMER_ADDRESS);
        withdrawalQueue.claimWithdrawals(requestIds_, hints_);

        // Verify ETH was received
        uint256 finalETHBalance_ = LIDO_WITHDRAWAL_CLAIMER_ADDRESS.balance;
        assertGt(finalETHBalance_, initialETHBalance_, "Should receive ETH from withdrawal");

        // Verify the withdrawal is now marked as claimed
        statuses_ = withdrawalQueue.getWithdrawalStatus(requestIds_);
        assertEq(statuses_[0].isClaimed, true, "Withdrawal should be marked as claimed");
    }

    /// @notice Test Rocket Pool rETH burning (direct redemption when possible)
    function test_rocketPoolWithdrawal_direct() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22783949);
        setUpContracts();

        address burner_ = ROCKET_POOL_WITHDRAWAL_BURNER_ADDRESS;
        uint256 rETHBalanceBefore_ = rETH.balanceOf(burner_);
        assertGt(rETHBalanceBefore_, 0);

        uint256 initialETHBalance_ = burner_.balance;
        uint256 burnAmount_ = 411000000000000000;

        vm.prank(burner_);
        rETH.burn(burnAmount_);

        assertGt(burner_.balance, initialETHBalance_, "ETH balance should increase after burning");
        assertEq(rETH.balanceOf(burner_), rETHBalanceBefore_ - burnAmount_, "rETH balance should decrease by burn amount");
    }

    //////////////////////// Delegation Tests ////////////////////////

    /**
     * @notice Test Lido deposit via delegation from Alice to Bob
     * @dev Uses exact value and allowed targets to ensure ETH can only be deposited to Lido with specified fee rate
     */
    function test_depositToLido_viaDelegation() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22791160);
        setUpContracts();

        uint256 initialStETHBalance_ = stETH.balanceOf(address(alice.deleGator));

        // Create caveat groups for Lido deposit operations
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = _createLiquidStakingCaveatGroups(LIDO_DEPOSIT_GROUP);

        // Create selected group for Lido deposit operations
        bytes[] memory caveatArgs_ = new bytes[](3);
        caveatArgs_[0] = hex""; // No args for allowedTargetsEnforcer
        caveatArgs_[1] = abi.encode(DEPOSIT_AMOUNT); // Value enforcer for exact ETH amount
        caveatArgs_[2] = hex""; // No args for allowedMethodsEnforcer
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ =
            LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: LIDO_DEPOSIT_GROUP, caveatArgs: caveatArgs_ });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: abi.encode(selectedGroup_), enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        Delegation memory delegation_ = Delegation({
            delegate: address(bob.deleGator),
            delegator: address(alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(alice, delegation_);

        Execution memory execution_ = Execution({
            target: address(liquidStaking),
            value: DEPOSIT_AMOUNT,
            callData: abi.encodeWithSelector(ILiquidStakingAggregator.depositToLido.selector, MAX_FEE_RATE)
        });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(bob, delegations_, execution_);

        uint256 finalStETHBalance_ = stETH.balanceOf(address(alice.deleGator));
        assertGt(finalStETHBalance_, initialStETHBalance_, "stETH balance should have increased after delegation");
        assertApproxEqRel(finalStETHBalance_, DEPOSIT_AMOUNT, 0.05e18); // 5% tolerance for fees
    }

    /**
     * @notice Test Rocket Pool deposit via delegation from Alice to Bob
     * @dev Uses exact value and allowed targets to ensure ETH can only be deposited to Rocket Pool with specified fee rate
     */
    function test_depositToRocketPool_viaDelegation() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22791160);
        setUpContracts();

        uint256 initialRETHBalance_ = rETH.balanceOf(address(alice.deleGator));

        // Create caveat groups for Rocket Pool deposit operations
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = _createLiquidStakingCaveatGroups(ROCKETPOOL_DEPOSIT_GROUP);

        // Create selected group for Rocket Pool deposit operations
        bytes[] memory caveatArgs_ = new bytes[](3);
        caveatArgs_[0] = hex""; // No args for allowedTargetsEnforcer
        caveatArgs_[1] = abi.encode(DEPOSIT_AMOUNT); // Value enforcer for exact ETH amount
        caveatArgs_[2] = hex""; // No args for allowedMethodsEnforcer
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ =
            LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: ROCKETPOOL_DEPOSIT_GROUP, caveatArgs: caveatArgs_ });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: abi.encode(selectedGroup_), enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        Delegation memory delegation_ = Delegation({
            delegate: address(bob.deleGator),
            delegator: address(alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(alice, delegation_);

        Execution memory execution_ = Execution({
            target: address(liquidStaking),
            value: DEPOSIT_AMOUNT,
            callData: abi.encodeWithSelector(ILiquidStakingAggregator.depositToRP.selector, MAX_FEE_RATE)
        });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(bob, delegations_, execution_);

        uint256 finalRETHBalance_ = rETH.balanceOf(address(alice.deleGator));
        assertGt(finalRETHBalance_, initialRETHBalance_, "rETH balance should have increased after delegation");
        assertLt(finalRETHBalance_, DEPOSIT_AMOUNT, "rETH received should be less than 1:1 due to repricing");
        assertGt(finalRETHBalance_, 0, "Should receive some rETH");
    }

    /**
     * @notice Test Lido withdrawal request via delegation using real mainnet address
     * @dev The withdrawal queue automatically handles token flows and request ownership. Uses vm.prank with a real address
     * that historically had stETH at this block number.
     */
    function test_lidoWithdrawalRequest_viaDelegation() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22791044);
        setUpContracts();

        _assignImplementationAndVerify(LIDO_WITHDRAWAL_REQUESTER_ADDRESS);

        uint256 stETHBalance = stETH.balanceOf(LIDO_WITHDRAWAL_REQUESTER_ADDRESS);
        assertGt(stETHBalance, 0, "LIDO_WITHDRAWAL_REQUESTER_ADDRESS should have stETH balance");

        // Create caveat groups for Lido withdrawal request operations
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = _createLiquidStakingCaveatGroups(LIDO_WITHDRAWAL_REQUEST_GROUP);

        // Create selected group for withdrawal request operations
        bytes[] memory caveatArgs_ = new bytes[](3);
        caveatArgs_[0] = hex""; // No args for allowedTargetsEnforcer
        caveatArgs_[1] = hex""; // No args for allowedMethodsEnforcer
        caveatArgs_[2] = hex""; // No args for valueLteEnforcer
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ =
            LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: LIDO_WITHDRAWAL_REQUEST_GROUP, caveatArgs: caveatArgs_ });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: abi.encode(selectedGroup_), enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        Delegation memory delegation_ = Delegation({
            delegate: address(bob.deleGator),
            delegator: LIDO_WITHDRAWAL_REQUESTER_ADDRESS,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = _mockSignDelegation(delegation_);

        uint256[] memory amounts_ = new uint256[](1);
        amounts_[0] = 1000 ether;
        address _owner = LIDO_WITHDRAWAL_REQUESTER_ADDRESS;
        IWithdrawalQueue.PermitInput memory permit_ = IWithdrawalQueue.PermitInput({
            value: 1000 ether,
            deadline: 1751056511,
            v: 28,
            r: 0x1ba4bbbaad41d68132e71af04cf876db76b8459e555e41c368f6389d951a5990,
            s: 0x635830efd45ef7057e5ef4b95b9e7c23db9893c04bf2928b11aea51a699d2483
        });

        Execution memory execution_ = Execution({
            target: LIDO_WITHDRAWAL_QUEUE,
            value: 0,
            callData: abi.encodeWithSelector(IWithdrawalQueue.requestWithdrawalsWithPermit.selector, amounts_, _owner, permit_)
        });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(bob, delegations_, execution_);

        // Verify withdrawal request was created
        uint256[] memory requestIds_ = withdrawalQueue.getWithdrawalRequests(LIDO_WITHDRAWAL_REQUESTER_ADDRESS);
        assertGt(requestIds_.length, 0, "Should have at least one withdrawal request");
    }

    /**
     * @notice Test Lido withdrawal claim via delegation using real mainnet address
     * @dev The withdrawal queue automatically sends claimed ETH to msg.sender (root delegator). Uses vm.prank with a real address
     * that historically had claimable requests at this block number.
     */
    function test_lidoWithdrawalCompletion_viaDelegation() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22791243);
        setUpContracts();

        _assignImplementationAndVerify(LIDO_WITHDRAWAL_CLAIMER_ADDRESS);

        uint256 initialETHBalance_ = LIDO_WITHDRAWAL_CLAIMER_ADDRESS.balance;

        // Create caveat groups for Lido withdrawal claim operations
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = _createLiquidStakingCaveatGroups(LIDO_WITHDRAWAL_CLAIM_GROUP);

        // Create selected group for withdrawal claim operations
        bytes[] memory caveatArgs_ = new bytes[](3);
        caveatArgs_[0] = hex""; // No args for allowedTargetsEnforcer
        caveatArgs_[1] = hex""; // No args for valueLteEnforcer
        caveatArgs_[2] = hex""; // No args for allowedMethodsEnforcer
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ =
            LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: LIDO_WITHDRAWAL_CLAIM_GROUP, caveatArgs: caveatArgs_ });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: abi.encode(selectedGroup_), enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        Delegation memory delegation_ = Delegation({
            delegate: address(bob.deleGator),
            delegator: LIDO_WITHDRAWAL_CLAIMER_ADDRESS,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = _mockSignDelegation(delegation_);

        uint256[] memory requestIds_ = new uint256[](1);
        requestIds_[0] = 68185; // Known finalized request ID
        uint256[] memory hints_ = new uint256[](1);
        hints_[0] = 618; // Simplified hint for testing

        Execution memory execution_ = Execution({
            target: LIDO_WITHDRAWAL_QUEUE,
            value: 0,
            callData: abi.encodeWithSelector(IWithdrawalQueue.claimWithdrawals.selector, requestIds_, hints_)
        });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(bob, delegations_, execution_);

        uint256 finalETHBalance_ = LIDO_WITHDRAWAL_CLAIMER_ADDRESS.balance;
        assertGt(finalETHBalance_, initialETHBalance_, "ETH balance should have increased after withdrawal claim");
    }

    /**
     * @notice Test Rocket Pool withdrawal via delegation using real mainnet address
     * @dev The rETH contract automatically sends ETH to msg.sender (root delegator). Uses vm.prank with a real address
     * that historically had rETH at this block number.
     */
    function test_rocketPoolWithdrawal_viaDelegation() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22783949);
        setUpContracts();

        _assignImplementationAndVerify(ROCKET_POOL_WITHDRAWAL_BURNER_ADDRESS);

        uint256 initialETHBalance_ = ROCKET_POOL_WITHDRAWAL_BURNER_ADDRESS.balance;
        uint256 rETHBalanceBefore_ = rETH.balanceOf(ROCKET_POOL_WITHDRAWAL_BURNER_ADDRESS);
        assertGt(rETHBalanceBefore_, 0, "Should have rETH to burn");

        // Create caveat groups for Rocket Pool withdrawal operations
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = _createLiquidStakingCaveatGroups(ROCKETPOOL_WITHDRAWAL_GROUP);

        // Create selected group for withdrawal operations
        bytes[] memory caveatArgs_ = new bytes[](3);
        caveatArgs_[0] = hex""; // No args for allowedTargetsEnforcer
        caveatArgs_[1] = hex""; // No args for valueLteEnforcer
        caveatArgs_[2] = hex""; // No args for allowedMethodsEnforcer
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ =
            LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: ROCKETPOOL_WITHDRAWAL_GROUP, caveatArgs: caveatArgs_ });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: abi.encode(selectedGroup_), enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        Delegation memory delegation_ = Delegation({
            delegate: address(bob.deleGator),
            delegator: ROCKET_POOL_WITHDRAWAL_BURNER_ADDRESS,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = _mockSignDelegation(delegation_);

        uint256 burnAmount_ = 411000000000000000;

        Execution memory execution_ =
            Execution({ target: RETH_ADDRESS, value: 0, callData: abi.encodeWithSelector(IrETH.burn.selector, burnAmount_) });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(bob, delegations_, execution_);

        uint256 finalETHBalance_ = ROCKET_POOL_WITHDRAWAL_BURNER_ADDRESS.balance;
        uint256 finalRETHBalance_ = rETH.balanceOf(ROCKET_POOL_WITHDRAWAL_BURNER_ADDRESS);

        assertGt(finalETHBalance_, initialETHBalance_, "ETH balance should increase after burning");
        assertEq(finalRETHBalance_, rETHBalanceBefore_ - burnAmount_, "rETH balance should decrease by burn amount");
    }

    /**
     * @notice Test Lido withdrawal request via LiquidStakingAdapter using delegation
     * @dev Tests the LiquidStakingAdapter.requestWithdrawalsByDelegation function with real mainnet address
     * that historically had stETH at this block number. Creates two delegations: one for stETH transfer
     * and another for calling the adapter function.
     */
    function test_liquidStakingAdapter_requestWithdrawalsByDelegation() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22791044);
        setUpContracts();

        _assignImplementationAndVerify(LIDO_WITHDRAWAL_REQUESTER_ADDRESS);

        LiquidStakingAdapter liquidStakingAdapter_ = new LiquidStakingAdapter(
            address(alice.deleGator), // owner
            address(delegationManager),
            LIDO_WITHDRAWAL_QUEUE,
            STETH_ADDRESS
        );

        uint256 initialStETHBalance_ = stETH.balanceOf(LIDO_WITHDRAWAL_REQUESTER_ADDRESS);
        assertGt(initialStETHBalance_, 0, "LIDO_WITHDRAWAL_REQUESTER_ADDRESS should have stETH balance");

        uint256 withdrawalAmount_ = 1000 ether;

        Delegation memory stETHTransferDelegation_ =
            _createStETHTransferDelegation(LIDO_WITHDRAWAL_REQUESTER_ADDRESS, address(liquidStakingAdapter_));

        Delegation memory adapterDelegation_ = _createAdapterMethodDelegation(
            address(bob.deleGator),
            LIDO_WITHDRAWAL_REQUESTER_ADDRESS,
            address(liquidStakingAdapter_),
            1 // Different salt
        );

        Delegation[] memory stETHDelegations_ = new Delegation[](1);
        stETHDelegations_[0] = stETHTransferDelegation_;

        uint256[] memory amounts_ = new uint256[](1);
        amounts_[0] = withdrawalAmount_;

        Execution memory execution_ = Execution({
            target: address(liquidStakingAdapter_),
            value: 0,
            callData: abi.encodeWithSelector(LiquidStakingAdapter.requestWithdrawalsByDelegation.selector, stETHDelegations_, amounts_)
        });

        Delegation[] memory adapterDelegations_ = new Delegation[](1);
        adapterDelegations_[0] = adapterDelegation_;

        uint256 stETHBalanceBeforeExecution_ = stETH.balanceOf(LIDO_WITHDRAWAL_REQUESTER_ADDRESS);

        invokeDelegation_UserOp(bob, adapterDelegations_, execution_);

        assertEq(
            stETH.balanceOf(LIDO_WITHDRAWAL_REQUESTER_ADDRESS),
            stETHBalanceBeforeExecution_ - withdrawalAmount_,
            "stETH should be transferred from delegator"
        );

        assertEq(stETH.balanceOf(address(liquidStakingAdapter_)), 0, "Adapter should not hold stETH after withdrawal request");

        uint256[] memory requestIds_ = withdrawalQueue.getWithdrawalRequests(LIDO_WITHDRAWAL_REQUESTER_ADDRESS);
        assertGt(requestIds_.length, 0, "Should have at least one withdrawal request");

        IWithdrawalQueue.WithdrawalRequestStatus[] memory statuses_ = withdrawalQueue.getWithdrawalStatus(requestIds_);
        uint256 latestIndex_ = statuses_.length - 1;

        assertEq(statuses_[latestIndex_].amountOfStETH, withdrawalAmount_, "Withdrawal amount should match");
        assertEq(
            statuses_[latestIndex_].owner, LIDO_WITHDRAWAL_REQUESTER_ADDRESS, "Original delegator should own the withdrawal request"
        );
        assertEq(statuses_[latestIndex_].isFinalized, false, "Withdrawal should not be finalized yet");
        assertEq(statuses_[latestIndex_].isClaimed, false, "Withdrawal should not be claimed yet");
    }

    /**
     * @notice Test LiquidStakingAdapter custom errors
     */
    function test_liquidStakingAdapter_errors() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22791044);
        setUpContracts();

        vm.expectRevert(LiquidStakingAdapter.InvalidZeroAddress.selector);
        new LiquidStakingAdapter(address(alice.deleGator), address(0), LIDO_WITHDRAWAL_QUEUE, STETH_ADDRESS);

        vm.expectRevert(LiquidStakingAdapter.InvalidZeroAddress.selector);
        new LiquidStakingAdapter(address(alice.deleGator), address(delegationManager), address(0), STETH_ADDRESS);

        vm.expectRevert(LiquidStakingAdapter.InvalidZeroAddress.selector);
        new LiquidStakingAdapter(address(alice.deleGator), address(delegationManager), LIDO_WITHDRAWAL_QUEUE, address(0));

        // Deploy valid adapter for further testing
        LiquidStakingAdapter liquidStakingAdapter_ =
            new LiquidStakingAdapter(address(alice.deleGator), address(delegationManager), LIDO_WITHDRAWAL_QUEUE, STETH_ADDRESS);

        // Test WrongNumberOfDelegations error
        Delegation[] memory emptyDelegations_ = new Delegation[](0);
        uint256[] memory amounts_ = new uint256[](1);
        amounts_[0] = 100 ether;

        vm.expectRevert(LiquidStakingAdapter.WrongNumberOfDelegations.selector);
        liquidStakingAdapter_.requestWithdrawalsByDelegation(emptyDelegations_, amounts_);

        Delegation[] memory tooManyDelegations_ = new Delegation[](2);
        vm.expectRevert(LiquidStakingAdapter.WrongNumberOfDelegations.selector);
        liquidStakingAdapter_.requestWithdrawalsByDelegation(tooManyDelegations_, amounts_);

        // Test NoAmountsSpecified error
        Delegation[] memory singleDelegation_ = new Delegation[](1);
        uint256[] memory emptyAmounts_ = new uint256[](0);

        vm.expectRevert(LiquidStakingAdapter.NoAmountsSpecified.selector);
        liquidStakingAdapter_.requestWithdrawalsByDelegation(singleDelegation_, emptyAmounts_);
    }

    /**
     * @notice Test LiquidStakingAdapter withdraw function
     */
    function test_liquidStakingAdapter_withdraw() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22791044);
        setUpContracts();

        LiquidStakingAdapter liquidStakingAdapter_ =
            new LiquidStakingAdapter(address(alice.deleGator), address(delegationManager), LIDO_WITHDRAWAL_QUEUE, STETH_ADDRESS);

        uint256 testAmount_ = 10 ether;
        BasicERC20 basicERC20_ = new BasicERC20(address(liquidStakingAdapter_), "stETH", "stETH", testAmount_);
        console2.log("basicERC20", address(basicERC20_));
        // deal(address(basicERC20_), address(liquidStakingAdapter_), testAmount_);

        // Test onlyOwner modifier - should fail when called by non-owner
        vm.prank(address(bob.deleGator));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(bob.deleGator)));
        liquidStakingAdapter_.withdraw(IERC20(address(basicERC20_)), 0, address(bob.deleGator));

        uint256 adapterBalance_ = basicERC20_.balanceOf(address(liquidStakingAdapter_));

        // Test ERC20 token withdrawal (as owner)
        uint256 bobInitialBalance_ = basicERC20_.balanceOf(address(bob.deleGator));

        vm.prank(address(alice.deleGator));
        liquidStakingAdapter_.withdraw(IERC20(address(basicERC20_)), adapterBalance_, address(bob.deleGator));

        assertEq(basicERC20_.balanceOf(address(liquidStakingAdapter_)), 0, "Adapter should have no basicERC20 after withdrawal");
        assertEq(
            basicERC20_.balanceOf(address(bob.deleGator)),
            bobInitialBalance_ + adapterBalance_,
            "Bob should receive withdrawn basicERC20"
        );

        // Test native ETH withdrawal
        uint256 ethAmount_ = 5 ether;
        vm.deal(address(liquidStakingAdapter_), ethAmount_);

        uint256 bobInitialETHBalance_ = address(bob.deleGator).balance;

        vm.prank(address(alice.deleGator));
        liquidStakingAdapter_.withdraw(IERC20(address(0)), ethAmount_, address(bob.deleGator));

        assertEq(address(liquidStakingAdapter_).balance, 0, "Adapter should have no ETH after withdrawal");
        assertEq(address(bob.deleGator).balance, bobInitialETHBalance_ + ethAmount_, "Bob should receive withdrawn ETH");
    }

    /**
     * @notice Test native token transfer failure
     */
    function test_liquidStakingAdapter_withdraw_nativeTokenTransferFailure() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22791044);
        setUpContracts();

        LiquidStakingAdapter liquidStakingAdapter_ =
            new LiquidStakingAdapter(address(alice.deleGator), address(delegationManager), LIDO_WITHDRAWAL_QUEUE, STETH_ADDRESS);

        // Deploy a contract that rejects ETH
        RejectETH rejectETH_ = new RejectETH();

        uint256 ethAmount_ = 1 ether;
        vm.deal(address(liquidStakingAdapter_), ethAmount_);

        // Should fail when trying to send ETH to a contract that rejects it
        vm.prank(address(alice.deleGator));
        vm.expectRevert(abi.encodeWithSelector(LiquidStakingAdapter.FailedNativeTokenTransfer.selector, address(rejectETH_)));
        liquidStakingAdapter_.withdraw(IERC20(address(0)), ethAmount_, address(rejectETH_));
    }

    /**
     * @notice Test requestWithdrawalsWithPermitByDelegation function
     */
    // function test_liquidStakingAdapter_requestWithdrawalsWithPermitByDelegation() public {
    //     vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22791044);
    //     setUpContracts();

    //     LiquidStakingAdapter liquidStakingAdapter =
    //         new LiquidStakingAdapter(address(alice.deleGator), address(delegationManager), LIDO_WITHDRAWAL_QUEUE, STETH_ADDRESS);

    //     // Give Alice some stETH
    //     uint256 testAmount = 500 ether;
    //     vm.deal(address(alice.deleGator), 100 ether);

    //     // Get stETH by depositing to Lido
    //     vm.prank(address(alice.deleGator));
    //     (bool success,) = STETH_ADDRESS.call{ value: testAmount }("");
    //     require(success, "Failed to get stETH");

    //     uint256 aliceStETHBalance = stETH.balanceOf(address(alice.deleGator));
    //     uint256 withdrawalAmount = 100 ether;
    //     require(aliceStETHBalance >= withdrawalAmount, "Alice should have enough stETH");

    //     // Create permit signature (using dummy values for testing)
    //     IWithdrawalQueue.PermitInput memory permit = IWithdrawalQueue.PermitInput({
    //         value: withdrawalAmount,
    //         deadline: block.timestamp + 1 hours,
    //         v: 27,
    //         r: bytes32(uint256(1)),
    //         s: bytes32(uint256(2))
    //     });

    //     uint256[] memory amounts = new uint256[](1);
    //     amounts[0] = withdrawalAmount;

    //     // Mock the permit call since we can't generate real permit signatures in tests
    //     vm.mockCall(
    //         STETH_ADDRESS,
    //         abi.encodeWithSelector(
    //             IERC20Permit.permit.selector,
    //             address(alice.deleGator),
    //             address(liquidStakingAdapter),
    //             permit.value,
    //             permit.deadline,
    //             permit.v,
    //             permit.r,
    //             permit.s
    //         ),
    //         ""
    //     );

    //     uint256 aliceInitialBalance = stETH.balanceOf(address(alice.deleGator));

    //     // Call the permit-based function
    //     vm.prank(address(alice.deleGator));
    //     uint256[] memory requestIds = liquidStakingAdapter.requestWithdrawalsWithPermitByDelegation(amounts, permit);

    //     // Verify withdrawal request was created
    //     assertGt(requestIds.length, 0, "Should create withdrawal requests");

    //     // Check that stETH was transferred (adapter should not hold any)
    //     assertEq(stETH.balanceOf(address(liquidStakingAdapter)), 0, "Adapter should not hold stETH after withdrawal request");

    //     // Verify Alice's stETH balance decreased
    //     assertLt(stETH.balanceOf(address(alice.deleGator)), aliceInitialBalance, "Alice's stETH balance should decrease");
    // }

    ////////////////////// Helper Functions //////////////////////

    /**
     * @notice Creates a delegation for stETH transfers from delegator to adapter
     * @param _delegator The address that will delegate stETH transfer rights
     * @param _adapterAddress The address of the LiquidStakingAdapter contract
     * @return stETHTransferDelegation_ The signed delegation for stETH transfers
     */
    function _createStETHTransferDelegation(
        address _delegator,
        address _adapterAddress
    )
        internal
        returns (Delegation memory stETHTransferDelegation_)
    {
        // Create adapter-specific caveat groups
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = _createAdapterCaveatGroups(_adapterAddress);

        // Create selected group for stETH transfer operations (group 0)
        bytes[] memory transferCaveatArgs_ = new bytes[](2);
        transferCaveatArgs_[0] = hex""; // No args for allowedTargetsEnforcer
        transferCaveatArgs_[1] = hex""; // No args for erc20TransferAmountEnforcer
        LogicalOrWrapperEnforcer.SelectedGroup memory stETHTransferGroup_ =
            LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: 0, caveatArgs: transferCaveatArgs_ });

        Caveat[] memory transferCaveats_ = new Caveat[](1);
        transferCaveats_[0] = Caveat({
            args: abi.encode(stETHTransferGroup_),
            enforcer: address(logicalOrWrapperEnforcer),
            terms: abi.encode(groups_)
        });

        stETHTransferDelegation_ = Delegation({
            delegate: _adapterAddress,
            delegator: _delegator,
            authority: ROOT_AUTHORITY,
            caveats: transferCaveats_,
            salt: 0,
            signature: hex""
        });

        stETHTransferDelegation_ = _mockSignDelegation(stETHTransferDelegation_);
    }

    /**
     * @notice Creates a delegation for calling adapter methods
     * @param _delegate The address that will be allowed to call adapter methods
     * @param _delegator The address that owns the adapter (delegator)
     * @param _adapterAddress The address of the LiquidStakingAdapter contract
     * @param _salt The salt for the delegation (to avoid collisions)
     * @return adapterDelegation_ The signed delegation for adapter method calls
     */
    function _createAdapterMethodDelegation(
        address _delegate,
        address _delegator,
        address _adapterAddress,
        uint256 _salt
    )
        internal
        returns (Delegation memory adapterDelegation_)
    {
        // Create adapter-specific caveat groups
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = _createAdapterCaveatGroups(_adapterAddress);

        // Create selected group for adapter method calls (group 1)
        bytes[] memory adapterCaveatArgs_ = new bytes[](2);
        adapterCaveatArgs_[0] = hex""; // No args for allowedTargetsEnforcer
        adapterCaveatArgs_[1] = hex""; // No args for allowedMethodsEnforcer
        LogicalOrWrapperEnforcer.SelectedGroup memory adapterCallGroup_ =
            LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: 1, caveatArgs: adapterCaveatArgs_ });

        Caveat[] memory adapterCaveats_ = new Caveat[](1);
        adapterCaveats_[0] =
            Caveat({ args: abi.encode(adapterCallGroup_), enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        adapterDelegation_ = Delegation({
            delegate: _delegate,
            delegator: _delegator,
            authority: ROOT_AUTHORITY,
            caveats: adapterCaveats_,
            salt: _salt,
            signature: hex""
        });

        adapterDelegation_ = _mockSignDelegation(adapterDelegation_);
    }

    /**
     * @notice Creates caveat groups for different liquid staking operations
     * @param _groupIndex The group index (0=lidoDeposit, 1=rocketPoolDeposit, 2=lidoWithdrawalRequest, 3=lidoWithdrawalClaim,
     * 4=rocketPoolWithdrawal)
     * @return groups_ Array of caveat groups
     */
    function _createLiquidStakingCaveatGroups(uint256 _groupIndex)
        internal
        view
        returns (LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_)
    {
        require(_groupIndex <= 4, "Invalid group index");

        groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](5);

        // Group 0: Lido deposit operations
        {
            Caveat[] memory lidoDepositCaveats_ = new Caveat[](3);
            lidoDepositCaveats_[0] =
                Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(liquidStaking)) });
            lidoDepositCaveats_[1] = Caveat({
                args: hex"",
                enforcer: address(valueLteEnforcer),
                terms: abi.encode(uint256(type(uint256).max)) // Allow any ETH value for flexibility
             });
            lidoDepositCaveats_[2] = Caveat({
                args: hex"",
                enforcer: address(allowedMethodsEnforcer),
                terms: abi.encodePacked(ILiquidStakingAggregator.depositToLido.selector)
            });
            groups_[0] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: lidoDepositCaveats_ });
        }

        // Group 1: Rocket Pool deposit operations
        {
            Caveat[] memory rpDepositCaveats = new Caveat[](3);
            rpDepositCaveats[0] =
                Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(liquidStaking)) });
            rpDepositCaveats[1] = Caveat({
                args: hex"",
                enforcer: address(valueLteEnforcer),
                terms: abi.encode(uint256(type(uint256).max)) // Allow any ETH value for flexibility
             });
            rpDepositCaveats[2] = Caveat({
                args: hex"",
                enforcer: address(allowedMethodsEnforcer),
                terms: abi.encodePacked(ILiquidStakingAggregator.depositToRP.selector)
            });
            groups_[1] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: rpDepositCaveats });
        }

        // Group 2: Lido withdrawal request operations
        {
            Caveat[] memory lidoRequestCaveats = new Caveat[](3);
            lidoRequestCaveats[0] =
                Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(LIDO_WITHDRAWAL_QUEUE) });
            lidoRequestCaveats[1] = Caveat({
                args: hex"",
                enforcer: address(allowedMethodsEnforcer),
                terms: abi.encodePacked(IWithdrawalQueue.requestWithdrawalsWithPermit.selector)
            });
            lidoRequestCaveats[2] = Caveat({
                args: hex"",
                enforcer: address(valueLteEnforcer),
                terms: abi.encode(uint256(0)) // No ETH value for requestWithdrawalsWithPermit
             });
            groups_[2] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: lidoRequestCaveats });
        }

        // Group 3: Lido withdrawal claim operations
        {
            Caveat[] memory lidoClaimCaveats = new Caveat[](3);
            lidoClaimCaveats[0] =
                Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(LIDO_WITHDRAWAL_QUEUE) });
            lidoClaimCaveats[1] = Caveat({
                args: hex"",
                enforcer: address(valueLteEnforcer),
                terms: abi.encode(uint256(0)) // No ETH value for claims
             });
            lidoClaimCaveats[2] = Caveat({
                args: hex"",
                enforcer: address(allowedMethodsEnforcer),
                terms: abi.encodePacked(IWithdrawalQueue.claimWithdrawals.selector)
            });
            groups_[3] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: lidoClaimCaveats });
        }

        // Group 4: Rocket Pool withdrawal operations
        {
            Caveat[] memory rpWithdrawalCaveats = new Caveat[](3);
            rpWithdrawalCaveats[0] =
                Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(RETH_ADDRESS) });
            rpWithdrawalCaveats[1] = Caveat({
                args: hex"",
                enforcer: address(valueLteEnforcer),
                terms: abi.encode(uint256(0)) // No ETH value for burns
             });
            rpWithdrawalCaveats[2] =
                Caveat({ args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(IrETH.burn.selector) });
            groups_[4] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: rpWithdrawalCaveats });
        }
    }

    /**
     * @notice Creates caveat groups for LiquidStakingAdapter operations
     * @param _adapterAddress The address of the LiquidStakingAdapter contract
     * @return groups_ Array of caveat groups for adapter operations
     */
    function _createAdapterCaveatGroups(address _adapterAddress)
        internal
        view
        returns (LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_)
    {
        groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](2);

        // Group 0: stETH transfer operations (for delegator to adapter transfers)
        {
            Caveat[] memory stETHTransferCaveats = new Caveat[](2);
            stETHTransferCaveats[0] =
                Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(STETH_ADDRESS) });
            stETHTransferCaveats[1] = Caveat({
                args: hex"",
                enforcer: address(erc20TransferAmountEnforcer),
                terms: abi.encodePacked(STETH_ADDRESS, uint256(1000 ether)) // 1000 stETH max
             });
            groups_[0] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: stETHTransferCaveats });
        }

        // Group 1: Adapter method calls
        {
            Caveat[] memory adapterMethodCaveats = new Caveat[](2);
            adapterMethodCaveats[0] =
                Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(_adapterAddress) });
            adapterMethodCaveats[1] = Caveat({
                args: hex"",
                enforcer: address(allowedMethodsEnforcer),
                terms: abi.encodePacked(LiquidStakingAdapter.requestWithdrawalsByDelegation.selector)
            });
            groups_[1] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: adapterMethodCaveats });
        }
    }

    /**
     * @notice Assigns EIP-7702 implementation to an address and verifies NAME() function
     */
    function _assignImplementationAndVerify(address _account) internal {
        vm.etch(_account, bytes.concat(hex"ef0100", abi.encodePacked(address(eip7702StatelessDeleGatorImpl))));

        string memory name_ = EIP7702StatelessDeleGator(payable(_account)).NAME();
        assertEq(name_, "EIP7702StatelessDeleGator", "NAME() should return correct implementation name");
    }

    /**
     * @notice Mocks signature validation for delegation testing
     * @dev Required because it's not possible to produce real signatures from pranked addresses
     */
    function _mockSignDelegation(Delegation memory _delegation) internal returns (Delegation memory delegation_) {
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(_delegation);
        bytes32 domainHash_ = delegationManager.getDomainHash();
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(domainHash_, delegationHash_);

        bytes memory dummySignature_ =
            hex"1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1b";

        vm.mockCall(
            address(_delegation.delegator),
            abi.encodeWithSelector(IERC1271.isValidSignature.selector, typedDataHash_, dummySignature_),
            abi.encode(ERC1271Lib.EIP1271_MAGIC_VALUE)
        );

        delegation_ = Delegation({
            delegate: _delegation.delegate,
            delegator: _delegation.delegator,
            authority: _delegation.authority,
            caveats: _delegation.caveats,
            salt: _delegation.salt,
            signature: dummySignature_
        });
    }
}

/**
 * @notice Helper contract that rejects ETH transfers for testing
 */
contract RejectETH {
// This contract has no receive() or fallback() function, so it will reject ETH transfers
}
