// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { BasicCF721 } from "../utils/BasicCF721.t.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC721TransferEnforcer } from "../../src/enforcers/ERC721TransferEnforcer.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract ERC721TransferEnforcerTest is CaveatEnforcerBaseTest {
    ////////////////////// State //////////////////////

    ERC721TransferEnforcer public erc721TransferEnforcer;
    uint256 public constant TOKEN_ID = 0;
    BasicCF721 public token;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        erc721TransferEnforcer = new ERC721TransferEnforcer();
        vm.label(address(erc721TransferEnforcer), "ERC721 Transfer Enforcer");

        token = new BasicCF721(address(users.alice.deleGator), "ERC721Token", "ERC721Token", "");
        vm.label(address(token), "ERC721 Test Token");

        vm.prank(address(users.alice.deleGator));
        token.selfMint();
    }

    ////////////////////// Valid cases //////////////////////

    /// @notice Tests that a valid transfer using transferFrom selector passes.
    function test_validTransfer() public {
        Execution memory execution_ = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC721.transferFrom.selector, address(this), address(0xBEEF), TOKEN_ID)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        erc721TransferEnforcer.beforeHook(
            abi.encodePacked(address(token), TOKEN_ID),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests that a valid transfer using safeTransferFrom (3 args) selector passes.
    function test_validSafeTransferFrom_3args() public {
        Execution memory execution_ = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", address(this), address(0xBEEF), TOKEN_ID)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        erc721TransferEnforcer.beforeHook(
            abi.encodePacked(address(token), TOKEN_ID),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests that a valid transfer using safeTransferFrom (4 args) selector passes.
    function test_validSafeTransferFrom_4args() public {
        Execution memory execution_ = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSignature(
                "safeTransferFrom(address,address,uint256,bytes)", address(this), address(0xBEEF), TOKEN_ID, hex""
            )
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        erc721TransferEnforcer.beforeHook(
            abi.encodePacked(address(token), TOKEN_ID),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    /// @notice Tests that getTermsInfo reverts if the terms length is invalid.
    function test_invalidTermsLength() public {
        vm.expectRevert("ERC721TransferEnforcer:invalid-terms-length");
        erc721TransferEnforcer.getTermsInfo(abi.encodePacked(address(token)));
    }

    /// @notice Tests that a transfer reverts if the target contract is unauthorized.
    function test_unauthorizedTransfer_wrongContract() public {
        Execution memory execution_ = Execution({
            target: address(0xDEAD),
            value: 0,
            callData: abi.encodeWithSelector(IERC721.transferFrom.selector, address(this), address(0xBEEF), TOKEN_ID)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC721TransferEnforcer:unauthorized-contract-target");
        erc721TransferEnforcer.beforeHook(
            abi.encodePacked(address(token), TOKEN_ID),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests that a transfer reverts when using an unauthorized function selector.
    function test_unauthorizedSelector_wrongMethod() public {
        bytes4 dummySelector_ = bytes4(keccak256("foo(address,address,uint256)"));
        bytes memory callData_ = abi.encodeWithSelector(dummySelector_, address(this), address(0xBEEF), TOKEN_ID);
        Execution memory execution_ = Execution({ target: address(token), value: 0, callData: callData_ });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC721TransferEnforcer:unauthorized-selector");
        erc721TransferEnforcer.beforeHook(
            abi.encodePacked(address(token), TOKEN_ID),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests that a transfer reverts if the tokenId does not match the permitted token.
    function test_unauthorizedTransfer_wrongTokenId() public {
        Execution memory execution_ = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC721.transferFrom.selector, address(this), address(0xBEEF), TOKEN_ID + 1)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC721TransferEnforcer:unauthorized-token-id");
        erc721TransferEnforcer.beforeHook(
            abi.encodePacked(address(token), TOKEN_ID),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    /// @notice Tests that a transfer reverts if the calldata length is insufficient.
    function test_unauthorizedTransfer_wrongSelectorLength() public {
        Execution memory execution_ = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(IERC721.approve.selector, address(0xBEEF), TOKEN_ID)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC721TransferEnforcer:invalid-calldata-length");
        erc721TransferEnforcer.beforeHook(
            abi.encodePacked(address(token), TOKEN_ID),
            hex"",
            singleDefaultMode,
            executionCallData_,
            keccak256(""),
            address(0),
            address(0)
        );
    }

    // should fail with invalid call type mode (batch instead of single mode)
    function test_revertWithInvalidCallTypeMode() public {
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(new Execution[](2));

        vm.expectRevert("CaveatEnforcer:invalid-call-type");

        erc721TransferEnforcer.beforeHook(hex"", hex"", batchDefaultMode, executionCallData_, bytes32(0), address(0), address(0));
    }

    // should fail with invalid call type mode (try instead of default)
    function test_revertWithInvalidExecutionMode() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("CaveatEnforcer:invalid-execution-type");
        erc721TransferEnforcer.beforeHook(hex"", hex"", singleTryMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// Integration //////////////////////

    /// @notice Integration test for valid transfer using transferFrom selector.
    function test_validTransferIntegration() public {
        // Pre-transfer: ensure the token is initially owned by Alice and record Bob's balance.
        uint256 initialRecipientBalance_ = token.balanceOf(address(users.bob.deleGator));
        address initialOwner_ = token.ownerOf(TOKEN_ID);
        assertEq(initialOwner_, address(users.alice.deleGator), "Initial owner should be Alice");

        Execution memory execution_ = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSelector(
                IERC721.transferFrom.selector, address(users.alice.deleGator), address(users.bob.deleGator), TOKEN_ID
            )
        });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(erc721TransferEnforcer), terms: abi.encodePacked(address(token), TOKEN_ID) });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegation_ = signDelegation(users.alice, delegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;

        // Execute Bob's UserOp
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        // Post-transfer: verify that Bob's balance increased and that the token owner is now Bob.
        uint256 finalRecipientBalance_ = token.balanceOf(address(users.bob.deleGator));
        address finalOwner_ = token.ownerOf(TOKEN_ID);
        assertEq(finalRecipientBalance_, initialRecipientBalance_ + 1, "Recipient balance should increase by 1");
        assertEq(finalOwner_, address(users.bob.deleGator), "Token owner should be Bob");
    }

    /// @notice Integration test for valid transfer using safeTransferFrom (3 args) selector.
    function test_validSafeTransferFrom3argsIntegration() public {
        uint256 initialRecipientBalance_ = token.balanceOf(address(users.bob.deleGator));
        address initialOwner_ = token.ownerOf(TOKEN_ID);
        assertEq(initialOwner_, address(users.alice.deleGator), "Initial owner should be Alice");

        Execution memory execution_ = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSignature(
                "safeTransferFrom(address,address,uint256)", address(users.alice.deleGator), address(users.bob.deleGator), TOKEN_ID
            )
        });
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(erc721TransferEnforcer), terms: abi.encodePacked(address(token), TOKEN_ID) });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        // Execute Bob's UserOp with safeTransferFrom (3 args)
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        uint256 finalRecipientBalance_ = token.balanceOf(address(users.bob.deleGator));
        address finalOwner_ = token.ownerOf(TOKEN_ID);
        assertEq(finalRecipientBalance_, initialRecipientBalance_ + 1, "Recipient balance should increase by 1");
        assertEq(finalOwner_, address(users.bob.deleGator), "Token owner should be Bob");
    }

    /// @notice Integration test for valid transfer using safeTransferFrom (4 args) selector.
    function test_validSafeTransferFrom4argsIntegration() public {
        uint256 initialRecipientBalance_ = token.balanceOf(address(users.bob.deleGator));
        address initialOwner_ = token.ownerOf(TOKEN_ID);
        assertEq(initialOwner_, address(users.alice.deleGator), "Initial owner should be Alice");

        Execution memory execution_ = Execution({
            target: address(token),
            value: 0,
            callData: abi.encodeWithSignature(
                "safeTransferFrom(address,address,uint256,bytes)",
                address(users.alice.deleGator),
                address(users.bob.deleGator),
                TOKEN_ID,
                hex""
            )
        });
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(erc721TransferEnforcer), terms: abi.encodePacked(address(token), TOKEN_ID) });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        // Execute Bob's UserOp with safeTransferFrom (4 args)
        invokeDelegation_UserOp(users.bob, delegations_, execution_);

        uint256 finalRecipientBalance_ = token.balanceOf(address(users.bob.deleGator));
        address finalOwner_ = token.ownerOf(TOKEN_ID);
        assertEq(finalRecipientBalance_, initialRecipientBalance_ + 1, "Recipient balance should increase by 1");
        assertEq(finalOwner_, address(users.bob.deleGator), "Token owner should be Bob");
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(erc721TransferEnforcer));
    }
}
