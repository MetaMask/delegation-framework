// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "../../src/enforcers/CaveatEnforcer.sol";
import { Execution, ModeCode } from "../../src/utils/Types.sol";

/**
 * @title Password Enforcer
 * @dev This contract is used only to test the caveat args that are passed in by the redeemer.
 */
contract PasswordEnforcer is CaveatEnforcer {
    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Testing user inputed args.
     * @param _terms A bytes32 that will be hashed.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode,
        bytes calldata,
        bytes32,
        address,
        address
    )
        public
        pure
        override
    {
        bytes32 hash_ = keccak256(_args);
        if (hash_ != keccak256(_terms)) revert("PasswordEnforcerError");
    }
}
