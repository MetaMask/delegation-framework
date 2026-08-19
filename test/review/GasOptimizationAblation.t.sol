// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { BaseTest } from "../utils/BaseTest.t.sol";
import { Implementation, SignatureType } from "../utils/Types.t.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { ExactExecutionBatchEnforcer } from "../../src/enforcers/ExactExecutionBatchEnforcer.sol";
import { ExactExecutionBatchLimitedCallsEnforcer } from "../../src/enforcers/ExactExecutionBatchLimitedCallsEnforcer.sol";
import { LimitedCallsEnforcer } from "../../src/enforcers/LimitedCallsEnforcer.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../src/utils/Types.sol";

/**
 * @notice Isolates combined-enforcer savings without changing manager, account, mode, or execution data.
 * @dev Run with `forge test --isolate --match-contract GasOptimizationAblation -vv`.
 */
contract GasOptimizationAblation is BaseTest {
    uint256 internal constant INTRINSIC_GAS = 21_000;
    uint256 internal constant CALL_LIMIT = 1;
    uint256 internal constant USER_AMOUNT = 100e18;
    uint256 internal constant FEE_AMOUNT = 1e18;

    ExactExecutionBatchEnforcer internal exactBatchEnforcer;
    LimitedCallsEnforcer internal limitedCallsEnforcer;
    ExactExecutionBatchLimitedCallsEnforcer internal combinedEnforcer;
    BasicERC20 internal token;

    address internal relayer;
    address internal recipient;
    address internal feeRecipient;

    constructor() {
        IMPLEMENTATION = Implementation.EIP7702Stateless;
        SIGNATURE_TYPE = SignatureType.EOA;
    }

    function setUp() public override {
        super.setUp();

        exactBatchEnforcer = new ExactExecutionBatchEnforcer();
        limitedCallsEnforcer = new LimitedCallsEnforcer();
        combinedEnforcer = new ExactExecutionBatchLimitedCallsEnforcer();
        token = new BasicERC20(address(this), "Mock USDC", "USDC", 0);
        token.mint(address(users.alice.deleGator), 1_000_000e18);

        relayer = makeAddr("relayer");
        recipient = makeAddr("recipient");
        feeRecipient = makeAddr("feeRecipient");
    }

    function test_bench_oneExecution_separateEnforcers() public {
        Execution[] memory executions_ = _buildExecutions(false);
        _bench(
            "canonical | 1-exec batch | separate exact + limited",
            _separateCaveats(executions_),
            ExecutionLib.encodeBatch(executions_)
        );
        assertEq(token.balanceOf(recipient), USER_AMOUNT);
    }

    function test_bench_oneExecution_combinedEnforcer() public {
        Execution[] memory executions_ = _buildExecutions(false);
        _bench(
            "canonical | 1-exec batch | combined exact + limited",
            _combinedCaveat(executions_),
            ExecutionLib.encodeBatch(executions_)
        );
        assertEq(token.balanceOf(recipient), USER_AMOUNT);
    }

    function test_bench_twoExecutions_separateEnforcers() public {
        Execution[] memory executions_ = _buildExecutions(true);
        _bench(
            "canonical | 2-exec batch | separate exact + limited",
            _separateCaveats(executions_),
            ExecutionLib.encodeBatch(executions_)
        );
        assertEq(token.balanceOf(recipient), USER_AMOUNT);
        assertEq(token.balanceOf(feeRecipient), FEE_AMOUNT);
    }

    function test_bench_twoExecutions_combinedEnforcer() public {
        Execution[] memory executions_ = _buildExecutions(true);
        _bench(
            "canonical | 2-exec batch | combined exact + limited",
            _combinedCaveat(executions_),
            ExecutionLib.encodeBatch(executions_)
        );
        assertEq(token.balanceOf(recipient), USER_AMOUNT);
        assertEq(token.balanceOf(feeRecipient), FEE_AMOUNT);
    }

    function _buildExecutions(bool _includeFee) internal view returns (Execution[] memory executions_) {
        executions_ = new Execution[](_includeFee ? 2 : 1);
        executions_[0] = Execution({
            target: address(token), value: 0, callData: abi.encodeWithSelector(IERC20.transfer.selector, recipient, USER_AMOUNT)
        });
        if (_includeFee) {
            executions_[1] = Execution({
                target: address(token),
                value: 0,
                callData: abi.encodeWithSelector(IERC20.transfer.selector, feeRecipient, FEE_AMOUNT)
            });
        }
    }

    function _separateCaveats(Execution[] memory _executions) internal view returns (Caveat[] memory caveats_) {
        caveats_ = new Caveat[](2);
        caveats_[0] = Caveat({ enforcer: address(exactBatchEnforcer), terms: ExecutionLib.encodeBatch(_executions), args: hex"" });
        caveats_[1] = Caveat({ enforcer: address(limitedCallsEnforcer), terms: abi.encode(CALL_LIMIT), args: hex"" });
    }

    function _combinedCaveat(Execution[] memory _executions) internal view returns (Caveat[] memory caveats_) {
        caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({
            enforcer: address(combinedEnforcer),
            terms: abi.encodePacked(CALL_LIMIT, ExecutionLib.encodeBatch(_executions)),
            args: hex""
        });
    }

    function _bench(string memory _label, Caveat[] memory _caveats, bytes memory _executionCallData) internal {
        Delegation memory delegation_ = Delegation({
            delegate: relayer,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: _caveats,
            salt: 0,
            signature: hex""
        });
        delegation_ = signDelegation(users.alice, delegation_);

        Delegation[] memory delegations_ = new Delegation[](1);
        delegations_[0] = delegation_;
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(delegations_);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = ModeLib.encodeSimpleBatch();
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = _executionCallData;

        bytes memory redeemCalldata_ = abi.encodeWithSelector(
            IDelegationManager.redeemDelegations.selector, permissionContexts_, modes_, executionCallDatas_
        );

        vm.prank(relayer);
        uint256 gasBefore_ = gasleft();
        (bool success_, bytes memory returnData_) = address(delegationManager).call(redeemCalldata_);
        uint256 executionGas_ = gasBefore_ - gasleft();
        if (!success_) {
            assembly {
                revert(add(returnData_, 0x20), mload(returnData_))
            }
        }

        uint256 calldataGas_ = _calldataGas(redeemCalldata_);
        console.log("=====================================================================");
        console.log(_label);
        console.log(string.concat("  execution gas .... ", vm.toString(executionGas_)));
        console.log(string.concat("  calldata gas ..... ", vm.toString(calldataGas_)));
        console.log(string.concat("  estimated tx gas . ", vm.toString(INTRINSIC_GAS + executionGas_ + calldataGas_)));
        console.log("=====================================================================");
    }

    function _calldataGas(bytes memory _data) internal pure returns (uint256 gas_) {
        for (uint256 i_; i_ < _data.length; ++i_) {
            gas_ += _data[i_] == 0 ? 4 : 16;
        }
    }
}
