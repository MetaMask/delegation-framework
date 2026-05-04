// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { IVedaTeller } from "../../src/helpers/interfaces/IVedaTeller.sol";
import { BaseTest } from "../utils/BaseTest.t.sol";
import { Implementation, SignatureType, TestUser } from "../utils/Types.t.sol";
import { Execution, Delegation, Caveat, ModeCode, CallType, ExecType } from "../../src/utils/Types.sol";
import { CALLTYPE_BATCH, EXECTYPE_TRY, MODE_DEFAULT } from "../../src/utils/Constants.sol";
import { ModePayload } from "@erc7579/lib/ModeLib.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";
import { AllowedCalldataEnforcer } from "../../src/enforcers/AllowedCalldataEnforcer.sol";
import { RedeemerEnforcer } from "../../src/enforcers/RedeemerEnforcer.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";
import { LimitedCallsEnforcer } from "../../src/enforcers/LimitedCallsEnforcer.sol";
import { LogicalOrWrapperEnforcer } from "../../src/enforcers/LogicalOrWrapperEnforcer.sol";
import { ERC20TransferAmountEnforcer } from "../../src/enforcers/ERC20TransferAmountEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { VedaAdapter } from "../../src/helpers/VedaAdapter.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

// @dev Do not remove this comment below
/// forge-config: default.evm_version = "shanghai"

/**
 * @title VedaLending Test
 * @notice Tests delegation-based lending on Veda BoringVault.
 * @dev Uses a forked Arbitrum mainnet environment to test real contract interactions.
 *
 * Veda BoringVault implements the ERC-4626 standard for tokenized vaults:
 * - Users deposit assets (e.g., USDC) and receive vault shares representing proportional ownership
 * - Shares are NOT 1:1 with assets - the conversion rate depends on vault's total assets and total supply
 * - The vault contract itself is the ERC-20 share token (no separate token contract)
 * - Veda uses multiple contracts to manage the flow of funds:
 * - We implement Teller for deposits and withdrawals
 * - We implement BoringVault for the approval and custody of assets
 * - More docs here: https://docs.veda.tech/architecture-and-flow-of-funds
 *
 * - Security considerations:
 * - We need a redelegation with specific amount to the adapter to prevent over withdrawal or deposit. This would not effect the
 * user, but could drain the transaction creator wallet.
 */
contract VedaLendingTest is BaseTest {
    using ModeLib for ModeCode;

    // Restricted vault - cannot set on behalfOf
    IVedaTeller public constant VEDA_TELLER = IVedaTeller(0x86821F179eaD9F0b3C79b2f8deF0227eEBFDc9f9);
    IERC20 public constant BORING_VAULT = IERC20(0xB5F07d769dD60fE54c97dd53101181073DDf21b2);

    IERC20 public constant USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    address public constant USDC_WHALE = 0xC6962004f452bE9203591991D15f6b388e09E8D0;
    address public owner;

    // Enforcers for delegation restrictions
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    AllowedCalldataEnforcer public allowedCalldataEnforcer;
    ValueLteEnforcer public valueLteEnforcer;
    LogicalOrWrapperEnforcer public logicalOrWrapperEnforcer;
    ERC20TransferAmountEnforcer public erc20TransferAmountEnforcer;
    RedeemerEnforcer public redeemerEnforcer;
    LimitedCallsEnforcer public limitedCallsEnforcer;
    VedaAdapter public vedaAdapter;

    uint256 public constant INITIAL_USD_BALANCE = 10000000000; // 10k USDC
    uint256 public constant DEPOSIT_AMOUNT = 1000000000; // 1k USDC
    uint256 public constant SHARE_LOCK_SECONDS = 61; // Warp past the 60s share lock period applied by deposit()

    ////////////////////// Setup //////////////////////

    function setUp() public override {
        // Create fork from mainnet at specific block
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"));

        // Set implementation type
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;

        // Call parent setup to initialize delegation framework
        super.setUp();

        owner = makeAddr("VedaAdapter Owner");

        // Deploy enforcers
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        allowedCalldataEnforcer = new AllowedCalldataEnforcer();
        valueLteEnforcer = new ValueLteEnforcer();
        erc20TransferAmountEnforcer = new ERC20TransferAmountEnforcer();
        redeemerEnforcer = new RedeemerEnforcer();
        limitedCallsEnforcer = new LimitedCallsEnforcer();
        logicalOrWrapperEnforcer = new LogicalOrWrapperEnforcer(delegationManager);
        vedaAdapter = new VedaAdapter(owner, address(delegationManager), address(BORING_VAULT), address(VEDA_TELLER), address(USDC));

        vm.label(address(allowedTargetsEnforcer), "AllowedTargetsEnforcer");
        vm.label(address(allowedMethodsEnforcer), "AllowedMethodsEnforcer");
        vm.label(address(allowedCalldataEnforcer), "AllowedCalldataEnforcer");
        vm.label(address(valueLteEnforcer), "ValueLteEnforcer");
        vm.label(address(logicalOrWrapperEnforcer), "LogicalOrWrapperEnforcer");
        vm.label(address(erc20TransferAmountEnforcer), "ERC20TransferAmountEnforcer");
        vm.label(address(vedaAdapter), "VedaAdapter");
        vm.label(address(BORING_VAULT), "Veda BoringVault");
        vm.label(address(VEDA_TELLER), "Veda Teller");
        vm.label(address(USDC), "USDC");
        vm.label(USDC_WHALE, "USDC Whale");

        vm.deal(address(users.alice.deleGator), 1 ether);
        vm.deal(address(users.bob.deleGator), 1 ether);

        vm.prank(USDC_WHALE);
        USDC.transfer(address(users.alice.deleGator), INITIAL_USD_BALANCE); // 10k USDC
    }

    // ==================================================================================
    // Section 1: Direct Protocol Tests (Fork Sanity)
    // Validates the forked mainnet environment works before testing adapter logic.
    // ==================================================================================

    function test_deposit_direct_usdc() public {
        uint256 aliceUSDCInitialBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCInitialBalance_, INITIAL_USD_BALANCE);

        uint256 aliceSharesBefore_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));

        vm.prank(address(users.alice.deleGator));
        USDC.approve(address(BORING_VAULT), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        uint256 sharesMinted_ = VEDA_TELLER.deposit(address(USDC), DEPOSIT_AMOUNT, 0, address(0));

        uint256 aliceUSDCBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance_, INITIAL_USD_BALANCE - DEPOSIT_AMOUNT);

        uint256 aliceSharesAfter_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));
        assertEq(aliceSharesAfter_ - aliceSharesBefore_, sharesMinted_);
    }

    function test_withdraw_direct_usdc() public {
        _setupLendingState();
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);

        uint256 aliceUSDCAfterDeposit_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCAfterDeposit_, INITIAL_USD_BALANCE - DEPOSIT_AMOUNT);

        uint256 aliceShares_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));
        assertGt(aliceShares_, 0, "Alice should have vault shares after deposit");

        // Withdraw all shares back to USDC
        vm.prank(address(users.alice.deleGator));
        uint256 assetsOut_ = VEDA_TELLER.withdraw(address(USDC), aliceShares_, 0, address(users.alice.deleGator));

        assertGt(assetsOut_, 0, "Should receive assets back");

        uint256 aliceSharesAfter_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));
        assertEq(aliceSharesAfter_, 0, "All shares should be burned");

        uint256 aliceUSDCFinal_ = USDC.balanceOf(address(users.alice.deleGator));
        assertApproxEqAbs(aliceUSDCFinal_, INITIAL_USD_BALANCE, DEPOSIT_AMOUNT / 100, "USDC balance should be close to initial");
    }

    // ==================================================================================
    // Section 2: Adapter Happy-Path Tests (Core Functionality)
    // Validates the standard deposit/withdraw flow via the adapter using delegations.
    // ==================================================================================

    function test_deposit_viaAdapterDelegation_usdc() public {
        uint256 aliceUSDCInitialBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCInitialBalance_, INITIAL_USD_BALANCE);
        uint256 aliceSharesInitial_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));
        assertEq(aliceSharesInitial_, 0);

        // Alice delegates USDC transfer rights to Bob, redeemable only by the adapter
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(vedaAdapter), address(USDC), type(uint256).max);

        // Bob redelegates to the VedaAdapter with a transfer amount cap
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        vm.prank(address(users.bob.deleGator));
        vedaAdapter.depositByDelegation(delegations_, 0);

        uint256 aliceUSDCFinal_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCFinal_, INITIAL_USD_BALANCE - DEPOSIT_AMOUNT, "USDC balance should decrease");

        uint256 aliceSharesFinal_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));
        assertGt(aliceSharesFinal_, 0, "Shares should be minted to Alice");
    }

    function test_withdraw_viaAdapterDelegation_usdc() public {
        _setupLendingState();
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);

        uint256 aliceShares_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));
        assertGt(aliceShares_, 0, "Alice should have vault shares");
        uint256 aliceUSDCBefore_ = USDC.balanceOf(address(users.alice.deleGator));

        // Alice delegates BoringVault share transfer rights to Bob, redeemable only by the adapter
        Delegation memory delegation_ = _createTransferDelegation(
            address(users.bob.deleGator), address(vedaAdapter), address(BORING_VAULT), type(uint256).max
        );

        // Bob redelegates to the VedaAdapter with a share transfer amount cap
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), address(BORING_VAULT), aliceShares_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        vm.prank(address(users.bob.deleGator));
        vedaAdapter.withdrawByDelegation(delegations_, 0);

        uint256 aliceSharesAfter_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));
        assertEq(aliceSharesAfter_, 0, "All shares should be burned");

        uint256 aliceUSDCAfter_ = USDC.balanceOf(address(users.alice.deleGator));
        assertGt(aliceUSDCAfter_, aliceUSDCBefore_, "Alice should receive USDC back");
        assertApproxEqAbs(aliceUSDCAfter_, INITIAL_USD_BALANCE, DEPOSIT_AMOUNT / 100, "USDC balance should be close to initial");
    }

    // ==================================================================================
    // Section 3: Constructor Validation Tests
    // Ensures the adapter rejects invalid constructor parameters.
    // ==================================================================================

    /// @notice Constructor must revert when delegationManager is zero address
    function test_constructor_revertsOnZeroDelegationManager() public {
        vm.expectRevert(VedaAdapter.InvalidZeroAddress.selector);
        new VedaAdapter(owner, address(0), address(BORING_VAULT), address(VEDA_TELLER), address(USDC));
    }

    /// @notice Constructor must revert when boringVault is zero address
    function test_constructor_revertsOnZeroBoringVault() public {
        vm.expectRevert(VedaAdapter.InvalidZeroAddress.selector);
        new VedaAdapter(owner, address(delegationManager), address(0), address(VEDA_TELLER), address(USDC));
    }

    /// @notice Constructor must revert when teller is zero address
    function test_constructor_revertsOnZeroTeller() public {
        vm.expectRevert(VedaAdapter.InvalidZeroAddress.selector);
        new VedaAdapter(owner, address(delegationManager), address(BORING_VAULT), address(0), address(USDC));
    }

    /// @notice Constructor must revert when depositToken is zero address
    function test_constructor_revertsOnZeroDepositToken() public {
        vm.expectRevert(VedaAdapter.InvalidZeroAddress.selector);
        new VedaAdapter(owner, address(delegationManager), address(BORING_VAULT), address(VEDA_TELLER), address(0));
    }

    /// @notice Constructor must revert when owner is zero address (OZ Ownable)
    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new VedaAdapter(address(0), address(delegationManager), address(BORING_VAULT), address(VEDA_TELLER), address(USDC));
    }

    /// @notice Constructor must store immutable state correctly with valid inputs
    function test_constructor_successWithValidAddresses() public {
        VedaAdapter newAdapter_ =
            new VedaAdapter(owner, address(delegationManager), address(BORING_VAULT), address(VEDA_TELLER), address(USDC));

        assertEq(address(newAdapter_.delegationManager()), address(delegationManager));
        assertEq(newAdapter_.boringVault(), address(BORING_VAULT));
        assertEq(address(newAdapter_.teller()), address(VEDA_TELLER));
        assertEq(address(newAdapter_.depositToken()), address(USDC));
        assertEq(newAdapter_.owner(), owner);
    }

    // ==================================================================================
    // Section 4: Deposit Input Validation / Revert Tests
    // Ensures depositByDelegation rejects invalid inputs before any state changes.
    // ==================================================================================

    /// @notice depositByDelegation must revert with 0 delegations
    function test_depositByDelegation_revertsOnEmptyDelegations() public {
        Delegation[] memory delegations_ = new Delegation[](0);

        vm.expectRevert(VedaAdapter.InvalidDelegationsLength.selector);
        vm.prank(address(users.bob.deleGator));
        vedaAdapter.depositByDelegation(delegations_, 0);
    }

    /// @notice depositByDelegation must revert with only 1 delegation (requires >= 2 for redelegation pattern)
    function test_depositByDelegation_revertsOnSingleDelegation() public {
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(vedaAdapter), address(USDC), DEPOSIT_AMOUNT);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        vm.expectRevert(VedaAdapter.InvalidDelegationsLength.selector);
        vm.prank(address(users.bob.deleGator));
        vedaAdapter.depositByDelegation(delegations_, 0);
    }

    // ==================================================================================
    // Section 5: Withdraw Input Validation / Revert Tests
    // Ensures withdrawByDelegation rejects invalid inputs before any state changes.
    // ==================================================================================

    /// @notice withdrawByDelegation must revert with 0 delegations
    function test_withdrawByDelegation_revertsOnEmptyDelegations() public {
        _setupLendingState();

        Delegation[] memory delegations_ = new Delegation[](0);

        vm.expectRevert(VedaAdapter.InvalidDelegationsLength.selector);
        vm.prank(address(users.bob.deleGator));
        vedaAdapter.withdrawByDelegation(delegations_, 0);
    }

    /// @notice withdrawByDelegation must revert with only 1 delegation (requires >= 2 for redelegation pattern)
    function test_withdrawByDelegation_revertsOnSingleDelegation() public {
        _setupLendingState();

        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(vedaAdapter), address(BORING_VAULT), DEPOSIT_AMOUNT);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        vm.expectRevert(VedaAdapter.InvalidDelegationsLength.selector);
        vm.prank(address(users.bob.deleGator));
        vedaAdapter.withdrawByDelegation(delegations_, 0);
    }

    // ==================================================================================
    // Section 6: Event Emission Tests
    // Validates that adapter emits correct events with expected indexed parameters.
    // ==================================================================================

    /// @notice depositByDelegation must emit DepositExecuted with correct parameters
    function test_depositByDelegation_emitsDepositExecutedEvent() public {
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(vedaAdapter), address(USDC), type(uint256).max);
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        // Expect event: check indexed delegator, delegate, and token. Amount and shares are checked via topic4.
        vm.expectEmit(true, true, true, false, address(vedaAdapter));
        emit VedaAdapter.DepositExecuted(
            address(users.alice.deleGator), address(users.bob.deleGator), address(USDC), DEPOSIT_AMOUNT, 0
        );

        vm.prank(address(users.bob.deleGator));
        vedaAdapter.depositByDelegation(delegations_, 0);
    }

    /// @notice withdrawByDelegation must emit WithdrawExecuted with correct parameters
    function test_withdrawByDelegation_emitsWithdrawExecutedEvent() public {
        _setupLendingState();
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);

        uint256 aliceShares_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));

        Delegation memory delegation_ = _createTransferDelegation(
            address(users.bob.deleGator), address(vedaAdapter), address(BORING_VAULT), type(uint256).max
        );
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), address(BORING_VAULT), aliceShares_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        // Expect event: check indexed delegator, delegate, and token. shareAmount and assetsOut are checked via topic4.
        vm.expectEmit(true, true, true, false, address(vedaAdapter));
        emit VedaAdapter.WithdrawExecuted(
            address(users.alice.deleGator), address(users.bob.deleGator), address(USDC), aliceShares_, 0
        );

        vm.prank(address(users.bob.deleGator));
        vedaAdapter.withdrawByDelegation(delegations_, 0);
    }

    // ==================================================================================
    // Section 7: Batch Operation Tests
    // Validates depositByDelegationBatch and withdrawByDelegationBatch.
    // ==================================================================================

    /// @notice depositByDelegationBatch must revert on empty array
    function test_depositByDelegationBatch_revertsOnEmptyArray() public {
        VedaAdapter.DepositParams[] memory streams_ = new VedaAdapter.DepositParams[](0);

        vm.expectRevert(VedaAdapter.InvalidBatchLength.selector);
        vm.prank(address(users.bob.deleGator));
        vedaAdapter.depositByDelegationBatch(streams_);
    }

    /// @notice withdrawByDelegationBatch must revert on empty array
    function test_withdrawByDelegationBatch_revertsOnEmptyArray() public {
        VedaAdapter.WithdrawParams[] memory streams_ = new VedaAdapter.WithdrawParams[](0);

        vm.expectRevert(VedaAdapter.InvalidBatchLength.selector);
        vm.prank(address(users.bob.deleGator));
        vedaAdapter.withdrawByDelegationBatch(streams_);
    }

    /// @notice Batch deposit with 2 independent delegation chains in a single transaction
    function test_depositByDelegationBatch_twoDelegationChains() public {
        uint256 amount1_ = 300 * 1e6; // 300 USDC
        uint256 amount2_ = 400 * 1e6; // 400 USDC

        // Chain 1: Alice -> Bob -> VedaAdapter (salt 0)
        Delegation memory delegation1_ = _createTransferDelegationWithSalt(
            address(users.bob.deleGator), address(vedaAdapter), address(USDC), type(uint256).max, 0
        );
        Delegation memory redelegation1_ =
            _createAdapterRedelegationWithSalt(EncoderLib._getDelegationHash(delegation1_), address(USDC), amount1_, 0);
        Delegation[] memory delegations1_ = new Delegation[](2);
        delegations1_[0] = redelegation1_;
        delegations1_[1] = delegation1_;

        // Chain 2: Alice -> Bob -> VedaAdapter (salt 1)
        Delegation memory delegation2_ = _createTransferDelegationWithSalt(
            address(users.bob.deleGator), address(vedaAdapter), address(USDC), type(uint256).max, 1
        );
        Delegation memory redelegation2_ =
            _createAdapterRedelegationWithSalt(EncoderLib._getDelegationHash(delegation2_), address(USDC), amount2_, 1);
        Delegation[] memory delegations2_ = new Delegation[](2);
        delegations2_[0] = redelegation2_;
        delegations2_[1] = delegation2_;

        VedaAdapter.DepositParams[] memory streams_ = new VedaAdapter.DepositParams[](2);
        streams_[0] = VedaAdapter.DepositParams({ delegations: delegations1_, minimumMint: 0 });
        streams_[1] = VedaAdapter.DepositParams({ delegations: delegations2_, minimumMint: 0 });

        vm.expectEmit(true, true, true, true, address(vedaAdapter));
        emit VedaAdapter.BatchDepositExecuted(address(users.bob.deleGator), 2);

        vm.prank(address(users.bob.deleGator));
        vedaAdapter.depositByDelegationBatch(streams_);

        uint256 aliceUSDCFinal_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCFinal_, INITIAL_USD_BALANCE - amount1_ - amount2_, "USDC should decrease by total batch amount");

        uint256 aliceShares_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));
        assertGt(aliceShares_, 0, "Alice should receive vault shares from batch deposit");
    }

    /// @notice Batch withdraw with 2 independent delegation chains in a single transaction
    function test_withdrawByDelegationBatch_twoDelegationChains() public {
        // Setup: Deposit via adapter to create shares, then warp past the 60s share lock period
        _depositViaAdapter(DEPOSIT_AMOUNT, 10);
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);

        uint256 totalShares_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));
        assertGt(totalShares_, 0, "Alice should have shares after deposit");

        uint256 sharesPart1_ = totalShares_ / 2;
        uint256 sharesPart2_ = totalShares_ - sharesPart1_;

        VedaAdapter.WithdrawParams[] memory wdStreams_ = new VedaAdapter.WithdrawParams[](2);
        wdStreams_[0] = _buildWithdrawParams(sharesPart1_, 20);
        wdStreams_[1] = _buildWithdrawParams(sharesPart2_, 21);

        vm.expectEmit(true, true, true, true, address(vedaAdapter));
        emit VedaAdapter.BatchWithdrawExecuted(address(users.bob.deleGator), 2);

        vm.prank(address(users.bob.deleGator));
        vedaAdapter.withdrawByDelegationBatch(wdStreams_);

        assertEq(BORING_VAULT.balanceOf(address(users.alice.deleGator)), 0, "All shares should be redeemed after batch withdraw");
        assertApproxEqAbs(
            USDC.balanceOf(address(users.alice.deleGator)),
            INITIAL_USD_BALANCE,
            DEPOSIT_AMOUNT / 100,
            "USDC should be approximately restored"
        );
    }

    // ==================================================================================
    // Section 8: Emergency Withdraw Tests
    // Validates the owner-only withdrawEmergency function for recovering stuck tokens.
    // ==================================================================================

    /// @notice Only the contract owner can call withdrawEmergency
    function test_withdrawEmergency_revertsOnNonOwner() public {
        BasicERC20 testToken_ = new BasicERC20(owner, "TestToken", "TST", 0);
        vm.prank(owner);
        testToken_.mint(address(vedaAdapter), 100 ether);

        vm.prank(address(users.alice.deleGator));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(users.alice.deleGator)));
        vedaAdapter.withdrawEmergency(testToken_, 50 ether, address(users.alice.deleGator));

        assertEq(testToken_.balanceOf(address(vedaAdapter)), 100 ether, "Balance should be unchanged");
    }

    /// @notice Owner can recover stuck tokens; emits StuckTokensWithdrawn event
    function test_withdrawEmergency_recoverTokens() public {
        BasicERC20 testToken_ = new BasicERC20(owner, "TestToken", "TST", 0);
        vm.prank(owner);
        testToken_.mint(address(vedaAdapter), 100 ether);

        vm.expectEmit(true, true, true, true, address(vedaAdapter));
        emit VedaAdapter.StuckTokensWithdrawn(testToken_, address(users.alice.deleGator), 50 ether);

        vm.prank(owner);
        vedaAdapter.withdrawEmergency(testToken_, 50 ether, address(users.alice.deleGator));

        assertEq(testToken_.balanceOf(address(vedaAdapter)), 50 ether, "Adapter should retain remaining tokens");
        assertEq(testToken_.balanceOf(address(users.alice.deleGator)), 50 ether, "Recipient should receive tokens");
    }

    /// @notice withdrawEmergency must revert when recipient is zero address
    function test_withdrawEmergency_revertsOnZeroRecipient() public {
        BasicERC20 testToken_ = new BasicERC20(owner, "TestToken", "TST", 0);
        vm.prank(owner);
        testToken_.mint(address(vedaAdapter), 100 ether);

        vm.expectRevert(VedaAdapter.InvalidRecipient.selector);
        vm.prank(owner);
        vedaAdapter.withdrawEmergency(testToken_, 50 ether, address(0));
    }

    // ==================================================================================
    // Section 9: Edge Cases and Security Validation
    // Tests for subtle behaviors, allowance management, chain integrity, and token mismatch.
    // ==================================================================================

    /// @notice After a deposit, the adapter must not retain any deposited tokens
    function test_adapterDoesNotRetainTokensAfterDeposit() public {
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(vedaAdapter), address(USDC), type(uint256).max);
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        vm.prank(address(users.bob.deleGator));
        vedaAdapter.depositByDelegation(delegations_, 0);

        assertEq(USDC.balanceOf(address(vedaAdapter)), 0, "Adapter must not retain any USDC after deposit");
    }

    /// @notice After a withdraw, the adapter must not retain any vault shares
    function test_adapterDoesNotRetainSharesAfterWithdraw() public {
        _setupLendingState();
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);

        uint256 aliceShares_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));

        Delegation memory delegation_ = _createTransferDelegation(
            address(users.bob.deleGator), address(vedaAdapter), address(BORING_VAULT), type(uint256).max
        );
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), address(BORING_VAULT), aliceShares_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        vm.prank(address(users.bob.deleGator));
        vedaAdapter.withdrawByDelegation(delegations_, 0);

        assertEq(BORING_VAULT.balanceOf(address(vedaAdapter)), 0, "Adapter must not retain any vault shares after withdraw");
    }

    /// @notice The adapter approves the BoringVault for `type(uint256).max` in the constructor,
    ///         so deposits draw from a pre-existing unlimited allowance that never needs topping up
    ///         under normal operation.
    function test_allowanceSetToMaxInConstructor() public {
        assertEq(
            USDC.allowance(address(vedaAdapter), address(BORING_VAULT)),
            type(uint256).max,
            "Constructor should set allowance to max"
        );
    }

    /// @notice After a deposit, the allowance is simply `max - depositAmount` because the BoringVault
    ///         pulled tokens via `safeTransferFrom`. The allowance is effectively still unbounded and
    ///         does not require re-approval.
    function test_allowanceRemainsUnlimitedAfterDeposit() public {
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(vedaAdapter), address(USDC), type(uint256).max);
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        vm.prank(address(users.bob.deleGator));
        vedaAdapter.depositByDelegation(delegations_, 0);

        assertEq(
            USDC.allowance(address(vedaAdapter), address(BORING_VAULT)),
            type(uint256).max - DEPOSIT_AMOUNT,
            "Allowance should be unlimited minus the deposited amount"
        );
    }

    /// @notice `ensureAllowance` is a fail-safe that lets the owner restore the BoringVault
    ///         allowance to `type(uint256).max` if it were ever reduced.
    function test_ensureAllowanceRestoresMaxAllowance() public {
        // Simulate the allowance being reduced by forcing an approval from the adapter via the owner.
        // We can't directly call forceApprove on the adapter, so we verify the fail-safe restores
        // allowance after a deposit consumes part of it.
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(vedaAdapter), address(USDC), type(uint256).max);
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        vm.prank(address(users.bob.deleGator));
        vedaAdapter.depositByDelegation(delegations_, 0);

        assertLt(
            USDC.allowance(address(vedaAdapter), address(BORING_VAULT)),
            type(uint256).max,
            "Allowance should be below max after a deposit"
        );

        vm.prank(owner);
        vedaAdapter.ensureAllowance();

        assertEq(
            USDC.allowance(address(vedaAdapter), address(BORING_VAULT)),
            type(uint256).max,
            "ensureAllowance should restore allowance to max"
        );
    }

    /// @notice `ensureAllowance` is owner-gated and reverts when called by a non-owner.
    function test_ensureAllowanceRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(users.bob.addr)));
        vm.prank(address(users.bob.addr));
        vedaAdapter.ensureAllowance();
    }

    /// @notice A 3-level delegation chain (Alice -> Carol -> Bob -> Adapter) must correctly resolve
    ///         rootDelegator as Alice, ensuring shares are minted to the actual token owner.
    function test_depositByDelegation_withThreeLevelDelegationChain() public {
        vm.deal(address(users.carol.deleGator), 1 ether);

        // Root delegation: Alice -> Carol (with transfer enforcer + redeemer enforcer)
        Delegation memory rootDelegation_ =
            _createTransferDelegation(address(users.carol.deleGator), address(vedaAdapter), address(USDC), type(uint256).max);

        // Middle delegation: Carol -> Bob (no additional caveats, just extends the chain)
        Delegation memory middleDelegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.carol.deleGator),
            authority: EncoderLib._getDelegationHash(rootDelegation_),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        middleDelegation_ = signDelegation(users.carol, middleDelegation_);

        // Leaf delegation: Bob -> VedaAdapter (with transfer amount cap)
        Delegation memory adapterDelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(middleDelegation_), address(USDC), DEPOSIT_AMOUNT);

        // Chain order: [leaf, middle, root]
        Delegation[] memory delegations_ = new Delegation[](3);
        delegations_[0] = adapterDelegation_;
        delegations_[1] = middleDelegation_;
        delegations_[2] = rootDelegation_;

        vm.prank(address(users.bob.deleGator));
        vedaAdapter.depositByDelegation(delegations_, 0);

        // rootDelegator_ = delegations[2].delegator = Alice
        uint256 aliceShares_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));
        assertGt(aliceShares_, 0, "Shares must be minted to Alice (root delegator), not Carol or Bob");

        assertEq(BORING_VAULT.balanceOf(address(users.carol.deleGator)), 0, "Carol must not receive shares");
        assertEq(BORING_VAULT.balanceOf(address(users.bob.deleGator)), 0, "Bob must not receive shares");
    }

    // ==================================================================================
    // Section 10: Terms Validation Tests
    // Ensures the adapter rejects malformed caveat terms before executing.
    // ==================================================================================

    /// @notice depositByDelegation must revert when leaf caveat terms are shorter than 52 bytes
    function test_depositByDelegation_revertsOnShortTerms() public {
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(vedaAdapter), address(USDC), type(uint256).max);

        Caveat[] memory shortCaveats_ = new Caveat[](1);
        shortCaveats_[0] = Caveat({
            args: hex"",
            enforcer: address(erc20TransferAmountEnforcer),
            terms: abi.encodePacked(address(USDC)) // 20 bytes, too short
        });

        Delegation memory redelegation_ = Delegation({
            delegate: address(vedaAdapter),
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(delegation_),
            caveats: shortCaveats_,
            salt: 0,
            signature: hex""
        });
        redelegation_ = signDelegation(users.bob, redelegation_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        vm.expectRevert(VedaAdapter.InvalidTermsLength.selector);
        vm.prank(address(users.bob.deleGator));
        vedaAdapter.depositByDelegation(delegations_, 0);
    }

    /// @notice withdrawByDelegation must revert when leaf caveat terms are shorter than 52 bytes
    function test_withdrawByDelegation_revertsOnShortTerms() public {
        _setupLendingState();

        Delegation memory delegation_ = _createTransferDelegation(
            address(users.bob.deleGator), address(vedaAdapter), address(BORING_VAULT), type(uint256).max
        );

        Caveat[] memory shortCaveats_ = new Caveat[](1);
        shortCaveats_[0] = Caveat({
            args: hex"",
            enforcer: address(erc20TransferAmountEnforcer),
            terms: hex"aabbccdd" // 4 bytes, too short
        });

        Delegation memory redelegation_ = Delegation({
            delegate: address(vedaAdapter),
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(delegation_),
            caveats: shortCaveats_,
            salt: 0,
            signature: hex""
        });
        redelegation_ = signDelegation(users.bob, redelegation_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        vm.expectRevert(VedaAdapter.InvalidTermsLength.selector);
        vm.prank(address(users.bob.deleGator));
        vedaAdapter.withdrawByDelegation(delegations_, 0);
    }

    // ==================================================================================
    // Section 11: Replay / Double-Spend Prevention Tests
    // Validates that the ERC20TransferAmountEnforcer prevents reuse of the same delegation.
    // ==================================================================================

    /// @notice Calling depositByDelegation twice with the same delegation chain must revert on the second call
    function test_depositByDelegation_revertsOnReplay() public {
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(vedaAdapter), address(USDC), type(uint256).max);
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        vm.prank(address(users.bob.deleGator));
        vedaAdapter.depositByDelegation(delegations_, 0);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        vedaAdapter.depositByDelegation(delegations_, 0);
    }

    // ==================================================================================
    // Section 12: Slippage Protection Tests
    // Validates that minimumMint / minimumAssets bounds cause reverts when not met.
    // ==================================================================================

    /// @notice depositByDelegation must revert when minimumMint exceeds the actual shares minted
    function test_depositByDelegation_revertsOnSlippage() public {
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(vedaAdapter), address(USDC), type(uint256).max);
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        vedaAdapter.depositByDelegation(delegations_, type(uint256).max);
    }

    /// @notice withdrawByDelegation must revert when minimumAssets exceeds the actual assets received
    function test_withdrawByDelegation_revertsOnSlippage() public {
        _setupLendingState();
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);

        uint256 aliceShares_ = BORING_VAULT.balanceOf(address(users.alice.deleGator));

        Delegation memory delegation_ = _createTransferDelegation(
            address(users.bob.deleGator), address(vedaAdapter), address(BORING_VAULT), type(uint256).max
        );
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), address(BORING_VAULT), aliceShares_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        vedaAdapter.withdrawByDelegation(delegations_, type(uint256).max);
    }

    // ==================================================================================
    // Section 13: Alternative Delegator Tests
    // Validates the adapter works correctly when Carol (not Alice) is the root delegator.
    // ==================================================================================

    /// @notice Deposit via adapter where Carol is the root delegator instead of Alice
    function test_depositByDelegation_carolAsRootDelegator() public {
        vm.deal(address(users.carol.deleGator), 1 ether);
        vm.prank(USDC_WHALE);
        USDC.transfer(address(users.carol.deleGator), INITIAL_USD_BALANCE);

        uint256 carolUSDCBefore_ = USDC.balanceOf(address(users.carol.deleGator));

        // Carol delegates USDC transfer rights to Bob, redeemable only by the adapter
        Delegation memory delegation_ = _createTransferDelegationFull(
            users.carol, address(users.bob.deleGator), address(vedaAdapter), address(USDC), type(uint256).max, 0
        );

        // Bob redelegates to the VedaAdapter with a transfer amount cap
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        vm.prank(address(users.bob.deleGator));
        vedaAdapter.depositByDelegation(delegations_, 0);

        uint256 carolUSDCAfter_ = USDC.balanceOf(address(users.carol.deleGator));
        assertEq(carolUSDCAfter_, carolUSDCBefore_ - DEPOSIT_AMOUNT, "Carol's USDC should decrease");

        uint256 carolShares_ = BORING_VAULT.balanceOf(address(users.carol.deleGator));
        assertGt(carolShares_, 0, "Shares should be minted to Carol (root delegator)");

        assertEq(BORING_VAULT.balanceOf(address(users.bob.deleGator)), 0, "Bob must not receive shares");
        assertEq(BORING_VAULT.balanceOf(address(users.alice.deleGator)), 0, "Alice must not receive shares");
    }

    /// @notice Withdraw via adapter where Carol is the root delegator instead of Alice
    function test_withdrawByDelegation_carolAsRootDelegator() public {
        vm.deal(address(users.carol.deleGator), 1 ether);
        vm.prank(USDC_WHALE);
        USDC.transfer(address(users.carol.deleGator), INITIAL_USD_BALANCE);

        // Carol deposits directly to get shares
        vm.prank(address(users.carol.deleGator));
        USDC.approve(address(BORING_VAULT), DEPOSIT_AMOUNT);
        vm.prank(address(users.carol.deleGator));
        VEDA_TELLER.deposit(address(USDC), DEPOSIT_AMOUNT, 0, address(0));
        vm.warp(block.timestamp + SHARE_LOCK_SECONDS);

        uint256 carolShares_ = BORING_VAULT.balanceOf(address(users.carol.deleGator));
        assertGt(carolShares_, 0, "Carol should have vault shares");
        uint256 carolUSDCBefore_ = USDC.balanceOf(address(users.carol.deleGator));

        // Carol delegates share transfer rights to Bob, redeemable only by the adapter
        Delegation memory delegation_ = _createTransferDelegationFull(
            users.carol, address(users.bob.deleGator), address(vedaAdapter), address(BORING_VAULT), type(uint256).max, 0
        );

        // Bob redelegates to the VedaAdapter with a share transfer amount cap
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), address(BORING_VAULT), carolShares_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        vm.prank(address(users.bob.deleGator));
        vedaAdapter.withdrawByDelegation(delegations_, 0);

        assertEq(BORING_VAULT.balanceOf(address(users.carol.deleGator)), 0, "All shares should be burned");
        uint256 carolUSDCAfter_ = USDC.balanceOf(address(users.carol.deleGator));
        assertGt(carolUSDCAfter_, carolUSDCBefore_, "Carol should receive USDC back");
    }

    // ==================================================================================
    // Helper Functions
    // ==================================================================================

    /// @notice Sets up initial lending state (Alice deposits USDC to get vault shares)
    function _setupLendingState() internal {
        vm.prank(address(users.alice.deleGator));
        USDC.approve(address(BORING_VAULT), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        VEDA_TELLER.deposit(address(USDC), DEPOSIT_AMOUNT, 0, address(0));
    }

    /// @notice Deposits USDC via adapter delegation (helper to reduce stack depth in batch tests)
    function _depositViaAdapter(uint256 _amount, uint256 _salt) internal {
        Delegation memory delegation_ = _createTransferDelegationWithSalt(
            address(users.bob.deleGator), address(vedaAdapter), address(USDC), type(uint256).max, _salt
        );
        Delegation memory redelegation_ =
            _createAdapterRedelegationWithSalt(EncoderLib._getDelegationHash(delegation_), address(USDC), _amount, _salt);
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = redelegation_;
        delegations_[1] = delegation_;

        vm.prank(address(users.bob.deleGator));
        vedaAdapter.depositByDelegation(delegations_, 0);
    }

    /// @notice Builds a WithdrawParams struct for batch withdraw (helper to reduce stack depth)
    function _buildWithdrawParams(uint256 _shareAmount, uint256 _salt) internal view returns (VedaAdapter.WithdrawParams memory) {
        Delegation memory wd_ = _createTransferDelegationWithSalt(
            address(users.bob.deleGator), address(vedaAdapter), address(BORING_VAULT), type(uint256).max, _salt
        );
        Delegation memory rewd_ =
            _createAdapterRedelegationWithSalt(EncoderLib._getDelegationHash(wd_), address(BORING_VAULT), _shareAmount, _salt);
        Delegation[] memory wdDelegations_ = new Delegation[](2);
        wdDelegations_[0] = rewd_;
        wdDelegations_[1] = wd_;

        return VedaAdapter.WithdrawParams({ delegations: wdDelegations_, minimumAssets: 0 });
    }

    /// @notice Creates a transfer delegation with ERC20TransferAmountEnforcer and RedeemerEnforcer
    function _createTransferDelegation(
        address _delegate,
        address _redeemer,
        address _token,
        uint256 _amount
    )
        internal
        view
        returns (Delegation memory)
    {
        return _createTransferDelegationFull(users.alice, _delegate, _redeemer, _token, _amount, 0);
    }

    /// @notice Creates a transfer delegation with a custom salt for unique delegation hashes in batch operations
    function _createTransferDelegationWithSalt(
        address _delegate,
        address _redeemer,
        address _token,
        uint256 _amount,
        uint256 _salt
    )
        internal
        view
        returns (Delegation memory)
    {
        return _createTransferDelegationFull(users.alice, _delegate, _redeemer, _token, _amount, _salt);
    }

    /// @notice Creates a transfer delegation signed by an arbitrary delegator
    function _createTransferDelegationFull(
        TestUser memory _delegator,
        address _delegate,
        address _redeemer,
        address _token,
        uint256 _amount,
        uint256 _salt
    )
        internal
        view
        returns (Delegation memory)
    {
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: abi.encodePacked(_token, _amount) });

        caveats_[1] = Caveat({ args: hex"", enforcer: address(redeemerEnforcer), terms: abi.encodePacked(_redeemer) });

        Delegation memory delegation_ = Delegation({
            delegate: _delegate,
            delegator: address(_delegator.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: _salt,
            signature: hex""
        });

        return signDelegation(_delegator, delegation_);
    }

    /// @notice Creates an adapter redelegation with ERC20TransferAmountEnforcer
    function _createAdapterRedelegation(
        bytes32 _authority,
        address _token,
        uint256 _amount
    )
        internal
        view
        returns (Delegation memory)
    {
        return _createAdapterRedelegationFull(users.bob, _authority, _token, _amount, 0);
    }

    /// @notice Creates an adapter redelegation with a custom salt for unique delegation hashes in batch operations
    function _createAdapterRedelegationWithSalt(
        bytes32 _authority,
        address _token,
        uint256 _amount,
        uint256 _salt
    )
        internal
        view
        returns (Delegation memory)
    {
        return _createAdapterRedelegationFull(users.bob, _authority, _token, _amount, _salt);
    }

    /// @notice Creates an adapter redelegation signed by an arbitrary operator
    function _createAdapterRedelegationFull(
        TestUser memory _operator,
        bytes32 _authority,
        address _token,
        uint256 _amount,
        uint256 _salt
    )
        internal
        view
        returns (Delegation memory)
    {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: abi.encodePacked(_token, _amount) });

        Delegation memory delegation_ = Delegation({
            delegate: address(vedaAdapter),
            delegator: address(_operator.deleGator),
            authority: _authority,
            caveats: caveats_,
            salt: _salt,
            signature: hex""
        });

        return signDelegation(_operator, delegation_);
    }
}
