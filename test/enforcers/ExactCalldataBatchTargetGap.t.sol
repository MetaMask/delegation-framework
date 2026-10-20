// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { Execution, Caveat, Delegation, ModeCode } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { ExactCalldataBatchEnforcer } from "../../src/enforcers/ExactCalldataBatchEnforcer.sol";
import { BasicERC20, IERC20 } from "../utils/BasicERC20.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

/// @dev Regression: terms encode Execution[] so target/value must be pinned, not only calldata.
contract ExactCalldataBatchTargetGapTest is CaveatEnforcerBaseTest {
    ExactCalldataBatchEnforcer public enforcer;
    BasicERC20 public tokenA;
    BasicERC20 public tokenB;

    function setUp() public override {
        super.setUp();
        enforcer = new ExactCalldataBatchEnforcer();
        tokenA = new BasicERC20(address(users.alice.deleGator), "A", "A", 100 ether);
        tokenB = new BasicERC20(address(users.alice.deleGator), "B", "B", 100 ether);
    }

    function test_rejectsTargetSwapWithSameCalldata() public {
        bytes memory call0 = abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(1 ether));
        bytes memory call1 = abi.encodeWithSelector(IERC20.transfer.selector, address(users.carol.deleGator), uint256(2 ether));

        Execution[] memory termsExec = new Execution[](2);
        termsExec[0] = Execution({ target: address(tokenA), value: 0, callData: call0 });
        termsExec[1] = Execution({ target: address(tokenA), value: 0, callData: call1 });

        Execution[] memory evil = new Execution[](2);
        evil[0] = Execution({ target: address(tokenB), value: 0, callData: call0 });
        evil[1] = Execution({ target: address(tokenB), value: 0, callData: call1 });

        bytes memory terms_ = ExecutionLib.encodeBatch(termsExec);
        bytes memory executionCallData_ = ExecutionLib.encodeBatch(evil);

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactCalldataBatchEnforcer:invalid-target");
        enforcer.beforeHook(terms_, hex"", batchDefaultMode, executionCallData_, keccak256("d"), address(0), address(0));
    }

    function test_rejectsNonZeroValueWithSameCalldataAndTarget() public {
        bytes memory call0 = abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(1 ether));

        Execution[] memory termsExec = new Execution[](1);
        termsExec[0] = Execution({ target: address(tokenA), value: 0, callData: call0 });

        Execution[] memory evil = new Execution[](1);
        evil[0] = Execution({ target: address(tokenA), value: 1, callData: call0 });

        vm.prank(address(delegationManager));
        vm.expectRevert("ExactCalldataBatchEnforcer:invalid-value");
        enforcer.beforeHook(
            ExecutionLib.encodeBatch(termsExec),
            hex"",
            batchDefaultMode,
            ExecutionLib.encodeBatch(evil),
            keccak256("d"),
            address(0),
            address(0)
        );
    }

    function test_integration_blocksTargetSwapDrain() public {
        bytes memory call0 = abi.encodeWithSelector(IERC20.transfer.selector, address(users.bob.deleGator), uint256(5 ether));
        bytes memory call1 = abi.encodeWithSelector(IERC20.transfer.selector, address(users.carol.deleGator), uint256(5 ether));

        Execution[] memory termsExec = new Execution[](2);
        termsExec[0] = Execution({ target: address(tokenA), value: 0, callData: call0 });
        termsExec[1] = Execution({ target: address(tokenA), value: 0, callData: call1 });

        Execution[] memory evil = new Execution[](2);
        evil[0] = Execution({ target: address(tokenB), value: 0, callData: call0 });
        evil[1] = Execution({ target: address(tokenB), value: 0, callData: call1 });

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(enforcer), terms: ExecutionLib.encodeBatch(termsExec) });
        Delegation memory delegation_ = Delegation({
            delegate: address(users.bob.deleGator),
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        bytes[] memory permissionContexts_ = new bytes[](1);
        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        permissionContexts_[0] = abi.encode(delegations_);

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeBatch(evil);

        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = batchDefaultMode;

        uint256 bobBBefore = tokenB.balanceOf(address(users.bob.deleGator));
        vm.prank(address(users.bob.deleGator));
        vm.expectRevert("ExactCalldataBatchEnforcer:invalid-target");
        delegationManager.redeemDelegations(permissionContexts_, modes_, executionCallDatas_);
        assertEq(tokenB.balanceOf(address(users.bob.deleGator)), bobBBefore);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(enforcer));
    }
}
