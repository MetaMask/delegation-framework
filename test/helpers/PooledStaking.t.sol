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
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";
import { IEthFoxVault, IVaultEthStaking } from "../../src/helpers/interfaces/IEthFoxVault.sol";

// @dev Do not remove this comment below
/// forge-config: default.evm_version = "shanghai"

/**
 * @title PooledStaking Test
 * @notice Tests delegation-based staking to MetaMask PooledStaking via EthFoxVault
 * @dev Uses a forked Ethereum mainnet environment to test real contract interactions
 */
contract PooledStakingTest is BaseTest {
    using ModeLib for ModeCode;

    ////////////////////// State //////////////////////

    // MetaMask PooledStaking contract (EthFoxVault) on Ethereum mainnet
    IEthFoxVault public constant METAMASK_POOLED_STAKING = IEthFoxVault(0x4FEF9D741011476750A243aC70b9789a63dd47Df);

    // Enforcers for delegation restrictions
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    ValueLteEnforcer public valueLteEnforcer;

    // Test constants
    uint256 public constant STAKE_AMOUNT = 1 ether;
    uint256 public constant MAINNET_FORK_BLOCK = 22734910; // Use latest available block

    ////////////////////// Setup //////////////////////

    function setUp() public override {
        // Create fork from mainnet at specific block
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);

        // Set implementation type
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;

        // Call parent setup to initialize delegation framework
        super.setUp();

        // Deploy caveat enforcers
        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        valueLteEnforcer = new ValueLteEnforcer();

        vm.label(address(allowedTargetsEnforcer), "AllowedTargetsEnforcer");
        vm.label(address(allowedMethodsEnforcer), "AllowedMethodsEnforcer");
        vm.label(address(valueLteEnforcer), "ValueLteEnforcer");
        vm.label(address(METAMASK_POOLED_STAKING), "MetaMask PooledStaking");

        // Fund Alice's DeleGator with ETH for staking
        vm.deal(address(users.alice.deleGator), 10 ether);
    }

    ////////////////////// Tests //////////////////////

    /**
     * Test Alice's direct ETH deposit into MetaMask PooledStaking
     * Verifies that Alice can successfully deposit 1 ETH and receive corresponding shares
     */
    function test_aliceDirectDeposit() public {
        // Get initial balances
        uint256 initialEthBalance_ = address(users.alice.deleGator).balance;

        // Alice directly deposits ETH into MetaMask PooledStaking
        vm.prank(address(users.alice.deleGator));
        uint256 shares_ = METAMASK_POOLED_STAKING.deposit{ value: STAKE_AMOUNT }(address(users.alice.deleGator), address(0));

        uint256 finalShares_ = METAMASK_POOLED_STAKING.getShares(address(users.alice.deleGator));

        // Verify Alice's deposit was successful
        assertApproxEqAbs(shares_, STAKE_AMOUNT, 3e16, "Alice should have received 1 ether worth of shares from direct deposit");
        assertApproxEqAbs(finalShares_, STAKE_AMOUNT, 3e16, "Alice should have 1 ether worth of shares total");
        assertApproxEqRel(
            address(users.alice.deleGator).balance, initialEthBalance_ - STAKE_AMOUNT, 3e16, "Alice's ETH should be deducted"
        );
    }

    /**
     * @notice Test successful staking with proper delegation setup
     * @dev Comprehensive test showing expected behavior with recommended delegation patterns
     */
    function test_recommendedDelegationPattern() public {
        // Get vault capacity and check if we can stake
        uint256 vaultCapacity_ = METAMASK_POOLED_STAKING.capacity();
        uint256 totalAssets_ = METAMASK_POOLED_STAKING.totalAssets();
        // Skip if vault is near capacity
        vm.assume(totalAssets_ + STAKE_AMOUNT < vaultCapacity_);

        // Create comprehensive delegation with all recommended enforcers
        Caveat[] memory caveats_ = new Caveat[](3);

        // Recommended: Restrict to specific contract
        caveats_[0] = Caveat({
            args: hex"",
            enforcer: address(allowedTargetsEnforcer),
            terms: abi.encodePacked(address(METAMASK_POOLED_STAKING))
        });

        // Recommended: Restrict to deposit function only
        caveats_[1] = Caveat({
            args: hex"",
            enforcer: address(allowedMethodsEnforcer),
            terms: abi.encodePacked(IVaultEthStaking.deposit.selector)
        });

        // Recommended: Set value limits for safety
        caveats_[2] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encode(STAKE_AMOUNT) });

        Delegation memory delegation = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation = signDelegation(users.alice, delegation);

        // Create proper execution for staking
        Execution memory execution_ = Execution({
            target: address(METAMASK_POOLED_STAKING),
            value: STAKE_AMOUNT,
            callData: abi.encodeWithSelector(
                IVaultEthStaking.deposit.selector,
                address(users.alice.deleGator), // Alice receives the shares
                address(0) // No referrer
            )
        });

        // Record state before
        uint256 initialEthBalance_ = address(users.alice.deleGator).balance;
        uint256 initialShares_ = METAMASK_POOLED_STAKING.getShares(address(users.alice.deleGator));

        // Execute delegation
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Verify results
        uint256 finalEthBalance_ = address(users.alice.deleGator).balance;
        uint256 finalShares_ = METAMASK_POOLED_STAKING.getShares(address(users.alice.deleGator));

        // Final assertions
        assertEq(finalEthBalance_, initialEthBalance_ - STAKE_AMOUNT, "ETH balance should decrease by stake amount");
        assertGt(finalShares_, initialShares_, "Staking shares should increase");
        assertApproxEqAbs(finalShares_, STAKE_AMOUNT, 3e16, "Alice should have received 1 ether worth of shares from delegation");
    }
}
