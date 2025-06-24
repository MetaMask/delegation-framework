// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import { BaseTest } from "../utils/BaseTest.t.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { Implementation, SignatureType } from "../utils/Types.t.sol";
import { Execution, Delegation, Caveat, ModeCode } from "../../src/utils/Types.sol";
import { AllowedTargetsEnforcer } from "../../src/enforcers/AllowedTargetsEnforcer.sol";
import { AllowedMethodsEnforcer } from "../../src/enforcers/AllowedMethodsEnforcer.sol";
import { ValueLteEnforcer } from "../../src/enforcers/ValueLteEnforcer.sol";
import { ExactCalldataEnforcer } from "../../src/enforcers/ExactCalldataEnforcer.sol";
import { LogicalOrWrapperEnforcer } from "../../src/enforcers/LogicalOrWrapperEnforcer.sol";
import { IEthFoxVault, IVaultEthStaking, IVaultEnterExit } from "../helpers/interfaces/IEthFoxVault.sol";
import { EIP7702StatelessDeleGator } from "../../src/EIP7702/EIP7702StatelessDeleGator.sol";
import { ERC1271Lib } from "../../src/libraries/ERC1271Lib.sol";

// @dev Do not remove this comment below
/// forge-config: default.evm_version = "shanghai"

/**
 * @title PooledStaking Forked Test
 * @notice Tests delegation-based interactions with MetaMask PooledStaking (EthFoxVault) on Ethereum mainnet
 *
 * @dev This test suite validates delegation patterns for staking operations using mainnet forks at specific block numbers.
 * It includes both direct protocol interactions (without delegations) to verify baseline functionality, and delegation-based
 * interactions using a single LogicalOrWrapperEnforcer that supports three operation types: deposits, entering the exit queue,
 * and claiming exited assets.
 *
 * @dev Amount restrictions are intentionally omitted (e.g., NativeTokenTransferAmountEnforcer) since all tokens in the
 * DeleGator account are intended for investment purposes. The deposit operation uses exact calldata matching to ensure tokens
 * can only be sent to the root delegator. Exit queue and claim operations automatically send outputs to msg.sender
 * (the root delegator) and have flexible parameters due to trust in the investment system.
 *
 * @dev These tests intentionally deploy fresh delegation framework contracts rather than using existing deployments to detect
 * compatibility issues when contracts are modified. Regular maintenance of this test file is expected as the
 * delegation framework evolves.
 *
 * @dev Exit queue and claim tests use vm.prank with real mainnet addresses at specific blocks where these users
 * historically had the required permissions, simplifying test setup compared to replicating the full multi-step
 * staking workflow.
 */
contract PooledStakingTest is BaseTest {
    ////////////////////// State //////////////////////

    // MetaMask PooledStaking contract (EthFoxVault) on Ethereum mainnet
    IEthFoxVault public constant VAULT = IEthFoxVault(0x4FEF9D741011476750A243aC70b9789a63dd47Df);

    // Enforcers for delegation restrictions
    AllowedTargetsEnforcer public allowedTargetsEnforcer;
    AllowedMethodsEnforcer public allowedMethodsEnforcer;
    ValueLteEnforcer public valueLteEnforcer;
    ExactCalldataEnforcer public exactCalldataEnforcer;
    LogicalOrWrapperEnforcer public logicalOrWrapperEnforcer;

    // Real mainnet addresses that have interacted with the vault
    address private constant EXIT_REQUESTER_ADDRESS = 0x600c080F3E0ce390Ee4699c70c1628fEF150eda4;
    address private constant CLAIMER_ADDRESS = 0xFbFFd0bBe31400567C18421D39D040ff3C7EdF42;

    // Test constants
    uint256 public constant MAINNET_FORK_BLOCK = 22734910;

    // Group indices for different vault operations
    uint256 private constant DEPOSIT_GROUP = 0;
    uint256 private constant EXIT_QUEUE_GROUP = 1;
    uint256 private constant CLAIM_ASSETS_GROUP = 2;

    ////////////////////// Setup //////////////////////

    function setUpContracts() public {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
        super.setUp();

        allowedTargetsEnforcer = new AllowedTargetsEnforcer();
        allowedMethodsEnforcer = new AllowedMethodsEnforcer();
        valueLteEnforcer = new ValueLteEnforcer();
        exactCalldataEnforcer = new ExactCalldataEnforcer();
        logicalOrWrapperEnforcer = new LogicalOrWrapperEnforcer(delegationManager);

        vm.label(address(allowedTargetsEnforcer), "AllowedTargetsEnforcer");
        vm.label(address(allowedMethodsEnforcer), "AllowedMethodsEnforcer");
        vm.label(address(valueLteEnforcer), "ValueLteEnforcer");
        vm.label(address(exactCalldataEnforcer), "ExactCalldataEnforcer");
        vm.label(address(logicalOrWrapperEnforcer), "LogicalOrWrapperEnforcer");
        vm.label(address(VAULT), "MetaMask PooledStaking");
        vm.label(EXIT_REQUESTER_ADDRESS, "MainnetExitRequester");
        vm.label(CLAIMER_ADDRESS, "MainnetClaimer");
    }

    ////////////////////// Tests //////////////////////

    /**
     * @notice Test direct deposit functionality
     */
    function test_deposit_direct() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);
        setUpContracts();

        uint256 initialShares_ = VAULT.getShares(address(users.alice.deleGator));
        uint256 depositAmount_ = 1 ether;

        vm.prank(address(users.alice.deleGator));
        VAULT.deposit{ value: depositAmount_ }(address(users.alice.deleGator), address(0));

        uint256 finalShares_ = VAULT.getShares(address(users.alice.deleGator));
        assertGt(finalShares_, initialShares_, "Shares should have increased after deposit");
    }

    /**
     * @notice Test deposit via delegation from Alice to Bob
     * @dev Uses exact calldata matching to ensure tokens can only be deposited to the root delegator's address,
     * preventing the redeemer from redirecting funds elsewhere
     */
    function test_deposit_viaDelegation() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);
        setUpContracts();

        uint256 initialShares_ = VAULT.getShares(address(users.alice.deleGator));

        // Create caveat groups for deposit operations
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ =
            _createVaultCaveatGroups(DEPOSIT_GROUP, address(users.alice.deleGator));

        // Create selected group for deposit operations
        bytes[] memory caveatArgs_ = new bytes[](2);
        caveatArgs_[0] = hex""; // No args for allowedTargetsEnforcer
        caveatArgs_[1] = hex""; // No args for exactCalldataEnforcer
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ =
            LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: DEPOSIT_GROUP, caveatArgs: caveatArgs_ });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: abi.encode(selectedGroup_), enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        uint256 depositAmount_ = 1 ether;
        Execution memory execution_ = Execution({
            target: address(VAULT),
            value: depositAmount_,
            callData: abi.encodeWithSelector(IVaultEthStaking.deposit.selector, address(users.alice.deleGator), address(0))
        });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        uint256 finalShares_ = VAULT.getShares(address(users.alice.deleGator));
        assertGt(finalShares_, initialShares_, "Shares should have increased after deposit");
    }

    /**
     * @notice Test direct exit queue entry using real mainnet address
     */
    function test_exitQueue_direct() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22769140);
        setUpContracts();

        uint256 initialShares_ = VAULT.getShares(EXIT_REQUESTER_ADDRESS);
        uint256 initialQueuedShares_ = VAULT.queuedShares();
        uint256 initialEthBalance_ = EXIT_REQUESTER_ADDRESS.balance;

        assertGt(initialShares_, 0, "Exit requester must have shares to enter exit queue");

        vm.prank(EXIT_REQUESTER_ADDRESS);
        VAULT.enterExitQueue(initialShares_, EXIT_REQUESTER_ADDRESS);

        uint256 finalShares_ = VAULT.getShares(EXIT_REQUESTER_ADDRESS);
        uint256 finalQueuedShares_ = VAULT.queuedShares();
        uint256 finalEthBalance_ = EXIT_REQUESTER_ADDRESS.balance;

        assertEq(finalShares_, 0, "User shares should be zero after entering exit queue");
        assertGt(finalQueuedShares_, initialQueuedShares_, "Queued shares should have increased");
        assertEq(finalQueuedShares_, initialQueuedShares_ + initialShares_, "All user shares should be in queue");
        assertEq(finalEthBalance_, initialEthBalance_, "ETH balance should remain unchanged");
    }

    /**
     * @notice Test exit queue entry via delegation using real mainnet address
     * @dev The vault automatically handles token flows to msg.sender (root delegator). Function parameters are
     * unrestricted to allow flexibility within the trusted investment system. Uses vm.prank with a real address
     * that historically had shares at this block number.
     */
    function test_exitQueue_viaDelegation() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22769140);
        setUpContracts();

        _assignImplementationAndVerify(EXIT_REQUESTER_ADDRESS);

        uint256 initialShares_ = VAULT.getShares(EXIT_REQUESTER_ADDRESS);
        uint256 initialQueuedShares_ = VAULT.queuedShares();
        uint256 initialEthBalance_ = EXIT_REQUESTER_ADDRESS.balance;

        assertGt(initialShares_, 0, "Exit requester must have shares to enter exit queue");

        // Create caveat groups for exit queue operations
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = _createVaultCaveatGroups(EXIT_QUEUE_GROUP, EXIT_REQUESTER_ADDRESS);

        // Create selected group for exit queue operations
        bytes[] memory caveatArgs_ = new bytes[](3);
        caveatArgs_[0] = hex""; // No args for allowedTargetsEnforcer
        caveatArgs_[1] = hex""; // No args for valueLteEnforcer
        caveatArgs_[2] = hex""; // No args for allowedMethodsEnforcer
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ =
            LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: EXIT_QUEUE_GROUP, caveatArgs: caveatArgs_ });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: abi.encode(selectedGroup_), enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: EXIT_REQUESTER_ADDRESS,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = _mockSignDelegation(delegation_);

        Execution memory execution_ = Execution({
            target: address(VAULT),
            value: 0,
            callData: abi.encodeWithSelector(IVaultEnterExit.enterExitQueue.selector, initialShares_, EXIT_REQUESTER_ADDRESS)
        });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        uint256 finalShares_ = VAULT.getShares(EXIT_REQUESTER_ADDRESS);
        uint256 finalQueuedShares_ = VAULT.queuedShares();
        uint256 finalEthBalance_ = EXIT_REQUESTER_ADDRESS.balance;

        assertEq(finalShares_, 0, "User shares should be zero after entering exit queue");
        assertGt(finalQueuedShares_, initialQueuedShares_, "Queued shares should have increased");
        assertEq(finalQueuedShares_, initialQueuedShares_ + initialShares_, "All user shares should be in queue");
        assertEq(finalEthBalance_, initialEthBalance_, "ETH balance should remain unchanged");
    }

    /**
     * @notice Test direct claiming of exited assets using real mainnet address
     */
    function test_claimExitedAssets_direct() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22769133);
        setUpContracts();

        uint256 initialEthBalance_ = CLAIMER_ADDRESS.balance;
        uint256 positionTicket_ = 31305208530820384526455;
        uint256 claimTimestamp_ = 1750591523;
        uint256 exitQueueIndex_ = 749;

        (,, uint256 claimedAssets_) =
            VAULT.calculateExitedAssets(CLAIMER_ADDRESS, positionTicket_, claimTimestamp_, exitQueueIndex_);

        vm.prank(CLAIMER_ADDRESS);
        VAULT.claimExitedAssets(positionTicket_, claimTimestamp_, exitQueueIndex_);

        uint256 ethObtained_ = CLAIMER_ADDRESS.balance - initialEthBalance_;
        assertEq(ethObtained_, claimedAssets_, "ETH balance should equal claimed assets");
    }

    /**
     * @notice Test claiming exited assets via delegation using real mainnet address
     * @dev The vault automatically sends claimed ETH to msg.sender (root delegator). Function parameters are
     * unrestricted to allow flexibility within the trusted investment system. Uses vm.prank with a real address
     * that historically had claimable assets at this block number.
     */
    function test_claimExitedAssets_viaDelegation() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 22769133);
        setUpContracts();

        _assignImplementationAndVerify(CLAIMER_ADDRESS);

        uint256 initialEthBalance_ = CLAIMER_ADDRESS.balance;
        uint256 initialShares_ = VAULT.getShares(CLAIMER_ADDRESS);

        // Create caveat groups for claim operations
        LogicalOrWrapperEnforcer.CaveatGroup[] memory groups_ = _createVaultCaveatGroups(CLAIM_ASSETS_GROUP, CLAIMER_ADDRESS);

        // Create selected group for claim operations
        // caveatArgs = No args for allowedTargetsEnforcer, No args for valueLteEnforcer, No args for allowedMethodsEnforcer
        LogicalOrWrapperEnforcer.SelectedGroup memory selectedGroup_ =
            LogicalOrWrapperEnforcer.SelectedGroup({ groupIndex: CLAIM_ASSETS_GROUP, caveatArgs: new bytes[](3) });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: abi.encode(selectedGroup_), enforcer: address(logicalOrWrapperEnforcer), terms: abi.encode(groups_) });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: CLAIMER_ADDRESS,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = _mockSignDelegation(delegation_);

        uint256 positionTicket_ = 31305208530820384526455;
        uint256 claimTimestamp_ = 1750591523;
        uint256 exitQueueIndex_ = 749;

        (,, uint256 expectedClaimedAssets_) =
            VAULT.calculateExitedAssets(CLAIMER_ADDRESS, positionTicket_, claimTimestamp_, exitQueueIndex_);

        Execution memory execution_ = Execution({
            target: address(VAULT),
            value: 0,
            callData: abi.encodeWithSelector(
                IVaultEnterExit.claimExitedAssets.selector, positionTicket_, claimTimestamp_, exitQueueIndex_
            )
        });

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        uint256 ethObtained_ = CLAIMER_ADDRESS.balance - initialEthBalance_;
        assertEq(ethObtained_, expectedClaimedAssets_, "ETH obtained should equal expected claimed assets");
        assertEq(VAULT.getShares(CLAIMER_ADDRESS), initialShares_, "Shares should remain unchanged after claiming assets");
    }

    ////////////////////// Helper Functions //////////////////////

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
            hex"1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1b";

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

    /**
     * @notice Creates caveat groups for different vault operations
     * @param _groupIndex The group index (0=deposit, 1=enterExitQueue, 2=claimExitedAssets)
     * @param _delegator The delegator address for deposit operations
     * @return groups Array of caveat groups
     */
    function _createVaultCaveatGroups(
        uint256 _groupIndex,
        address _delegator
    )
        internal
        view
        returns (LogicalOrWrapperEnforcer.CaveatGroup[] memory groups)
    {
        require(_groupIndex <= 2, "Invalid group index");

        groups = new LogicalOrWrapperEnforcer.CaveatGroup[](3);

        // Group 0: Deposit operations
        {
            Caveat[] memory depositCaveats = new Caveat[](2);
            depositCaveats[0] =
                Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(VAULT)) });
            depositCaveats[1] = Caveat({
                args: hex"",
                enforcer: address(exactCalldataEnforcer),
                terms: abi.encodeWithSelector(IVaultEthStaking.deposit.selector, _delegator, address(0))
            });
            groups[0] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: depositCaveats });
        }

        // Group 1: Enter exit queue operations
        {
            Caveat[] memory exitQueueCaveats = new Caveat[](3);
            exitQueueCaveats[0] =
                Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(VAULT)) });
            exitQueueCaveats[1] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encode(uint256(0)) });
            exitQueueCaveats[2] = Caveat({
                args: hex"",
                enforcer: address(allowedMethodsEnforcer),
                terms: abi.encodePacked(IVaultEnterExit.enterExitQueue.selector)
            });
            groups[1] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: exitQueueCaveats });
        }

        // Group 2: Claim exited assets operations
        {
            Caveat[] memory claimCaveats = new Caveat[](3);
            claimCaveats[0] =
                Caveat({ args: hex"", enforcer: address(allowedTargetsEnforcer), terms: abi.encodePacked(address(VAULT)) });
            claimCaveats[1] = Caveat({ args: hex"", enforcer: address(valueLteEnforcer), terms: abi.encode(uint256(0)) });
            claimCaveats[2] = Caveat({
                args: hex"",
                enforcer: address(allowedMethodsEnforcer),
                terms: abi.encodePacked(IVaultEnterExit.claimExitedAssets.selector)
            });
            groups[2] = LogicalOrWrapperEnforcer.CaveatGroup({ caveats: claimCaveats });
        }
    }
}
