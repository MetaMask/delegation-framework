// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { IMorphoVault } from "../../src/helpers/interfaces/IMorphoVault.sol";
import { BaseTest } from "../utils/BaseTest.t.sol";
import { Implementation, SignatureType } from "../utils/Types.t.sol";
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
import { MorphoAdapter } from "../../src/helpers/MorphoAdapter.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";

// @dev Do not remove this comment below
/// forge-config: default.evm_version = "shanghai"

/**
 * @title MorphoLending Test
 * @notice Tests delegation-based lending on Morpho Vaults V2.
 * @dev Uses a forked Ethereum mainnet environment to test real contract interactions.
 *
 * Morpho Vaults V2 implement the ERC-4626 standard for tokenized vaults:
 * - Users deposit assets (e.g., USDC) and receive vault shares representing proportional ownership
 * - Shares are NOT 1:1 with assets - the conversion rate depends on vault's total assets and total supply
 * - The vault contract itself is the ERC-20 share token (no separate token contract)
 * - Users can redeem shares to withdraw their proportional share of vault assets
 */
contract MorphoLendingTest is BaseTest {
    using ModeLib for ModeCode;

    // Restricted vault - cannot set on behalfOf
    // IMorphoVault public constant MORPHO_VAULT = IMorphoVault(0x334F5d28a71432f8fc21C7B2B6F5dBbcD8B32A7b);
    IMorphoVault public constant MORPHO_VAULT = IMorphoVault(0x711a68a82dd80cB0435b281aF76B0B80804eFab9);
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 public constant MUSD = IERC20(0xacA92E438df0B2401fF60dA7E4337B687a2435DA);
    address public constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    address public constant MUSD_WHALE = 0x795fACaa76Aed7C5F44a053155407199F4075139;
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
    MorphoAdapter public morphoAdapter;

    uint256 public constant MAINNET_FORK_BLOCK = 24426084; // Use latest available block
    uint256 public constant INITIAL_USD_BALANCE = 10000000000; // 10k USDC
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
        redeemerEnforcer = new RedeemerEnforcer();
        limitedCallsEnforcer = new LimitedCallsEnforcer();
        logicalOrWrapperEnforcer = new LogicalOrWrapperEnforcer(delegationManager);
        morphoAdapter = new MorphoAdapter(owner, address(delegationManager));

        vm.label(address(allowedTargetsEnforcer), "AllowedTargetsEnforcer");
        vm.label(address(allowedMethodsEnforcer), "AllowedMethodsEnforcer");
        vm.label(address(allowedCalldataEnforcer), "AllowedCalldataEnforcer");
        vm.label(address(valueLteEnforcer), "ValueLteEnforcer");
        vm.label(address(logicalOrWrapperEnforcer), "LogicalOrWrapperEnforcer");
        vm.label(address(erc20TransferAmountEnforcer), "ERC20TransferAmountEnforcer");
        vm.label(address(morphoAdapter), "MorphoAdapter");
        vm.label(address(MORPHO_VAULT), "Morpho lending");
        vm.label(address(USDC), "USDC");
        vm.label(address(MUSD), "MUSD");
        vm.label(USDC_WHALE, "USDC Whale");
        vm.label(MUSD_WHALE, "MUSD Whale");

        vm.deal(address(users.alice.deleGator), 1 ether);
        vm.deal(address(users.bob.deleGator), 1 ether);

        vm.prank(USDC_WHALE);
        USDC.transfer(address(users.alice.deleGator), INITIAL_USD_BALANCE); // 10k USDC

        vm.prank(MUSD_WHALE);
        MUSD.transfer(address(users.alice.deleGator), INITIAL_USD_BALANCE); // 10k MUSD
    }

    // Testing directly depositing USDC to Morpho vault to see if everything works on the forked mainnet
    function test_deposit_direct_usdc() public {
        uint256 aliceUSDCInitialBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCInitialBalance_, INITIAL_USD_BALANCE);

        // Morpho vault shares are ERC20s and are tracked on the vault contract itself.
        // Record share balance before deposit and validate minted shares after deposit.
        uint256 aliceSharesBefore_ = MORPHO_VAULT.balanceOf(address(users.alice.deleGator));
        uint256 expectedShares_ = MORPHO_VAULT.previewDeposit(DEPOSIT_AMOUNT);

        vm.prank(address(users.alice.deleGator));
        USDC.approve(address(MORPHO_VAULT), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        uint256 sharesMinted_ = MORPHO_VAULT.deposit(DEPOSIT_AMOUNT, address(users.alice.deleGator));

        uint256 aliceUSDCBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance_, INITIAL_USD_BALANCE - DEPOSIT_AMOUNT);

        uint256 aliceSharesAfter_ = MORPHO_VAULT.balanceOf(address(users.alice.deleGator));
        assertEq(aliceSharesAfter_ - aliceSharesBefore_, sharesMinted_);
        assertEq(sharesMinted_, expectedShares_);
    }

    // Testing directly withdrawing USDC from Morpho vault to see if everything works on the forked mainnet
    function test_withdraw_direct_usdc() public {
        // Setup phase: Deposit USDC to get vault shares
        uint256 aliceUSDCInitialBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCInitialBalance_, INITIAL_USD_BALANCE);

        vm.prank(address(users.alice.deleGator));
        USDC.approve(address(MORPHO_VAULT), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        MORPHO_VAULT.deposit(DEPOSIT_AMOUNT, address(users.alice.deleGator));

        // Withdrawal phase: Redeem all shares to get USDC back
        uint256 aliceSharesBalance_ = MORPHO_VAULT.balanceOf(address(users.alice.deleGator));
        uint256 expectedAssets_ = MORPHO_VAULT.previewRedeem(aliceSharesBalance_);

        vm.prank(address(users.alice.deleGator));
        uint256 assetsRedeemed_ =
            MORPHO_VAULT.redeem(aliceSharesBalance_, address(users.alice.deleGator), address(users.alice.deleGator));

        // Validation phase: Assert the full cycle
        uint256 aliceSharesAfter_ = MORPHO_VAULT.balanceOf(address(users.alice.deleGator));
        assertEq(aliceSharesAfter_, 0, "All shares should be burned");

        uint256 aliceUSDCFinalBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        uint256 expectedFinalBalance_ = INITIAL_USD_BALANCE - DEPOSIT_AMOUNT + assetsRedeemed_;
        assertEq(aliceUSDCFinalBalance_, expectedFinalBalance_, "USDC balance mismatch after withdrawal");

        // Assets redeemed should match preview (allow for small rounding errors)
        assertApproxEqAbs(assetsRedeemed_, expectedAssets_, 2, "Assets redeemed should match preview");
    }

    ////////////////////// Adapter Delegation Tests //////////////////////

    // Testing deposit via adapter using delegation
    function test_deposit_viaAdapterDelegation_usdc() public {
        // Assert initial balances
        uint256 aliceUSDCInitialBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCInitialBalance_, INITIAL_USD_BALANCE);
        uint256 aliceSharesInitial_ = MORPHO_VAULT.balanceOf(address(users.alice.deleGator));
        assertEq(aliceSharesInitial_, 0);

        // Preview expected shares (handles decimal conversion properly)
        uint256 expectedShares_ = MORPHO_VAULT.previewDeposit(DEPOSIT_AMOUNT);

        // Create transfer delegation from Alice to Bob for USDC transfer
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(morphoAdapter), address(USDC), type(uint256).max);

        // Create adapter redelegation from Bob to MorphoAdapter allowing deposit()
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), false, address(USDC), DEPOSIT_AMOUNT);

        // Arrange delegations array: [redelegation, rootDelegation]
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        // Bob calls depositByDelegation
        vm.prank(address(users.bob.deleGator));
        morphoAdapter.depositByDelegation(delegations_, address(MORPHO_VAULT), DEPOSIT_AMOUNT);

        // Assert final balances
        uint256 aliceUSDCFinal_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCFinal_, INITIAL_USD_BALANCE - DEPOSIT_AMOUNT, "USDC balance should decrease");

        uint256 aliceSharesFinal_ = MORPHO_VAULT.balanceOf(address(users.alice.deleGator));
        assertGt(aliceSharesFinal_, 0, "Shares should be minted");
        assertApproxEqAbs(aliceSharesFinal_, expectedShares_, 2, "Shares should match previewDeposit");
    }

    // Testing redeem via adapter using delegation
    function test_redeem_viaAdapterDelegation_usdc() public {
        // Setup: Deposit USDC to get vault shares
        _setupLendingState();

        // Assert initial state after deposit
        uint256 aliceUSDCAfterDeposit_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCAfterDeposit_, INITIAL_USD_BALANCE - DEPOSIT_AMOUNT);

        uint256 aliceSharesBalance_ = MORPHO_VAULT.balanceOf(address(users.alice.deleGator));
        assertGt(aliceSharesBalance_, 0, "Should have shares after deposit");

        // Create transfer delegation from Alice to Bob for vault share transfer
        // Key: Use address(MORPHO_VAULT) as the token since vault shares are ERC-20 at vault address
        Delegation memory delegation_ = _createTransferDelegation(
            address(users.bob.deleGator), address(morphoAdapter), address(MORPHO_VAULT), type(uint256).max
        );

        // Create adapter redelegation from Bob to MorphoAdapter allowing redeem()
        Delegation memory redelegation_ = _createAdapterRedelegation(
            EncoderLib._getDelegationHash(delegation_), true, address(MORPHO_VAULT), aliceSharesBalance_
        );

        // Arrange delegations array: [redelegation, rootDelegation]
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        // Bob calls redeemByDelegation
        vm.prank(address(users.bob.deleGator));
        morphoAdapter.redeemByDelegation(delegations_, address(MORPHO_VAULT), aliceSharesBalance_);

        // Assert final balances
        uint256 aliceSharesFinal_ = MORPHO_VAULT.balanceOf(address(users.alice.deleGator));
        assertEq(aliceSharesFinal_, 0, "All shares should be redeemed");

        uint256 aliceUSDCFinal_ = USDC.balanceOf(address(users.alice.deleGator));
        assertApproxEqAbs(aliceUSDCFinal_, INITIAL_USD_BALANCE, 2, "USDC should be approximately back to initial balance");
    }

    ////////////////////// Helper Functions //////////////////////

    /// @notice Sets up initial lending state (Alice deposits USDC to get vault shares)
    function _setupLendingState() internal {
        vm.prank(address(users.alice.deleGator));
        USDC.approve(address(MORPHO_VAULT), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        MORPHO_VAULT.deposit(DEPOSIT_AMOUNT, address(users.alice.deleGator));
    }

    /// @notice Creates a transfer delegation with ERC20TransferAmountEnforcer and RedeemerEnforcer
    /// @param _delegate Address that can execute the delegation
    /// @param _redeemer Address that can redeem the delegation
    /// @param _token Token to transfer
    /// @param _amount Amount to transfer
    /// @return Signed delegation ready for execution
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
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: abi.encodePacked(_token, _amount) });

        caveats_[1] = Caveat({ args: hex"", enforcer: address(redeemerEnforcer), terms: abi.encodePacked(_redeemer) });

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

    /// @notice Creates an adapter redelegation with ERC20TransferAmountEnforcer and AllowedMethodsEnforcer
    /// @param _authority Authority from the parent delegation
    /// @param _isRedeem True for redeem operations, false for deposit operations
    /// @param _token Token to transfer
    /// @param _amount Amount to transfer
    /// @return Signed delegation from Bob to the adapter
    function _createAdapterRedelegation(
        bytes32 _authority,
        bool _isRedeem,
        address _token,
        uint256 _amount
    )
        internal
        view
        returns (Delegation memory)
    {
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: abi.encodePacked(_token, _amount) });
        caveats_[1] = Caveat({
            args: hex"",
            enforcer: address(allowedMethodsEnforcer),
            terms: _isRedeem
                ? abi.encodePacked(IERC20.transfer.selector, MorphoAdapter.redeem.selector)
                : abi.encodePacked(IERC20.transfer.selector, MorphoAdapter.deposit.selector)
        });

        Delegation memory delegation_ = Delegation({
            delegate: address(morphoAdapter),
            delegator: address(users.bob.deleGator),
            authority: _authority,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        return signDelegation(users.bob, delegation_);
    }
}
