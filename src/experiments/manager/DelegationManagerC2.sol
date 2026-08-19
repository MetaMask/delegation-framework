// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { ICaveatEnforcer } from "../../interfaces/ICaveatEnforcer.sol";
import { IDelegationManager } from "../../interfaces/IDelegationManager.sol";
import { IDeleGatorCore } from "../../interfaces/IDeleGatorCore.sol";
import { Delegation, Caveat, ModeCode } from "../../utils/Types.sol";
import { EncoderLib } from "../../libraries/EncoderLib.sol";
import { ERC1271Lib } from "../../libraries/ERC1271Lib.sol";

/**
 * @title DelegationManagerC2
 * @notice Compatible ablation C2: cache lengths and root-delegator references; safe unchecked loop increments.
 * @dev Single change vs canonical: hoists `delegations_.length`, root delegator, and caveat counts into locals and
 *      uses `unchecked` for loop counters bounded by calldata/memory lengths.
 */
contract DelegationManagerC2 is IDelegationManager, Ownable2Step, Pausable, EIP712 {
    using MessageHashUtils for bytes32;

    string public constant NAME = "DelegationManager";
    string public constant VERSION = "1.3.0";
    string public constant DOMAIN_VERSION = "1";
    bytes32 public constant ROOT_AUTHORITY = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    address public constant ANY_DELEGATE = address(0xa11);

    mapping(bytes32 delegationHash => bool isDisabled) public disabledDelegations;

    modifier onlyDeleGator(address delegator) {
        if (delegator != msg.sender) revert InvalidDelegator();
        _;
    }

    constructor(address _owner) Ownable(_owner) EIP712(NAME, DOMAIN_VERSION) {
        bytes32 DOMAIN_HASH = _domainSeparatorV4();
        emit SetDomain(DOMAIN_HASH, NAME, DOMAIN_VERSION, block.chainid, address(this));
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function disableDelegation(Delegation calldata _delegation) external onlyDeleGator(_delegation.delegator) {
        bytes32 delegationHash_ = getDelegationHash(_delegation);
        if (disabledDelegations[delegationHash_]) revert AlreadyDisabled();
        disabledDelegations[delegationHash_] = true;
        emit DisabledDelegation(delegationHash_, _delegation.delegator, _delegation.delegate, _delegation);
    }

    function enableDelegation(Delegation calldata _delegation) external onlyDeleGator(_delegation.delegator) {
        bytes32 delegationHash_ = getDelegationHash(_delegation);
        if (!disabledDelegations[delegationHash_]) revert AlreadyEnabled();
        disabledDelegations[delegationHash_] = false;
        emit EnabledDelegation(delegationHash_, _delegation.delegator, _delegation.delegate, _delegation);
    }

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

        for (uint256 batchIndex_; batchIndex_ < batchSize_;) {
            Delegation[] memory delegations_ = abi.decode(_permissionContexts[batchIndex_], (Delegation[]));
            uint256 delegationsLength_ = delegations_.length;

            if (delegationsLength_ == 0) {
                batchDelegations_[batchIndex_] = new Delegation[](0);
                batchDelegationHashes_[batchIndex_] = new bytes32[](0);
            } else {
                batchDelegations_[batchIndex_] = delegations_;
                bytes32[] memory delegationHashes_ = new bytes32[](delegationsLength_);
                batchDelegationHashes_[batchIndex_] = delegationHashes_;

                if (delegations_[0].delegate != msg.sender && delegations_[0].delegate != ANY_DELEGATE) {
                    revert InvalidDelegate();
                }

                for (uint256 delegationsIndex_; delegationsIndex_ < delegationsLength_;) {
                    Delegation memory delegation_ = delegations_[delegationsIndex_];
                    delegationHashes_[delegationsIndex_] = EncoderLib._getDelegationHash(delegation_);

                    if (delegation_.delegator.code.length == 0) {
                        address result_ = ECDSA.recover(
                            MessageHashUtils.toTypedDataHash(getDomainHash(), delegationHashes_[delegationsIndex_]),
                            delegation_.signature
                        );
                        if (result_ != delegation_.delegator) revert InvalidEOASignature();
                    } else {
                        bytes32 typedDataHash_ =
                            MessageHashUtils.toTypedDataHash(getDomainHash(), delegationHashes_[delegationsIndex_]);
                        bytes32 result_ = IERC1271(delegation_.delegator).isValidSignature(typedDataHash_, delegation_.signature);
                        if (result_ != ERC1271Lib.EIP1271_MAGIC_VALUE) revert InvalidERC1271Signature();
                    }
                    unchecked {
                        ++delegationsIndex_;
                    }
                }

                for (uint256 delegationsIndex_; delegationsIndex_ < delegationsLength_;) {
                    if (disabledDelegations[delegationHashes_[delegationsIndex_]]) revert CannotUseADisabledDelegation();

                    if (delegationsIndex_ != delegationsLength_ - 1) {
                        if (delegations_[delegationsIndex_].authority != delegationHashes_[delegationsIndex_ + 1]) {
                            revert InvalidAuthority();
                        }
                        address nextDelegate_ = delegations_[delegationsIndex_ + 1].delegate;
                        if (nextDelegate_ != ANY_DELEGATE && delegations_[delegationsIndex_].delegator != nextDelegate_) {
                            revert InvalidDelegate();
                        }
                    } else if (delegations_[delegationsIndex_].authority != ROOT_AUTHORITY) {
                        revert InvalidAuthority();
                    }
                    unchecked {
                        ++delegationsIndex_;
                    }
                }
            }
            unchecked {
                ++batchIndex_;
            }
        }

        for (uint256 batchIndex_; batchIndex_ < batchSize_;) {
            Delegation[] memory batchDelegationsSlice_ = batchDelegations_[batchIndex_];
            uint256 delegationsLength_ = batchDelegationsSlice_.length;
            if (delegationsLength_ > 0) {
                bytes32[] memory delegationHashesSlice_ = batchDelegationHashes_[batchIndex_];
                ModeCode mode_ = _modes[batchIndex_];
                bytes calldata executionCallData_ = _executionCallDatas[batchIndex_];

                for (uint256 delegationsIndex_; delegationsIndex_ < delegationsLength_;) {
                    Delegation memory delegation_ = batchDelegationsSlice_[delegationsIndex_];
                    Caveat[] memory caveats_ = delegation_.caveats;
                    uint256 caveatsLength_ = caveats_.length;
                    bytes32 delegationHash_ = delegationHashesSlice_[delegationsIndex_];
                    address delegator_ = delegation_.delegator;

                    for (uint256 caveatsIndex_; caveatsIndex_ < caveatsLength_;) {
                        ICaveatEnforcer(caveats_[caveatsIndex_].enforcer)
                            .beforeAllHook(
                                caveats_[caveatsIndex_].terms,
                                caveats_[caveatsIndex_].args,
                                mode_,
                                executionCallData_,
                                delegationHash_,
                                delegator_,
                                msg.sender
                            );
                        unchecked {
                            ++caveatsIndex_;
                        }
                    }
                    unchecked {
                        ++delegationsIndex_;
                    }
                }
            }
            unchecked {
                ++batchIndex_;
            }
        }

        for (uint256 batchIndex_; batchIndex_ < batchSize_;) {
            Delegation[] memory batchDelegationsSlice_ = batchDelegations_[batchIndex_];
            uint256 delegationsLength_ = batchDelegationsSlice_.length;

            if (delegationsLength_ == 0) {
                IDeleGatorCore(msg.sender).executeFromExecutor(_modes[batchIndex_], _executionCallDatas[batchIndex_]);
            } else {
                bytes32[] memory delegationHashesSlice_ = batchDelegationHashes_[batchIndex_];
                ModeCode mode_ = _modes[batchIndex_];
                bytes calldata executionCallData_ = _executionCallDatas[batchIndex_];
                address rootDelegator_ = batchDelegationsSlice_[delegationsLength_ - 1].delegator;

                for (uint256 delegationsIndex_; delegationsIndex_ < delegationsLength_;) {
                    Delegation memory delegation_ = batchDelegationsSlice_[delegationsIndex_];
                    Caveat[] memory caveats_ = delegation_.caveats;
                    uint256 caveatsLength_ = caveats_.length;
                    bytes32 delegationHash_ = delegationHashesSlice_[delegationsIndex_];
                    address delegator_ = delegation_.delegator;

                    for (uint256 caveatsIndex_; caveatsIndex_ < caveatsLength_;) {
                        ICaveatEnforcer(caveats_[caveatsIndex_].enforcer)
                            .beforeHook(
                                caveats_[caveatsIndex_].terms,
                                caveats_[caveatsIndex_].args,
                                mode_,
                                executionCallData_,
                                delegationHash_,
                                delegator_,
                                msg.sender
                            );
                        unchecked {
                            ++caveatsIndex_;
                        }
                    }
                    unchecked {
                        ++delegationsIndex_;
                    }
                }

                IDeleGatorCore(rootDelegator_).executeFromExecutor(mode_, executionCallData_);

                for (uint256 delegationsIndex_ = delegationsLength_; delegationsIndex_ > 0;) {
                    Delegation memory delegation_ = batchDelegationsSlice_[delegationsIndex_ - 1];
                    Caveat[] memory caveats_ = delegation_.caveats;
                    uint256 caveatsLength_ = caveats_.length;
                    bytes32 delegationHash_ = delegationHashesSlice_[delegationsIndex_ - 1];
                    address delegator_ = delegation_.delegator;

                    for (uint256 caveatsIndex_ = caveatsLength_; caveatsIndex_ > 0;) {
                        ICaveatEnforcer(caveats_[caveatsIndex_ - 1].enforcer)
                            .afterHook(
                                caveats_[caveatsIndex_ - 1].terms,
                                caveats_[caveatsIndex_ - 1].args,
                                mode_,
                                executionCallData_,
                                delegationHash_,
                                delegator_,
                                msg.sender
                            );
                        unchecked {
                            --caveatsIndex_;
                        }
                    }
                    unchecked {
                        --delegationsIndex_;
                    }
                }
            }
            unchecked {
                ++batchIndex_;
            }
        }

        for (uint256 batchIndex_; batchIndex_ < batchSize_;) {
            Delegation[] memory batchDelegationsSlice_ = batchDelegations_[batchIndex_];
            uint256 delegationsLength_ = batchDelegationsSlice_.length;
            if (delegationsLength_ > 0) {
                bytes32[] memory delegationHashesSlice_ = batchDelegationHashes_[batchIndex_];
                ModeCode mode_ = _modes[batchIndex_];
                bytes calldata executionCallData_ = _executionCallDatas[batchIndex_];

                for (uint256 delegationsIndex_ = delegationsLength_; delegationsIndex_ > 0;) {
                    Delegation memory delegation_ = batchDelegationsSlice_[delegationsIndex_ - 1];
                    Caveat[] memory caveats_ = delegation_.caveats;
                    uint256 caveatsLength_ = caveats_.length;
                    bytes32 delegationHash_ = delegationHashesSlice_[delegationsIndex_ - 1];
                    address delegator_ = delegation_.delegator;

                    for (uint256 caveatsIndex_ = caveatsLength_; caveatsIndex_ > 0;) {
                        ICaveatEnforcer(caveats_[caveatsIndex_ - 1].enforcer)
                            .afterAllHook(
                                caveats_[caveatsIndex_ - 1].terms,
                                caveats_[caveatsIndex_ - 1].args,
                                mode_,
                                executionCallData_,
                                delegationHash_,
                                delegator_,
                                msg.sender
                            );
                        unchecked {
                            --caveatsIndex_;
                        }
                    }
                    unchecked {
                        --delegationsIndex_;
                    }
                }
            }
            unchecked {
                ++batchIndex_;
            }
        }

        for (uint256 batchIndex_; batchIndex_ < batchSize_;) {
            Delegation[] memory batchDelegationsSlice_ = batchDelegations_[batchIndex_];
            uint256 delegationsLength_ = batchDelegationsSlice_.length;
            if (delegationsLength_ > 0) {
                address rootDelegator_ = batchDelegationsSlice_[delegationsLength_ - 1].delegator;
                for (uint256 delegationsIndex_; delegationsIndex_ < delegationsLength_;) {
                    emit RedeemedDelegation(rootDelegator_, msg.sender, batchDelegationsSlice_[delegationsIndex_]);
                    unchecked {
                        ++delegationsIndex_;
                    }
                }
            }
            unchecked {
                ++batchIndex_;
            }
        }
    }

    function getDomainHash() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function getDelegationHash(Delegation calldata _input) public pure returns (bytes32) {
        return EncoderLib._getDelegationHash(_input);
    }
}
