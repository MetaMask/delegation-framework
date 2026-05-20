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
import { ApprovalRevocationEnforcer } from "../../src/enforcers/ApprovalRevocationEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

/**
 * @title ApprovalRevocationEnforcer Test
 */
contract ApprovalRevocationEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////////////// State //////////////////////////////

    ApprovalRevocationEnforcer public enforcer;
    BasicERC20 public erc20;
    BasicCF721 public erc721;
    BasicERC1155 public erc1155;

    address public delegator;
    address public spender;
    address public operator;

    uint256 public mintedTokenId;

    /// @dev Permission flag constants mirroring the contract.
    uint8 internal constant PERMISSION_ERC20_APPROVE = 0x01;
    uint8 internal constant PERMISSION_ERC721_APPROVE = 0x02;
    uint8 internal constant PERMISSION_SET_APPROVAL_FOR_ALL = 0x04;
    uint8 internal constant PERMISSION_PERMIT2_APPROVE = 0x08;
    uint8 internal constant PERMISSION_PERMIT2_LOCKDOWN = 0x10;
    uint8 internal constant PERMISSION_PERMIT2_INVALIDATE_NONCES = 0x20;
    uint8 internal constant PERMISSION_ALL = 0x3F;

    /// @dev Mirrors the contract constants.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bytes4 internal constant PERMIT2_APPROVE_SELECTOR = 0x87517c45;
    bytes4 internal constant PERMIT2_LOCKDOWN_SELECTOR = 0xcc53287f;
    bytes4 internal constant PERMIT2_INVALIDATE_NONCES_SELECTOR = 0x65d9723c;

    ////////////////////////////// Set up //////////////////////////////

    function setUp() public override {
        super.setUp();
        enforcer = new ApprovalRevocationEnforcer();
        vm.label(address(enforcer), "ApprovalRevocationEnforcer");

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

    function _terms(uint8 _flags) internal pure returns (bytes memory) {
        return abi.encodePacked(_flags);
    }

    function _approveCallData(address _spender, uint256 _amount) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC20.approve.selector, _spender, _amount);
    }

    function _setApprovalForAllCallData(address _operator, bool _approved) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC721.setApprovalForAll.selector, _operator, _approved);
    }

    function _permit2ApproveCallData(address _token, address _spender, uint160 _amount, uint48 _expiration)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(PERMIT2_APPROVE_SELECTOR, _token, _spender, _amount, _expiration);
    }

    /// @dev Mirrors Permit2's `TokenSpenderPair { address token; address spender; }`. Defined locally to avoid a
    /// direct Permit2 dependency.
    struct TokenSpenderPair {
        address token;
        address spender;
    }

    function _permit2LockdownCallData(TokenSpenderPair[] memory _pairs) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(PERMIT2_LOCKDOWN_SELECTOR, _pairs);
    }

    function _singlePair(address _token, address _spender) internal pure returns (TokenSpenderPair[] memory pairs_) {
        pairs_ = new TokenSpenderPair[](1);
        pairs_[0] = TokenSpenderPair({ token: _token, spender: _spender });
    }

    function _permit2InvalidateNoncesCallData(address _token, address _spender, uint48 _newNonce)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(PERMIT2_INVALIDATE_NONCES_SELECTOR, _token, _spender, _newNonce);
    }

    function _encodeSingle(address _target, uint256 _value, bytes memory _callData) internal pure returns (bytes memory) {
        return ExecutionLib.encodeSingle(_target, _value, _callData);
    }

    function _callBeforeHook(bytes memory _termsBytes, bytes memory _executionCallData) internal {
        vm.prank(address(delegationManager));
        enforcer.beforeHook(_termsBytes, hex"", singleDefaultMode, _executionCallData, bytes32(0), delegator, address(0));
    }

    function _expectRevertBeforeHook(bytes memory _termsBytes, bytes memory _executionCallData, bytes memory _revertReason) internal {
        vm.prank(address(delegationManager));
        vm.expectRevert(_revertReason);
        enforcer.beforeHook(_termsBytes, hex"", singleDefaultMode, _executionCallData, bytes32(0), delegator, address(0));
    }

    ////////////////////////////// Terms decoding //////////////////////////////

    function test_terms_revertOnEmptyTerms() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 0));
        _expectRevertBeforeHook(hex"", executionCallData_, "ApprovalRevocationEnforcer:invalid-terms-length");
    }

    function test_terms_revertOnWrongLength() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 0));
        _expectRevertBeforeHook(abi.encodePacked(uint16(0x0007)), executionCallData_, "ApprovalRevocationEnforcer:invalid-terms-length");
    }

    function test_terms_revertOnZeroMask() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 0));
        _expectRevertBeforeHook(_terms(0x00), executionCallData_, "ApprovalRevocationEnforcer:no-methods-allowed");
    }

    function test_terms_revertOnReservedBitSet_bit6() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 0));
        _expectRevertBeforeHook(_terms(0x40), executionCallData_, "ApprovalRevocationEnforcer:invalid-terms");
    }

    function test_terms_revertOnReservedBitSet_highBit() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 0));
        _expectRevertBeforeHook(_terms(0x80), executionCallData_, "ApprovalRevocationEnforcer:invalid-terms");
    }

    function test_terms_revertOnReservedBitSet_allBits() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 0));
        _expectRevertBeforeHook(_terms(0xFF), executionCallData_, "ApprovalRevocationEnforcer:invalid-terms");
    }

    ////////////////////////////// Per-flag gating //////////////////////////////

    function test_terms_onlyErc20_allowsErc20() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 0));
        _callBeforeHook(_terms(PERMISSION_ERC20_APPROVE), executionCallData_);
    }

    function test_terms_onlyErc20_blocksErc721Approve() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _approveCallData(address(0), mintedTokenId));
        _expectRevertBeforeHook(_terms(PERMISSION_ERC20_APPROVE), executionCallData_, "ApprovalRevocationEnforcer:erc721-approve-not-allowed");
    }

    function test_terms_onlyErc20_blocksSetApprovalForAll() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _setApprovalForAllCallData(operator, false));
        _expectRevertBeforeHook(_terms(PERMISSION_ERC20_APPROVE), executionCallData_, "ApprovalRevocationEnforcer:setApprovalForAll-not-allowed");
    }

    function test_terms_onlyErc721Approve_allowsErc721() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _approveCallData(address(0), mintedTokenId));
        _callBeforeHook(_terms(PERMISSION_ERC721_APPROVE), executionCallData_);
    }

    function test_terms_onlyErc721Approve_blocksErc20() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 0));
        _expectRevertBeforeHook(_terms(PERMISSION_ERC721_APPROVE), executionCallData_, "ApprovalRevocationEnforcer:erc20-approve-not-allowed");
    }

    function test_terms_onlyErc721Approve_blocksSetApprovalForAll() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _setApprovalForAllCallData(operator, false));
        _expectRevertBeforeHook(_terms(PERMISSION_ERC721_APPROVE), executionCallData_, "ApprovalRevocationEnforcer:setApprovalForAll-not-allowed");
    }

    function test_terms_onlySetApprovalForAll_allowsErc721() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _setApprovalForAllCallData(operator, false));
        _callBeforeHook(_terms(PERMISSION_SET_APPROVAL_FOR_ALL), executionCallData_);
    }

    function test_terms_onlySetApprovalForAll_allowsErc1155() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc1155), 0, _setApprovalForAllCallData(operator, false));
        _callBeforeHook(_terms(PERMISSION_SET_APPROVAL_FOR_ALL), executionCallData_);
    }

    function test_terms_onlySetApprovalForAll_blocksErc20Approve() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 0));
        _expectRevertBeforeHook(_terms(PERMISSION_SET_APPROVAL_FOR_ALL), executionCallData_, "ApprovalRevocationEnforcer:erc20-approve-not-allowed");
    }

    function test_terms_onlySetApprovalForAll_blocksErc721Approve() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _approveCallData(address(0), mintedTokenId));
        _expectRevertBeforeHook(_terms(PERMISSION_SET_APPROVAL_FOR_ALL), executionCallData_, "ApprovalRevocationEnforcer:erc721-approve-not-allowed");
    }

    function test_terms_pair_erc20AndErc721Approve_blocksSetApprovalForAll() public {
        uint8 flags_ = PERMISSION_ERC20_APPROVE | PERMISSION_ERC721_APPROVE;
        // Both approve variants allowed.
        _callBeforeHook(_terms(flags_), _encodeSingle(address(erc20), 0, _approveCallData(spender, 0)));
        _callBeforeHook(_terms(flags_), _encodeSingle(address(erc721), 0, _approveCallData(address(0), mintedTokenId)));
        // setApprovalForAll blocked.
        _expectRevertBeforeHook(_terms(flags_), _encodeSingle(address(erc721), 0, _setApprovalForAllCallData(operator, false)), "ApprovalRevocationEnforcer:setApprovalForAll-not-allowed");
    }

    function test_terms_pair_erc20AndSetApprovalForAll_blocksErc721Approve() public {
        uint8 flags_ = PERMISSION_ERC20_APPROVE | PERMISSION_SET_APPROVAL_FOR_ALL;
        _callBeforeHook(_terms(flags_), _encodeSingle(address(erc20), 0, _approveCallData(spender, 0)));
        _callBeforeHook(_terms(flags_), _encodeSingle(address(erc721), 0, _setApprovalForAllCallData(operator, false)));
        _expectRevertBeforeHook(_terms(flags_), _encodeSingle(address(erc721), 0, _approveCallData(address(0), mintedTokenId)), "ApprovalRevocationEnforcer:erc721-approve-not-allowed");
    }

    ////////////////////////////// Valid cases (ERC-20 approve) //////////////////////////////

    function test_erc20_revokeSucceedsForExistingAllowance() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 0));
        _callBeforeHook(_terms(PERMISSION_ALL), executionCallData_);
    }

    function test_erc20_revokeSucceedsForOneWeiAllowance() public {
        address other_ = address(users.dave.deleGator);
        vm.prank(delegator);
        erc20.approve(other_, 1);
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(other_, 0));
        _callBeforeHook(_terms(PERMISSION_ALL), executionCallData_);
    }

    ////////////////////////////// Invalid cases (ERC-20 approve) //////////////////////////////

    function test_erc20_revertOnNonZeroAmount() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 1));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:non-zero-amount");
    }

    function test_erc20_revertWhenNoApproval() public {
        address other_ = address(users.dave.deleGator);
        assertEq(erc20.allowance(delegator, other_), 0);
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(other_, 0));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:no-approval-to-revoke");
    }

    function test_erc20_revertWhenAllowanceCallFails() public {
        // Target is a contract with no `allowance(address,address)` function; the high-level call reverts with
        // empty returndata when ABI-decoding the (empty) response fails.
        bytes memory executionCallData_ = _encodeSingle(address(enforcer), 0, _approveCallData(spender, 0));
        vm.prank(address(delegationManager));
        vm.expectRevert();
        enforcer.beforeHook(_terms(PERMISSION_ALL), hex"", singleDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    ////////////////////////////// Valid cases (ERC-721 approve) //////////////////////////////

    function test_erc721_revokeSucceedsForExistingApproval() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _approveCallData(address(0), mintedTokenId));
        _callBeforeHook(_terms(PERMISSION_ALL), executionCallData_);
    }

    ////////////////////////////// Invalid cases (ERC-721 approve) //////////////////////////////

    function test_erc721_revertWhenNoApproval() public {
        // Mint a fresh token without approving it.
        vm.prank(delegator);
        erc721.mint(delegator);
        uint256 freshTokenId_ = 1;
        assertEq(erc721.getApproved(freshTokenId_), address(0));

        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _approveCallData(address(0), freshTokenId_));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:no-approval-to-revoke");
    }

    function test_erc721_revertWhenGetApprovedCallFails() public {
        // Non-existent token id reverts in OpenZeppelin's getApproved; the custom error bubbles up through the
        // high-level call.
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _approveCallData(address(0), 9999));
        vm.prank(address(delegationManager));
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", 9999));
        enforcer.beforeHook(_terms(PERMISSION_ALL), hex"", singleDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    ////////////////////////////// Valid cases (setApprovalForAll) //////////////////////////////

    function test_setApprovalForAll_erc721_revokeSucceeds() public {
        assertTrue(erc721.isApprovedForAll(delegator, operator));
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _setApprovalForAllCallData(operator, false));
        _callBeforeHook(_terms(PERMISSION_ALL), executionCallData_);
    }

    function test_setApprovalForAll_erc1155_revokeSucceeds() public {
        assertTrue(erc1155.isApprovedForAll(delegator, operator));
        bytes memory executionCallData_ = _encodeSingle(address(erc1155), 0, _setApprovalForAllCallData(operator, false));
        _callBeforeHook(_terms(PERMISSION_ALL), executionCallData_);
    }

    ////////////////////////////// Invalid cases (setApprovalForAll) //////////////////////////////

    function test_setApprovalForAll_revertWhenSettingTrue() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _setApprovalForAllCallData(operator, true));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:not-a-revocation");
    }

    function test_setApprovalForAll_revertWhenNotApproved() public {
        address other_ = address(users.dave.deleGator);
        assertFalse(erc721.isApprovedForAll(delegator, other_));
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _setApprovalForAllCallData(other_, false));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:no-approval-to-revoke");
    }

    function test_setApprovalForAll_revertWhenIsApprovedForAllCallFails() public {
        // Target is a contract with no `isApprovedForAll(address,address)` function; the high-level call reverts
        // with empty returndata when ABI-decoding the (empty) response fails.
        bytes memory executionCallData_ = _encodeSingle(address(enforcer), 0, _setApprovalForAllCallData(operator, false));
        vm.prank(address(delegationManager));
        vm.expectRevert();
        enforcer.beforeHook(_terms(PERMISSION_ALL), hex"", singleDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    ////////////////////////////// Per-flag gating (Permit2 approve) //////////////////////////////

    function test_terms_onlyPermit2Approve_allowsPermit2Approve() public {
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, _permit2ApproveCallData(address(erc20), spender, 0, 0));
        _callBeforeHook(_terms(PERMISSION_PERMIT2_APPROVE), executionCallData_);
    }

    function test_terms_onlyPermit2Approve_blocksErc20() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 0));
        _expectRevertBeforeHook(_terms(PERMISSION_PERMIT2_APPROVE), executionCallData_, "ApprovalRevocationEnforcer:erc20-approve-not-allowed");
    }

    function test_terms_onlyPermit2Approve_blocksErc721Approve() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _approveCallData(address(0), mintedTokenId));
        _expectRevertBeforeHook(_terms(PERMISSION_PERMIT2_APPROVE), executionCallData_, "ApprovalRevocationEnforcer:erc721-approve-not-allowed");
    }

    function test_terms_onlyPermit2Approve_blocksSetApprovalForAll() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _setApprovalForAllCallData(operator, false));
        _expectRevertBeforeHook(_terms(PERMISSION_PERMIT2_APPROVE), executionCallData_, "ApprovalRevocationEnforcer:setApprovalForAll-not-allowed");
    }

    function test_terms_withoutPermit2Approve_blocksPermit2Approve() public {
        uint8 flags_ = PERMISSION_ERC20_APPROVE | PERMISSION_ERC721_APPROVE | PERMISSION_SET_APPROVAL_FOR_ALL;
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, _permit2ApproveCallData(address(erc20), spender, 0, 0));
        _expectRevertBeforeHook(_terms(flags_), executionCallData_, "ApprovalRevocationEnforcer:permit2-approve-not-allowed");
    }

    ////////////////////////////// Valid cases (Permit2 approve) //////////////////////////////

    function test_permit2_revokeSucceeds() public {
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, _permit2ApproveCallData(address(erc20), spender, 0, 0));
        _callBeforeHook(_terms(PERMISSION_ALL), executionCallData_);
    }

    function test_permit2_revokeSucceedsWithArbitraryTokenAndSpender() public {
        // The enforcer does not constrain the (token, spender) pair on its own — those should be pinned via
        // composition (e.g. AllowedCalldataEnforcer). Here we just verify the hook accepts arbitrary values.
        bytes memory executionCallData_ =
            _encodeSingle(PERMIT2, 0, _permit2ApproveCallData(address(0xdead), address(0xbeef), 0, 0));
        _callBeforeHook(_terms(PERMISSION_ALL), executionCallData_);
    }

    ////////////////////////////// Invalid cases (Permit2 approve) //////////////////////////////

    function test_permit2_revertOnNonPermit2Target() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _permit2ApproveCallData(address(erc20), spender, 0, 0));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:invalid-permit2-target");
    }

    function test_permit2_revertOnNonZeroAmount() public {
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, _permit2ApproveCallData(address(erc20), spender, 1, 0));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:non-zero-amount");
    }

    function test_permit2_revertOnNonZeroExpiration() public {
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, _permit2ApproveCallData(address(erc20), spender, 0, 1));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:non-zero-expiration");
    }

    function test_permit2_revertOnMaxNonZeroAmount() public {
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, _permit2ApproveCallData(address(erc20), spender, type(uint160).max, 0));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:non-zero-amount");
    }

    function test_permit2_revertOnMaxNonZeroExpiration() public {
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, _permit2ApproveCallData(address(erc20), spender, 0, type(uint48).max));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:non-zero-expiration");
    }

    function test_permit2_revertOnTruncatedCallData() public {
        // 4 selector + 3 words = 100 bytes; matches Permit2 selector dispatch but fails the length gate.
        bytes memory truncated_ = abi.encodePacked(
            PERMIT2_APPROVE_SELECTOR, bytes32(uint256(uint160(address(erc20)))), bytes32(uint256(uint160(spender))), bytes32(uint256(0))
        );
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, truncated_);
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:permit2-invalid-execution-length");
    }

    function test_permit2_revertOnExtraTrailingByte() public {
        bytes memory longCallData_ = abi.encodePacked(_permit2ApproveCallData(address(erc20), spender, 0, 0), bytes1(0x00));
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, longCallData_);
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:permit2-invalid-execution-length");
    }

    function test_permit2_revertOnNonZeroValue() public {
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 1, _permit2ApproveCallData(address(erc20), spender, 0, 0));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:invalid-value");
    }

    ////////////////////////////// Per-flag gating (Permit2 lockdown) //////////////////////////////

    function test_terms_onlyPermit2Lockdown_allowsLockdown() public {
        bytes memory executionCallData_ =
            _encodeSingle(PERMIT2, 0, _permit2LockdownCallData(_singlePair(address(erc20), spender)));
        _callBeforeHook(_terms(PERMISSION_PERMIT2_LOCKDOWN), executionCallData_);
    }

    function test_terms_onlyPermit2Lockdown_blocksErc20() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 0));
        _expectRevertBeforeHook(_terms(PERMISSION_PERMIT2_LOCKDOWN), executionCallData_, "ApprovalRevocationEnforcer:erc20-approve-not-allowed");
    }

    function test_terms_onlyPermit2Lockdown_blocksErc721Approve() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _approveCallData(address(0), mintedTokenId));
        _expectRevertBeforeHook(_terms(PERMISSION_PERMIT2_LOCKDOWN), executionCallData_, "ApprovalRevocationEnforcer:erc721-approve-not-allowed");
    }

    function test_terms_onlyPermit2Lockdown_blocksSetApprovalForAll() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _setApprovalForAllCallData(operator, false));
        _expectRevertBeforeHook(_terms(PERMISSION_PERMIT2_LOCKDOWN), executionCallData_, "ApprovalRevocationEnforcer:setApprovalForAll-not-allowed");
    }

    function test_terms_onlyPermit2Lockdown_blocksPermit2Approve() public {
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, _permit2ApproveCallData(address(erc20), spender, 0, 0));
        _expectRevertBeforeHook(_terms(PERMISSION_PERMIT2_LOCKDOWN), executionCallData_, "ApprovalRevocationEnforcer:permit2-approve-not-allowed");
    }

    function test_terms_onlyPermit2Approve_blocksLockdown() public {
        bytes memory executionCallData_ =
            _encodeSingle(PERMIT2, 0, _permit2LockdownCallData(_singlePair(address(erc20), spender)));
        _expectRevertBeforeHook(_terms(PERMISSION_PERMIT2_APPROVE), executionCallData_, "ApprovalRevocationEnforcer:permit2-lockdown-not-allowed");
    }

    function test_terms_withoutPermit2Lockdown_blocksLockdown() public {
        uint8 flags_ = PERMISSION_ERC20_APPROVE | PERMISSION_ERC721_APPROVE | PERMISSION_SET_APPROVAL_FOR_ALL | PERMISSION_PERMIT2_APPROVE;
        bytes memory executionCallData_ =
            _encodeSingle(PERMIT2, 0, _permit2LockdownCallData(_singlePair(address(erc20), spender)));
        _expectRevertBeforeHook(_terms(flags_), executionCallData_, "ApprovalRevocationEnforcer:permit2-lockdown-not-allowed");
    }

    ////////////////////////////// Valid cases (Permit2 lockdown) //////////////////////////////

    function test_permit2Lockdown_revokeSucceedsForSinglePair() public {
        bytes memory executionCallData_ =
            _encodeSingle(PERMIT2, 0, _permit2LockdownCallData(_singlePair(address(erc20), spender)));
        _callBeforeHook(_terms(PERMISSION_ALL), executionCallData_);
    }

    function test_permit2Lockdown_revokeSucceedsForMultiplePairs() public {
        TokenSpenderPair[] memory pairs_ = new TokenSpenderPair[](3);
        pairs_[0] = TokenSpenderPair({ token: address(erc20), spender: spender });
        pairs_[1] = TokenSpenderPair({ token: address(0xdead), spender: address(0xbeef) });
        pairs_[2] = TokenSpenderPair({ token: address(erc721), spender: operator });
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, _permit2LockdownCallData(pairs_));
        _callBeforeHook(_terms(PERMISSION_ALL), executionCallData_);
    }

    function test_permit2Lockdown_revokeSucceedsForEmptyArray() public {
        // Empty lockdown is structurally a no-op — Permit2 accepts it. The enforcer accepts it too: there is
        // nothing here that could ever grant authority. Pinned as documented behavior so future refactors don't
        // silently change it.
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, _permit2LockdownCallData(new TokenSpenderPair[](0)));
        _callBeforeHook(_terms(PERMISSION_ALL), executionCallData_);
    }

    ////////////////////////////// Invalid cases (Permit2 lockdown) //////////////////////////////

    function test_permit2Lockdown_revertOnNonPermit2Target() public {
        bytes memory executionCallData_ =
            _encodeSingle(address(erc20), 0, _permit2LockdownCallData(_singlePair(address(erc20), spender)));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:invalid-permit2-target");
    }

    function test_permit2Lockdown_revertOnNonZeroValue() public {
        bytes memory executionCallData_ =
            _encodeSingle(PERMIT2, 1, _permit2LockdownCallData(_singlePair(address(erc20), spender)));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:invalid-value");
    }

    function test_permit2Lockdown_acceptsMalformedPayload_safetyRestsOnPermit2() public {
        // The lockdown branch performs no calldata-shape validation: the structural argument is that any contract
        // at the canonical Permit2 address can only zero allowance amounts under this selector. Pin the
        // enforcer-level behavior here so future refactors don't silently introduce a length check that breaks
        // composition with `ExactCalldataEnforcer` for non-standard pinning shapes.
        bytes memory malformed_ = abi.encodePacked(PERMIT2_LOCKDOWN_SELECTOR, hex"deadbeef");
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, malformed_);
        _callBeforeHook(_terms(PERMISSION_ALL), executionCallData_);
    }

    ////////////////////////////// Per-flag gating (Permit2 invalidateNonces) //////////////////////////////

    function test_terms_onlyPermit2InvalidateNonces_allowsInvalidateNonces() public {
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, _permit2InvalidateNoncesCallData(address(erc20), spender, 1));
        _callBeforeHook(_terms(PERMISSION_PERMIT2_INVALIDATE_NONCES), executionCallData_);
    }

    function test_terms_onlyPermit2InvalidateNonces_blocksErc20() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 0));
        _expectRevertBeforeHook(_terms(PERMISSION_PERMIT2_INVALIDATE_NONCES), executionCallData_, "ApprovalRevocationEnforcer:erc20-approve-not-allowed");
    }

    function test_terms_onlyPermit2InvalidateNonces_blocksErc721Approve() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _approveCallData(address(0), mintedTokenId));
        _expectRevertBeforeHook(_terms(PERMISSION_PERMIT2_INVALIDATE_NONCES), executionCallData_, "ApprovalRevocationEnforcer:erc721-approve-not-allowed");
    }

    function test_terms_onlyPermit2InvalidateNonces_blocksSetApprovalForAll() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _setApprovalForAllCallData(operator, false));
        _expectRevertBeforeHook(_terms(PERMISSION_PERMIT2_INVALIDATE_NONCES), executionCallData_, "ApprovalRevocationEnforcer:setApprovalForAll-not-allowed");
    }

    function test_terms_onlyPermit2InvalidateNonces_blocksPermit2Approve() public {
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, _permit2ApproveCallData(address(erc20), spender, 0, 0));
        _expectRevertBeforeHook(_terms(PERMISSION_PERMIT2_INVALIDATE_NONCES), executionCallData_, "ApprovalRevocationEnforcer:permit2-approve-not-allowed");
    }

    function test_terms_onlyPermit2InvalidateNonces_blocksLockdown() public {
        bytes memory executionCallData_ =
            _encodeSingle(PERMIT2, 0, _permit2LockdownCallData(_singlePair(address(erc20), spender)));
        _expectRevertBeforeHook(_terms(PERMISSION_PERMIT2_INVALIDATE_NONCES), executionCallData_, "ApprovalRevocationEnforcer:permit2-lockdown-not-allowed");
    }

    function test_terms_withoutPermit2InvalidateNonces_blocksInvalidateNonces() public {
        uint8 flags_ = PERMISSION_ERC20_APPROVE | PERMISSION_ERC721_APPROVE | PERMISSION_SET_APPROVAL_FOR_ALL
            | PERMISSION_PERMIT2_APPROVE | PERMISSION_PERMIT2_LOCKDOWN;
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, _permit2InvalidateNoncesCallData(address(erc20), spender, 1));
        _expectRevertBeforeHook(_terms(flags_), executionCallData_, "ApprovalRevocationEnforcer:permit2-invalidate-nonces-not-allowed");
    }

    ////////////////////////////// Valid cases (Permit2 invalidateNonces) //////////////////////////////

    function test_permit2InvalidateNonces_succeedsWithArbitraryNonce() public {
        // The enforcer does not validate the nonce value — Permit2 itself enforces strict monotonicity and the
        // per-call uint16-bounded delta. Pin the enforcer-level acceptance with a representative nonce.
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, _permit2InvalidateNoncesCallData(address(erc20), spender, 1));
        _callBeforeHook(_terms(PERMISSION_ALL), executionCallData_);
    }

    function test_permit2InvalidateNonces_succeedsWithMaxNonce() public {
        bytes memory executionCallData_ =
            _encodeSingle(PERMIT2, 0, _permit2InvalidateNoncesCallData(address(erc20), spender, type(uint48).max));
        _callBeforeHook(_terms(PERMISSION_ALL), executionCallData_);
    }

    function test_permit2InvalidateNonces_succeedsWithArbitraryTokenAndSpender() public {
        bytes memory executionCallData_ =
            _encodeSingle(PERMIT2, 0, _permit2InvalidateNoncesCallData(address(0xdead), address(0xbeef), 7));
        _callBeforeHook(_terms(PERMISSION_ALL), executionCallData_);
    }

    function test_permit2InvalidateNonces_acceptsMalformedPayload_safetyRestsOnPermit2() public {
        // Same rationale as the lockdown counterpart: nonce monotonicity is enforced inside Permit2, so the
        // enforcer does not validate calldata shape beyond the selector + target.
        bytes memory malformed_ = abi.encodePacked(PERMIT2_INVALIDATE_NONCES_SELECTOR, hex"deadbeef");
        bytes memory executionCallData_ = _encodeSingle(PERMIT2, 0, malformed_);
        _callBeforeHook(_terms(PERMISSION_ALL), executionCallData_);
    }

    ////////////////////////////// Invalid cases (Permit2 invalidateNonces) //////////////////////////////

    function test_permit2InvalidateNonces_revertOnNonPermit2Target() public {
        bytes memory executionCallData_ =
            _encodeSingle(address(erc20), 0, _permit2InvalidateNoncesCallData(address(erc20), spender, 1));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:invalid-permit2-target");
    }

    function test_permit2InvalidateNonces_revertOnNonZeroValue() public {
        bytes memory executionCallData_ =
            _encodeSingle(PERMIT2, 1, _permit2InvalidateNoncesCallData(address(erc20), spender, 1));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:invalid-value");
    }

    ////////////////////////////// Generic invalid cases //////////////////////////////

    function test_revertOnNonZeroValue() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 1, _approveCallData(spender, 0));
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:invalid-value");
    }

    function test_revertOnInvalidExecutionLengthShort() public {
        bytes memory shortCallData_ = abi.encodePacked(IERC20.approve.selector, bytes32(uint256(uint160(spender))));
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, shortCallData_);
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:invalid-execution-length");
    }

    function test_revertOnInvalidExecutionLengthLong() public {
        bytes memory longCallData_ = abi.encodePacked(_approveCallData(spender, 0), bytes1(0x00));
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, longCallData_);
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:invalid-execution-length");
    }

    function test_revertOnInvalidMethod() public {
        bytes memory wrongMethodCallData_ = abi.encodeWithSelector(IERC20.transfer.selector, spender, uint256(0));
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, wrongMethodCallData_);
        _expectRevertBeforeHook(_terms(PERMISSION_ALL), executionCallData_, "ApprovalRevocationEnforcer:invalid-method");
    }

    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        enforcer.beforeHook(_terms(PERMISSION_ALL), hex"", batchDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    function test_revertWithInvalidExecutionMode() public {
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        enforcer.beforeHook(_terms(PERMISSION_ALL), hex"", singleTryMode, hex"", bytes32(0), delegator, address(0));
    }

    ////////////////////////////// Integration //////////////////////////////

    function test_integration_revokesErc20Allowance() public {
        assertEq(erc20.allowance(delegator, spender), 42 ether);

        Execution memory execution_ =
            Execution({ target: address(erc20), value: 0, callData: _approveCallData(spender, 0) });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: _terms(PERMISSION_ALL) });
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
        caveats_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: _terms(PERMISSION_ALL) });
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
        caveats_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: _terms(PERMISSION_ALL) });
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

    function test_integration_onlyErc20_revokesErc20AllowanceAndBlocksOtherPrimitives() public {
        assertEq(erc20.allowance(delegator, spender), 42 ether);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: _terms(PERMISSION_ERC20_APPROVE) });
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

        // ERC-20 revocation succeeds.
        Execution memory erc20Execution_ = Execution({ target: address(erc20), value: 0, callData: _approveCallData(spender, 0) });
        invokeDelegation_UserOp(users.bob, delegations_, erc20Execution_);
        assertEq(erc20.allowance(delegator, spender), 0);

        // ERC-721 approve revocation is blocked (UserOp swallows revert; approval unchanged).
        Execution memory erc721Execution_ = Execution({ target: address(erc721), value: 0, callData: _approveCallData(address(0), mintedTokenId) });
        invokeDelegation_UserOp(users.bob, delegations_, erc721Execution_);
        assertEq(erc721.getApproved(mintedTokenId), spender);
    }

    ////////////////////////////// Redelegation //////////////////////////////

    /**
     * @notice Alice -> Bob -> Carol, with the `ApprovalRevocationEnforcer` caveat on Alice's (root) link. Carol
     * redeems. The caveat's `beforeHook` receives `_delegator = Alice`, matching the account whose approval is
     * actually cleared at execution time. Works end-to-end.
     */
    function test_integration_redelegation_caveatOnRootLink_revokesRootAllowance() public {
        assertEq(erc20.allowance(delegator, spender), 42 ether);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: _terms(PERMISSION_ALL) });
        Delegation memory aliceDelegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        aliceDelegation_ = signDelegation(users.alice, aliceDelegation_);
        bytes32 aliceDelegationHash_ = EncoderLib._getDelegationHash(aliceDelegation_);

        Delegation memory bobDelegation_ = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: aliceDelegationHash_,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        bobDelegation_ = signDelegation(users.bob, bobDelegation_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = bobDelegation_;
        delegations_[1] = aliceDelegation_;

        Execution memory execution_ =
            Execution({ target: address(erc20), value: 0, callData: _approveCallData(spender, 0) });

        invokeDelegation_UserOp(users.carol, delegations_, execution_);
        assertEq(erc20.allowance(delegator, spender), 0);
    }

    /**
     * @notice Alice -> Bob -> Carol, with the caveat on Bob's (intermediate) link. The `beforeHook` runs with
     * `_delegator = Bob`, so the pre-check queries `allowance(Bob, spender)`. Bob has no such allowance, so the
     * hook reverts even though Alice (the root, whose account actually runs `approve`) does have one.
     *
     * @dev This test pins down a subtlety of redelegation semantics: caveats are evaluated against the delegator
     * of their own link, not the root of the chain. For this enforcer it means an intermediate-link caveat
     * checks the *intermediate* delegator's approval state, which is almost never what the delegator intends.
     */
    function test_integration_redelegation_caveatOnIntermediateLink_revertsWhenIntermediateHasNoApproval() public {
        assertEq(erc20.allowance(delegator, spender), 42 ether);
        assertEq(erc20.allowance(address(users.bob.deleGator), spender), 0);

        Delegation memory aliceDelegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: delegator,
            authority: ROOT_AUTHORITY,
            caveats: new Caveat[](0),
            salt: 0,
            signature: hex""
        });
        aliceDelegation_ = signDelegation(users.alice, aliceDelegation_);
        bytes32 aliceDelegationHash_ = EncoderLib._getDelegationHash(aliceDelegation_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: _terms(PERMISSION_ALL) });
        Delegation memory bobDelegation_ = Delegation({
            delegate: address(users.carol.deleGator),
            delegator: address(users.bob.deleGator),
            authority: aliceDelegationHash_,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bobDelegation_ = signDelegation(users.bob, bobDelegation_);

        Delegation[] memory delegations_ = new Delegation[](2);
        delegations_[0] = bobDelegation_;
        delegations_[1] = aliceDelegation_;

        Execution memory execution_ =
            Execution({ target: address(erc20), value: 0, callData: _approveCallData(spender, 0) });

        // UserOp swallows the enforcer revert; the effect is that the approval is NOT cleared.
        invokeDelegation_UserOp(users.carol, delegations_, execution_);
        assertEq(erc20.allowance(delegator, spender), 42 ether);
    }

    /**
     * @notice Unit-level check on the link-local `_delegator` semantics. The hook queries the external token
     * using whatever address is passed as `_delegator`; it does not reach back into the chain to find the root.
     */
    function test_unit_beforeHook_usesPassedDelegatorNotRoot() public {
        address intermediate_ = address(users.bob.deleGator);
        assertEq(erc20.allowance(intermediate_, spender), 0);

        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(spender, 0));

        vm.prank(address(delegationManager));
        vm.expectRevert("ApprovalRevocationEnforcer:no-approval-to-revoke");
        enforcer.beforeHook(_terms(PERMISSION_ALL), hex"", singleDefaultMode, executionCallData_, bytes32(0), intermediate_, address(0));

        // And once Bob has an allowance of his own, the pre-check passes against Bob's state (regardless of who
        // would actually execute the call).
        vm.prank(intermediate_);
        erc20.approve(spender, 1);
        vm.prank(address(delegationManager));
        enforcer.beforeHook(_terms(PERMISSION_ALL), hex"", singleDefaultMode, executionCallData_, bytes32(0), intermediate_, address(0));
    }

    ////////////////////////////// Additional coverage //////////////////////////////

    /**
     * @notice `approve(non-zero, 0)` targeting an ERC-721 contract routes to the ERC-20 branch (because the
     * first parameter is non-zero). The pre-check calls `allowance(delegator, spender)` on the ERC-721, which
     * does not implement it and therefore reverts (empty returndata after ABI-decode).
     */
    function test_crossStandard_erc721TargetWithErc20Style_reverts() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc721), 0, _approveCallData(spender, 0));
        vm.prank(address(delegationManager));
        vm.expectRevert();
        enforcer.beforeHook(_terms(PERMISSION_ALL), hex"", singleDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    /**
     * @notice `approve(address(0), 0)` on an ERC-20 is routed to the ERC-721 branch by the `firstParam == 0`
     * heuristic. The branch then calls `getApproved(0)` on the target. Standard ERC-20s do not implement
     * `getApproved`, so the pre-check reverts. Pins the behavior of this edge case so future refactors don't
     * silently change routing.
     */
    function test_edgeCase_approveAddressZeroAmountZeroOnErc20_reverts() public {
        bytes memory executionCallData_ = _encodeSingle(address(erc20), 0, _approveCallData(address(0), 0));
        vm.prank(address(delegationManager));
        vm.expectRevert();
        enforcer.beforeHook(_terms(PERMISSION_ALL), hex"", singleDefaultMode, executionCallData_, bytes32(0), delegator, address(0));
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
