// SPDX-License-Identifier: MIT AND Apache-2.0
/// forge-config: evm_version = 'cancun'
pragma solidity 0.8.23;

/**
 * @title TransientStorageLib
 * @notice Thin EIP-1153 wrapper for hook/balance coordination experiments (X2).
 * @dev Requires `evm_version = "cancun"` at compile/runtime.
 */
library TransientStorageLib {
    function tload(bytes32 _slot) internal view returns (uint256 value_) {
        assembly {
            value_ := tload(_slot)
        }
    }

    function tstore(bytes32 _slot, uint256 _value) internal {
        assembly {
            tstore(_slot, _value)
        }
    }

    function tloadBool(bytes32 _slot) internal view returns (bool value_) {
        value_ = tload(_slot) != 0;
    }

    function tstoreBool(bytes32 _slot, bool _value) internal {
        tstore(_slot, _value ? 1 : 0);
    }
}
