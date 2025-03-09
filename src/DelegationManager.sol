// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { ICaveatEnforcer } from "./interfaces/ICaveatEnforcer.sol";
import { IDelegationManager } from "./interfaces/IDelegationManager.sol";
import { IDeleGatorCore } from "./interfaces/IDeleGatorCore.sol";
import { Delegation, Caveat, ModeCode } from "./utils/Types.sol";
import { EncoderLib } from "./libraries/EncoderLib.sol";
import { ERC1271Lib } from "./libraries/ERC1271Lib.sol";

/**
 * @title DelegationManager
 * @notice This contract is used to manage delegations.
 * Delegations can be validated and executed through this contract.
 */
contract DelegationManager is IDelegationManager, Ownable2Step, Pausable, EIP712 {
    using MessageHashUtils for bytes32;

    ////////////////////////////// State //////////////////////////////

    /// @dev The name of the contract
    string public constant NAME = "DelegationManager";

    /// @dev The full version of the contract
    string public constant VERSION = "1.3.0";

    /// @dev The version used in the domainSeparator for EIP712
    string public constant DOMAIN_VERSION = "1";

    /// @dev Special authority value. Indicates that the delegator is the authority
    bytes32 public constant ROOT_AUTHORITY = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    /// @dev Special delegate value. Allows any delegate to redeem the delegation
    address public constant ANY_DELEGATE = address(0xa11);

    /// @dev A mapping of delegation hashes that have been disabled by the delegator
    mapping(bytes32 delegationHash => bool isDisabled) public disabledDelegations;

    ////////////////////////////// Modifier //////////////////////////////

    /**
     * @notice Require the caller to be the delegator
     * This is to prevent others from accessing protected methods.
     * @dev Check that the caller is delegator.
     */
    modifier onlyDeleGator(address delegator) {
        if (delegator != msg.sender) revert InvalidDelegator();
        _;
    }

    ////////////////////////////// Constructor //////////////////////////////

    /**
     * @notice Initializes Ownable and the DelegationManager's state
     * @param _owner The initial owner of the contract
     */
    constructor(address _owner) Ownable(_owner) EIP712(NAME, DOMAIN_VERSION) {
        bytes32 DOMAIN_HASH = _domainSeparatorV4();
        emit SetDomain(DOMAIN_HASH, NAME, DOMAIN_VERSION, block.chainid, address(this));
    }

    ////////////////////////////// External Methods //////////////////////////////

    /**
     * @notice Allows the owner of the DelegationManager to pause delegation redemption functionality
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Allows the owner of the DelegationManager to unpause the delegation redemption functionality
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice This method is used to disable a delegation. Disabled delegations will fail upon redemption.
     * @dev This method MUST be called by the delegator
     * @param _delegation The delegation to be disabled
     */
    function disableDelegation(Delegation calldata _delegation) external onlyDeleGator(_delegation.delegator) {
        bytes32 delegationHash_ = getDelegationHash(_delegation);
        if (disabledDelegations[delegationHash_]) revert AlreadyDisabled();
        disabledDelegations[delegationHash_] = true;
        emit DisabledDelegation(delegationHash_, _delegation.delegator, _delegation.delegate, _delegation);
    }

    /**
     * @notice This method is used to enable a delegation
     * @dev This method MUST be called by the delegator
     * @dev This method is only needed when a delegation has previously been disabled
     * @param _delegation The delegation to be disabled
     */
    function enableDelegation(Delegation calldata _delegation) external onlyDeleGator(_delegation.delegator) {
        bytes32 delegationHash_ = getDelegationHash(_delegation);
        if (!disabledDelegations[delegationHash_]) revert AlreadyEnabled();
        disabledDelegations[delegationHash_] = false;
        emit EnabledDelegation(delegationHash_, _delegation.delegator, _delegation.delegate, _delegation);
    }

    /**
     * @notice Validates permission contexts and executes batch actions if the caller is authorized.
     * @dev For each execution in the batch:
     *      - Calls `beforeAllHook` before any actions begin.
     *      - For each delegation, calls `beforeHook` before its execution.
     *      - Executes the call data.
     *      - For each delegation, calls `afterHook` after execution.
     *      - Calls `afterAllHook` after all actions are completed.
     *      If any hook fails, the entire transaction reverts.
     *
     * @dev The lengths of `_permissionContexts`, `_modes`, and `_executionCallDatas` must be equal.
     * @param _permissionContexts An array where each element is an array of `Delegation` structs used for
     * authority validation ordered from leaf to root. An empty entry denotes self-authorization.
     * @param _modes An array specifying modes to execute the corresponding `_executionCallDatas`.
     * @param _executionCallDatas An array of encoded actions to be executed.
     */
    function redeemDelegations(
        bytes[] calldata _permissionContexts,
        ModeCode[] calldata _modes,
        bytes[] calldata _executionCallDatas
    )
        external
        whenNotPaused
    {
        uint256 batchSize_ = _permissionContexts.length;
        if (batchSize_ != _executionCallDatas.length || batchSize_ != _modes.length) revert BatchDataLengthMismatch();

        Delegation[][] memory batchDelegations_ = new Delegation[][](batchSize_);
        bytes32[][] memory batchDelegationHashes_ = new bytes32[][](batchSize_);

        // Validate and process delegations for each execution
        for (uint256 batchIndex_; batchIndex_ < batchSize_; ++batchIndex_) {
            Delegation[] memory delegations_ = abi.decode(_permissionContexts[batchIndex_], (Delegation[]));

            if (delegations_.length == 0) {
                // Special case: If the permissionContext is empty, treat it as a self authorized execution
                batchDelegations_[batchIndex_] = new Delegation[](0);
                batchDelegationHashes_[batchIndex_] = new bytes32[](0);
            } else {
                batchDelegations_[batchIndex_] = delegations_;

                // Load delegation hashes and validate signatures (leaf to root)
                bytes32[] memory delegationHashes_ = new bytes32[](delegations_.length);
                batchDelegationHashes_[batchIndex_] = delegationHashes_;

                // Validate caller
                if (delegations_[0].delegate != msg.sender && delegations_[0].delegate != ANY_DELEGATE) {
                    revert InvalidDelegate();
                }

                for (uint256 delegationsIndex_; delegationsIndex_ < delegations_.length; ++delegationsIndex_) {
                    Delegation memory delegation_ = delegations_[delegationsIndex_];
                    delegationHashes_[delegationsIndex_] = EncoderLib._getDelegationHash(delegation_);

                    if (delegation_.delegator.code.length == 0) {
                        // Validate delegation if it's an EOA
                        address result_ = ECDSA.recover(
                            MessageHashUtils.toTypedDataHash(getDomainHash(), delegationHashes_[delegationsIndex_]),
                            delegation_.signature
                        );
                        if (result_ != delegation_.delegator) revert InvalidEOASignature();
                    } else {
                        // Validate delegation if it's a contract
                        bytes32 typedDataHash_ =
                            MessageHashUtils.toTypedDataHash(getDomainHash(), delegationHashes_[delegationsIndex_]);

                        bytes32 result_ = IERC1271(delegation_.delegator).isValidSignature(typedDataHash_, delegation_.signature);
                        if (result_ != ERC1271Lib.EIP1271_MAGIC_VALUE) {
                            revert InvalidERC1271Signature();
                        }
                    }
                }

                // Validate authority and delegate (leaf to root)
                for (uint256 delegationsIndex_; delegationsIndex_ < delegations_.length; ++delegationsIndex_) {
                    // Validate if delegation is disabled
                    if (disabledDelegations[delegationHashes_[delegationsIndex_]]) {
                        revert CannotUseADisabledDelegation();
                    }

                    // Validate authority
                    if (delegationsIndex_ != delegations_.length - 1) {
                        if (delegations_[delegationsIndex_].authority != delegationHashes_[delegationsIndex_ + 1]) {
                            revert InvalidAuthority();
                        }
                        // Validate delegate
                        address nextDelegate_ = delegations_[delegationsIndex_ + 1].delegate;
                        if (nextDelegate_ != ANY_DELEGATE && delegations_[delegationsIndex_].delegator != nextDelegate_) {
                            revert InvalidDelegate();
                        }
                    } else if (delegations_[delegationsIndex_].authority != ROOT_AUTHORITY) {
                        revert InvalidAuthority();
                    }
                }
            }
        }

        // beforeAllHook (leaf to root)
        for (uint256 batchIndex_; batchIndex_ < batchSize_; ++batchIndex_) {
            if (batchDelegations_[batchIndex_].length > 0) {
                // Execute beforeAllHooks
                for (uint256 delegationsIndex_; delegationsIndex_ < batchDelegations_[batchIndex_].length; ++delegationsIndex_) {
                    Caveat[] memory caveats_ = batchDelegations_[batchIndex_][delegationsIndex_].caveats;
                    for (uint256 caveatsIndex_; caveatsIndex_ < caveats_.length; ++caveatsIndex_) {
                        ICaveatEnforcer enforcer_ = ICaveatEnforcer(caveats_[caveatsIndex_].enforcer);
                        enforcer_.beforeAllHook(
                            caveats_[caveatsIndex_].terms,
                            caveats_[caveatsIndex_].args,
                            _modes[batchIndex_],
                            _executionCallDatas[batchIndex_],
                            batchDelegationHashes_[batchIndex_][delegationsIndex_],
                            batchDelegations_[batchIndex_][delegationsIndex_].delegator,
                            msg.sender
                        );
                    }
                }
            }
        }

        for (uint256 batchIndex_; batchIndex_ < batchSize_; ++batchIndex_) {
            if (batchDelegations_[batchIndex_].length == 0) {
                // Special case: If there are no delegations, defer the call to the caller.
                IDeleGatorCore(msg.sender).executeFromExecutor(_modes[batchIndex_], _executionCallDatas[batchIndex_]);
            } else {
                // Execute beforeHooks
                for (uint256 delegationsIndex_; delegationsIndex_ < batchDelegations_[batchIndex_].length; ++delegationsIndex_) {
                    Caveat[] memory caveats_ = batchDelegations_[batchIndex_][delegationsIndex_].caveats;
                    for (uint256 caveatsIndex_; caveatsIndex_ < caveats_.length; ++caveatsIndex_) {
                        ICaveatEnforcer enforcer_ = ICaveatEnforcer(caveats_[caveatsIndex_].enforcer);
                        enforcer_.beforeHook(
                            caveats_[caveatsIndex_].terms,
                            caveats_[caveatsIndex_].args,
                            _modes[batchIndex_],
                            _executionCallDatas[batchIndex_],
                            batchDelegationHashes_[batchIndex_][delegationsIndex_],
                            batchDelegations_[batchIndex_][delegationsIndex_].delegator,
                            msg.sender
                        );
                    }
                }

                // Perform execution
                IDeleGatorCore(batchDelegations_[batchIndex_][batchDelegations_[batchIndex_].length - 1].delegator)
                    .executeFromExecutor(_modes[batchIndex_], _executionCallDatas[batchIndex_]);

                // Execute afterHooks
                for (uint256 delegationsIndex_ = batchDelegations_[batchIndex_].length; delegationsIndex_ > 0; --delegationsIndex_)
                {
                    Caveat[] memory caveats_ = batchDelegations_[batchIndex_][delegationsIndex_ - 1].caveats;
                    for (uint256 caveatsIndex_ = caveats_.length; caveatsIndex_ > 0; --caveatsIndex_) {
                        ICaveatEnforcer enforcer_ = ICaveatEnforcer(caveats_[caveatsIndex_ - 1].enforcer);
                        enforcer_.afterHook(
                            caveats_[caveatsIndex_ - 1].terms,
                            caveats_[caveatsIndex_ - 1].args,
                            _modes[batchIndex_],
                            _executionCallDatas[batchIndex_],
                            batchDelegationHashes_[batchIndex_][delegationsIndex_ - 1],
                            batchDelegations_[batchIndex_][delegationsIndex_ - 1].delegator,
                            msg.sender
                        );
                    }
                }
            }
        }

        // afterAllHook (root to leaf)
        for (uint256 batchIndex_; batchIndex_ < batchSize_; ++batchIndex_) {
            if (batchDelegations_[batchIndex_].length > 0) {
                // Execute afterAllHooks
                for (uint256 delegationsIndex_ = batchDelegations_[batchIndex_].length; delegationsIndex_ > 0; --delegationsIndex_)
                {
                    Caveat[] memory caveats_ = batchDelegations_[batchIndex_][delegationsIndex_ - 1].caveats;
                    for (uint256 caveatsIndex_ = caveats_.length; caveatsIndex_ > 0; --caveatsIndex_) {
                        ICaveatEnforcer enforcer_ = ICaveatEnforcer(caveats_[caveatsIndex_ - 1].enforcer);
                        enforcer_.afterAllHook(
                            caveats_[caveatsIndex_ - 1].terms,
                            caveats_[caveatsIndex_ - 1].args,
                            _modes[batchIndex_],
                            _executionCallDatas[batchIndex_],
                            batchDelegationHashes_[batchIndex_][delegationsIndex_ - 1],
                            batchDelegations_[batchIndex_][delegationsIndex_ - 1].delegator,
                            msg.sender
                        );
                    }
                }
            }
        }

        for (uint256 batchIndex_; batchIndex_ < batchSize_; ++batchIndex_) {
            if (batchDelegations_[batchIndex_].length > 0) {
                for (uint256 delegationsIndex_; delegationsIndex_ < batchDelegations_[batchIndex_].length; ++delegationsIndex_) {
                    emit RedeemedDelegation(
                        batchDelegations_[batchIndex_][batchDelegations_[batchIndex_].length - 1].delegator,
                        msg.sender,
                        batchDelegations_[batchIndex_][delegationsIndex_]
                    );
                }
            }
        }
    }

    /**
     * @notice This method returns the domain hash used for signing typed data
     * @return bytes32 The domain hash
     */
    function getDomainHash() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Creates a hash of a Delegation
     * @dev Used in EIP712 signatures and as a key for enabling and disabling delegations
     * @param _input A Delegation struct
     */
    function getDelegationHash(Delegation calldata _input) public pure returns (bytes32) {
        return EncoderLib._getDelegationHash(_input);
    }
}
