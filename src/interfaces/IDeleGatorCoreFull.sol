// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IDeleGatorCore } from "./IDeleGatorCore.sol";
import { IDelegationManager } from "./IDelegationManager.sol";
import { Action, Delegation, PackedUserOperation } from "../utils/Types.sol";

/**
 * @title IDeleGatorCoreFull
 * @notice Interface for a DeleGator that exposes the minimal functionality required.
 */
interface IDeleGatorCoreFull is IDeleGatorCore, IERC165 {
    ////////////////////////////// Events //////////////////////////////
    event SetDelegationManager(IDelegationManager indexed newDelegationManager);

    event SetEntryPoint(IEntryPoint indexed entryPoint);

    event ClearedStorage();

    ////////////////////////////// Errors //////////////////////////////

    error NotSelf();
    error NotEntryPoint();
    error NotEntryPointOrSelf();
    error NotDelegationManager();

    ////////////////////////////// MM Implementation Methods //////////////////////////////

    function redeemDelegation(bytes calldata _data, Action calldata _action) external;

    function execute(Action calldata _action) external;

    function executeBatch(Action[] calldata _actions) external;

    function validateUserOp(
        PackedUserOperation calldata _userOp,
        bytes32 _userOpHash,
        uint256 _missingAccountFunds
    )
        external
        returns (uint256 validationData_);

    function isValidSignature(bytes32 _hash, bytes memory _signature) external view returns (bytes4 magicValue_);

    function addDeposit() external payable;

    function withdrawDeposit(address payable _withdrawAddress, uint256 _withdrawAmount) external;

    function disableDelegation(Delegation calldata _delegation) external;

    function enableDelegation(Delegation calldata _delegation) external;

    function upgradeToAndCall(address _newImplementation, bytes memory _data) external payable;

    function upgradeToAndCallAndRetainStorage(address _newImplementation, bytes memory _data) external payable;

    function isDelegationDisabled(bytes32 _delegationHash) external view returns (bool);

    function entryPoint() external view returns (IEntryPoint);

    function delegationManager() external view returns (IDelegationManager);

    function getNonce() external view returns (uint256);

    function getNonce(uint192 _key) external view returns (uint256);

    function getDeposit() external view returns (uint256);

    function getImplementation() external view returns (address);

    function getInitializedVersion() external view returns (uint64);

    ////////////////////////////// TokenCallbackHandler Methods //////////////////////////////

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4);

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4);

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    )
        external
        pure
        returns (bytes4);

    ////////////////////////////// UUPSUpgradeable Methods //////////////////////////////

    function proxiableUUID() external view returns (bytes32);
}
