// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Delegation, Execution, ModeCode } from "../utils/Types.sol";

/**
 * @title IDelegationManager
 * @notice Interface that exposes methods of a custom DelegationManager implementation.
 */
interface IDelegationManager {
    ////////////////////////////// Events //////////////////////////////

    /// @dev Emitted when a delegation is redeemed
    event RedeemedDelegation(address indexed rootDelegator, address indexed redeemer, Delegation delegation);

    /// @dev Emitted when a delegation is enabled after being disabled
    event EnabledDelegation(
        bytes32 indexed delegationHash, address indexed delegator, address indexed delegate, Delegation delegation
    );

    /// @dev Emitted when a delegation is disabled
    event DisabledDelegation(
        bytes32 indexed delegationHash, address indexed delegator, address indexed delegate, Delegation delegation
    );

    /// @dev Emitted when the domain hash is set
    event SetDomain(
        bytes32 indexed domainHash, string name, string domainVersion, uint256 chainId, address indexed contractAddress
    );

    ////////////////////////////// Errors //////////////////////////////

    /// @dev Error thrown when a user attempts to use a disabled delegation
    error CannotUseADisabledDelegation();

    /// @dev Error thrown when the authority in a chain of delegations doesn't match the expected authority
    error InvalidAuthority();

    /// @dev Error thrown when the redeemer doesn't match the approved delegate
    error InvalidDelegate();

    /// @dev Error thrown when the delegator of a delegation doesn't match the caller
    error InvalidDelegator();

    /// @dev Error thrown when the EOA signature provided is invalid
    error InvalidEOASignature();

    /// @dev Error thrown when the ERC1271 signature provided is invalid
    error InvalidERC1271Signature();

    /// @dev Error thrown when the signature is empty
    error EmptySignature();

    /// @dev Error thrown when the delegation provided is already disabled
    error AlreadyDisabled();

    /// @dev Error thrown when the delegation provided is already enabled
    error AlreadyEnabled();

    /// @dev Error thrown when the batch size doesn't match the execution array size
    error BatchDataLengthMismatch();

    ////////////////////////////// MM Implementation Methods //////////////////////////////

    function pause() external;

    function unpause() external;

    function enableDelegation(Delegation calldata _delegation) external;

    function disableDelegation(Delegation calldata _delegation) external;

    function disabledDelegations(bytes32 _delegationHash) external view returns (bool);

    function getDelegationHash(Delegation calldata _delegation) external pure returns (bytes32);

    function redeemDelegations(
        bytes[] calldata _permissionContexts,
        ModeCode[] calldata _modes,
        bytes[] calldata _executionCallDatas
    )
        external;

    function getDomainHash() external view returns (bytes32);
}
