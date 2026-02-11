// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

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
    IERC20 public constant MUSD = IERC20(0xacA92E438df0B2401fF60dA7E4337B687a2435DA);
    IERC20 public aUSDC;
    IERC20 public aMUSD;
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
    AaveAdapter public aaveAdapter;

    uint256 public constant MAINNET_FORK_BLOCK = 24289219; // Use latest available block
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
        aaveAdapter = new AaveAdapter(owner, address(delegationManager), address(AAVE_POOL));

        vm.label(address(allowedTargetsEnforcer), "AllowedTargetsEnforcer");
        vm.label(address(allowedMethodsEnforcer), "AllowedMethodsEnforcer");
        vm.label(address(allowedCalldataEnforcer), "AllowedCalldataEnforcer");
        vm.label(address(valueLteEnforcer), "ValueLteEnforcer");
        vm.label(address(logicalOrWrapperEnforcer), "LogicalOrWrapperEnforcer");
        vm.label(address(erc20TransferAmountEnforcer), "ERC20TransferAmountEnforcer");
        vm.label(address(AAVE_POOL), "Aave lending");
        vm.label(address(USDC), "USDC");
        vm.label(address(MUSD), "MUSD");
        vm.label(USDC_WHALE, "USDC Whale");
        vm.label(MUSD_WHALE, "MUSD Whale");
        vm.label(address(aaveAdapter), "AaveAdapter");

        vm.deal(address(users.alice.deleGator), 1 ether);
        vm.deal(address(users.bob.deleGator), 1 ether);

        vm.prank(USDC_WHALE);
        USDC.transfer(address(users.alice.deleGator), INITIAL_USD_BALANCE); // 10k USDC

        vm.prank(MUSD_WHALE);
        MUSD.transfer(address(users.alice.deleGator), INITIAL_USD_BALANCE); // 10k MUSD

        aUSDC = IERC20(AAVE_POOL.getReserveAToken(address(USDC)));
        aMUSD = IERC20(AAVE_POOL.getReserveAToken(address(MUSD)));
    }

    // Testing directly depositing USDC to Aave to see if everything works on the forked mainnet
    function test_deposit_direct_usdc() public {
        uint256 aliceUSDCInitialBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCInitialBalance_, INITIAL_USD_BALANCE);

        vm.prank(address(users.alice.deleGator));
        USDC.approve(address(AAVE_POOL), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        AAVE_POOL.supply(address(USDC), DEPOSIT_AMOUNT, address(users.alice.deleGator), 0);

        uint256 aliceUSDCBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance_, INITIAL_USD_BALANCE - DEPOSIT_AMOUNT);

        uint256 aliceATokenBalance_ = aUSDC.balanceOf(address(users.alice.deleGator));
        // aToken balances may have 1-2 wei rounding error due to Aave's ray-based math
        assertApproxEqAbs(aliceATokenBalance_, DEPOSIT_AMOUNT, 2);
    }

    function test_deposit_direct_musd() public {
        uint256 aliceMUSDInitialBalance_ = MUSD.balanceOf(address(users.alice.deleGator));
        assertEq(aliceMUSDInitialBalance_, INITIAL_USD_BALANCE);

        vm.prank(address(users.alice.deleGator));
        MUSD.approve(address(AAVE_POOL), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        AAVE_POOL.supply(address(MUSD), DEPOSIT_AMOUNT, address(users.alice.deleGator), 0);

        uint256 aliceMUSDBalance_ = MUSD.balanceOf(address(users.alice.deleGator));
        assertEq(aliceMUSDBalance_, INITIAL_USD_BALANCE - DEPOSIT_AMOUNT);

        uint256 aliceATokenBalance_ = aMUSD.balanceOf(address(users.alice.deleGator));
        // aToken balances may have 1-2 wei rounding error due to Aave's ray-based math
        assertApproxEqAbs(aliceATokenBalance_, DEPOSIT_AMOUNT, 2);
    }

    // Testing directly withdrawing USDC from Aave to see if everything works on the forked mainnet
    function test_withdraw_direct_usdc() public {
        vm.prank(address(users.alice.deleGator));
        USDC.approve(address(AAVE_POOL), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        AAVE_POOL.supply(address(USDC), DEPOSIT_AMOUNT, address(users.alice.deleGator), 0);

        vm.prank(address(users.alice.deleGator));
        AAVE_POOL.withdraw(address(USDC), type(uint256).max, address(users.alice.deleGator));

        _assertBalances(INITIAL_USD_BALANCE, 0);
    }

    function test_withdraw_direct_musd() public {
        vm.prank(address(users.alice.deleGator));
        MUSD.approve(address(AAVE_POOL), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        AAVE_POOL.supply(address(MUSD), DEPOSIT_AMOUNT, address(users.alice.deleGator), 0);

        vm.prank(address(users.alice.deleGator));
        AAVE_POOL.withdraw(address(MUSD), type(uint256).max, address(users.alice.deleGator));
    }

    // Testing delegating approval and supply functions in 2 separate delegations
    function test_deposit_viaDelegation_usdc() public {
        _assertBalances(INITIAL_USD_BALANCE, 0);

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

        _assertBalances(INITIAL_USD_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
    }

    // Testing delegating withdrawal function in a single delegation
    function test_withdraw_viaDelegation_usdc() public {
        _setupLendingState();
        _assertBalances(INITIAL_USD_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

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

        _assertBalances(INITIAL_USD_BALANCE, 0);
    }

    // Testing delegating approval and supply functions in a single delegation using LogicalOrWrapperEnforcer
    function test_deposit_viaDelegationWithLogicalOrWrapper_usdc() public {
        // Check initial balance
        uint256 aliceUSDCInitialBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCInitialBalance_, INITIAL_USD_BALANCE);

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
            args: hex"", enforcer: address(allowedCalldataEnforcer), terms: abi.encodePacked(paramStart_, DEPOSIT_AMOUNT)
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
            args: hex"", enforcer: address(allowedCalldataEnforcer), terms: abi.encode(paramStart_, address(users.alice.deleGator))
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
        assertEq(aliceUSDCBalance_, INITIAL_USD_BALANCE - DEPOSIT_AMOUNT);

        uint256 aliceATokenBalance_ = aUSDC.balanceOf(address(users.alice.deleGator));
        // aToken balances may have 1-2 wei rounding error due to Aave's ray-based math
        assertApproxEqAbs(aliceATokenBalance_, DEPOSIT_AMOUNT, 2);
    }

    // Testing delegating transfer to adapter and then supply by delegation
    function test_deposit_viaAdapterDelegation_usdc() public {
        _assertBalances(INITIAL_USD_BALANCE, 0);

        // Create transfer delegation to adapter
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(USDC), type(uint256).max);
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), false, address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);

        _assertBalances(INITIAL_USD_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
    }

    function test_deposit_viaAdapterMultipleDelegation_usdc() public {
        _assertBalances(INITIAL_USD_BALANCE, 0);

        // Create transfer delegation from Alice to Bob for USDC transfer
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.carol.deleGator), address(aaveAdapter), address(USDC), type(uint256).max);

        Delegation memory delegation2_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.carol.deleGator),
            authority: EncoderLib._getDelegationHash(delegation_),
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });

        delegation2_ = signDelegation(users.carol, delegation2_);

        // Create adapter redelegation from Bob to MorphoAdapter allowing deposit()
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation2_), false, address(USDC), DEPOSIT_AMOUNT);

        // Arrange delegations array: [redelegation, delegation2, rootDelegation]
        Delegation[] memory delegations_ = new Delegation[](3);
        delegations_[2] = delegation_;
        delegations_[1] = delegation2_;
        delegations_[0] = redelegation_;

        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);

        _assertBalances(INITIAL_USD_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
    }

    // Testing delegating transfer to adapter using LogicalOrWrapperEnforcer with USDC and aUSDC groups
    function test_deposit_viaAdapterDelegation_usdc_withLogicalOrWrapperEnforcer() public {
        _assertBalances(INITIAL_USD_BALANCE, 0);

        // Create Group 0 - USDC Transfer caveats
        Caveat[] memory usdcCaveats_ = new Caveat[](2);
        usdcCaveats_[0] = Caveat({
            args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: abi.encodePacked(address(USDC), type(uint256).max)
        });
        usdcCaveats_[1] =
            Caveat({ args: hex"", enforcer: address(redeemerEnforcer), terms: abi.encodePacked(address(aaveAdapter)) });

        // Create Group 1 - aUSDC Transfer caveats
        Caveat[] memory aUsdcCaveats_ = new Caveat[](2);
        aUsdcCaveats_[0] = Caveat({
            args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: abi.encodePacked(address(aUSDC), type(uint256).max)
        });
        aUsdcCaveats_[1] =
            Caveat({ args: hex"", enforcer: address(redeemerEnforcer), terms: abi.encodePacked(address(aaveAdapter)) });

        // Wrap groups in LogicalOrWrapperEnforcer
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = new LogicalOrWrapperEnforcer.CaveatGroup[](2);
        groups_[0] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: usdcCaveats_ });
        groups_[1] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: aUsdcCaveats_ });

        Caveat[] memory orCaveats_ = new Caveat[](1);
        orCaveats_[0] = Caveat({ args: hex"", enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        // Create root delegation with LogicalOrWrapperEnforcer
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: orCaveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        // Create manual redelegation with ERC20TransferAmountEnforcer and AllowedMethodsEnforcer
        Caveat[] memory redelegationCaveats_ = new Caveat[](2);
        redelegationCaveats_[0] = Caveat({
            args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: abi.encodePacked(address(USDC), DEPOSIT_AMOUNT)
        });
        redelegationCaveats_[1] = Caveat({
            args: hex"",
            enforcer: address(allowedMethodsEnforcer),
            terms: abi.encodePacked(IERC20.transfer.selector, AaveAdapter.supply.selector)
        });

        Delegation memory redelegation_ = Delegation({
            delegate: address(aaveAdapter),
            delegator: address(users.bob.deleGator),
            authority: EncoderLib._getDelegationHash(delegation_),
            caveats: redelegationCaveats_,
            salt: 0,
            signature: hex""
        });
        redelegation_ = signDelegation(users.bob, redelegation_);

        // Set args to select Group 0 (USDC) for the LogicalOrWrapperEnforcer
        delegation_.caveats[0].args =
            abi.encode(LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: 0, caveatArgs: new bytes[](2) }));

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);

        _assertBalances(INITIAL_USD_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
    }

    // Testing delegating transfer to adapter and then supply by delegation (MUSD)
    function test_deposit_viaAdapterDelegation_musd() public {
        _assertBalancesMUSD(INITIAL_USD_BALANCE, 0);

        // Create transfer delegation to adapter with unlimited amount
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(MUSD), type(uint256).max);
        // Redelegation restricts to DEPOSIT_AMOUNT
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), false, address(MUSD), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(MUSD), DEPOSIT_AMOUNT);

        _assertBalancesMUSD(INITIAL_USD_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
    }

    // Testing delegating transfer of aTokens to adapter and then withdraw by delegation
    function test_withdraw_viaAdapter_usdc() public {
        _setupLendingState();
        _assertBalances(INITIAL_USD_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        // Get actual aToken balance (may differ from DEPOSIT_AMOUNT due to Aave rounding)
        uint256 actualATokenBalance_ = aUSDC.balanceOf(address(users.alice.deleGator));

        // Create transfer delegation to adapter with unlimited amount
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(aUSDC), type(uint256).max);
        // Redelegation restricts to DEPOSIT_AMOUNT
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), true, address(aUSDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        vm.prank(address(users.bob.deleGator));
        aaveAdapter.withdrawByDelegation(delegations_, address(USDC), actualATokenBalance_);

        _assertBalances(INITIAL_USD_BALANCE, 0);
    }

    // Testing delegating transfer of aTokens to adapter and then withdraw by delegation (MUSD)
    function test_withdraw_viaAdapterDelegation_musd() public {
        _setupLendingStateMUSD();
        _assertBalancesMUSD(INITIAL_USD_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        // Get actual aToken balance (may differ from DEPOSIT_AMOUNT due to Aave rounding)
        uint256 actualATokenBalance_ = aMUSD.balanceOf(address(users.alice.deleGator));

        // Create transfer delegation to adapter with unlimited amount
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(aMUSD), type(uint256).max);
        // Redelegation restricts to DEPOSIT_AMOUNT
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), true, address(aMUSD), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        vm.prank(address(users.bob.deleGator));
        aaveAdapter.withdrawByDelegation(delegations_, address(MUSD), actualATokenBalance_);

        _assertBalancesMUSD(INITIAL_USD_BALANCE, 0);
    }

    ////////////////////// Event Tests //////////////////////

    /// @notice Tests that verify events are properly emitted by AaveAdapter functions
    function test_supplyByDelegation_emitsSupplyExecutedEvent_usdc() public {
        _assertBalances(INITIAL_USD_BALANCE, 0);

        // Create transfer delegation to adapter with unlimited amount
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(USDC), type(uint256).max);
        // Redelegation restricts to DEPOSIT_AMOUNT
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), false, address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        // Expect the SupplyExecuted event to be emitted (delegate is Bob who calls the adapter)
        vm.expectEmit(true, true, true, true, address(aaveAdapter));
        emit AaveAdapter.SupplyExecuted(address(users.alice.deleGator), address(users.bob.deleGator), address(USDC), DEPOSIT_AMOUNT);

        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);

        _assertBalances(INITIAL_USD_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
    }

    /// @notice Tests that withdrawByDelegation emits the correct event when alice withdraws her own funds
    function test_withdrawByDelegation_emitsWithdrawExecutedEvent_usdc() public {
        _setupLendingState();
        _assertBalances(INITIAL_USD_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        // Get actual aToken balance (may differ from DEPOSIT_AMOUNT due to Aave rounding)
        uint256 actualATokenBalance_ = aUSDC.balanceOf(address(users.alice.deleGator));

        // Create transfer delegation to adapter with unlimited amount
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(aUSDC), type(uint256).max);
        // Redelegation restricts to DEPOSIT_AMOUNT
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), true, address(aUSDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        // Expect the WithdrawExecuted event to be emitted (delegate is Bob who calls the adapter)
        vm.expectEmit(true, true, true, true, address(aaveAdapter));
        emit AaveAdapter.WithdrawExecuted(
            address(users.alice.deleGator), address(users.bob.deleGator), address(USDC), actualATokenBalance_
        );

        vm.prank(address(users.bob.deleGator));
        aaveAdapter.withdrawByDelegation(delegations_, address(USDC), actualATokenBalance_);

        _assertBalances(INITIAL_USD_BALANCE, 0);
    }

    ////////////////////// Error Tests //////////////////////

    /// @notice Tests that verify the custom errors are properly thrown by AaveAdapter functions
    function test_supplyByDelegation_revertsOnInvalidDelegationsLength_usdc() public {
        // Create empty delegations array (0 elements)
        Delegation[] memory delegations_ = new Delegation[](0);

        vm.expectRevert(AaveAdapter.InvalidDelegationsLength.selector);
        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);

        // Create delegations array with 1 element (needs 2 or more)
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(USDC), DEPOSIT_AMOUNT);
        delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        vm.expectRevert(AaveAdapter.InvalidDelegationsLength.selector);
        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);
    }

    /// @notice Tests that supplyByDelegation reverts when called by an unauthorized caller (not the delegator of delegations[0])
    function test_supplyByDelegation_revertsOnUnauthorizedCaller_usdc() public {
        // Create valid delegations where Bob is the delegator of delegations[0]
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(USDC), type(uint256).max);
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), false, address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        // Alice tries to call but she's not delegations[0].delegator (Bob is)
        vm.expectRevert(AaveAdapter.UnauthorizedCaller.selector);
        vm.prank(address(users.alice.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);
    }

    /// @notice Tests that supplyByDelegation reverts when token is zero address
    function test_supplyByDelegation_revertsOnInvalidZeroAddress_usdc() public {
        // Create valid delegations
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(USDC), DEPOSIT_AMOUNT);
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), false, address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        vm.expectRevert(AaveAdapter.InvalidZeroAddress.selector);
        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(0), DEPOSIT_AMOUNT);
    }

    /// @notice Tests that supplyByDelegation reverts when amount exceeds the redelegation limit (USDC)
    function test_supplyByDelegation_revertsOnExcessiveAmount_usdc() public {
        _assertBalances(INITIAL_USD_BALANCE, 0);

        // Create transfer delegation to adapter with unlimited amount
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(USDC), type(uint256).max);
        // Redelegation restricts to DEPOSIT_AMOUNT
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), false, address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        // Attempt to supply more than the redelegation allows - should fail
        uint256 excessiveAmount_ = DEPOSIT_AMOUNT + 1;
        vm.expectRevert();
        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), excessiveAmount_);

        // Verify balances unchanged
        _assertBalances(INITIAL_USD_BALANCE, 0);
    }

    /// @notice Tests that supplyByDelegation reverts when amount exceeds the redelegation limit (MUSD)
    function test_supplyByDelegation_revertsOnExcessiveAmount_musd() public {
        _assertBalancesMUSD(INITIAL_USD_BALANCE, 0);

        // Create transfer delegation to adapter with unlimited amount
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(MUSD), type(uint256).max);
        // Redelegation restricts to DEPOSIT_AMOUNT
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), false, address(MUSD), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        // Attempt to supply more than the redelegation allows - should fail
        uint256 excessiveAmount_ = DEPOSIT_AMOUNT + 1;
        vm.expectRevert();
        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(MUSD), excessiveAmount_);

        // Verify balances unchanged
        _assertBalancesMUSD(INITIAL_USD_BALANCE, 0);
    }

    /// @notice Tests that withdrawByDelegation reverts when delegations array length is not exactly 2
    function test_withdrawByDelegation_revertsOnInvalidDelegationsLength_usdc() public {
        _setupLendingState();

        // Create empty delegations array (0 elements)
        Delegation[] memory delegations_ = new Delegation[](0);

        vm.expectRevert(AaveAdapter.InvalidDelegationsLength.selector);
        vm.prank(address(users.bob.deleGator));
        aaveAdapter.withdrawByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);

        // Create delegations array with 1 element (needs exactly 2 or more)
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(aUSDC), DEPOSIT_AMOUNT);
        delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        vm.expectRevert(AaveAdapter.InvalidDelegationsLength.selector);
        vm.prank(address(users.bob.deleGator));
        aaveAdapter.withdrawByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);
    }

    /// @notice Tests that withdrawByDelegation reverts when called by an unauthorized caller (not the delegator of delegations[0])
    function test_withdrawByDelegation_revertsOnUnauthorizedCaller_usdc() public {
        _setupLendingState();

        // Create valid delegations where Bob is the delegator of delegations[0]
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(aUSDC), type(uint256).max);
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), true, address(aUSDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        // Alice tries to call but she's not delegations[0].delegator (Bob is)
        vm.expectRevert(AaveAdapter.UnauthorizedCaller.selector);
        vm.prank(address(users.alice.deleGator));
        aaveAdapter.withdrawByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);
    }

    /// @notice Tests that withdrawByDelegation reverts when token is zero address
    function test_withdrawByDelegation_revertsOnInvalidZeroAddress_usdc() public {
        _setupLendingState();

        // Create valid delegations
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(aUSDC), type(uint256).max);
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), true, address(aUSDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        vm.expectRevert(AaveAdapter.InvalidZeroAddress.selector);
        vm.prank(address(users.bob.deleGator));
        aaveAdapter.withdrawByDelegation(delegations_, address(0), DEPOSIT_AMOUNT);
    }

    ////////////////////// Constructor Error Tests //////////////////////

    /// @notice Tests that constructor reverts when owner is zero address
    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AaveAdapter(address(0), address(delegationManager), address(AAVE_POOL));
    }

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
    function test_supplyByDelegation_withMaxAmount_usdc() public {
        // First, we need to ensure Alice has sufficient balance for a reasonable test
        uint256 testAmount_ = INITIAL_USD_BALANCE; // Use all her balance

        _assertBalances(INITIAL_USD_BALANCE, 0);

        // Create transfer delegation to adapter with unlimited amount
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(USDC), type(uint256).max);
        // Redelegation restricts to testAmount_
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), false, address(USDC), testAmount_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), testAmount_);

        _assertBalances(0, testAmount_);
    }

    /// @notice Tests withdrawByDelegation with maximum uint256 amount (withdraw all)
    function test_withdrawByDelegation_withMaxAmount_usdc() public {
        _setupLendingState();
        _assertBalances(INITIAL_USD_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        // Get Alice's actual aToken balance and use a high limit for delegation
        uint256 aTokenBalance_ = aUSDC.balanceOf(address(users.alice.deleGator));

        // Create transfer delegation to adapter with unlimited amount
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(aUSDC), type(uint256).max);
        // Redelegation with high limit for max amount withdrawal
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), true, address(aUSDC), type(uint128).max);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        vm.prank(address(users.bob.deleGator));
        aaveAdapter.withdrawByDelegation(delegations_, address(USDC), aTokenBalance_);

        _assertBalances(INITIAL_USD_BALANCE, 0);
    }

    /// @notice Tests that adapter properly handles allowance management
    function test_ensureAllowance_increasesWhenNeeded_usdc() public {
        _assertBalances(INITIAL_USD_BALANCE, 0);

        // Create transfer delegation to adapter with unlimited amount
        Delegation memory delegation_ =
            _createTransferDelegation(address(users.bob.deleGator), address(aaveAdapter), address(USDC), type(uint256).max);
        // Redelegation restricts to DEPOSIT_AMOUNT
        Delegation memory redelegation_ =
            _createAdapterRedelegation(EncoderLib._getDelegationHash(delegation_), false, address(USDC), DEPOSIT_AMOUNT);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[1] = delegation_;
        delegations_[0] = redelegation_;

        // Check initial allowance (should be 0)
        uint256 initialAllowance = USDC.allowance(address(aaveAdapter), address(AAVE_POOL));
        assertEq(initialAllowance, 0);

        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegation(delegations_, address(USDC), DEPOSIT_AMOUNT);

        // safeIncreaseAllowance adds DEPOSIT_AMOUNT to allowance, then Aave consumes it
        // Final allowance should be 0 after the supply
        uint256 finalAllowance = USDC.allowance(address(aaveAdapter), address(AAVE_POOL));
        assertEq(finalAllowance, 0);

        _assertBalances(INITIAL_USD_BALANCE - DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
    }

    /// @notice Tests multiple supplies - each supply increases and then consumes allowance
    function test_ensureAllowance_doesNotIncreaseWhenSufficient_usdc() public {
        _assertBalances(INITIAL_USD_BALANCE, 0);

        // First supply - create delegations with salt 0 and unlimited initial amount
        Delegation memory delegation1_ = _createTransferDelegationWithSalt(
            address(users.bob.deleGator), address(aaveAdapter), address(USDC), type(uint256).max, 0
        );
        // Redelegation restricts to DEPOSIT_AMOUNT
        Delegation memory redelegation1_ = _createAdapterRedelegationWithSalt(
            EncoderLib._getDelegationHash(delegation1_), false, address(USDC), DEPOSIT_AMOUNT, 0
        );

        Delegation[] memory delegations1_ = new Delegation[](2);
        delegations1_[1] = delegation1_;
        delegations1_[0] = redelegation1_;

        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegation(delegations1_, address(USDC), DEPOSIT_AMOUNT);

        // After first supply: safeIncreaseAllowance added DEPOSIT_AMOUNT, Aave consumed it
        uint256 allowanceAfterFirst_ = USDC.allowance(address(aaveAdapter), address(AAVE_POOL));
        assertEq(allowanceAfterFirst_, 0, "Allowance after first supply should be 0");

        // Second supply - create delegations with salt 1 (different delegation) and unlimited initial amount
        Delegation memory delegation2_ = _createTransferDelegationWithSalt(
            address(users.bob.deleGator), address(aaveAdapter), address(USDC), type(uint256).max, 1
        );
        // Redelegation restricts to DEPOSIT_AMOUNT
        Delegation memory redelegation2_ = _createAdapterRedelegationWithSalt(
            EncoderLib._getDelegationHash(delegation2_), false, address(USDC), DEPOSIT_AMOUNT, 1
        );

        Delegation[] memory delegations2_ = new Delegation[](2);
        delegations2_[1] = delegation2_;
        delegations2_[0] = redelegation2_;

        vm.prank(address(users.bob.deleGator));
        aaveAdapter.supplyByDelegation(delegations2_, address(USDC), DEPOSIT_AMOUNT);

        // After second supply: safeIncreaseAllowance added DEPOSIT_AMOUNT, Aave consumed it
        uint256 allowanceAfterSecond_ = USDC.allowance(address(aaveAdapter), address(AAVE_POOL));
        assertEq(allowanceAfterSecond_, 0, "Allowance after second supply should be 0");

        // Check USDC balance
        uint256 aliceUSDCBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance_, INITIAL_USD_BALANCE - (2 * DEPOSIT_AMOUNT), "USDC balance mismatch");

        // Check aUSDC balance (allow for rounding errors: up to 2 wei per operation, so ~4 wei for 2 deposits)
        uint256 aliceATokenBalance_ = aUSDC.balanceOf(address(users.alice.deleGator));
        assertApproxEqAbs(aliceATokenBalance_, 2 * DEPOSIT_AMOUNT, 4, "aUSDC balance should be approximately 2x deposit amount");
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
        aaveAdapter.withdrawEmergency(testToken_, 50 ether, address(users.alice.deleGator));

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
        aaveAdapter.withdrawEmergency(testToken_, 50 ether, address(users.alice.deleGator));

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
        aaveAdapter.withdrawEmergency(testToken_, 100 ether, address(users.bob.deleGator));

        // Verify all tokens were withdrawn
        assertEq(testToken_.balanceOf(address(aaveAdapter)), 0);
        assertEq(testToken_.balanceOf(address(users.bob.deleGator)), 100 ether);
    }

    /// @notice Tests that withdrawEmergency reverts when recipient is zero address
    function test_withdrawEmergency_revertsOnInvalidRecipient() public {
        // Create test token and give some balance to the adapter
        BasicERC20 testToken_ = new BasicERC20(owner, "TestToken", "TST", 1000 ether);

        // Mint some tokens to the adapter
        vm.prank(owner);
        testToken_.mint(address(aaveAdapter), 100 ether);

        // Try to withdraw to zero address (should fail)
        vm.expectRevert(AaveAdapter.InvalidRecipient.selector);
        vm.prank(owner);
        aaveAdapter.withdrawEmergency(testToken_, 50 ether, address(0));
    }

    ////////////////////// onlySelf Modifier Tests //////////////////////

    /// @notice Tests that supply function reverts when called externally (not by self)
    function test_supply_revertsOnNotSelf() public {
        vm.expectRevert(AaveAdapter.NotSelf.selector);
        aaveAdapter.supply(address(USDC), DEPOSIT_AMOUNT, address(users.alice.deleGator));
    }

    /// @notice Tests that withdraw function (not withdrawEmergency) reverts when called externally
    function test_aaveWithdraw_revertsOnNotSelf() public {
        vm.expectRevert(AaveAdapter.NotSelf.selector);
        aaveAdapter.withdraw(address(USDC), DEPOSIT_AMOUNT, address(users.alice.deleGator));
    }

    ////////////////////// executeFromExecutor Tests //////////////////////

    /// @notice Tests that executeFromExecutor reverts when caller is not the delegation manager
    function test_executeFromExecutor_revertsOnNotDelegationManager() public {
        ModeCode mode_ = ModeLib.encodeSimpleSingle();
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(address(USDC), 0, hex"");

        vm.expectRevert(AaveAdapter.NotDelegationManager.selector);
        vm.prank(address(users.alice.deleGator));
        aaveAdapter.executeFromExecutor(mode_, executionCallData_);
    }

    /// @notice Tests that executeFromExecutor reverts on unsupported call type (batch)
    function test_executeFromExecutor_revertsOnUnsupportedCallType() public {
        // Create a mode with CALLTYPE_BATCH instead of CALLTYPE_SINGLE
        ModeCode mode_ = ModeLib.encode(CALLTYPE_BATCH, ExecType.wrap(0x00), MODE_DEFAULT, ModePayload.wrap(0x00));
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(address(USDC), 0, hex"");

        vm.expectRevert(abi.encodeWithSelector(AaveAdapter.UnsupportedCallType.selector, CALLTYPE_BATCH));
        vm.prank(address(delegationManager));
        aaveAdapter.executeFromExecutor(mode_, executionCallData_);
    }

    /// @notice Tests that executeFromExecutor reverts on unsupported exec type (try)
    function test_executeFromExecutor_revertsOnUnsupportedExecType() public {
        // Create a mode with EXECTYPE_TRY instead of EXECTYPE_DEFAULT
        ModeCode mode_ = ModeLib.encode(CallType.wrap(0x00), EXECTYPE_TRY, MODE_DEFAULT, ModePayload.wrap(0x00));
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(address(USDC), 0, hex"");

        vm.expectRevert(abi.encodeWithSelector(AaveAdapter.UnsupportedExecType.selector, EXECTYPE_TRY));
        vm.prank(address(delegationManager));
        aaveAdapter.executeFromExecutor(mode_, executionCallData_);
    }

    ////////////////////// Helpers //////////////////////

    /// @notice Creates a transfer delegation with ERC20TransferAmountEnforcer
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
        return _createTransferDelegationWithSalt(_delegate, _redeemer, _token, _amount, 0);
    }

    /// @notice Creates a transfer delegation with ERC20TransferAmountEnforcer and custom salt
    /// @param _delegate Address that can execute the delegation
    /// @param _redeemer Address that can redeem the delegation
    /// @param _token Token to transfer
    /// @param _amount Amount to transfer
    /// @param _salt Salt for unique delegation hash
    /// @return Signed delegation ready for execution
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
        Caveat[] memory caveats_ = new Caveat[](2);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(erc20TransferAmountEnforcer), terms: abi.encodePacked(_token, _amount) });

        caveats_[1] = Caveat({ args: hex"", enforcer: address(redeemerEnforcer), terms: abi.encodePacked(_redeemer) });

        Delegation memory delegation_ = Delegation({
            delegate: _delegate,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: _salt,
            signature: hex""
        });

        return signDelegation(users.alice, delegation_);
    }

    function _createAdapterRedelegation(
        bytes32 _authority,
        bool withdrawDeposit,
        address _token,
        uint256 _amount
    )
        internal
        view
        returns (Delegation memory)
    {
        return _createAdapterRedelegationWithSalt(_authority, withdrawDeposit, _token, _amount, 0);
    }

    function _createAdapterRedelegationWithSalt(
        bytes32 _authority,
        bool withdrawDeposit,
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
        caveats_[1] = Caveat({
            args: hex"",
            enforcer: address(allowedMethodsEnforcer),
            terms: withdrawDeposit
                ? abi.encodePacked(IERC20.transfer.selector, AaveAdapter.withdraw.selector)
                : abi.encodePacked(IERC20.transfer.selector, AaveAdapter.supply.selector)
        });

        Delegation memory delegation_ = Delegation({
            delegate: address(aaveAdapter),
            delegator: address(users.bob.deleGator),
            authority: _authority,
            caveats: caveats_,
            salt: _salt,
            signature: hex""
        });

        return signDelegation(users.bob, delegation_);
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
            args: hex"", enforcer: address(allowedCalldataEnforcer), terms: abi.encode(paramStart_, address(users.alice.deleGator))
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
        caveats_[1] = Caveat({
            args: hex"", enforcer: address(allowedMethodsEnforcer), terms: abi.encodePacked(IAavePool.withdraw.selector)
        });

        // Restrict to parameter to Alice
        uint256 paramStart_ = abi.encodeWithSelector(IAavePool.withdraw.selector, address(0), uint256(0)).length;
        caveats_[2] = Caveat({
            args: hex"", enforcer: address(allowedCalldataEnforcer), terms: abi.encode(paramStart_, address(users.alice.deleGator))
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

    /// @notice Sets up initial lending state (Alice deposits MUSD to get aTokens)
    function _setupLendingStateMUSD() internal {
        vm.prank(address(users.alice.deleGator));
        MUSD.approve(address(AAVE_POOL), DEPOSIT_AMOUNT);
        vm.prank(address(users.alice.deleGator));
        AAVE_POOL.supply(address(MUSD), DEPOSIT_AMOUNT, address(users.alice.deleGator), 0);
    }

    /// @notice Asserts Alice's token and aToken balances
    /// @param _token The underlying token (USDC or MUSD)
    /// @param _aToken The corresponding aToken (aUSDC or aMUSD)
    /// @param _expectedToken Expected underlying token balance
    /// @param _expectedAToken Expected aToken balance
    function _assertBalances(IERC20 _token, IERC20 _aToken, uint256 _expectedToken, uint256 _expectedAToken) internal {
        uint256 aliceTokenBalance_ = _token.balanceOf(address(users.alice.deleGator));
        // Token balance should be exact (no rounding on ERC20 transfers)
        assertApproxEqAbs(aliceTokenBalance_, _expectedToken, 2, "Token balance mismatch");

        uint256 aliceATokenBalance_ = _aToken.balanceOf(address(users.alice.deleGator));
        // aToken balances may have 1-2 wei rounding error due to Aave's ray-based math
        assertApproxEqAbs(aliceATokenBalance_, _expectedAToken, 2, "aToken balance mismatch");
    }

    /// @notice Convenience function for USDC/aUSDC balance assertions (backwards compatibility)
    /// @param _expectedUSDC Expected USDC balance
    /// @param _expectedAUSDC Expected aUSDC balance
    function _assertBalances(uint256 _expectedUSDC, uint256 _expectedAUSDC) internal {
        _assertBalances(USDC, aUSDC, _expectedUSDC, _expectedAUSDC);
    }

    /// @notice Convenience function for MUSD/aMUSD balance assertions
    /// @param _expectedMUSD Expected MUSD balance
    /// @param _expectedAMUSD Expected aMUSD balance
    function _assertBalancesMUSD(uint256 _expectedMUSD, uint256 _expectedAMUSD) internal {
        _assertBalances(MUSD, aMUSD, _expectedMUSD, _expectedAMUSD);
    }
}
