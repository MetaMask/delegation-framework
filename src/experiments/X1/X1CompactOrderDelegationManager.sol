// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Delegation } from "../../utils/Types.sol";
import { ExperimentDelegationManagerBase } from "../lib/ExperimentDelegationManagerBase.sol";
import { CompactOrderCodec } from "./CompactOrderCodec.sol";

/**
 * @title X1CompactOrderDelegationManager
 * @notice Experiment manager that accepts compact fixed-schema permission contexts (X1).
 * @dev Standard `abi.encode(Delegation[])` contexts remain supported for differential testing.
 */
contract X1CompactOrderDelegationManager is ExperimentDelegationManagerBase {
    string public constant NAME = "X1CompactOrderDelegationManager";
    string public constant VERSION = "1.0.0-exp";

    constructor(address _owner) ExperimentDelegationManagerBase(NAME, VERSION, _owner) { }

    function _decodePermissionContext(bytes calldata _context) internal pure override returns (Delegation[] memory) {
        if (CompactOrderCodec.isCompact(_context)) {
            return CompactOrderCodec.decodeToArray(_context);
        }
        return abi.decode(_context, (Delegation[]));
    }
}
