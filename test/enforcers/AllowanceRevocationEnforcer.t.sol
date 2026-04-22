// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { BasicCF721 } from "../utils/BasicCF721.t.sol";
import { BasicERC1155 } from "../utils/BasicERC1155.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { AllowanceRevocationEnforcer } from "../../src/enforcers/AllowanceRevocationEnforcer.sol";

/**
 * @title AllowanceRevocationEnforcer Test
 */
contract AllowanceRevocationEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////

    AllowanceRevocationEnforcer public enforcer;
    BasicERC20 public erc20;
    BasicCF721 public erc721;
    BasicERC1155 public erc1155;

    address public delegator;
    address public spender;
    address public operator;

    uint256 public mintedTokenId;

    ////////////////////////////// Set up //////////////////////////////

    function setUp() public override {
        super.setUp();
        enforcer = new AllowanceRevocationEnforcer();
        vm.label(address(enforcer), "AllowanceRevocationEnforcer");

        delegator = address(users.alice.deleGator);
        spender = address(users.bob.deleGator);
        operator = address(users.carol.deleGator);

        erc20 = new BasicERC20(delegator, "TestToken", "TT", 100 ether);
        erc721 = new BasicCF721(delegator, "TestNFT", "TNFT", "");
        erc1155 = new BasicERC1155(delegator, "Test1155", "T1155", "");

        vm.label(address(erc20), "BasicERC20");
        vm.label(address(erc721), "BasicCF721");
        vm.label(address(erc1155), "BasicERC1155");

        // Mint an ERC-721 token to the delegator and approve it.
        vm.startPrank(delegator);
        erc721.mint(delegator);
        mintedTokenId = 0;
        erc721.approve(spender, mintedTokenId);

        // ERC-20 allowance.
        erc20.approve(spender, 42 ether);

        // setApprovalForAll on both ERC-721 and ERC-1155.
        erc721.setApprovalForAll(operator, true);
        erc1155.setApprovalForAll(operator, true);
        vm.stopPrank();
    }

    ////////////////////////////// Helpers //////////////////////////////

    function _approveCallData(address _spender, uint256 _amount) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC20.approve.selector, _spender, _amount);
    }

    function _setApprovalForAllCallData(address _operator, bool _approved) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC721.setApprovalForAll.selector, _operator, _approved);
    }

    function _encodeSingle(address _target, uint256 _value, bytes memory _callData) internal pure returns (bytes memory) {
        return ExecutionLib.encodeSingle(_target, _value, _callData);
    }

    function _callBeforeHook(bytes memory _executionCallData) internal {
        vm.prank(address(delegationManager));
        enforcer.beforeHook(hex"", hex"", singleDefaultMode, _executionCallData, bytes32(0), delegator, address(0));
    }

    function _expectRevertBeforeHook(bytes memory _executionCallData, bytes memory _revertReason) internal {
        vm.prank(address(delegationManager));
        vm.expectRevert(_revertReason);
        enforcer.beforeHook(hex"", hex"", singleDefaultMode, _executionCallData, bytes32(0), delegator, address(0));
    }

    ////////////////////////////// Valid cases (ERC-20 approve) //////////////////////////////

    function test_erc20_revokeSucceedsForExistingAllowance() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 0));
        _callBeforeHook(executionCallData_);
    }

    function test_erc20_revokeSucceedsForOneWeiAllowance() public {
        address other_ = address(users.dave.deleGator);
        vm.prank(delegator);
        erc20.approve(other_, 1);
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(other_, 0));
        _callBeforeHook(executionCallData_);
    }

    ////////////////////////////// Invalid cases (ERC-20 approve) //////////////////////////////

    function test_erc20_revertOnNonZeroAmount() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 1));
        _expectRevertBeforeHook(executionCallData_, "AllowanceRevocationEnforcer:non-zero-amount");
    }

    function test_erc20_revertWhenNoAllowance() public {
        address other_ = address(users.dave.deleGator);
        assertEq(erc20.allowance(delegator, other_), 0);
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(other_, 0));
        _expectRevertBeforeHook(executionCallData_, "AllowanceRevocationEnforcer:no-allowance-to-revoke");
    }

    function test_erc20_revertWhenAllowanceCallFails() public {
        // Target is a contract with no `allowance(address,address)` function.
        bytes memory executionCallData_ = _encodeSingle(address(enforcer), 0, _approveCallData(spender, 0));
        _expectRevertBeforeHook(executionCallData_, "AllowanceRevocationEnforcer:allowance-call-failed");
    }

    ////////////////////////////// Valid cases (ERC-721 approve) //////////////////////////////

    function test_erc721_revokeSucceedsForExistingApproval() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _approveCallData(address(0), mintedTokenId));
        _callBeforeHook(executionCallData_);
    }

    ////////////////////////////// Invalid cases (ERC-721 approve) //////////////////////////////

    function test_erc721_revertWhenNoApproval() public {
        // Mint a fresh token without approving it.
        vm.prank(delegator);
        erc721.mint(delegator);
        uint256 freshTokenId_ = 1;
        assertEq(erc721.getApproved(freshTokenId_), address(0));

        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _approveCallData(address(0), freshTokenId_));
        _expectRevertBeforeHook(executionCallData_, "AllowanceRevocationEnforcer:no-approval-to-revoke");
    }

    function test_erc721_revertWhenGetApprovedCallFails() public {
        // Non-existent token id reverts in OpenZeppelin's getApproved.
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _approveCallData(address(0), 9999));
        _expectRevertBeforeHook(executionCallData_, "AllowanceRevocationEnforcer:getApproved-call-failed");
    }

    ////////////////////////////// Valid cases (setApprovalForAll) //////////////////////////////

    function test_setApprovalForAll_erc721_revokeSucceeds() public {
        assertTrue(erc721.isApprovedForAll(delegator, operator));
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _setApprovalForAllCallData(operator, false));
        _callBeforeHook(executionCallData_);
    }

    function test_setApprovalForAll_erc1155_revokeSucceeds() public {
        assertTrue(erc1155.isApprovedForAll(delegator, operator));
        bytes memory executionCallData_ = _encodeSingle(address(erc1155), 0, _setApprovalForAllCallData(operator, false));
        _callBeforeHook(executionCallData_);
    }

    ////////////////////////////// Invalid cases (setApprovalForAll) //////////////////////////////

    function test_setApprovalForAll_revertWhenSettingTrue() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _setApprovalForAllCallData(operator, true));
        _expectRevertBeforeHook(executionCallData_, "AllowanceRevocationEnforcer:not-a-revocation");
    }

    function test_setApprovalForAll_revertWhenNotApproved() public {
        address other_ = address(users.dave.deleGator);
        assertFalse(erc721.isApprovedForAll(delegator, other_));
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _setApprovalForAllCallData(other_, false));
        _expectRevertBeforeHook(executionCallData_, "AllowanceRevocationEnforcer:no-approval-to-revoke");
    }

    function test_setApprovalForAll_revertWhenIsApprovedForAllCallFails() public {
        // Target is a contract with no `isApprovedForAll(address,address)` function.
        bytes memory executionCallData_ = _encodeSingle(address(enforcer), 0, _setApprovalForAllCallData(operator, false));
        _expectRevertBeforeHook(executionCallData_, "AllowanceRevocationEnforcer:isApprovedForAll-call-failed");
    }

    ////////////////////////////// Generic invalid cases //////////////////////////////

    function test_revertOnNonZeroValue() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 1, _approveCallData(spender, 0));
        _expectRevertBeforeHook(executionCallData_, "AllowanceRevocationEnforcer:invalid-value");
    }

    function test_revertOnInvalidExecutionLengthShort() public {
        bytes memory shortCallData_ = abi.encodePacked(IERC20.approve.selector, bytes32(uint256(uint160(spender))));
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, shortCallData_);
        _expectRevertBeforeHook(executionCallData_, "AllowanceRevocationEnforcer:invalid-execution-length");
    }

    function test_revertOnInvalidExecutionLengthLong() public {
        bytes memory longCallData_ = abi.encodePacked(_approveCallData(spender, 0), bytes1(0x00));
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, longCallData_);
        _expectRevertBeforeHook(executionCallData_, "AllowanceRevocationEnforcer:invalid-execution-length");
    }

    function test_revertOnInvalidMethod() public {
        bytes memory wrongMethodCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, spender, uint256(0));
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, wrongMethodCallData_);
        _expectRevertBeforeHook(executionCallData_, "AllowanceRevocationEnforcer:invalid-method");
    }

    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        enforcer.beforeHook(hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    function test_revertWithInvalidExecutionMode() public {
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), delegator, address(0));
    }

    ////////////////////////////// Integration //////////////////////////////

    function test_integration_revokesErc20Allowance() public {
        assertEq(erc20.allowance(delegator, spender), 42 ether);

        Execution memory execution_ =
            Execution({ target: address(erc20), value: 0, callData: _approveCallData(spender, 0) });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: hex"" });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        assertEq(erc20.allowance(delegator, spender), 0);
    }

    function test_integration_revokesErc721Approval() public {
        assertEq(erc721.getApproved(mintedTokenId), spender);

        Execution memory execution_ =
            Execution({ target: address(erc721), value: 0, callData: _approveCallData(address(0), mintedTokenId) });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: hex"" });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        assertEq(erc721.getApproved(mintedTokenId), address(0));
    }

    function test_integration_revokesSetApprovalForAll() public {
        assertTrue(erc1155.isApprovedForAll(delegator, operator));

        Execution memory execution_ =
            Execution({ target: address(erc1155), value: 0, callData: _setApprovalForAllCallData(operator, false) });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: hex"" });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        invokeDelegation_UserOp(users.bob, delegations_, execution_);
        assertFalse(erc1155.isApprovedForAll(delegator, operator));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
