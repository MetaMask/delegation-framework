// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Vm } from "forge-std/Vm.sol";

/**
 * @title GasReporter
 * @dev A utility contract to measure gas usage
 */
contract GasReporter {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    /**
     * @notice Measures gas used for a function call
     * @param _target The target contract to call
     * @param _callData The calldata for the function
     * @param _expectRevert Whether to expect a revert
     * @return gasUsed The amount of gas used
     */

    function measureGas(
        address caller,
        address _target,
        bytes memory _callData,
        bool _expectRevert
    )
        public
        returns (bytes memory)
    {
        uint256 gasStart = gasleft();
        bool success;
        bytes memory returnData;
        if (caller != address(0)) {
            vm.prank(caller);
            (success, returnData) = _target.call(_callData);
        } else {
            (success, returnData) = _target.call(_callData);
        }

        uint256 gasUsed = gasStart - gasleft();

        if (_expectRevert) {
            require(!success, "Expected revert but call succeeded");
        } else {
            require(success, "Call failed");
        }

        return abi.encodePacked(gasUsed);
    }

    /**
     * @notice Measures gas used for a function call, default to expecting success
     * @param _target The target contract to call
     * @param _callData The calldata for the function
     * @return gasUsed The amount of gas used
     */
    function measureGas(address _caller, address _target, bytes memory _callData) public returns (bytes memory) {
        return measureGas(_caller, _target, _callData, false);
    }
}
