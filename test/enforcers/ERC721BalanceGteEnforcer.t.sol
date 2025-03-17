// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicCF721 } from "../utils/BasicCF721.t.sol";

import "../../src/utils/Types.sol";
import { Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC721BalanceGteEnforcer } from "../../src/enforcers/ERC721BalanceGteEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ERC721BalanceGteEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC721BalanceGteEnforcer public enforcer;
    BasicCF721 public token;
    address delegator;
    address delegate;
    address dm;
    Execution mintExecution;
    bytes mintExecutionCallData;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        delegate = address(users.bob.deleGator);
        dm = address(delegationManager);
        enforcer = new ERC721BalanceGteEnforcer();
        vm.label(address(enforcer), "ERC721 BalanceGte Enforcer");
        token = new BasicCF721(delegator, "ERC721Token", "ERC721Token", "");
        vm.label(address(token), "ERC721 Test Token");

        // Prepare the Execution data for minting
        mintExecution =
            Execution({ target: address(token), value: 0, callData: abi.encodeWithSelector(token.mint.selector, delegator) });
        mintExecutionCallData = abi.encode(mintExecution);
    }

    ////////////////////// Basic Functionality //////////////////////

    // Validates the terms get decoded correctly
    function test_decodedTheTerms() public {
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));
        (address token_, address recipient_, uint256 amount_) = enforcer.getTermsInfo(terms_);
        assertEq(token_, address(token));
        assertEq(recipient_, delegator);
        assertEq(amount_, 1);
    }

    // Validates that a balance has increased at least by the expected amount
    function test_allow_ifBalanceIncreases() public {
        // Expect it to increase by at least 1
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));

        // Increase by 1
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(dm);
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Increase by 2
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator);
        vm.prank(dm);
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    ////////////////////// Errors //////////////////////

    // Reverts if a balance hasn't increased by the set amount
    function test_notAllow_insufficientIncrease() public {
        // Expect it to increase by at least 1
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));

        // No increase
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        // No minting occurs here
        vm.prank(dm);
        vm.expectRevert(bytes("ERC721BalanceGteEnforcer:balance-not-gt"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if a balance decreased in between the hooks
    function test_notAllow_ifBalanceDecreases() public {
        // Starting with 1 token
        vm.prank(delegator);
        token.mint(delegator);

        // Expect it to increase by at least 1
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));

        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Decrease balance by transferring token away
        uint256 tokenIdToTransfer_ = (token.tokenId()) - 1;
        vm.prank(delegator);
        token.transferFrom(delegator, address(1), tokenIdToTransfer_);

        vm.prank(dm);
        vm.expectRevert(bytes("ERC721BalanceGteEnforcer:balance-not-gt"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Allows to check the balance of different recipients
    function test_allow_withDifferentRecipients() public {
        address[] memory recipients_ = new address[](2);
        recipients_[0] = delegator;
        recipients_[1] = address(99999);

        for (uint256 i = 0; i < recipients_.length; i++) {
            address currentRecipient_ = recipients_[i];
            bytes memory terms_ = abi.encodePacked(address(token), currentRecipient_, uint256(1));

            // Increase by 1 for each recipient
            vm.prank(dm);
            enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), address(0), delegate);
            vm.prank(delegator);
            token.mint(currentRecipient_);
            vm.prank(dm);
            enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), address(0), delegate);
        }
    }

    // Considers any pre-existing balances in the recipient
    function test_notAllow_withPreExistingBalance() public {
        // Recipient already has 1 token
        vm.prank(delegator);
        token.mint(delegator);

        // Expect balance to increase by at least 1
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));

        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // No increase occurs here

        vm.prank(dm);
        vm.expectRevert(bytes("ERC721BalanceGteEnforcer:balance-not-gt"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Same delegation hash multiple recipients
    function test_differentiateDelegationHashWithRecipient() public {
        bytes32 delegationHash_ = bytes32(uint256(99999999));
        address recipient2_ = address(1111111);
        // Expect balance to increase by at least 1 in different recipients
        bytes memory terms1_ = abi.encodePacked(address(token), delegator, uint256(1));
        bytes memory terms2_ = abi.encodePacked(address(token), recipient2_, uint256(1));

        vm.prank(dm);
        enforcer.beforeHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        vm.prank(dm);
        enforcer.beforeHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Increase balance by 1 only in recipient1
        vm.prank(delegator);
        token.mint(delegator);

        // This one works well recipient1 increased
        vm.prank(dm);
        enforcer.afterHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // This one fails recipient2 didn't increase
        vm.prank(dm);
        vm.expectRevert(bytes("ERC721BalanceGteEnforcer:balance-not-gt"));
        enforcer.afterHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Increase balance by 1 in recipient2 to fix it
        vm.prank(delegator);
        token.mint(recipient2_);

        // Recipient2 works well
        vm.prank(dm);
        enforcer.afterHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
    }

    // Reverts if the enforcer is locked
    function test_notAllow_reenterALockedEnforcer() public {
        // Expect it to increase by at least 1
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(1));
        bytes32 delegationHash_ = bytes32(uint256(99999999));

        // Lock the enforcer
        vm.startPrank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
        bytes32 hashKey_ = enforcer.getHashKey(address(delegationManager), address(token), address(delegator), delegationHash_);
        assertTrue(enforcer.isLocked(hashKey_));
        vm.expectRevert(bytes("ERC721BalanceGteEnforcer:enforcer-is-locked"));
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
        vm.stopPrank();

        vm.prank(delegator);
        token.mint(delegator);

        vm.startPrank(dm);
        // Unlock the enforcer
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
        assertFalse(enforcer.isLocked(hashKey_));
        // Can be used again, and locks it again
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
        assertTrue(enforcer.isLocked(hashKey_));
        vm.stopPrank();
    }

    // Validates the terms are well-formed
    function test_invalid_decodedTheTerms() public {
        bytes memory terms_;

        // Too small
        terms_ = abi.encodePacked(address(token), address(delegator), uint8(1));
        vm.expectRevert(bytes("ERC721BalanceGteEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large
        terms_ = abi.encodePacked(uint256(1), uint256(1), uint256(1), uint256(1));
        vm.expectRevert(bytes("ERC721BalanceGteEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Validates that an invalid token address causes a revert
    function test_invalid_tokenAddress() public {
        bytes memory terms_;

        // Invalid token address
        terms_ = abi.encodePacked(address(0), address(delegator), uint256(1));
        vm.expectRevert();
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Validates that an unrealistic amount causes a revert
    function test_notAllow_expectingOverflow() public {
        // Expect balance to increase by max uint256, which is unrealistic
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), type(uint256).max);

        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.expectRevert();
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
