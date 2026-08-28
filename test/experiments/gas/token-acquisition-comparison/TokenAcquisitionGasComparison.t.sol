// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { console } from "forge-std/console.sol";

import { IDelegationManager } from "../../../../src/interfaces/IDelegationManager.sol";
import { Caveat, Delegation, Execution, ModeCode } from "../../../../src/utils/Types.sol";
import { BaseTest } from "../../../utils/BaseTest.t.sol";
import { Implementation, SignatureType } from "../../../utils/Types.t.sol";
import { MockSwapProtocol, TokenAcquisitionBenchmarkERC20 } from "./MockSwapProtocol.sol";
import { TokenAcquisitionBenchmarkAdapter } from "./TokenAcquisitionBenchmarkAdapter.sol";

/**
 * @notice Compares two ways of acquiring swap input while holding all other behavior constant.
 * @dev Run with:
 *      forge test --isolate --match-contract TokenAcquisitionGasComparisonTest -vv
 *
 *      Both paths use:
 *      - the same MultiSig delegator account and DelegationManager;
 *      - one signed delegation with zero caveats;
 *      - the same adapter, tokens, mock protocol and shared internal swap function;
 *      - the same input amount, output amount, approval, protocol pull and recipient.
 *
 *      Caveats are deliberately omitted because the benchmark isolates acquisition topology rather than
 *      comparing policy implementations.
 */
contract TokenAcquisitionGasComparisonTest is BaseTest {
    uint256 internal constant INTRINSIC_GAS = 21_000;
    uint256 internal constant TOKEN_IN_AMOUNT = 100 ether;
    uint256 internal constant TOKEN_OUT_AMOUNT = 200 ether;

    struct GasMeasurement {
        uint256 executionGas;
        uint256 calldataBytes;
        uint256 calldataGas;
        uint256 estimatedTransactionGas;
    }

    TokenAcquisitionBenchmarkERC20 internal tokenIn;
    TokenAcquisitionBenchmarkERC20 internal tokenOut;
    MockSwapProtocol internal swapProtocol;
    TokenAcquisitionBenchmarkAdapter internal adapter;

    constructor() {
        IMPLEMENTATION = Implementation.MultiSig;
        SIGNATURE_TYPE = SignatureType.MultiSig;
    }

    function setUp() public override {
        super.setUp();

        tokenIn = new TokenAcquisitionBenchmarkERC20("Token In", "TIN");
        tokenOut = new TokenAcquisitionBenchmarkERC20("Token Out", "TOUT");
        swapProtocol = new MockSwapProtocol();
        adapter = new TokenAcquisitionBenchmarkAdapter(IDelegationManager(address(delegationManager)), swapProtocol);

        tokenIn.mint(address(users.alice.deleGator), TOKEN_IN_AMOUNT);
        tokenOut.mint(address(swapProtocol), TOKEN_OUT_AMOUNT);
    }

    /// @notice Measures manager redemption of an atomic transfer + prefunded swap batch.
    function test_gas_batchTransferThenSwap() public {
        Delegation[] memory delegations_ = _buildSignedDelegation(address(users.bob.deleGator));
        bytes memory transactionCalldata_ = _encodeBatchTransferThenSwap(delegations_);

        GasMeasurement memory measurement_ =
            _measureCall(address(delegationManager), address(users.bob.deleGator), transactionCalldata_);

        _assertExpectedSettlement();
        _logMeasurement("BATCH: manager redeems transfer + swap", measurement_);
    }

    /// @notice Measures an adapter call which internally redeems a transfer before executing the same swap.
    function test_gas_internalRedemptionThenSwap() public {
        Delegation[] memory delegations_ = _buildSignedDelegation(address(adapter));
        bytes memory transactionCalldata_ = abi.encodeCall(
            adapter.swapByDelegation, (delegations_, IERC20(address(tokenIn)), IERC20(address(tokenOut)), TOKEN_IN_AMOUNT)
        );

        GasMeasurement memory measurement_ = _measureCall(address(adapter), address(users.bob.deleGator), transactionCalldata_);

        _assertExpectedSettlement();
        _logMeasurement("INTERNAL: adapter redeems transfer, then swaps", measurement_);
    }

    function _buildSignedDelegation(address _delegate) private view returns (Delegation[] memory delegations_) {
        Caveat[] memory caveats_ = new Caveat[](0);
        Delegation memory delegation_ = Delegation({
            delegate: _delegate,
            delegator: address(users.alice.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegations_ = new Delegation[](1);
        delegations_[0] = signDelegation(users.alice, delegation_);
    }

    function _encodeBatchTransferThenSwap(Delegation[] memory _delegations) private view returns (bytes memory calldata_) {
        Execution[] memory executions_ = new Execution[](2);
        executions_[0] = Execution({
            target: address(tokenIn), value: 0, callData: abi.encodeCall(IERC20.transfer, (address(adapter), TOKEN_IN_AMOUNT))
        });
        executions_[1] = Execution({
            target: address(adapter),
            value: 0,
            callData: abi.encodeCall(adapter.swapPrefunded, (IERC20(address(tokenIn)), IERC20(address(tokenOut)), TOKEN_IN_AMOUNT))
        });

        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);

        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = batchDefaultMode;

        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = ExecutionLib.encodeBatch(executions_);

        calldata_ = abi.encodeCall(IDelegationManager.redeemDelegations, (permissionContexts_, modes_, executionCallDatas_));
    }

    function _measureCall(
        address _target,
        address _caller,
        bytes memory _calldata
    )
        private
        returns (GasMeasurement memory measurement_)
    {
        measurement_.calldataBytes = _calldata.length;
        measurement_.calldataGas = _calldataGas(_calldata);

        vm.prank(_caller);
        uint256 gasBefore_ = gasleft();
        (bool success_, bytes memory returnData_) = _target.call(_calldata);
        measurement_.executionGas = gasBefore_ - gasleft();
        measurement_.estimatedTransactionGas = INTRINSIC_GAS + measurement_.calldataGas + measurement_.executionGas;

        if (!success_) {
            assembly {
                revert(add(returnData_, 0x20), mload(returnData_))
            }
        }
    }

    function _calldataGas(bytes memory _calldata) private pure returns (uint256 gas_) {
        uint256 length_ = _calldata.length;
        for (uint256 i_; i_ < length_;) {
            gas_ += _calldata[i_] == 0 ? 4 : 16;
            unchecked {
                ++i_;
            }
        }
    }

    function _assertExpectedSettlement() private {
        assertEq(tokenIn.balanceOf(address(users.alice.deleGator)), 0);
        assertEq(tokenOut.balanceOf(address(users.alice.deleGator)), TOKEN_OUT_AMOUNT);
        assertEq(tokenIn.balanceOf(address(adapter)), 0);
        assertEq(tokenOut.balanceOf(address(adapter)), 0);
        assertEq(tokenIn.balanceOf(address(swapProtocol)), TOKEN_IN_AMOUNT);
        assertEq(tokenOut.balanceOf(address(swapProtocol)), 0);
    }

    function _logMeasurement(string memory _label, GasMeasurement memory _measurement) private view {
        console.log("=====================================================================");
        console.log(_label);
        console.log(string.concat("  execution gas ........ ", vm.toString(_measurement.executionGas)));
        console.log(string.concat("  calldata bytes ....... ", vm.toString(_measurement.calldataBytes)));
        console.log(string.concat("  calldata gas ......... ", vm.toString(_measurement.calldataGas)));
        console.log(string.concat("  estimated tx gas ..... ", vm.toString(_measurement.estimatedTransactionGas)));
        console.log("=====================================================================");
    }
}
