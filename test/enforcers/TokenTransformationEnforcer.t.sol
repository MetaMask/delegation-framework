// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Implementation, SignatureType } from "../utils/Types.t.sol";
import { TokenTransformationEnforcer } from "../../src/enforcers/TokenTransformationEnforcer.sol";
import { AdapterManager } from "../../src/helpers/adapters/AdapterManager.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

/**
 * @title TokenTransformationEnforcer Test
 * @notice Tests for the TokenTransformationEnforcer that tracks multiple tokens per delegation
 */
contract TokenTransformationEnforcerTest is CaveatEnforcerBaseTest {
    using ModeLib for ModeCode;

    ////////////////////////////// State //////////////////////////////

    TokenTransformationEnforcer public tokenTransformationEnforcer;
    AdapterManager public adapterManager;
    BasicERC20 public testToken;
    BasicERC20 public testToken2;

    uint256 public constant INITIAL_AMOUNT = 1000 ether;
    uint256 public constant TRANSFER_AMOUNT = 500 ether;

    ////////////////////////////// Setup //////////////////////////////

    function setUp() public override {
        super.setUp();

        address owner_ = makeAddr("AdapterManager Owner");

        // Deploy TokenTransformationEnforcer with placeholder address
        // (AdapterManager will be deployed next, but enforcer needs its address)
        // We'll use a placeholder and note that updateAssetState calls from real adapterManager will work
        // because msg.sender will be the real adapterManager address
        address placeholderAdapterManager_ = makeAddr("PlaceholderAdapterManager");
        tokenTransformationEnforcer = new TokenTransformationEnforcer(placeholderAdapterManager_);
        vm.label(address(tokenTransformationEnforcer), "TokenTransformationEnforcer");

        // Deploy AdapterManager with the real enforcer
        adapterManager = new AdapterManager(owner_, delegationManager);

        // Set the enforcer in the adapterManager
        adapterManager.setTokenTransformationEnforcer(tokenTransformationEnforcer);
        vm.label(address(adapterManager), "AdapterManager");

        // Deploy test tokens
        testToken = new BasicERC20(address(users.alice.deleGator), "TestToken", "TEST", INITIAL_AMOUNT);
        testToken2 = new BasicERC20(address(users.alice.deleGator), "TestToken2", "TEST2", INITIAL_AMOUNT);
        vm.label(address(testToken), "TestToken");
        vm.label(address(testToken2), "TestToken2");

        // Fund wallets with ETH for gas
        vm.deal(address(users.alice.deleGator), 10 ether);
        vm.deal(address(users.bob.deleGator), 10 ether);
    }

    ////////////////////////////// Unit Tests //////////////////////////////

    /// @notice Test that getTermsInfo correctly decodes terms
    function test_getTermsInfo() public {
        bytes memory terms_ = abi.encodePacked(address(testToken), INITIAL_AMOUNT);
        (address token_, uint256 amount_, address[] memory allowedProtocols_) = tokenTransformationEnforcer.getTermsInfo(terms_);
        assertEq(token_, address(testToken));
        assertEq(amount_, INITIAL_AMOUNT);
        assertEq(allowedProtocols_.length, 0, "Should have no protocols for base format");
    }

    /// @notice Test that getTermsInfo reverts on invalid terms length
    function test_getTermsInfo_invalidLength() public {
        bytes memory invalidTerms_ = abi.encodePacked(address(testToken));
        vm.expectRevert(TokenTransformationEnforcer.InvalidTermsLength.selector);
        tokenTransformationEnforcer.getTermsInfo(invalidTerms_);
    }

    /// @notice Test that initial amount is set on first use
    function test_initializesOnFirstUse() public {
        bytes memory terms_ = abi.encodePacked(address(testToken), INITIAL_AMOUNT);
        Execution memory execution_ = Execution({
            target: address(testToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), TRANSFER_AMOUNT)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(tokenTransformationEnforcer), terms: terms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        // Before first use, available amount should be 0
        assertEq(tokenTransformationEnforcer.getAvailableAmount(delegationHash_, address(testToken)), 0);
        assertEq(tokenTransformationEnforcer.isInitialized(delegationHash_), false);

        // Execute beforeHook
        vm.prank(address(delegationManager));
        tokenTransformationEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );

        // After first use, should be initialized and amount deducted
        assertEq(tokenTransformationEnforcer.isInitialized(delegationHash_), true);
        assertEq(
            tokenTransformationEnforcer.getAvailableAmount(delegationHash_, address(testToken)), INITIAL_AMOUNT - TRANSFER_AMOUNT
        );
    }

    /// @notice Test that transfer succeeds when amount is available
    function test_transferSucceedsWhenAmountAvailable() public {
        bytes memory terms_ = abi.encodePacked(address(testToken), INITIAL_AMOUNT);
        Execution memory execution_ = Execution({
            target: address(testToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), TRANSFER_AMOUNT)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(tokenTransformationEnforcer), terms: terms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        vm.prank(address(delegationManager));
        tokenTransformationEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );

        assertEq(
            tokenTransformationEnforcer.getAvailableAmount(delegationHash_, address(testToken)), INITIAL_AMOUNT - TRANSFER_AMOUNT
        );
    }

    /// @notice Test that transfer fails when amount exceeds available
    function test_transferFailsWhenAmountExceedsAvailable() public {
        bytes memory terms_ = abi.encodePacked(address(testToken), INITIAL_AMOUNT);
        uint256 excessiveAmount_ = INITIAL_AMOUNT + 1;
        Execution memory execution_ = Execution({
            target: address(testToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), excessiveAmount_)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(tokenTransformationEnforcer), terms: terms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        vm.prank(address(delegationManager));
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransformationEnforcer.InsufficientTokensAvailable.selector,
                delegationHash_,
                address(testToken),
                excessiveAmount_,
                0
            )
        );
        tokenTransformationEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    /// @notice Test that updateAssetState can only be called by AdapterManager
    function test_updateAssetState_onlyAdapterManager() public {
        bytes memory terms_ = abi.encodePacked(address(testToken), INITIAL_AMOUNT);
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(tokenTransformationEnforcer), terms: terms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        // Try to update from non-AdapterManager address
        vm.prank(address(users.bob.deleGator));
        vm.expectRevert(TokenTransformationEnforcer.NotAdapterManager.selector);
        tokenTransformationEnforcer.updateAssetState(delegationHash_, address(testToken2), 100 ether);

        // Note: Calling from real adapterManager won't work in unit test because enforcer
        // was deployed with placeholder address. This is tested in integration tests.
    }

    /// @notice Test that updateAssetState correctly adds new token amounts
    /// @dev Note: This test uses the placeholder adapterManager address stored in enforcer
    ///      Full integration is tested in TokenTransformationSystemTest
    function test_updateAssetState_addsNewToken() public {
        bytes memory terms_ = abi.encodePacked(address(testToken), INITIAL_AMOUNT);
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(tokenTransformationEnforcer), terms: terms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        uint256 newTokenAmount_ = 200 ether;

        // Update state from placeholder AdapterManager address (stored in enforcer)
        // In real usage, this would be called from the actual AdapterManager
        address storedAdapterManager_ = tokenTransformationEnforcer.adapterManager();
        vm.prank(storedAdapterManager_);
        tokenTransformationEnforcer.updateAssetState(delegationHash_, address(testToken2), newTokenAmount_);

        assertEq(tokenTransformationEnforcer.getAvailableAmount(delegationHash_, address(testToken2)), newTokenAmount_);
    }

    /// @notice Test that updateAssetState adds to existing amounts
    function test_updateAssetState_addsToExisting() public {
        bytes memory terms_ = abi.encodePacked(address(testToken), INITIAL_AMOUNT);
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(tokenTransformationEnforcer), terms: terms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        uint256 firstAmount_ = 100 ether;
        uint256 secondAmount_ = 50 ether;

        address storedAdapterManager_ = tokenTransformationEnforcer.adapterManager();

        // Add first amount
        vm.prank(storedAdapterManager_);
        tokenTransformationEnforcer.updateAssetState(delegationHash_, address(testToken2), firstAmount_);

        // Add second amount
        vm.prank(storedAdapterManager_);
        tokenTransformationEnforcer.updateAssetState(delegationHash_, address(testToken2), secondAmount_);

        assertEq(tokenTransformationEnforcer.getAvailableAmount(delegationHash_, address(testToken2)), firstAmount_ + secondAmount_);
    }

    /// @notice Test that initialization only happens once per delegationHash
    function test_initializationOnlyOnce() public {
        bytes memory terms_ = abi.encodePacked(address(testToken), INITIAL_AMOUNT);
        Execution memory execution1_ = Execution({
            target: address(testToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 100 ether)
        });
        bytes memory executionCallData1_ = ExecutionLib.encodeSingle(execution1_.target, execution1_.value, execution1_.callData);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(tokenTransformationEnforcer), terms: terms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        // First use - should initialize
        vm.prank(address(delegationManager));
        tokenTransformationEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData1_, delegationHash_, address(0), address(0)
        );

        assertEq(tokenTransformationEnforcer.isInitialized(delegationHash_), true);
        assertEq(tokenTransformationEnforcer.getAvailableAmount(delegationHash_, address(testToken)), INITIAL_AMOUNT - 100 ether);

        // Second use - should NOT re-initialize, should deduct from remaining
        Execution memory execution2_ = Execution({
            target: address(testToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 200 ether)
        });
        bytes memory executionCallData2_ = ExecutionLib.encodeSingle(execution2_.target, execution2_.value, execution2_.callData);

        vm.prank(address(delegationManager));
        tokenTransformationEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData2_, delegationHash_, address(0), address(0)
        );

        assertEq(
            tokenTransformationEnforcer.getAvailableAmount(delegationHash_, address(testToken)),
            INITIAL_AMOUNT - 100 ether - 200 ether
        );
    }

    /// @notice Test that initialization only happens for the initial token
    function test_initializationOnlyForInitialToken() public {
        bytes memory terms_ = abi.encodePacked(address(testToken), INITIAL_AMOUNT);
        Execution memory execution_ = Execution({
            target: address(testToken2), // Different token
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), 100 ether)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(tokenTransformationEnforcer), terms: terms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        // Try to use different token - should fail (no available amount)
        vm.prank(address(delegationManager));
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransformationEnforcer.InsufficientTokensAvailable.selector, delegationHash_, address(testToken2), 100 ether, 0
            )
        );
        tokenTransformationEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    /// @notice Test that invalid execution length reverts
    function test_invalidExecutionLength() public {
        bytes memory terms_ = abi.encodePacked(address(testToken), INITIAL_AMOUNT);
        Execution memory execution_ = Execution({
            target: address(testToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.transferFrom.selector, address(0), address(0), 0) // Wrong length
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(tokenTransformationEnforcer), terms: terms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        vm.prank(address(delegationManager));
        vm.expectRevert("TokenTransformationEnforcer:invalid-execution-length");
        tokenTransformationEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    /// @notice Test that invalid method selector reverts
    function test_invalidMethod() public {
        bytes memory terms_ = abi.encodePacked(address(testToken), INITIAL_AMOUNT);
        Execution memory execution_ = Execution({
            target: address(testToken),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.approve.selector, address(users.bob.deleGator), 100 ether) // Wrong method
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(tokenTransformationEnforcer), terms: terms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        vm.prank(address(delegationManager));
        vm.expectRevert("TokenTransformationEnforcer:invalid-method");
        tokenTransformationEnforcer.beforeHook(
            terms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    ////////////////////////////// Helper Methods //////////////////////////////

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(tokenTransformationEnforcer));
    }
}

