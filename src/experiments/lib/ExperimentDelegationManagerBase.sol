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
 * @title ExperimentDelegationManagerBase
 * @notice Shared redemption core for gas experiment managers (X* variants).
 * @dev Mirrors canonical `DelegationManager` behavior; subclasses override decode and/or signature validation hooks.
 */
abstract contract ExperimentDelegationManagerBase is IDelegationManager, Ownable2Step, Pausable, EIP712 {
    using MessageHashUtils for bytes32;

    string public constant DOMAIN_VERSION = "1";
    bytes32 public constant ROOT_AUTHORITY = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    address public constant ANY_DELEGATE = address(0xa11);

    mapping(bytes32 delegationHash => bool isDisabled) public disabledDelegations;

    modifier onlyDeleGator(address delegator) {
        if (delegator != msg.sender) revert InvalidDelegator();
        _;
    }

    constructor(string memory _name, string memory _version, address _owner) Ownable(_owner) EIP712(_name, DOMAIN_VERSION) {
        emit SetDomain(_domainSeparatorV4(), _name, DOMAIN_VERSION, block.chainid, address(this));
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
        _onDelegationDisabled(_delegation.delegator, delegationHash_);
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

        for (uint256 batchIndex_; batchIndex_ < batchSize_; ++batchIndex_) {
            Delegation[] memory delegations_ = _decodePermissionContext(_permissionContexts[batchIndex_]);

            if (delegations_.length == 0) {
                batchDelegations_[batchIndex_] = new Delegation[](0);
                batchDelegationHashes_[batchIndex_] = new bytes32[](0);
            } else {
                batchDelegations_[batchIndex_] = delegations_;

                bytes32[] memory delegationHashes_ = new bytes32[](delegations_.length);
                batchDelegationHashes_[batchIndex_] = delegationHashes_;

                if (delegations_[0].delegate != msg.sender && delegations_[0].delegate != ANY_DELEGATE) {
                    revert InvalidDelegate();
                }

                for (uint256 delegationsIndex_; delegationsIndex_ < delegations_.length; ++delegationsIndex_) {
                    Delegation memory delegation_ = delegations_[delegationsIndex_];
                    delegationHashes_[delegationsIndex_] = EncoderLib._getDelegationHash(delegation_);
                    _validateDelegationSignature(delegation_, delegationHashes_[delegationsIndex_]);
                }

                for (uint256 delegationsIndex_; delegationsIndex_ < delegations_.length; ++delegationsIndex_) {
                    if (disabledDelegations[delegationHashes_[delegationsIndex_]]) {
                        revert CannotUseADisabledDelegation();
                    }

                    if (delegationsIndex_ != delegations_.length - 1) {
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
                }
            }
        }

        _runHookPhases(batchDelegations_, batchDelegationHashes_, _modes, _executionCallDatas, batchSize_);

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

    function getDomainHash() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function getDelegationHash(Delegation calldata _input) public pure returns (bytes32) {
        return EncoderLib._getDelegationHash(_input);
    }

    function _decodePermissionContext(bytes calldata _context) internal view virtual returns (Delegation[] memory) {
        return abi.decode(_context, (Delegation[]));
    }

    function _validateDelegationSignature(Delegation memory _delegation, bytes32 _delegationHash) internal virtual {
        if (_delegation.delegator.code.length == 0) {
            address result_ = ECDSA.recover(
                MessageHashUtils.toTypedDataHash(getDomainHash(), _delegationHash), _delegation.signature
            );
            if (result_ != _delegation.delegator) revert InvalidEOASignature();
        } else {
            bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(getDomainHash(), _delegationHash);
            bytes32 result_ = IERC1271(_delegation.delegator).isValidSignature(typedDataHash_, _delegation.signature);
            if (result_ != ERC1271Lib.EIP1271_MAGIC_VALUE) revert InvalidERC1271Signature();
        }
    }

    function _onDelegationDisabled(address, bytes32) internal virtual { }

    function _runHookPhases(
        Delegation[][] memory batchDelegations_,
        bytes32[][] memory batchDelegationHashes_,
        ModeCode[] calldata _modes,
        bytes[] calldata _executionCallDatas,
        uint256 batchSize_
    )
        private
    {
        for (uint256 batchIndex_; batchIndex_ < batchSize_; ++batchIndex_) {
            _beforeAllHooks(
                batchDelegations_[batchIndex_], batchDelegationHashes_[batchIndex_], _modes[batchIndex_], _executionCallDatas[batchIndex_]
            );
        }

        for (uint256 batchIndex_; batchIndex_ < batchSize_; ++batchIndex_) {
            _executeBatch(batchDelegations_[batchIndex_], batchDelegationHashes_[batchIndex_], _modes[batchIndex_], _executionCallDatas[batchIndex_]);
        }

        for (uint256 batchIndex_; batchIndex_ < batchSize_; ++batchIndex_) {
            _afterAllHooks(
                batchDelegations_[batchIndex_], batchDelegationHashes_[batchIndex_], _modes[batchIndex_], _executionCallDatas[batchIndex_]
            );
        }
    }

    function _beforeAllHooks(
        Delegation[] memory _delegations,
        bytes32[] memory _delegationHashes,
        ModeCode _mode,
        bytes calldata _executionCalldata
    )
        private
    {
        uint256 delegationCount_ = _delegations.length;
        for (uint256 i_; i_ < delegationCount_; ++i_) {
            Caveat[] memory caveats_ = _delegations[i_].caveats;
            address delegator_ = _delegations[i_].delegator;
            bytes32 delegationHash_ = _delegationHashes[i_];
            uint256 caveatCount_ = caveats_.length;
            for (uint256 j_; j_ < caveatCount_; ++j_) {
                ICaveatEnforcer(caveats_[j_].enforcer).beforeAllHook(
                    caveats_[j_].terms, caveats_[j_].args, _mode, _executionCalldata, delegationHash_, delegator_, msg.sender
                );
            }
        }
    }

    function _executeBatch(
        Delegation[] memory _delegations,
        bytes32[] memory _delegationHashes,
        ModeCode _mode,
        bytes calldata _executionCalldata
    )
        private
    {
        if (_delegations.length == 0) {
            IDeleGatorCore(msg.sender).executeFromExecutor(_mode, _executionCalldata);
            return;
        }

        uint256 delegationCount_ = _delegations.length;
        for (uint256 i_; i_ < delegationCount_; ++i_) {
            Caveat[] memory caveats_ = _delegations[i_].caveats;
            address delegator_ = _delegations[i_].delegator;
            bytes32 delegationHash_ = _delegationHashes[i_];
            uint256 caveatCount_ = caveats_.length;
            for (uint256 j_; j_ < caveatCount_; ++j_) {
                ICaveatEnforcer(caveats_[j_].enforcer).beforeHook(
                    caveats_[j_].terms, caveats_[j_].args, _mode, _executionCalldata, delegationHash_, delegator_, msg.sender
                );
            }
        }

        IDeleGatorCore(_delegations[delegationCount_ - 1].delegator).executeFromExecutor(_mode, _executionCalldata);

        for (uint256 i_ = delegationCount_; i_ > 0; --i_) {
            Caveat[] memory caveats_ = _delegations[i_ - 1].caveats;
            address delegator_ = _delegations[i_ - 1].delegator;
            bytes32 delegationHash_ = _delegationHashes[i_ - 1];
            uint256 caveatCount_ = caveats_.length;
            for (uint256 j_ = caveatCount_; j_ > 0; --j_) {
                ICaveatEnforcer(caveats_[j_ - 1].enforcer).afterHook(
                    caveats_[j_ - 1].terms, caveats_[j_ - 1].args, _mode, _executionCalldata, delegationHash_, delegator_, msg.sender
                );
            }
        }
    }

    function _afterAllHooks(
        Delegation[] memory _delegations,
        bytes32[] memory _delegationHashes,
        ModeCode _mode,
        bytes calldata _executionCalldata
    )
        private
    {
        uint256 delegationCount_ = _delegations.length;
        for (uint256 i_ = delegationCount_; i_ > 0; --i_) {
            Caveat[] memory caveats_ = _delegations[i_ - 1].caveats;
            address delegator_ = _delegations[i_ - 1].delegator;
            bytes32 delegationHash_ = _delegationHashes[i_ - 1];
            uint256 caveatCount_ = caveats_.length;
            for (uint256 j_ = caveatCount_; j_ > 0; --j_) {
                ICaveatEnforcer(caveats_[j_ - 1].enforcer).afterAllHook(
                    caveats_[j_ - 1].terms, caveats_[j_ - 1].args, _mode, _executionCalldata, delegationHash_, delegator_, msg.sender
                );
            }
        }
    }
}
