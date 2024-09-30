// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ERC721TransferEnforcer } from "../../src/enforcers/ERC721TransferEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract ERC721TransferEnforcerTest is CaveatEnforcerBaseTest {
    using ModeLib for ModeCode;

    ////////////////////// State //////////////////////

    ERC721TransferEnforcer public erc721TransferEnforcer;
    ModeCode public mode = ModeLib.encodeSimpleSingle();
    IERC721 public mockNFT;
    address public constant NFT_CONTRACT = address(0x1234567890123456789012345678901234567890);
    uint256 public constant TOKEN_ID = 42;

    ////////////////////// Set up //////////////////////

    function setUp() public override {
        super.setUp();
        erc721TransferEnforcer = new ERC721TransferEnforcer();
        vm.label(address(erc721TransferEnforcer), "ERC721 Transfer Enforcer");
        mockNFT = IERC721(NFT_CONTRACT);
    }

    ////////////////////// Valid cases //////////////////////
    function test_validTransfer() public {
        Execution memory execution_ = Execution({
            target: NFT_CONTRACT,
            value: 0,
            callData: abi.encodeWithSelector(IERC721.transferFrom.selector, address(this), address(0xBEEF), TOKEN_ID)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        erc721TransferEnforcer.beforeHook(
            abi.encodePacked(NFT_CONTRACT, TOKEN_ID), hex"", mode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    ////////////////////// Invalid cases //////////////////////

    function test_invalidTermsLength() public {
        vm.expectRevert("ERC721TransferEnforcer:invalid-terms-length");
        erc721TransferEnforcer.getTermsInfo(abi.encodePacked(NFT_CONTRACT));
    }

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
            abi.encodePacked(NFT_CONTRACT, TOKEN_ID), hex"", mode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    function test_unauthorizedSelector_wrongMethod() public {
        Execution memory execution_ = Execution({
            target: NFT_CONTRACT,
            value: 0,
            callData: abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", address(this), address(0xBEEF), TOKEN_ID)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC721TransferEnforcer:unauthorized-selector");
        erc721TransferEnforcer.beforeHook(
            abi.encodePacked(NFT_CONTRACT, TOKEN_ID), hex"", mode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    function test_unauthorizedTransfer_wrongTokenId() public {
        Execution memory execution_ = Execution({
            target: NFT_CONTRACT,
            value: 0,
            callData: abi.encodeWithSelector(IERC721.transferFrom.selector, address(this), address(0xBEEF), TOKEN_ID + 1)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC721TransferEnforcer:unauthorized-token-id");
        erc721TransferEnforcer.beforeHook(
            abi.encodePacked(NFT_CONTRACT, TOKEN_ID), hex"", mode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    function test_unauthorizedTransfer_wrongSelector() public {
        Execution memory execution_ = Execution({
            target: NFT_CONTRACT,
            value: 0,
            callData: abi.encodeWithSelector(IERC721.approve.selector, address(0xBEEF), TOKEN_ID)
        });
        bytes memory executionCallData_ = ExecutionLib.encodeSingle(execution_.target, execution_.value, execution_.callData);

        vm.prank(address(delegationManager));
        vm.expectRevert("ERC721TransferEnforcer:invalid-calldata-length");
        erc721TransferEnforcer.beforeHook(
            abi.encodePacked(NFT_CONTRACT, TOKEN_ID), hex"", mode, executionCallData_, keccak256(""), address(0), address(0)
        );
    }

    ////////////////////// Integration //////////////////////

    function test_validTransferIntegration() public {
        Execution memory execution_ = Execution({
            target: NFT_CONTRACT,
            value: 0,
            callData: abi.encodeWithSelector(
                IERC721.transferFrom.selector, address(users.alice.deleGator), address(users.bob.deleGator), TOKEN_ID
            )
        });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] =
            Caveat({ args: hex"", enforcer: address(erc721TransferEnforcer), terms: abi.encodePacked(NFT_CONTRACT, TOKEN_ID) });
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
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(erc721TransferEnforcer));
    }
}
