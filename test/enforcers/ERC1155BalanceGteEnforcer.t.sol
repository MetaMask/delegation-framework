// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../../src/utils/Types.sol";
import { BasicERC1155 } from "../utils/BasicERC1155.t.sol";
import { Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC1155BalanceGteEnforcer } from "../../src/enforcers/ERC1155BalanceGteEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

contract ERC1155BalanceGteEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////
    ERC1155BalanceGteEnforcer public enforcer;
    BasicERC1155 public token;
    address delegator;
    address delegate;
    address dm;
    Execution mintExecution;
    bytes mintExecutionCallData;

    uint256 public tokenId = 1;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        delegator = address(users.alice.deleGator);
        delegate = address(users.bob.deleGator);
        dm = address(delegationManager);
        enforcer = new ERC1155BalanceGteEnforcer();
        vm.label(address(enforcer), "ERC1155 BalanceGte Enforcer");
        token = new BasicERC1155(delegator, "ERC1155Token", "ERC1155Token", "");
        vm.label(address(token), "ERC1155 Test Token");

        // Prepare the Execution data for minting
        mintExecution = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(token.mint.selector, delegator, tokenId, 100, "")
        });
        mintExecutionCallData = abi.encode(mintExecution);
    }

    ////////////////////// Basic Functionality //////////////////////

    // Validates the terms get decoded correctly
    function test_decodedTheTerms() public {
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));
        (address token_, address recipient_, uint256 tokenId_, uint256 amount_) = enforcer.getTermsInfo(terms_);
        assertEq(token_, address(token));
        assertEq(recipient_, delegator);
        assertEq(tokenId_, tokenId);
        assertEq(amount_, 100);
    }

    // Validates that a balance has increased at least by the expected amount
    function test_allow_ifBalanceIncreases() public {
        // Expect it to increase by at least 100
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));

        // Increase by 100
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator, tokenId, 100, "");
        vm.prank(dm);
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Increase by 1000
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator, tokenId, 1000, "");
        vm.prank(dm);
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    ////////////////////// Errors //////////////////////

    // Reverts if a balance hasn't increased by the set amount
    function test_notAllow_insufficientIncrease() public {
        // Expect it to increase by at least 100
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));

        // Increase by 10, expect revert
        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.prank(delegator);
        token.mint(delegator, tokenId, 10, "");
        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155BalanceGteEnforcer:balance-not-gt"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Reverts if a balance descreased in between the hooks
    function test_notAllow_ifBalanceDecreases() public {
        // Starting with 10 tokens
        vm.prank(delegator);
        token.mint(delegator, tokenId, 10, "");

        // Expect it to increase by at least 100
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Decrease balance by transferring tokens away
        vm.prank(delegator);
        token.safeTransferFrom(delegator, address(1), tokenId, 10, "");

        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155BalanceGteEnforcer:balance-not-gt"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Allows to check the balance of different recipients
    function test_allow_withDifferentRecipients() public {
        address[] memory recipients_ = new address[](2);
        recipients_[0] = delegator;
        recipients_[1] = address(99999);

        for (uint256 i = 0; i < recipients_.length; i++) {
            address currentRecipient_ = recipients_[i];
            bytes memory terms_ = abi.encodePacked(address(token), currentRecipient_, uint256(tokenId), uint256(100));

            // Increase by 100 for each recipient
            vm.prank(dm);
            enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), address(0), delegate);
            vm.prank(delegator);
            token.mint(currentRecipient_, tokenId, 100, "");
            vm.prank(dm);
            enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(i), address(0), delegate);
        }
    }

    // Considers any pre existing balances in the recipient
    function test_notAllow_withPreExistingBalance() public {
        // Recipient already has 50 tokens
        vm.prank(delegator);
        token.mint(delegator, tokenId, 50, "");

        // Expect balance to increase by at least 100
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);

        // Increase balance by 100
        vm.prank(delegator);
        token.mint(delegator, tokenId, 50, "");

        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155BalanceGteEnforcer:balance-not-gt"));
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Same delegation hash multiple recipients
    function test_differentiateDelegationHashWithRecipient() public {
        bytes32 delegationHash_ = bytes32(bytes32(uint256(99999999)));
        address recipient2_ = address(1111111);
        // Expect balance to increase by at least 100 in different recipients
        bytes memory terms1_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));
        bytes memory terms2_ = abi.encodePacked(address(token), address(recipient2_), uint256(tokenId), uint256(100));

        vm.prank(dm);
        enforcer.beforeHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        vm.prank(dm);
        enforcer.beforeHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Increase balance by 100 only in recipient1
        vm.prank(delegator);
        token.mint(delegator, tokenId, 100, "");

        // This one works well recipient1 increased
        vm.prank(dm);
        enforcer.afterHook(terms1_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // This one fails recipient1 didn't increase
        vm.prank(dm);
        vm.expectRevert(bytes("ERC1155BalanceGteEnforcer:balance-not-gt"));
        enforcer.afterHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);

        // Increase balance by 100 only in recipient2 to fix it
        vm.prank(delegator);
        token.mint(recipient2_, tokenId, 100, "");

        // Recipient2 works well
        vm.prank(dm);
        enforcer.afterHook(terms2_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
    }

    // Reverts if the enforcer is locked
    function test_notAllow_reenterALockedEnforcer() public {
        // Expect it to increase by at least 100
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), uint256(100));
        bytes32 delegationHash_ = bytes32(uint256(99999999));

        // Lock the enforcer
        vm.startPrank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
        bytes32 hashKey_ =
            enforcer.getHashKey(address(delegationManager), address(token), address(delegator), tokenId, delegationHash_);
        assertTrue(enforcer.isLocked(hashKey_));
        vm.expectRevert(bytes("ERC1155BalanceGteEnforcer:enforcer-is-locked"));
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, delegationHash_, address(0), delegate);
        vm.stopPrank();

        vm.prank(delegator);
        token.mint(delegator, tokenId, 1000, "");

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
        terms_ = abi.encodePacked(address(token), address(delegator), uint8(100));
        vm.expectRevert(bytes("ERC1155BalanceGteEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);

        // Too large
        terms_ = abi.encodePacked(uint256(100), uint256(100), uint256(100), uint256(100));
        vm.expectRevert(bytes("ERC1155BalanceGteEnforcer:invalid-terms-length"));
        enforcer.getTermsInfo(terms_);
    }

    // Validates that an invalid token address causes a revert
    function test_invalid_tokenAddress() public {
        bytes memory terms_;

        // Invalid token address
        terms_ = abi.encodePacked(address(0), address(delegator), uint256(tokenId), uint256(100));
        vm.expectRevert();
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    // Validates that an invalid amount causes a revert
    function test_notAllow_expectingOverflow() public {
        // Expect balance to increase by max uint256, which is unrealistic
        bytes memory terms_ = abi.encodePacked(address(token), address(delegator), uint256(tokenId), type(uint256).max);

        vm.prank(dm);
        enforcer.beforeHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
        vm.expectRevert();
        enforcer.afterHook(terms_, hex"", singleDefaultMode, mintExecutionCallData, bytes32(0), address(0), delegate);
    }

    //////////////////////  Integration  //////////////////////

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
