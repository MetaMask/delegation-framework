// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";

/**
 * @title LogicalOrWrapperEnforcer
 * @notice Enforces a logical OR operation across multiple caveat groups, where each group requires all caveats to pass (AND)
 * @dev This contract implements a wrapper around multiple caveat groups, allowing them to be combined with OR logic between groups
 *      and AND logic within groups. This enables patterns like (Caveat1 AND Caveat2) OR (Caveat3 AND Caveat4)
 * @dev This enforcer operates only in single call type and default execution mode
 */
contract LogicalOrWrapperEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    struct CaveatData {
        address enforcer;
        bytes terms;
    }

    struct CaveatGroup {
        CaveatData[] caveats;
    }

    struct HookParams {
        bytes args;
        ModeCode mode;
        bytes executionCallData;
        bytes32 delegationHash;
        address delegator;
        address redeemer;
    }

    ////////////////////////////// Public Methods //////////////////////

    /**
     * @notice Hook called before a delegation execution to check if any of the caveat groups pass
     * @dev A group passes if ALL caveats within it pass. The overall check passes if ANY group passes.
     *      If _args contains a group index, only that specific group will be checked.
     * @param _terms The encoded array of CaveatGroups
     * @param _args Optional arguments passed by the redeemer at execution time. If non-empty, should be abi.encode(uint256)
     *              representing the group index to check
     * @param _mode The execution mode. (Must be Single callType, Default execType)
     * @param _executionCallData The execution data encoded via ExecutionLib.encodeSingle
     * @param _delegationHash The hash identifying the delegation
     * @param _delegator The address of the delegator
     * @param _redeemer The address redeeming the delegation
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata _args,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _delegator,
        address _redeemer
    )
        public
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        CaveatGroup[] memory caveatGroups_ = abi.decode(_terms, (CaveatGroup[]));
        HookParams memory params_ = HookParams({
            args: _args,
            mode: _mode,
            executionCallData: _executionCallData,
            delegationHash: _delegationHash,
            delegator: _delegator,
            redeemer: _redeemer
        });

        // If args contains a group index, only check that specific group
        if (_args.length > 0) {
            uint256 groupIndex_ = abi.decode(_args, (uint256));
            require(groupIndex_ < caveatGroups_.length, "LogicalOrWrapperEnforcer:invalid-group-index");
            require(_tryCaveatGroup(caveatGroups_[groupIndex_], params_), "LogicalOrWrapperEnforcer:all-caveats-reverted");
            return;
        }

        // Otherwise check all groups until one passes
        require(_tryAllCaveatGroups(caveatGroups_, params_), "LogicalOrWrapperEnforcer:all-groups-reverted");
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @dev Decodes the terms into an array of CaveatGroups.
     * @param _terms The encoded terms containing the CaveatGroup array.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (CaveatGroup[] memory caveatGroups_) {
        caveatGroups_ = abi.decode(_terms, (CaveatGroup[]));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Internal function to try each group in the logical OR chain
     * @dev Returns true if any group passes (all caveats within the group pass)
     * @param _caveatGroups The array of CaveatGroups to check
     * @param _params The hook parameters struct
     * @return success True if any group passes, false if all fail
     */
    function _tryAllCaveatGroups(CaveatGroup[] memory _caveatGroups, HookParams memory _params) internal returns (bool success) {
        for (uint256 i = 0; i < _caveatGroups.length; i++) {
            if (_tryCaveatGroup(_caveatGroups[i], _params)) {
                return true; // Short circuit on first successful group
            }
        }
        return false;
    }

    /**
     * @notice Internal function to try all caveats within a group
     * @dev Returns true only if ALL caveats in the group pass
     * @param _group The CaveatGroup containing an array of caveats that must all pass
     * @param _params The hook parameters struct
     * @return success True if all caveats in the group pass, false otherwise
     */
    function _tryCaveatGroup(CaveatGroup memory _group, HookParams memory _params) internal returns (bool success) {
        // Empty group is considered a failure
        if (_group.caveats.length == 0) return false;

        for (uint256 i = 0; i < _group.caveats.length; i++) {
            CaveatData memory caveat = _group.caveats[i];

            try CaveatEnforcer(caveat.enforcer).beforeHook(
                caveat.terms,
                _params.args,
                _params.mode,
                _params.executionCallData,
                _params.delegationHash,
                _params.delegator,
                _params.redeemer
            ) {
                continue; // This caveat passed, continue checking others in group
            } catch {
                return false; // If any caveat fails, the whole group fails
            }
        }
        return true; // All caveats in group passed
    }
}
