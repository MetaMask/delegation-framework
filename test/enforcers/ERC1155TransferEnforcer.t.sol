// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { BasicERC1155 } from "../utils/BasicERC1155.t.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { Implementation, SignatureType } from "../utils/Types.t.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { ERC1155TransferEnforcer } from "../../src/enforcers/ERC1155TransferEnforcer.sol";

/**
 * @title ERC1155TransferEnforcerTest
 * @notice Comprehensive tests for ERC1155TransferEnforcer following ERC20TransferAmountEnforcer structure
 */
contract ERC1155TransferEnforcerTest is CaveatEnforcerBaseTest {
    using MessageHashUtils for bytes32;
    using ModeLib for ModeCode;

    ////////////////////// State //////////////////////

    ERC1155TransferEnforcer public erc1155TransferEnforcer;
    BasicERC1155 public basicERC1155;
    BasicERC1155 public invalidERC1155;

    // Test parameters
    uint256 constant TOKEN_ID_1 = 1;
    uint256 constant TOKEN_ID_2 = 2;
    uint256 constant TOKEN_ID_3 = 3;
    uint256 constant TRANSFER_LIMIT_1 = 100;
    uint256 constant TRANSFER_LIMIT_2 = 200;

    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
    }

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        erc1155TransferEnforcer = new ERC1155TransferEnforcer();
        vm.label(address(erc1155TransferEnforcer), "ERC1155TransferEnforcer");

        basicERC1155 = new BasicERC1155(address(users.alice.deleGator), "TestERC1155", "T1155", "https://test.com/");
        invalidERC1155 = new BasicERC1155(address(users.alice.deleGator), "InvalidERC1155", "I1155", "https://invalid.com/");

        // Mint initial tokens for testing
        vm.startPrank(address(users.alice.deleGator));
        basicERC1155.mint(address(users.alice.deleGator), TOKEN_ID_1, 1000, "");
        basicERC1155.mint(address(users.alice.deleGator), TOKEN_ID_2, 1000, "");
        basicERC1155.mint(address(users.alice.deleGator), TOKEN_ID_3, 1000, "");
        vm.stopPrank();

        // Fund wallets with ETH for gas
        vm.deal(address(users.alice.deleGator), 10 ether);
        vm.deal(address(users.bob.deleGator), 10 ether);

        // Labels
        vm.label(address(basicERC1155), "BasicERC1155");
        vm.label(address(invalidERC1155), "InvalidERC1155");
    }

    ////////////////////// Helper Functions //////////////////////

    function _encodeSingleTerms(address _contract, uint256 _tokenId, uint256 _amount) internal pure returns (bytes memory) {
        return abi.encode(_contract, _tokenId, _amount);
    }

    function _encodeBatchTerms(
        address _contract,
        uint256[] memory _tokenIds,
        uint256[] memory _amounts
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_contract, _tokenIds, _amounts);
    }

    ////////////////////// Valid cases //////////////////////

    // should SUCCEED to INVOKE single transfer BELOW enforcer allowance
    function test_singleTransferSucceedsIfCalledBelowAllowance() public {
        uint256 transferAmount_ = 50;

        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeTransferFrom.selector,
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                TOKEN_ID_1,
                transferAmount_,
                ""
            )
        });

        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = _encodeSingleTerms(address(basicERC1155), TOKEN_ID_1, TRANSFER_LIMIT_1);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc1155TransferEnforcer), terms: inputTerms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), 0);

        vm.prank(address(delegationManager));
        vm.expectEmit(true, true, true, true, address(erc1155TransferEnforcer));
        emit ERC1155TransferEnforcer.IncreasedSpentMap(
            address(delegationManager), delegationHash_, TOKEN_ID_1, TRANSFER_LIMIT_1, transferAmount_
        );

        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );

        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), transferAmount_);
    }

    // should SUCCEED to INVOKE batch transfer BELOW enforcer allowances
    function test_batchTransferSucceedsIfCalledBelowAllowances() public {
        uint256[] memory tokenIds_ = new uint256[](2);
        uint256[] memory transferAmounts_ = new uint256[](2);
        uint256[] memory limits_ = new uint256[](2);

        tokenIds_[0] = TOKEN_ID_1;
        tokenIds_[1] = TOKEN_ID_2;
        transferAmounts_[0] = 30;
        transferAmounts_[1] = 50;
        limits_[0] = TRANSFER_LIMIT_1;
        limits_[1] = TRANSFER_LIMIT_2;

        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeBatchTransferFrom.selector,
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                tokenIds_,
                transferAmounts_,
                ""
            )
        });

        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = _encodeBatchTerms(address(basicERC1155), tokenIds_, limits_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc1155TransferEnforcer), terms: inputTerms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), 0);
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_2), 0);

        vm.prank(address(delegationManager));
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );

        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), transferAmounts_[0]);
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_2), transferAmounts_[1]);
    }

    // should SUCCEED twice but FAIL on third single transfer when limit is reached
    function test_singleTransferMultipleCallsReachesLimit() public {
        uint256 transferAmount_ = 50;
        uint256 spendingLimit_ = 100;
        bytes32 delegationHash_ = keccak256("testDelegation");

        bytes memory inputTerms_ = _encodeSingleTerms(address(basicERC1155), TOKEN_ID_1, spendingLimit_);

        // Create single execution to reuse
        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeTransferFrom.selector,
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                TOKEN_ID_1,
                transferAmount_,
                ""
            )
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), 0);

        // First transfer - should succeed
        vm.prank(address(delegationManager));
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), transferAmount_);

        // Second transfer - should succeed
        vm.prank(address(delegationManager));
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), spendingLimit_);

        // Third transfer - should fail (limit reached)
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC1155TransferEnforcer:unauthorized-amount");
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );

        // Spent amount should remain at limit
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), spendingLimit_);
    }

    // should SUCCEED twice but FAIL on third batch transfer when limit is reached
    function test_batchTransferMultipleCallsReachesLimit() public {
        uint256 transferAmount_ = 50;
        uint256 spendingLimit_ = 100;
        bytes32 delegationHash_ = keccak256("testDelegationBatch");

        uint256[] memory tokenIds_ = new uint256[](1);
        uint256[] memory transferAmounts_ = new uint256[](1);
        uint256[] memory limits_ = new uint256[](1);

        tokenIds_[0] = TOKEN_ID_1;
        transferAmounts_[0] = transferAmount_;
        limits_[0] = spendingLimit_;

        bytes memory inputTerms_ = _encodeBatchTerms(address(basicERC1155), tokenIds_, limits_);

        // Create single execution to reuse
        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeBatchTransferFrom.selector,
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                tokenIds_,
                transferAmounts_,
                ""
            )
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), 0);

        // First batch transfer - should succeed
        vm.prank(address(delegationManager));
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), transferAmount_);

        // Second batch transfer - should succeed
        vm.prank(address(delegationManager));
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), spendingLimit_);

        // Third batch transfer - should fail (limit reached)
        vm.prank(address(delegationManager));
        vm.expectRevert("ERC1155TransferEnforcer:unauthorized-amount");
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );

        // Spent amount should remain at limit
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), spendingLimit_);
    }

    ////////////////////// Invalid cases //////////////////////

    // should FAIL to INVOKE single transfer ABOVE enforcer allowance
    function test_singleTransferFailsIfCalledAboveAllowance() public {
        uint256 transferAmount_ = TRANSFER_LIMIT_1 + 1;

        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeTransferFrom.selector,
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                TOKEN_ID_1,
                transferAmount_,
                ""
            )
        });

        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = _encodeSingleTerms(address(basicERC1155), TOKEN_ID_1, TRANSFER_LIMIT_1);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc1155TransferEnforcer), terms: inputTerms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), 0);

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC1155TransferEnforcer:unauthorized-amount");
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );

        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), 0);
    }

    // should FAIL to INVOKE batch transfer with one amount ABOVE enforcer allowance
    function test_batchTransferFailsIfOneAmountAboveAllowance() public {
        uint256[] memory tokenIds_ = new uint256[](2);
        uint256[] memory transferAmounts_ = new uint256[](2);
        uint256[] memory limits_ = new uint256[](2);

        tokenIds_[0] = TOKEN_ID_1;
        tokenIds_[1] = TOKEN_ID_2;
        transferAmounts_[0] = 30;
        transferAmounts_[1] = TRANSFER_LIMIT_2 + 1; // Above limit
        limits_[0] = TRANSFER_LIMIT_1;
        limits_[1] = TRANSFER_LIMIT_2;

        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeBatchTransferFrom.selector,
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                tokenIds_,
                transferAmounts_,
                ""
            )
        });

        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = _encodeBatchTerms(address(basicERC1155), tokenIds_, limits_);

        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC1155TransferEnforcer:unauthorized-amount");
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    // should FAIL to INVOKE invalid ERC1155-contract
    function test_methodFailsIfInvokesInvalidContract() public {
        uint256 transferAmount_ = 50;

        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeTransferFrom.selector,
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                TOKEN_ID_1,
                transferAmount_,
                ""
            )
        });

        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = _encodeSingleTerms(address(invalidERC1155), TOKEN_ID_1, TRANSFER_LIMIT_1);

        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC1155TransferEnforcer:unauthorized-contract-target");
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    // should FAIL to INVOKE invalid execution data length
    function test_notAllow_invalidExecutionLength() public {
        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeBatchTransferFrom.selector,
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                new uint256[](0), // Empty array
                new uint256[](0), // Empty array
                ""
            )
        });

        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = _encodeSingleTerms(address(basicERC1155), TOKEN_ID_1, TRANSFER_LIMIT_1);

        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC1155TransferEnforcer:invalid-calldata-length");
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    // should FAIL to INVOKE invalid method selector for single transfer
    function test_methodFailsIfInvokesInvalidSingleSelector() public {
        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeBatchTransferFrom.selector, // Wrong selector for single transfer
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                new uint256[](1),
                new uint256[](1),
                ""
            )
        });

        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = _encodeSingleTerms(address(basicERC1155), TOKEN_ID_1, TRANSFER_LIMIT_1);

        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC1155TransferEnforcer:unauthorized-selector-single");
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    // should FAIL to INVOKE invalid method selector for batch transfer
    function test_methodFailsIfInvokesInvalidBatchSelector() public {
        uint256[] memory tokenIds_ = new uint256[](1);
        uint256[] memory limits_ = new uint256[](1);
        tokenIds_[0] = TOKEN_ID_1;
        limits_[0] = TRANSFER_LIMIT_1;

        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeTransferFrom.selector, // Wrong selector for batch transfer
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                TOKEN_ID_1,
                50,
                ""
            )
        });

        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = _encodeBatchTerms(address(basicERC1155), tokenIds_, limits_);

        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC1155TransferEnforcer:unauthorized-selector-batch");
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    // should FAIL to INVOKE invalid terms length
    function test_methodFailsIfInvokesInvalidTermsLength() public {
        bytes memory inputTerms_ = abi.encode(address(basicERC1155)); // Too short

        vm.expectRevert("ERC1155TransferEnforcer:invalid-terms-length");
        erc1155TransferEnforcer.getTermsInfo(inputTerms_);

        inputTerms_ = abi.encode(address(basicERC1155), TOKEN_ID_1);

        // Empty arrays
        uint256[] memory tokenIds_ = new uint256[](0);
        uint256[] memory transferAmounts_ = new uint256[](0);
        inputTerms_ = abi.encode(address(basicERC1155), tokenIds_, transferAmounts_);
        vm.expectRevert("ERC1155TransferEnforcer:invalid-terms-length");
        erc1155TransferEnforcer.getTermsInfo(inputTerms_);
    }

    // should FAIL to get terms info when passing zero address
    function test_getTermsInfoFailsForZeroAddress() public {
        bytes memory inputTerms_ = _encodeSingleTerms(address(0), TOKEN_ID_1, TRANSFER_LIMIT_1);

        vm.expectRevert("ERC1155TransferEnforcer:invalid-contract-address");
        erc1155TransferEnforcer.getTermsInfo(inputTerms_);
    }

    // should FAIL to get terms info when arrays have different lengths
    function test_getTermsInfoFailsForMismatchedArrayLengths() public {
        uint256[] memory tokenIds_ = new uint256[](2);
        uint256[] memory limits_ = new uint256[](1); // Different length
        tokenIds_[0] = TOKEN_ID_1;
        tokenIds_[1] = TOKEN_ID_2;
        limits_[0] = TRANSFER_LIMIT_1;

        bytes memory inputTerms_ = _encodeBatchTerms(address(basicERC1155), tokenIds_, limits_);

        vm.expectRevert("ERC1155TransferEnforcer:invalid-ids-values-length");
        erc1155TransferEnforcer.getTermsInfo(inputTerms_);
    }

    // should FAIL with unauthorized token ID in single transfer
    function test_unauthorizedTokenIdInSingleTransfer() public {
        uint256 transferAmount_ = 50;

        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeTransferFrom.selector,
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                TOKEN_ID_2, // Different token ID
                transferAmount_,
                ""
            )
        });

        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = _encodeSingleTerms(address(basicERC1155), TOKEN_ID_1, TRANSFER_LIMIT_1);

        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC1155TransferEnforcer:unauthorized-token-id");
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    // should FAIL with unauthorized token ID in batch transfer
    function test_unauthorizedTokenIdInBatchTransfer() public {
        uint256[] memory permittedTokenIds_ = new uint256[](1);
        uint256[] memory limits_ = new uint256[](1);
        permittedTokenIds_[0] = TOKEN_ID_1;
        limits_[0] = TRANSFER_LIMIT_1;

        uint256[] memory transferTokenIds_ = new uint256[](2);
        uint256[] memory transferAmounts_ = new uint256[](2);
        transferTokenIds_[0] = TOKEN_ID_1;
        transferTokenIds_[1] = TOKEN_ID_3; // Unauthorized token ID
        transferAmounts_[0] = 30;
        transferAmounts_[1] = 40;

        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeBatchTransferFrom.selector,
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                transferTokenIds_,
                transferAmounts_,
                ""
            )
        });

        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = _encodeBatchTerms(address(basicERC1155), permittedTokenIds_, limits_);

        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC1155TransferEnforcer:unauthorized-token-id");
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    // should FAIL with zero address in transfer
    function test_invalidFromAddress() public {
        uint256 transferAmount_ = 50;

        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeTransferFrom.selector,
                address(0), // Invalid from address
                address(users.bob.deleGator),
                TOKEN_ID_1,
                transferAmount_,
                ""
            )
        });

        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = _encodeSingleTerms(address(basicERC1155), TOKEN_ID_1, TRANSFER_LIMIT_1);

        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC1155TransferEnforcer:invalid-address");
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    // should FAIL with zero address in transfer
    function test_invalidToAddress() public {
        uint256 transferAmount_ = 50;

        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeTransferFrom.selector,
                address(users.alice.deleGator),
                address(0), // Invalid to address
                TOKEN_ID_1,
                transferAmount_,
                ""
            )
        });

        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = _encodeSingleTerms(address(basicERC1155), TOKEN_ID_1, TRANSFER_LIMIT_1);

        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC1155TransferEnforcer:invalid-address");
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    // should FAIL with non-zero value
    function test_invalidNonZeroValue() public {
        uint256 transferAmount_ = 50;

        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 1 ether, // Non-zero value
            callData: abi.encodeWithSelector(
                IERC1155.safeTransferFrom.selector,
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                TOKEN_ID_1,
                transferAmount_,
                ""
            )
        });

        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);
        bytes memory inputTerms_ = _encodeSingleTerms(address(basicERC1155), TOKEN_ID_1, TRANSFER_LIMIT_1);

        bytes32 delegationHash_ = keccak256("test");

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC1155TransferEnforcer:invalid-value");
        erc1155TransferEnforcer.beforeHook(
            inputTerms_, hex"", singleDefaultMode, executionCallData_, delegationHash_, address(0), address(0)
        );
    }

    // should NOT transfer when max allowance is reached
    function test_transferFailsAboveAllowance() public {
        uint256 spendingLimit_ = 100;
        uint256 firstTransfer_ = 60;

        assertEq(basicERC1155.balanceOf(address(users.alice.deleGator), TOKEN_ID_1), 1000);
        assertEq(basicERC1155.balanceOf(address(users.bob.deleGator), TOKEN_ID_1), 0);

        Execution memory execution1_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeTransferFrom.selector,
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                TOKEN_ID_1,
                firstTransfer_,
                ""
            )
        });

        bytes memory inputTerms_ = _encodeSingleTerms(address(basicERC1155), TOKEN_ID_1, spendingLimit_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc1155TransferEnforcer), terms: inputTerms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), 0);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // First transfer - should succeed
        invokeDelegation_UserOp(users.bob, delegations_, execution1_);

        assertEq(basicERC1155.balanceOf(address(users.alice.deleGator), TOKEN_ID_1), 940);
        assertEq(basicERC1155.balanceOf(address(users.bob.deleGator), TOKEN_ID_1), 60);
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), firstTransfer_);

        // Second transfer - should succeed (40 more to reach limit)
        Execution memory execution2_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeTransferFrom.selector, address(users.alice.deleGator), address(users.bob.deleGator), TOKEN_ID_1, 40, ""
            )
        });

        invokeDelegation_UserOp(users.bob, delegations_, execution2_);
        assertEq(basicERC1155.balanceOf(address(users.alice.deleGator), TOKEN_ID_1), 900);
        assertEq(basicERC1155.balanceOf(address(users.bob.deleGator), TOKEN_ID_1), 100);
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), spendingLimit_);

        // Third transfer - should fail (attempt transfer above allowance: balances should remain unchanged)
        Execution memory execution3_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeTransferFrom.selector, address(users.alice.deleGator), address(users.bob.deleGator), TOKEN_ID_1, 1, ""
            )
        });

        invokeDelegation_UserOp(users.bob, delegations_, execution3_);
        assertEq(basicERC1155.balanceOf(address(users.alice.deleGator), TOKEN_ID_1), 900);
        assertEq(basicERC1155.balanceOf(address(users.bob.deleGator), TOKEN_ID_1), 100);
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), spendingLimit_);
    }

    // should fail with invalid call type mode (batch instead of single mode)
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        erc1155TransferEnforcer.beforeHook(hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        erc1155TransferEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// Integration //////////////////////

    // should allow single token transfer integration
    function test_singleTransferIntegration() public {
        uint256 transferAmount_ = 50;

        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeTransferFrom.selector,
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                TOKEN_ID_1,
                transferAmount_,
                ""
            )
        });

        bytes memory inputTerms_ = _encodeSingleTerms(address(basicERC1155), TOKEN_ID_1, TRANSFER_LIMIT_1);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc1155TransferEnforcer), terms: inputTerms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Enforcer allows the delegation
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Verify the transfer
        assertEq(basicERC1155.balanceOf(address(users.alice.deleGator), TOKEN_ID_1), 950);
        assertEq(basicERC1155.balanceOf(address(users.bob.deleGator), TOKEN_ID_1), 50);
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), transferAmount_);

        // Enforcer allows to reuse the delegation
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Verify second transfer
        assertEq(basicERC1155.balanceOf(address(users.alice.deleGator), TOKEN_ID_1), 900);
        assertEq(basicERC1155.balanceOf(address(users.bob.deleGator), TOKEN_ID_1), 100);
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), transferAmount_ * 2);
    }

    // should allow batch token transfer integration
    function test_batchTransferIntegration() public {
        uint256[] memory tokenIds_ = new uint256[](2);
        uint256[] memory transferAmounts_ = new uint256[](2);
        uint256[] memory limits_ = new uint256[](2);

        tokenIds_[0] = TOKEN_ID_1;
        tokenIds_[1] = TOKEN_ID_2;
        transferAmounts_[0] = 30;
        transferAmounts_[1] = 50;
        limits_[0] = TRANSFER_LIMIT_1;
        limits_[1] = TRANSFER_LIMIT_2;

        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeBatchTransferFrom.selector,
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                tokenIds_,
                transferAmounts_,
                ""
            )
        });

        bytes memory inputTerms_ = _encodeBatchTerms(address(basicERC1155), tokenIds_, limits_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc1155TransferEnforcer), terms: inputTerms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Enforcer allows the delegation
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Verify the transfers
        assertEq(basicERC1155.balanceOf(address(users.alice.deleGator), TOKEN_ID_1), 970);
        assertEq(basicERC1155.balanceOf(address(users.alice.deleGator), TOKEN_ID_2), 950);
        assertEq(basicERC1155.balanceOf(address(users.bob.deleGator), TOKEN_ID_1), 30);
        assertEq(basicERC1155.balanceOf(address(users.bob.deleGator), TOKEN_ID_2), 50);
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_1), transferAmounts_[0]);
        assertEq(erc1155TransferEnforcer.spentMap(address(delegationManager), delegationHash_, TOKEN_ID_2), transferAmounts_[1]);
    }

    // should NOT allow unauthorized amounts in batch transfer integration
    function test_batchTransferFailsAboveAllowanceIntegration() public {
        uint256[] memory tokenIds_ = new uint256[](2);
        uint256[] memory transferAmounts_ = new uint256[](2);
        uint256[] memory limits_ = new uint256[](2);

        tokenIds_[0] = TOKEN_ID_1;
        tokenIds_[1] = TOKEN_ID_2;
        transferAmounts_[0] = TRANSFER_LIMIT_1 + 1; // Exceeds limit
        transferAmounts_[1] = 50;
        limits_[0] = TRANSFER_LIMIT_1;
        limits_[1] = TRANSFER_LIMIT_2;

        Execution memory execution_ = Execution({
            target: address(basicERC1155),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC1155.safeBatchTransferFrom.selector,
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                tokenIds_,
                transferAmounts_,
                ""
            )
        });

        bytes memory inputTerms_ = _encodeBatchTerms(address(basicERC1155), tokenIds_, limits_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(erc1155TransferEnforcer), terms: inputTerms_ });

        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        // Execute Bob's UserOp
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Should fail - balances remain unchanged
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Verify no transfers occurred
        assertEq(basicERC1155.balanceOf(address(users.alice.deleGator), TOKEN_ID_1), 1000);
        assertEq(basicERC1155.balanceOf(address(users.alice.deleGator), TOKEN_ID_2), 1000);
        assertEq(basicERC1155.balanceOf(address(users.bob.deleGator), TOKEN_ID_1), 0);
        assertEq(basicERC1155.balanceOf(address(users.bob.deleGator), TOKEN_ID_2), 0);
    }

    ////////////////////// Helper functions //////////////////////

    function createPermissionContexts(Delegation memory del) internal pure returns (bytes[] memory) {
        Delegation[] memory delegations = new Delegation[](1);
        delegations[0] = del;
        bytes[] memory permissionContexts = new bytes[](1);
        permissionContexts[0] = abi.encode(delegations);
        return permissionContexts;
    }

    function createExecutionCallDatas(Execution memory execution) internal pure returns (bytes[] memory) {
        bytes[] memory executionCallDatas = new bytes[](1);
        executionCallDatas[0] = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);
        return executionCallDatas;
    }

    function createModes(ModeCode _mode) internal pure returns (ModeCode[] memory) {
        ModeCode[] memory modes = new ModeCode[](1);
        modes[0] = _mode;
        return modes;
    }

    // Override helper from BaseTest.
    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(erc1155TransferEnforcer));
    }
}
