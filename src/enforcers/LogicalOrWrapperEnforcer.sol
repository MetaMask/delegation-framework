// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { IDelegationManager } from "../interfaces/IDelegationManager.sol";
import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode, Caveat } from "../utils/Types.sol";

/**
 * @title LogicalOrWrapperEnforcer
 * @dev This enforcer operates in the default execution mode only.
 *
 * @dev Overview:
 *  - The hook functions expect two encoded parameters:
 *    1. **Terms**: Encoded as an array of `CaveatGroup`. Each `CaveatGroup` struct holds an array of `Caveat` structs.
 *       Each `Caveat` includes the enforcer address and its specific terms.
 *    2. **Args**: Encoded as a `SelectedGroup` struct. `SelectedGroup` specifies:
 *          - `groupIndex`: Which element (i.e. which `CaveatGroup`) in the terms array should be evaluated.
 *          - `caveatArgs`: An array of bytes corresponding to each caveat's arguments within the selected group.
 *
 * @dev Usage Flow:
 *  1. Define your caveats in logical groups by populating an array of `CaveatGroup`.
 *  2. For each group, include the appropriate enforcer details and terms.
 *  3. When calling a hook (e.g. `beforeAllHook`), pass the terms as a `CaveatGroup[]` and the group selection
 *     & arguments as a `SelectedGroup`.
 *  4. The contract uses the group index to retrieve the proper `CaveatGroup` and iterates over each `Caveat`,
 *     calling the corresponding enforcer with its specific term and argument.
 *
 * @dev Behavior:
 *  - The enforcer iterates over all caveats in the specified `CaveatGroup`.
 *  - For a group to pass, all caveats within that group must succeed.
 *  - Every caveat in the group is evaluated.
 *  - The group index provided via `SelectedGroup.groupIndex` must be valid (i.e. less than or equal to the length of the terms
 * array).
 *  - The length of `SelectedGroup.caveatArgs` must exactly match the number of caveats in the corresponding `CaveatGroup`.
 *    Empty bytes can be used for caveats that do not require arguments.
 *
 * @dev Security Notice: This enforcer allows the redeemer to choose which caveat group to use at
 * execution time, via the groupIndex parameter. If multiple caveat groups are defined with varying
 * levels of restrictions, the redeemer can select the least restrictive group, bypassing stricter
 * requirements in other groups.
 *
 * To maintain proper security:
 *  - Ensure each caveat group represents a complete and equally secure permission set.
 *  - Never assume the redeemer will select the most restrictive group.
 *  - Design caveat groups with the understanding that the redeemer will choose the path of least
 *    resistance.
 *
 * Use this enforcer at your own risk and ensure it aligns with your intended security model.
 */
contract LogicalOrWrapperEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    /**
     * @notice Struct representing a group of caveats that will be evaluated together
     * @dev Each group contains an array of Caveat structs that will be evaluated in sequence
     * @dev The terms parameter passed to this enforcer's hook functions is an array of these groups
     */
    struct CaveatGroup {
        Caveat[] caveats;
    }

    /**
     * @notice Struct used to specify which group to evaluate and provide arguments for its caveats
     * @dev Contains the index of the group to evaluate from the terms array and the corresponding arguments for each caveat
     * @dev The args are the arguments for each of the caveats in the group, use empty bytes for no arguments, the length of the
     * caveatArgs array must match the number of caveats in the group
     */
    struct SelectedGroup {
        uint256 groupIndex;
        bytes[] caveatArgs;
    }

    /**
     * @notice Struct used internally to pass common parameters to hook functions
     * @dev Consolidates parameters that are common across all hook calls
     */
    struct Params {
        ModeCode mode;
        bytes executionCallData;
        bytes32 delegationHash;
        address delegator;
        address redeemer;
    }

    ////////////////////////////// State //////////////////////////////

    /// @dev The Delegation Manager contract to redeem the delegation
    IDelegationManager public immutable delegationManager;

    ////////////////////////////// Constructor //////////////////////////////

    constructor(IDelegationManager _delegationManager) {
        delegationManager = _delegationManager;
    }

    ////////////////////////////// Modifiers //////////////////////////////

    modifier onlyDelegationManager() {
        require(msg.sender == address(delegationManager), "LogicalOrWrapperEnforcer:only-delegation-manager");
        _;
    }

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Hook called before all delegations are executed
     * @dev Validates that the execution mode is default and calls the appropriate hook on all caveats
     * @param _terms Encoded array of CaveatGroup, where each group contains multiple caveats to evaluate
     * @param _args Encoded SelectedGroup specifying which group to evaluate and arguments for its caveats
     * @param _mode The execution mode
     * @param _executionCallData The execution data
     * @param _delegationHash The hash identifying the delegation
     * @param _delegator The address of the delegator
     * @param _redeemer The address redeeming the delegation
     */
    function beforeAllHook(
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
        onlyDelegationManager
    {
        _executeHook(
            _terms,
            _args,
            Params(_mode, _executionCallData, _delegationHash, _delegator, _redeemer),
            CaveatEnforcer.beforeAllHook.selector
        );
    }

    /**
     * @notice Hook called before each delegation is executed
     * @dev Validates that the execution mode is default and calls the appropriate hook on all caveats
     * @param _terms Encoded array of CaveatGroup, where each group contains multiple caveats to evaluate
     * @param _args Encoded SelectedGroup specifying which group to evaluate and arguments for its caveats
     * @param _mode The execution mode
     * @param _executionCallData The execution data
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
        onlyDefaultExecutionMode(_mode)
        onlyDelegationManager
    {
        _executeHook(
            _terms,
            _args,
            Params(_mode, _executionCallData, _delegationHash, _delegator, _redeemer),
            CaveatEnforcer.beforeHook.selector
        );
    }

    /**
     * @notice Hook called after each delegation is executed
     * @dev Validates that the execution mode is default and calls the appropriate hook on all caveats
     * @param _terms Encoded array of CaveatGroup, where each group contains multiple caveats to evaluate
     * @param _args Encoded SelectedGroup specifying which group to evaluate and arguments for its caveats
     * @param _mode The execution mode
     * @param _executionCallData The execution data
     * @param _delegationHash The hash identifying the delegation
     * @param _delegator The address of the delegator
     * @param _redeemer The address redeeming the delegation
     */
    function afterHook(
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
        onlyDefaultExecutionMode(_mode)
        onlyDelegationManager
    {
        _executeHook(
            _terms,
            _args,
            Params(_mode, _executionCallData, _delegationHash, _delegator, _redeemer),
            CaveatEnforcer.afterHook.selector
        );
    }

    /**
     * @notice Hook called after all delegations are executed
     * @dev Validates that the execution mode is default and calls the appropriate hook on all caveats
     * @param _terms Encoded array of CaveatGroup, where each group contains multiple caveats to evaluate
     * @param _args Encoded SelectedGroup specifying which group to evaluate and arguments for its caveats
     * @param _mode The execution mode
     * @param _executionCallData The execution data
     * @param _delegationHash The hash identifying the delegation
     * @param _delegator The address of the delegator
     * @param _redeemer The address redeeming the delegation
     */
    function afterAllHook(
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
        onlyDefaultExecutionMode(_mode)
        onlyDelegationManager
    {
        _executeHook(
            _terms,
            _args,
            Params(_mode, _executionCallData, _delegationHash, _delegator, _redeemer),
            CaveatEnforcer.afterAllHook.selector
        );
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    /**
     * @notice Internal function that executes the specified hook on all caveats in a group
     * @dev This function handles the core logic of decoding terms and args, validating indices,
     *      and executing the specified hook on each caveat in the selected group
     * @param _terms Encoded array of CaveatGroup, where each group contains multiple caveats to evaluate
     * @param _args Encoded SelectedGroup specifying which group to evaluate and arguments for its caveats
     * @param _params The consolidated parameters for the hook execution
     * @param _hookSelector The function selector for the hook to execute
     */
    function _executeHook(bytes calldata _terms, bytes calldata _args, Params memory _params, bytes4 _hookSelector) internal {
        CaveatGroup[] memory caveatGroups_ = abi.decode(_terms, (CaveatGroup[]));
        SelectedGroup memory selectedGroup_ = abi.decode(_args, (SelectedGroup));

        require(selectedGroup_.groupIndex < caveatGroups_.length, "LogicalOrWrapperEnforcer:invalid-group-index");

        CaveatGroup memory caveatGroup_ = caveatGroups_[selectedGroup_.groupIndex];
        uint256 caveatsLength_ = caveatGroup_.caveats.length;
        require(selectedGroup_.caveatArgs.length == caveatsLength_, "LogicalOrWrapperEnforcer:invalid-caveat-args-length");

        for (uint256 i = 0; i < caveatsLength_; ++i) {
            Address.functionCall(
                caveatGroup_.caveats[i].enforcer,
                abi.encodeWithSelector(
                    _hookSelector,
                    caveatGroup_.caveats[i].terms,
                    selectedGroup_.caveatArgs[i],
                    _params.mode,
                    _params.executionCallData,
                    _params.delegationHash,
                    _params.delegator,
                    _params.redeemer
                )
            );
        }
    }
}
