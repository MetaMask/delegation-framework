// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { IDelegationManager } from "../../../src/interfaces/IDelegationManager.sol";
import { ModeCode } from "../../../src/utils/Types.sol";
import { Delegation } from "../../../src/utils/Types.sol";

/**
 * @notice Reusable gas measurement utilities for delegation-manager experiment matrices.
 * @dev Uses `forge test --isolate` plus `vm.snapshotState` / `vm.revertToState` for cold-state repeats.
 *      Execution gas is measured with a `gasleft()` bracket around a low-level manager call.
 */
abstract contract GasExperimentHarness is Test {
    uint256 internal constant INTRINSIC_GAS = 21_000;

    struct GasMeasurement {
        uint256 executionGas;
        uint256 calldataBytes;
        uint256 calldataGas;
        uint256 estimatedTxGas;
    }

    struct RedeemCall {
        bytes calldataEncoded;
        ModeCode mode;
        bytes executionCalldata;
    }

    /// @dev EIP-2028 calldata cost: 4 gas per zero byte, 16 per non-zero byte.
    function calldataGas(bytes memory _data) internal pure returns (uint256 gas_) {
        uint256 len_ = _data.length;
        for (uint256 i_; i_ < len_; ++i_) {
            gas_ += _data[i_] == 0x00 ? 4 : 16;
        }
    }

    function encodeRedeemCall(
        Delegation[] memory _delegations,
        ModeCode _mode,
        bytes memory _executionCalldata
    )
        internal
        pure
        returns (bytes memory cd_)
    {
        bytes[] memory permissionContexts_ = new bytes[](1);
        permissionContexts_[0] = abi.encode(_delegations);
        ModeCode[] memory modes_ = new ModeCode[](1);
        modes_[0] = _mode;
        bytes[] memory executionCallDatas_ = new bytes[](1);
        executionCallDatas_[0] = _executionCalldata;
        cd_ = abi.encodeWithSelector(
            IDelegationManager.redeemDelegations.selector, permissionContexts_, modes_, executionCallDatas_
        );
    }

    function measureManagerCall(address _manager, address _redeemer, bytes memory _redeemCalldata)
        internal
        returns (GasMeasurement memory m_)
    {
        m_.calldataBytes = _redeemCalldata.length;
        m_.calldataGas = calldataGas(_redeemCalldata);

        vm.prank(_redeemer);
        uint256 gasBefore_ = gasleft();
        (bool ok_, bytes memory ret_) = _manager.call(_redeemCalldata);
        m_.executionGas = gasBefore_ - gasleft();
        m_.estimatedTxGas = INTRINSIC_GAS + m_.calldataGas + m_.executionGas;

        if (!ok_) {
            assembly {
                revert(add(ret_, 0x20), mload(ret_))
            }
        }
    }

    function logGasReport(string memory _label, GasMeasurement memory _m) internal view {
        console.log("=====================================================================");
        console.log(_label);
        console.log(string.concat("  execution gas .... ", vm.toString(_m.executionGas)));
        console.log(string.concat("  calldata bytes ... ", vm.toString(_m.calldataBytes)));
        console.log(string.concat("  calldata gas ..... ", vm.toString(_m.calldataGas)));
        console.log(string.concat("  estimated tx gas . ", vm.toString(_m.estimatedTxGas)));
        console.log("=====================================================================");
    }

    /// @dev Measures from a cold snapshot; returns snapshot id for caller-driven `revertToState`.
    function saveGasSnapshot() internal returns (uint256 snap_) {
        snap_ = vm.snapshot();
    }

    function restoreGasSnapshot(uint256 _snap) internal {
        vm.revertTo(_snap);
    }
}
