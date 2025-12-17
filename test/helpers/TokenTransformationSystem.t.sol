// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { BaseTest } from "../utils/BaseTest.t.sol";
import { Implementation, SignatureType } from "../utils/Types.t.sol";
import { Execution, Delegation, Caveat, ModeCode } from "../../src/utils/Types.sol";
import { TokenTransformationEnforcer } from "../../src/enforcers/TokenTransformationEnforcer.sol";
import { AdapterManager } from "../../src/helpers/adapters/AdapterManager.sol";
import { AaveAdapter } from "../../src/helpers/adapters/AaveAdapter.sol";
import { IAdapter } from "../../src/helpers/interfaces/IAdapter.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { TimestampEnforcer } from "../../src/enforcers/TimestampEnforcer.sol";

// Aave interfaces
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveAToken(address asset) external view returns (address);
}

interface IAaveDataProvider {
    function getReserveTokensAddresses(address asset) external view returns (address aTokenAddress, address, address);
}

interface IATokenWrapper {
    function wrap(address aToken, uint256 amount) external returns (uint256 wrappedAmount);
    function unwrap(address aToken, uint256 wrappedAmount) external returns (uint256 aTokenAmount);
    function getWrappedToken(address aToken) external view returns (address wrappedToken);
}

// @dev Do not remove this comment below
/// forge-config: default.evm_version = "shanghai"

/**
 * @title TokenTransformationSystem Test
 * @notice Integration tests for the token transformation system with Aave V3
 * @dev Uses a forked Ethereum mainnet environment to test real contract interactions
 */
contract TokenTransformationSystemTest is BaseTest {
    using ModeLib for ModeCode;
    using SafeERC20 for IERC20;

    ////////////////////////////// Constants //////////////////////////////

    IAavePool public constant AAVE_POOL = IAavePool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address public constant AAVE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address public constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;

    uint256 public constant MAINNET_FORK_BLOCK = 24029630;

    uint256 public constant INITIAL_USDC_BALANCE = 10000000000; // 10k USDC (6 decimals)
    uint256 public constant DEPOSIT_AMOUNT = 1000000000; // 1k USDC

    ////////////////////////////// State //////////////////////////////

    TokenTransformationEnforcer public tokenTransformationEnforcer;
    AdapterManager public adapterManager;
    AaveAdapter public aaveAdapter;
    IERC20 public aUSDC;
    address public aTokenWrapper; // Mock wrapper for testing
    TimestampEnforcer public timestampEnforcer;

    ////////////////////////////// Setup //////////////////////////////

    function setUp() public override {
        // Create fork from mainnet at specific block
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);

        // Set implementation type
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;

        // Call parent setup to initialize delegation framework
        super.setUp();

        address owner_ = makeAddr("AdapterManager Owner");

        adapterManager = new AdapterManager(owner_, delegationManager);
        tokenTransformationEnforcer = new TokenTransformationEnforcer(address(adapterManager));

        // Set the enforcer on AdapterManager
        vm.prank(adapterManager.owner());
        adapterManager.setTokenTransformationEnforcer(tokenTransformationEnforcer);

        vm.label(address(tokenTransformationEnforcer), "TokenTransformationEnforcer");
        vm.label(address(adapterManager), "AdapterManager");

        // Note: The enforcer's adapterManager immutable points to placeholder, but adapterManager
        // has the real enforcer. When adapterManager calls enforcer.updateAssetState, we need to
        // ensure the call works. We'll use a helper contract or modify the test approach.

        // Deploy mock ATokenWrapper (for testing - in production this would be a real contract)
        aTokenWrapper = address(new MockATokenWrapper());
        vm.label(aTokenWrapper, "ATokenWrapper");

        // Deploy TimestampEnforcer for testing with multiple caveats (set to future so it doesn't restrict)
        timestampEnforcer = new TimestampEnforcer();
        vm.label(address(timestampEnforcer), "TimestampEnforcer");

        // Deploy AaveAdapter
        aaveAdapter = new AaveAdapter(address(AAVE_POOL), AAVE_DATA_PROVIDER, aTokenWrapper);
        vm.label(address(aaveAdapter), "AaveAdapter");

        // Register Aave adapter in AdapterManager
        vm.prank(adapterManager.owner());
        adapterManager.registerProtocolAdapter(address(AAVE_POOL), address(aaveAdapter));

        // Get aUSDC address
        aUSDC = IERC20(AAVE_POOL.getReserveAToken(address(USDC)));
        vm.label(address(aUSDC), "aUSDC");

        // Labels
        vm.label(address(AAVE_POOL), "Aave Pool");
        vm.label(address(USDC), "USDC");
        vm.label(USDC_WHALE, "USDC Whale");

        // Fund Alice's deleGator with USDC
        vm.deal(address(users.alice.deleGator), 1 ether);
        vm.prank(USDC_WHALE);
        USDC.transfer(address(users.alice.deleGator), INITIAL_USDC_BALANCE);
    }

    ////////////////////////////// Helper Functions //////////////////////////////

    /// @notice Creates a delegation with TokenTransformationEnforcer as the first caveat (required by AdapterManager)
    /// @dev TokenTransformationEnforcer MUST be at index 0 of the root delegation's caveats
    /// @dev For the leaf delegation, the caller must be the delegator
    function _createTokenTransformationDelegation(
        address _delegate,
        address _token,
        uint256 _amount
    )
        internal
        view
        returns (Delegation memory)
    {
        bytes memory terms_ = abi.encodePacked(_token, _amount);
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(tokenTransformationEnforcer), terms: terms_ });

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

    /// @notice Creates a leaf delegation where the caller is the delegator (required for executeProtocolActionByDelegation)
    /// @dev The delegator must be the caller (msg.sender) for the first delegation in the chain
    /// @dev Note: The leaf delegation doesn't need TokenTransformationEnforcer - it's only required in the root delegation
    function _createLeafDelegation(
        address _callerDeleGator,
        bytes32 _parentDelegationHash
    )
        internal
        pure
        returns (Delegation memory)
    {
        // Leaf delegation has no caveats - validation happens at root level
        Caveat[] memory caveats_ = new Caveat[](0);

        Delegation memory delegation_ = Delegation({
            delegate: address(0), // Will be set by caller
            delegator: _callerDeleGator,
            authority: _parentDelegationHash,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        return delegation_;
    }

    /// @notice Asserts balances for Alice's deleGator
    function _assertBalances(uint256 expectedUSDC, uint256 expectedAUSDC) internal {
        uint256 aliceUSDCBalance_ = USDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceUSDCBalance_, expectedUSDC, "USDC balance mismatch");

        uint256 aliceATokenBalance_ = aUSDC.balanceOf(address(users.alice.deleGator));
        assertEq(aliceATokenBalance_, expectedAUSDC, "aUSDC balance mismatch");
    }

    /// @notice Asserts available amounts in enforcer
    function _assertAvailableAmounts(bytes32 _delegationHash, address _token, uint256 _expectedAmount) internal {
        uint256 available_ = tokenTransformationEnforcer.getAvailableAmount(_delegationHash, _token);
        assertEq(available_, _expectedAmount, "Available amount mismatch");
    }

    ////////////////////////////// Tests //////////////////////////////

    /// @notice Test direct deposit to Aave (baseline test)
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
        // Aave may return slightly less due to interest accrual (allow 1 wei tolerance)
        assertGe(aliceATokenBalance_, DEPOSIT_AMOUNT - 1, "aToken balance should be close to deposit amount");
        assertLe(aliceATokenBalance_, DEPOSIT_AMOUNT, "aToken balance should not exceed deposit amount");
    }

    /// @notice Test token transformation flow: deposit USDC → get wrapped aUSDC
    function test_depositViaDelegation_tracksTransformation() public {
        // Create root delegation: Alice delegates to Bob
        Delegation memory rootDelegation_ =
            _createTokenTransformationDelegation(address(users.bob.deleGator), address(USDC), DEPOSIT_AMOUNT);
        bytes32 rootDelegationHash_ = EncoderLib._getDelegationHash(rootDelegation_);

        // Create leaf delegation: Bob delegates to AdapterManager
        Delegation memory leafDelegation_ = _createLeafDelegation(address(users.bob.deleGator), rootDelegationHash_);
        leafDelegation_.delegate = address(adapterManager);
        leafDelegation_ = signDelegation(users.bob, leafDelegation_);
        bytes32 delegationHash_ = rootDelegationHash_;

        // Verify initial state
        assertEq(tokenTransformationEnforcer.getAvailableAmount(delegationHash_, address(USDC)), 0);
        assertEq(tokenTransformationEnforcer.isInitialized(delegationHash_), false);

        // Execute protocol action via AdapterManager
        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = leafDelegation_; // Leaf delegation (Bob -> AdapterManager)
        delegations_[1] = rootDelegation_; // Root delegation (Alice -> Bob)

        bytes memory originalActionData_ = abi.encode(address(adapterManager));
        bytes memory actionData_ = abi.encode("deposit", originalActionData_);

        vm.prank(address(users.bob.deleGator));
        adapterManager.executeProtocolActionByDelegation(address(AAVE_POOL), USDC, DEPOSIT_AMOUNT, actionData_, delegations_);

        // Get wrapped token address AFTER wrapping (it's created during the first wrap)
        address wrappedToken_ = IATokenWrapper(aTokenWrapper).getWrappedToken(address(aUSDC));
        require(wrappedToken_ != address(0), "Wrapped token should be created");

        // Verify tokens were transferred to Alice (root delegator)
        assertEq(USDC.balanceOf(address(users.alice.deleGator)), INITIAL_USDC_BALANCE - DEPOSIT_AMOUNT);

        // Verify wrapped tokens were received (Aave may return slightly less due to interest accrual)
        uint256 wrappedBalance_ = IERC20(wrappedToken_).balanceOf(address(users.alice.deleGator));
        assertGe(wrappedBalance_, DEPOSIT_AMOUNT - 1, "Wrapped token balance should be close to deposit amount");
        assertLe(wrappedBalance_, DEPOSIT_AMOUNT, "Wrapped token balance should not exceed deposit amount");

        // Verify enforcer state was updated
        assertEq(tokenTransformationEnforcer.getAvailableAmount(delegationHash_, address(USDC)), 0, "USDC should be fully spent");
        uint256 trackedAmount_ = tokenTransformationEnforcer.getAvailableAmount(delegationHash_, wrappedToken_);
        assertGe(trackedAmount_, wrappedBalance_ - 1, "Wrapped token should be tracked");
        assertLe(trackedAmount_, wrappedBalance_ + 1, "Wrapped token should be tracked");
    }

    /// @notice Test partial deposit: use only part of delegated amount
    function test_partialDeposit_tracksRemaining() public {
        uint256 delegatedAmount_ = DEPOSIT_AMOUNT * 2; // 2000 USDC
        uint256 depositAmount_ = DEPOSIT_AMOUNT; // 1000 USDC

        // Create root delegation: Alice delegates to Bob
        Delegation memory rootDelegation_ =
            _createTokenTransformationDelegation(address(users.bob.deleGator), address(USDC), delegatedAmount_);
        bytes32 rootDelegationHash_ = EncoderLib._getDelegationHash(rootDelegation_);
        bytes32 delegationHash_ = rootDelegationHash_;

        // Create leaf delegation: Bob delegates to AdapterManager
        Delegation memory leafDelegation_ = _createLeafDelegation(address(users.bob.deleGator), rootDelegationHash_);
        leafDelegation_.delegate = address(adapterManager);
        leafDelegation_ = signDelegation(users.bob, leafDelegation_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = leafDelegation_; // Leaf delegation (Bob -> AdapterManager)
        delegations_[1] = rootDelegation_; // Root delegation (Alice -> Bob)

        bytes memory originalActionData_ = abi.encode(address(adapterManager));
        bytes memory actionData_ = abi.encode("deposit", originalActionData_);

        vm.prank(address(users.bob.deleGator));
        adapterManager.executeProtocolActionByDelegation(address(AAVE_POOL), USDC, depositAmount_, actionData_, delegations_);

        // Verify remaining USDC is still available
        assertEq(
            tokenTransformationEnforcer.getAvailableAmount(delegationHash_, address(USDC)),
            delegatedAmount_ - depositAmount_,
            "Remaining USDC should be tracked"
        );

        // Get wrapped token address AFTER wrapping
        address wrappedToken_ = IATokenWrapper(aTokenWrapper).getWrappedToken(address(aUSDC));
        require(wrappedToken_ != address(0), "Wrapped token should be created");
        uint256 wrappedBalance_ = IERC20(wrappedToken_).balanceOf(address(users.alice.deleGator));

        // Verify wrapped tokens were added
        uint256 trackedWrapped_ = tokenTransformationEnforcer.getAvailableAmount(delegationHash_, wrappedToken_);
        assertGe(trackedWrapped_, wrappedBalance_ - 1, "Wrapped token should be tracked");
        assertLe(trackedWrapped_, wrappedBalance_ + 1, "Wrapped token should be tracked");
    }

    /// @notice Test withdraw flow: wrapped aUSDC → USDC
    function test_withdrawViaDelegation_tracksTransformation() public {
        // First, deposit to get wrapped tokens
        // Create root delegation: Alice delegates to Bob
        Delegation memory depositRootDelegation_ =
            _createTokenTransformationDelegation(address(users.bob.deleGator), address(USDC), DEPOSIT_AMOUNT);
        bytes32 depositRootDelegationHash_ = EncoderLib._getDelegationHash(depositRootDelegation_);

        // Create leaf delegation: Bob delegates to AdapterManager
        Delegation memory depositLeafDelegation_ = _createLeafDelegation(address(users.bob.deleGator), depositRootDelegationHash_);
        depositLeafDelegation_.delegate = address(adapterManager);
        depositLeafDelegation_ = signDelegation(users.bob, depositLeafDelegation_);

        Delegation[] memory depositDelegations_ = new Delegation[](2);
        depositDelegations_[0] = depositLeafDelegation_; // Leaf delegation (Bob -> AdapterManager)
        depositDelegations_[1] = depositRootDelegation_; // Root delegation (Alice -> Bob)

        bytes memory originalDepositActionData_ = abi.encode(address(adapterManager));
        bytes memory depositActionData_ = abi.encode("deposit", originalDepositActionData_);

        vm.prank(address(users.bob.deleGator));
        adapterManager.executeProtocolActionByDelegation(
            address(AAVE_POOL), USDC, DEPOSIT_AMOUNT, depositActionData_, depositDelegations_
        );

        address wrappedToken_ = IATokenWrapper(aTokenWrapper).getWrappedToken(address(aUSDC));
        require(wrappedToken_ != address(0), "Wrapped token should be created");
        // Get actual wrapped amount received (may be slightly less due to Aave interest accrual)
        uint256 wrappedAmount_ = IERC20(wrappedToken_).balanceOf(address(users.alice.deleGator));
        require(wrappedAmount_ > 0, "Should have wrapped tokens");

        // Now create delegation for withdrawal using wrapped tokens
        // Create root delegation: Alice delegates to Bob
        Delegation memory withdrawRootDelegation_ =
            _createTokenTransformationDelegation(address(users.bob.deleGator), wrappedToken_, wrappedAmount_);
        bytes32 withdrawRootDelegationHash_ = EncoderLib._getDelegationHash(withdrawRootDelegation_);
        bytes32 withdrawDelegationHash_ = withdrawRootDelegationHash_;

        // Note: In a real scenario, we'd use the same delegationHash, but for testing
        // we'll simulate by updating the enforcer state manually first
        vm.prank(address(adapterManager));
        tokenTransformationEnforcer.updateAssetState(withdrawDelegationHash_, wrappedToken_, wrappedAmount_);

        // Create leaf delegation: Bob delegates to AdapterManager
        Delegation memory withdrawLeafDelegation_ = _createLeafDelegation(address(users.bob.deleGator), withdrawRootDelegationHash_);
        withdrawLeafDelegation_.delegate = address(adapterManager);
        withdrawLeafDelegation_ = signDelegation(users.bob, withdrawLeafDelegation_);

        Delegation[] memory withdrawDelegations_ = new Delegation[](2);
        withdrawDelegations_[0] = withdrawLeafDelegation_; // Leaf delegation (Bob -> AdapterManager)
        withdrawDelegations_[1] = withdrawRootDelegation_; // Root delegation (Alice -> Bob)

        bytes memory originalWithdrawActionData_ = abi.encode(address(adapterManager), address(USDC));
        bytes memory withdrawActionData_ = abi.encode("withdraw", originalWithdrawActionData_);

        uint256 usdcBalanceBefore_ = USDC.balanceOf(address(users.alice.deleGator));

        vm.prank(address(users.bob.deleGator));
        adapterManager.executeProtocolActionByDelegation(
            address(AAVE_POOL), IERC20(wrappedToken_), wrappedAmount_, withdrawActionData_, withdrawDelegations_
        );

        // Verify USDC was received
        uint256 usdcBalanceAfter_ = USDC.balanceOf(address(users.alice.deleGator));
        assertGt(usdcBalanceAfter_, usdcBalanceBefore_, "USDC should increase after withdraw");

        // Verify wrapped tokens were deducted
        assertEq(
            tokenTransformationEnforcer.getAvailableAmount(withdrawDelegationHash_, wrappedToken_),
            0,
            "Wrapped tokens should be fully spent"
        );
    }

    /// @notice Test multiple transformations: USDC → wrapped aUSDC → USDC
    function test_multipleTransformations_tracksAllTokens() public {
        uint256 initialAmount_ = DEPOSIT_AMOUNT * 2; // 2000 USDC

        // Create root delegation: Alice delegates to Bob
        Delegation memory rootDelegation_ =
            _createTokenTransformationDelegation(address(users.bob.deleGator), address(USDC), initialAmount_);
        bytes32 rootDelegationHash_ = EncoderLib._getDelegationHash(rootDelegation_);
        bytes32 delegationHash_ = rootDelegationHash_;

        // Create leaf delegation: Bob delegates to AdapterManager
        Delegation memory leafDelegation_ = _createLeafDelegation(address(users.bob.deleGator), rootDelegationHash_);
        leafDelegation_.delegate = address(adapterManager);
        leafDelegation_ = signDelegation(users.bob, leafDelegation_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = leafDelegation_; // Leaf delegation (Bob -> AdapterManager)
        delegations_[1] = rootDelegation_; // Root delegation (Alice -> Bob)

        bytes memory originalActionData_ = abi.encode(address(adapterManager));
        bytes memory actionData_ = abi.encode("deposit", originalActionData_);

        // Step 1: Deposit 1000 USDC
        vm.prank(address(users.bob.deleGator));
        adapterManager.executeProtocolActionByDelegation(address(AAVE_POOL), USDC, DEPOSIT_AMOUNT, actionData_, delegations_);

        address wrappedToken_ = IATokenWrapper(aTokenWrapper).getWrappedToken(address(aUSDC));
        require(wrappedToken_ != address(0), "Wrapped token should be created");
        uint256 wrappedAmount1_ = IERC20(wrappedToken_).balanceOf(address(users.alice.deleGator));

        // Verify state after deposit
        assertEq(
            tokenTransformationEnforcer.getAvailableAmount(delegationHash_, address(USDC)),
            DEPOSIT_AMOUNT,
            "Remaining USDC should be tracked"
        );
        uint256 trackedWrapped1_ = tokenTransformationEnforcer.getAvailableAmount(delegationHash_, wrappedToken_);
        assertGe(trackedWrapped1_, wrappedAmount1_ - 1, "Wrapped tokens should be tracked");
        assertLe(trackedWrapped1_, wrappedAmount1_ + 1, "Wrapped tokens should be tracked");

        // Step 2: Use remaining 1000 USDC for another deposit
        vm.prank(address(users.bob.deleGator));
        adapterManager.executeProtocolActionByDelegation(address(AAVE_POOL), USDC, DEPOSIT_AMOUNT, actionData_, delegations_);

        uint256 wrappedAmount2_ = IERC20(wrappedToken_).balanceOf(address(users.alice.deleGator));

        // Verify final state
        assertEq(tokenTransformationEnforcer.getAvailableAmount(delegationHash_, address(USDC)), 0, "All USDC should be spent");
        uint256 trackedWrapped2_ = tokenTransformationEnforcer.getAvailableAmount(delegationHash_, wrappedToken_);
        assertGe(trackedWrapped2_, wrappedAmount2_ - 1, "All wrapped tokens should be tracked");
        assertLe(trackedWrapped2_, wrappedAmount2_ + 1, "All wrapped tokens should be tracked");
    }

    /// @notice Test that exceeding available amount fails
    function test_exceedingAvailableAmount_fails() public {
        // Create root delegation: Alice delegates to Bob
        Delegation memory rootDelegation_ =
            _createTokenTransformationDelegation(address(users.bob.deleGator), address(USDC), DEPOSIT_AMOUNT);
        bytes32 rootDelegationHash_ = EncoderLib._getDelegationHash(rootDelegation_);

        // Create leaf delegation: Bob delegates to AdapterManager
        Delegation memory leafDelegation_ = _createLeafDelegation(address(users.bob.deleGator), rootDelegationHash_);
        leafDelegation_.delegate = address(adapterManager);
        leafDelegation_ = signDelegation(users.bob, leafDelegation_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = leafDelegation_; // Leaf delegation (Bob -> AdapterManager)
        delegations_[1] = rootDelegation_; // Root delegation (Alice -> Bob)

        bytes memory originalActionData_ = abi.encode(address(adapterManager));
        bytes memory actionData_ = abi.encode("deposit", originalActionData_);

        uint256 excessiveAmount_ = DEPOSIT_AMOUNT + 1;

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert();
        adapterManager.executeProtocolActionByDelegation(address(AAVE_POOL), USDC, excessiveAmount_, actionData_, delegations_);
    }

    /// @notice Test that delegation without TokenTransformationEnforcer at index 0 fails
    function test_missingTokenTransformationEnforcerAtIndex0_fails() public {
        // Create root delegation with TokenTransformationEnforcer NOT at index 0
        bytes memory terms_ = abi.encodePacked(address(USDC), DEPOSIT_AMOUNT);
        Caveat[] memory caveats_ = new Caveat[](2);
        // Put a dummy enforcer at index 0
        caveats_[0] = Caveat({ args: hex"", enforcer: address(0x1234), terms: hex"" });
        // TokenTransformationEnforcer at index 1 (should fail)
        caveats_[1] = Caveat({ args: hex"", enforcer: address(tokenTransformationEnforcer), terms: terms_ });

        Delegation memory rootDelegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        rootDelegation_ = signDelegation(users.alice, rootDelegation_);
        bytes32 rootDelegationHash_ = EncoderLib._getDelegationHash(rootDelegation_);

        // Create leaf delegation: Bob delegates to AdapterManager
        Delegation memory leafDelegation_ = _createLeafDelegation(address(users.bob.deleGator), rootDelegationHash_);
        leafDelegation_.delegate = address(adapterManager);
        leafDelegation_ = signDelegation(users.bob, leafDelegation_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = leafDelegation_; // Leaf delegation (Bob -> AdapterManager)
        delegations_[1] = rootDelegation_; // Root delegation (Alice -> Bob)

        bytes memory originalActionData_ = abi.encode(address(adapterManager));
        bytes memory actionData_ = abi.encode("deposit", originalActionData_);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert(AdapterManager.TokenTransformationEnforcerNotFound.selector);
        adapterManager.executeProtocolActionByDelegation(address(AAVE_POOL), USDC, DEPOSIT_AMOUNT, actionData_, delegations_);
    }

    /// @notice Test that delegation with no caveats fails
    function test_delegationWithNoCaveats_fails() public {
        // Create root delegation with no caveats
        Delegation memory rootDelegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        rootDelegation_ = signDelegation(users.alice, rootDelegation_);
        bytes32 rootDelegationHash_ = EncoderLib._getDelegationHash(rootDelegation_);

        // Create leaf delegation: Bob delegates to AdapterManager
        Delegation memory leafDelegation_ = _createLeafDelegation(address(users.bob.deleGator), rootDelegationHash_);
        leafDelegation_.delegate = address(adapterManager);
        leafDelegation_ = signDelegation(users.bob, leafDelegation_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = leafDelegation_; // Leaf delegation (Bob -> AdapterManager)
        delegations_[1] = rootDelegation_; // Root delegation (Alice -> Bob)

        bytes memory originalActionData_ = abi.encode(address(adapterManager));
        bytes memory actionData_ = abi.encode("deposit", originalActionData_);

        vm.prank(address(users.bob.deleGator));
        vm.expectRevert(AdapterManager.TokenTransformationEnforcerNotFound.selector);
        adapterManager.executeProtocolActionByDelegation(address(AAVE_POOL), USDC, DEPOSIT_AMOUNT, actionData_, delegations_);
    }

    /// @notice Test that delegation with TokenTransformationEnforcer at index 0 but other caveats works
    function test_tokenTransformationEnforcerAtIndex0WithOtherCaveats_succeeds() public {
        // Create root delegation with TokenTransformationEnforcer at index 0 and another caveat
        bytes memory terms_ = abi.encodePacked(address(USDC), DEPOSIT_AMOUNT);
        Caveat[] memory caveats_ = new Caveat[](2);
        // TokenTransformationEnforcer at index 0 (required)
        caveats_[0] = Caveat({ args: hex"", enforcer: address(tokenTransformationEnforcer), terms: terms_ });
        // Another caveat at index 1 - use TimestampEnforcer set to future timestamp (won't restrict)
        bytes memory timestampTerms_ = abi.encodePacked(uint256(block.timestamp + 1 days));
        caveats_[1] = Caveat({ args: hex"", enforcer: address(timestampEnforcer), terms: timestampTerms_ });

        Delegation memory rootDelegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        rootDelegation_ = signDelegation(users.alice, rootDelegation_);
        bytes32 rootDelegationHash_ = EncoderLib._getDelegationHash(rootDelegation_);
        bytes32 delegationHash_ = rootDelegationHash_;

        // Create leaf delegation: Bob delegates to AdapterManager
        Delegation memory leafDelegation_ = _createLeafDelegation(address(users.bob.deleGator), rootDelegationHash_);
        leafDelegation_.delegate = address(adapterManager);
        leafDelegation_ = signDelegation(users.bob, leafDelegation_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = leafDelegation_; // Leaf delegation (Bob -> AdapterManager)
        delegations_[1] = rootDelegation_; // Root delegation (Alice -> Bob)

        bytes memory originalActionData_ = abi.encode(address(adapterManager));
        bytes memory actionData_ = abi.encode("deposit", originalActionData_);

        vm.prank(address(users.bob.deleGator));
        adapterManager.executeProtocolActionByDelegation(address(AAVE_POOL), USDC, DEPOSIT_AMOUNT, actionData_, delegations_);

        // Get wrapped token address AFTER wrapping
        address wrappedToken_ = IATokenWrapper(aTokenWrapper).getWrappedToken(address(aUSDC));
        require(wrappedToken_ != address(0), "Wrapped token should be created");

        // Verify transformation was tracked correctly
        assertEq(tokenTransformationEnforcer.getAvailableAmount(delegationHash_, address(USDC)), 0);
        uint256 wrappedBalance_ = IERC20(wrappedToken_).balanceOf(address(users.alice.deleGator));
        uint256 trackedWrapped_ = tokenTransformationEnforcer.getAvailableAmount(delegationHash_, wrappedToken_);
        assertGe(trackedWrapped_, wrappedBalance_ - 1, "Wrapped token should be tracked");
        assertLe(trackedWrapped_, wrappedBalance_ + 1, "Wrapped token should be tracked");
    }
}

/**
 * @title MockATokenWrapper
 * @notice Mock wrapper for testing - wraps aTokens into fixed-supply tokens
 */
contract MockATokenWrapper {
    mapping(address => address) public wrappedTokens;
    mapping(address => uint256) public totalSupply;

    function wrap(address aToken, uint256 amount) external returns (uint256 wrappedAmount) {
        if (wrappedTokens[aToken] == address(0)) {
            // Deploy a new wrapped token (simplified - in production this would be more complex)
            wrappedTokens[aToken] = address(new MockWrappedToken());
        }

        IERC20(aToken).transferFrom(msg.sender, address(this), amount);
        MockWrappedToken(wrappedTokens[aToken]).mint(msg.sender, amount);
        totalSupply[aToken] += amount;
        return amount;
    }

    function unwrap(address aToken, uint256 wrappedAmount) external returns (uint256 aTokenAmount) {
        MockWrappedToken(wrappedTokens[aToken]).burnFrom(msg.sender, wrappedAmount);
        IERC20(aToken).transfer(msg.sender, wrappedAmount);
        totalSupply[aToken] -= wrappedAmount;
        return wrappedAmount;
    }

    function getWrappedToken(address aToken) external view returns (address) {
        return wrappedTokens[aToken];
    }
}

/**
 * @title MockWrappedToken
 * @notice Simple ERC20 for wrapped tokens
 */
contract MockWrappedToken is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burnFrom(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

/**
 * @title DummyContract
 * @notice Dummy contract for address manipulation in tests
 */
contract DummyContract {
    constructor() { }
}

