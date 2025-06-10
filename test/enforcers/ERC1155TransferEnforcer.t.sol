// // SPDX-License-Identifier: MIT AND Apache-2.0
// pragma solidity 0.8.23;

// import { Test } from "forge-std/Test.sol";
// import { ERC1155TransferEnforcer } from "../../src/enforcers/ERC1155TransferEnforcer.sol";
// import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
// import { ModeLib } from "@erc7579/lib/ModeLib.sol";
// import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
// import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
// import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
// import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
// import { BasicERC1155 } from "../utils/BasicERC1155.t.sol";

// contract ERC1155TransferEnforcerTest is CaveatEnforcerBaseTest {
//     ////////////////////// State //////////////////////

//     ERC1155TransferEnforcer public erc1155TransferEnforcer;
//     BasicERC1155 public mockERC1155;
//     ModeCode public mode = ModeLib.encodeSimpleSingle();

//     ////////////////////// Set up //////////////////////

//     function setUp() public override {
//         super.setUp();
//         erc1155TransferEnforcer = new ERC1155TransferEnforcer();
//         mockERC1155 = new BasicERC1155(address(this), "Basic ERC1155", "B1155", "");
//         vm.label(address(erc1155TransferEnforcer), "ERC1155 Transfer Enforcer");
//         vm.label(address(mockERC1155), "Basic ERC1155");
//     }

//     ////////////////////// Helper Functions //////////////////////

//     function _encodeTerms(
//         bool isBatch,
//         address contract_,
//         uint256[] memory tokenIds,
//         uint256[] memory values
//     )
//         internal
//         pure
//         returns (bytes memory)
//     {
//         return abi.encode(isBatch, contract_, tokenIds, values);
//     }

//     ////////////////////// Valid cases //////////////////////

//     // Tests single token transfer with a permitted token ID and amount
//     function test_singleTransferWithSinglePermittedToken() public {
//         uint256[] memory permittedTokenIds = new uint256[](1);
//         uint256[] memory permittedValues = new uint256[](1);
//         permittedTokenIds[0] = 1;
//         permittedValues[0] = 1;

//         bytes memory terms = _encodeTerms(false, address(mockERC1155), permittedTokenIds, permittedValues);

//         Execution memory execution = Execution({
//             target: address(mockERC1155),
//             value: 0,
//             callData: abi.encodeWithSelector(
//                 IERC1155.safeTransferFrom.selector, address(users.alice.deleGator), address(users.bob.deleGator), 1, 1, ""
//             )
//         });
//         bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

//         vm.prank(address(delegationManager));
//         erc1155TransferEnforcer.beforeHook(terms, "", mode, executionCallData, keccak256(""), address(0), address(0));
//     }

//     // Tests batch transfer with multiple permitted token IDs and amounts
//     function test_batchTransferWithMultiplePermittedTokens() public {
//         uint256[] memory permittedTokenIds = new uint256[](2);
//         uint256[] memory permittedValues = new uint256[](2);
//         permittedTokenIds[0] = 1;
//         permittedTokenIds[1] = 2;
//         permittedValues[0] = 1;
//         permittedValues[1] = 1;

//         bytes memory terms = _encodeTerms(address(mockERC1155), permittedTokenIds, permittedValues, true);

//         uint256[] memory ids = new uint256[](2);
//         uint256[] memory amounts = new uint256[](2);
//         ids[0] = 1;
//         ids[1] = 2;
//         amounts[0] = 1;
//         amounts[1] = 1;

//         Execution memory execution = Execution({
//             target: address(mockERC1155),
//             value: 0,
//             callData: abi.encodeWithSelector(
//                 IERC1155.safeBatchTransferFrom.selector, address(users.alice.deleGator), address(users.bob.deleGator), ids,
// amounts, ""
//             )
//         });
//         bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

//         vm.prank(address(delegationManager));
//         erc1155TransferEnforcer.beforeHook(terms, "", mode, executionCallData, keccak256(""), address(0), address(0));
//     }

//     ////////////////////// Invalid cases //////////////////////

//     // Tests rejection of invalid terms data length
//     function test_invalidTermsLength() public {
//         vm.expectRevert("ERC1155TransferEnforcer:invalid-terms-length");
//         erc1155TransferEnforcer.getTermsInfo(bytes("1"));
//     }

//     // Tests rejection of too short calldata
//     function test_invalidCalldataLength() public {
//         uint256[] memory permittedTokenIds = new uint256[](1);
//         uint256[] memory permittedValues = new uint256[](1);
//         permittedTokenIds[0] = 1;
//         permittedValues[0] = 1;

//         bytes memory terms = _encodeTerms(address(mockERC1155), permittedTokenIds, permittedValues, false);

//         Execution memory execution = Execution({ target: address(mockERC1155), value: 0, callData: abi.encodePacked(bytes4(0))
// });
//         bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

//         vm.prank(address(delegationManager));
//         vm.expectRevert("ERC1155TransferEnforcer:invalid-calldata-length");
//         erc1155TransferEnforcer.beforeHook(terms, "", mode, executionCallData, keccak256(""), address(0), address(0));
//     }

//     // Tests rejection of unauthorized contract target
//     function test_unauthorizedContractTarget() public {
//         uint256[] memory permittedTokenIds = new uint256[](1);
//         uint256[] memory permittedValues = new uint256[](1);
//         permittedTokenIds[0] = 1;
//         permittedValues[0] = 1;

//         bytes memory terms = _encodeTerms(address(mockERC1155), permittedTokenIds, permittedValues, false);

//         Execution memory execution = Execution({
//             target: address(0x1234), // Different contract address
//             value: 0,
//             callData: abi.encodeWithSelector(
//                 IERC1155.safeTransferFrom.selector, address(users.alice.deleGator), address(users.bob.deleGator), 1, 1, ""
//             )
//         });
//         bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

//         vm.prank(address(delegationManager));
//         vm.expectRevert("ERC1155TransferEnforcer:unauthorized-contract-target");
//         erc1155TransferEnforcer.beforeHook(terms, "", mode, executionCallData, keccak256(""), address(0), address(0));
//     }

//     // Tests rejection of unauthorized function selector
//     function test_unauthorizedSelector() public {
//         uint256[] memory permittedTokenIds = new uint256[](1);
//         uint256[] memory permittedValues = new uint256[](1);
//         permittedTokenIds[0] = 1;
//         permittedValues[0] = 1;

//         bytes memory terms = _encodeTerms(address(mockERC1155), permittedTokenIds, permittedValues, false);

//         Execution memory execution = Execution({
//             target: address(mockERC1155),
//             value: 0,
//             callData: abi.encodeWithSelector(bytes4(0x12345678)) // Invalid selector
//          });
//         bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

//         vm.prank(address(delegationManager));
//         vm.expectRevert("ERC1155TransferEnforcer:unauthorized-selector-single");
//         erc1155TransferEnforcer.beforeHook(terms, "", mode, executionCallData, keccak256(""), address(0), address(0));
//     }

//     // Tests rejection of unauthorized token ID in single transfer
//     function test_unauthorizedTokenId() public {
//         uint256[] memory permittedTokenIds = new uint256[](1);
//         uint256[] memory permittedValues = new uint256[](1);
//         permittedTokenIds[0] = 1;
//         permittedValues[0] = 1;

//         bytes memory terms = _encodeTerms(address(mockERC1155), permittedTokenIds, permittedValues, false);

//         Execution memory execution = Execution({
//             target: address(mockERC1155),
//             value: 0,
//             callData: abi.encodeWithSelector(
//                 IERC1155.safeTransferFrom.selector,
//                 address(users.alice.deleGator),
//                 address(users.bob.deleGator),
//                 2, // Different token ID
//                 1,
//                 ""
//             )
//         });
//         bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

//         vm.prank(address(delegationManager));
//         vm.expectRevert("ERC1155TransferEnforcer:unauthorized-token-id");
//         erc1155TransferEnforcer.beforeHook(terms, "", mode, executionCallData, keccak256(""), address(0), address(0));
//     }

//     // Tests rejection of unauthorized amount in single transfer
//     function test_unauthorizedAmount() public {
//         uint256[] memory permittedTokenIds = new uint256[](1);
//         uint256[] memory permittedValues = new uint256[](1);
//         permittedTokenIds[0] = 1;
//         permittedValues[0] = 1;

//         bytes memory terms = _encodeTerms(address(mockERC1155), permittedTokenIds, permittedValues, false);

//         Execution memory execution = Execution({
//             target: address(mockERC1155),
//             value: 0,
//             callData: abi.encodeWithSelector(
//                 IERC1155.safeTransferFrom.selector,
//                 address(users.alice.deleGator),
//                 address(users.bob.deleGator),
//                 1,
//                 2, // Different amount
//                 ""
//             )
//         });
//         bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

//         vm.prank(address(delegationManager));
//         vm.expectRevert("ERC1155TransferEnforcer:unauthorized-amount");
//         erc1155TransferEnforcer.beforeHook(terms, "", mode, executionCallData, keccak256(""), address(0), address(0));
//     }

//     // Tests rejection of zero address in transfer
//     function test_invalidAddress() public {
//         uint256[] memory permittedTokenIds = new uint256[](1);
//         uint256[] memory permittedValues = new uint256[](1);
//         permittedTokenIds[0] = 1;
//         permittedValues[0] = 1;

//         bytes memory terms = _encodeTerms(address(mockERC1155), permittedTokenIds, permittedValues, false);

//         Execution memory execution = Execution({
//             target: address(mockERC1155),
//             value: 0,
//             callData: abi.encodeWithSelector(
//                 IERC1155.safeTransferFrom.selector,
//                 address(0), // Invalid from address
//                 address(users.bob.deleGator),
//                 1,
//                 1,
//                 ""
//             )
//         });
//         bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

//         vm.prank(address(delegationManager));
//         vm.expectRevert("ERC1155TransferEnforcer:invalid-address");
//         erc1155TransferEnforcer.beforeHook(terms, "", mode, executionCallData, keccak256(""), address(0), address(0));
//     }

//     // Tests rejection of unauthorized token ID in batch transfer
//     function test_batchTransferWithUnauthorizedTokenId() public {
//         uint256[] memory permittedTokenIds = new uint256[](1);
//         uint256[] memory permittedValues = new uint256[](1);
//         permittedTokenIds[0] = 1;
//         permittedValues[0] = 1;

//         bytes memory terms = _encodeTerms(address(mockERC1155), permittedTokenIds, permittedValues, true);

//         uint256[] memory ids = new uint256[](2);
//         uint256[] memory amounts = new uint256[](2);
//         ids[0] = 1;
//         ids[1] = 2; // Unauthorized token ID
//         amounts[0] = 1;
//         amounts[1] = 1;

//         Execution memory execution = Execution({
//             target: address(mockERC1155),
//             value: 0,
//             callData: abi.encodeWithSelector(
//                 IERC1155.safeBatchTransferFrom.selector, address(users.alice.deleGator), address(users.bob.deleGator), ids,
// amounts, ""
//             )
//         });
//         bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

//         vm.prank(address(delegationManager));
//         vm.expectRevert("ERC1155TransferEnforcer:unauthorized-token-id");
//         erc1155TransferEnforcer.beforeHook(terms, "", mode, executionCallData, keccak256(""), address(0), address(0));
//     }

//     // Tests rejection of unauthorized amount in batch transfer
//     function test_batchTransferWithUnauthorizedAmount() public {
//         uint256[] memory permittedTokenIds = new uint256[](2);
//         uint256[] memory permittedValues = new uint256[](2);
//         permittedTokenIds[0] = 1;
//         permittedTokenIds[1] = 2;
//         permittedValues[0] = 1;
//         permittedValues[1] = 1;

//         bytes memory terms = _encodeTerms(address(mockERC1155), permittedTokenIds, permittedValues, true);

//         uint256[] memory ids = new uint256[](2);
//         uint256[] memory amounts = new uint256[](2);
//         ids[0] = 1;
//         ids[1] = 2;
//         amounts[0] = 1;
//         amounts[1] = 2; // Unauthorized amount

//         Execution memory execution = Execution({
//             target: address(mockERC1155),
//             value: 0,
//             callData: abi.encodeWithSelector(
//                 IERC1155.safeBatchTransferFrom.selector, address(users.alice.deleGator), address(users.bob.deleGator), ids,
// amounts, ""
//             )
//         });
//         bytes memory executionCallData = ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData);

//         vm.prank(address(delegationManager));
//         vm.expectRevert("ERC1155TransferEnforcer:unauthorized-amount");
//         erc1155TransferEnforcer.beforeHook(terms, "", mode, executionCallData, keccak256(""), address(0), address(0));
//     }

//     ////////////////////// Integration //////////////////////

//     // Tests complete single token transfer flow with delegation
//     function test_singleTransferIntegration() public {
//         uint256[] memory permittedTokenIds = new uint256[](1);
//         uint256[] memory permittedValues = new uint256[](1);
//         permittedTokenIds[0] = 1;
//         permittedValues[0] = 1;

//         bytes memory terms = _encodeTerms(address(mockERC1155), permittedTokenIds, permittedValues, false);

//         // Set up initial balances
//         mockERC1155.mint(address(users.alice.deleGator), 1, 1, "");

//         Execution memory execution = Execution({
//             target: address(mockERC1155),
//             value: 0,
//             callData: abi.encodeWithSelector(
//                 IERC1155.safeTransferFrom.selector, address(users.alice.deleGator), address(users.bob.deleGator), 1, 1, ""
//             )
//         });

//         Caveat[] memory caveats = new Caveat[](1);
//         caveats[0] = Caveat({ args: "", enforcer: address(erc1155TransferEnforcer), terms: terms });

//         Delegation memory delegation = Delegation({
//             delegate: address(users.bob.deleGator),
//             delegator: address(users.alice.deleGator),
//             authority: ROOT_AUTHORITY,
//             caveats: caveats,
//             salt: 0,
//             signature: ""
//         });

//         delegation = signDelegation(users.alice, delegation);

//         Delegation[] memory delegations = new Delegation[](1);
//         delegations[0] = delegation;

//         // Execute the transfer
//         invokeDelegation_UserOp(users.bob, delegations, execution);

//         // Verify the transfer
//         assertEq(mockERC1155.balanceOf(address(users.alice.deleGator), 1), 0);
//         assertEq(mockERC1155.balanceOf(address(users.bob.deleGator), 1), 1);
//     }

//     // Tests complete batch token transfer flow with delegation
//     function test_batchTransferIntegration() public {
//         uint256[] memory permittedTokenIds = new uint256[](2);
//         uint256[] memory permittedValues = new uint256[](2);
//         permittedTokenIds[0] = 1;
//         permittedTokenIds[1] = 2;
//         permittedValues[0] = 1;
//         permittedValues[1] = 1;

//         bytes memory terms = _encodeTerms(address(mockERC1155), permittedTokenIds, permittedValues, true);

//         // Set up initial balances
//         mockERC1155.mint(address(users.alice.deleGator), 1, 1, "");
//         mockERC1155.mint(address(users.alice.deleGator), 2, 1, "");

//         uint256[] memory ids = new uint256[](2);
//         uint256[] memory amounts = new uint256[](2);
//         ids[0] = 1;
//         ids[1] = 2;
//         amounts[0] = 1;
//         amounts[1] = 1;

//         Execution memory execution = Execution({
//             target: address(mockERC1155),
//             value: 0,
//             callData: abi.encodeWithSelector(
//                 IERC1155.safeBatchTransferFrom.selector, address(users.alice.deleGator), address(users.bob.deleGator), ids,
// amounts, ""
//             )
//         });

//         Caveat[] memory caveats = new Caveat[](1);
//         caveats[0] = Caveat({ args: "", enforcer: address(erc1155TransferEnforcer), terms: terms });

//         Delegation memory delegation = Delegation({
//             delegate: address(users.bob.deleGator),
//             delegator: address(users.alice.deleGator),
//             authority: ROOT_AUTHORITY,
//             caveats: caveats,
//             salt: 0,
//             signature: ""
//         });

//         delegation = signDelegation(users.alice, delegation);

//         Delegation[] memory delegations = new Delegation[](1);
//         delegations[0] = delegation;

//         // Execute the transfer
//         invokeDelegation_UserOp(users.bob, delegations, execution);

//         // Verify the transfers
//         assertEq(mockERC1155.balanceOf(address(users.alice.deleGator), 1), 0);
//         assertEq(mockERC1155.balanceOf(address(users.alice.deleGator), 2), 0);
//         assertEq(mockERC1155.balanceOf(address(users.bob.deleGator), 1), 1);
//         assertEq(mockERC1155.balanceOf(address(users.bob.deleGator), 2), 1);
//     }

//     function _getEnforcer() internal view override returns (ICaveatEnforcer) {
//         return ICaveatEnforcer(address(erc1155TransferEnforcer));
//     }
// }
