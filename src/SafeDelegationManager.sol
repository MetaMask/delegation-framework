// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { DelegationManager } from "./DelegationManager.sol";
import { Parameter, ReadableTerm } from "./utils/Types.sol";

contract SafeDelegationManager is DelegationManager {
    constructor(address _owner) DelegationManager(_owner) {}

    mapping(string => address) public termsToEnforcer;

    /**
     * @dev Decodes readable terms into standard delegation format
     */
    modifier _decodeReadableTerms(bytes[] calldata _permissionContexts) {
        uint256 batchSize_ = _permissionContexts.length;
        bytes[] memory rewrittenContexts_ = new bytes[](batchSize_);

        for (uint256 batchIndex_; batchIndex_ < batchSize_; ++batchIndex_) {
            // Try to decode as readable format
            try abi.decode(_permissionContexts[batchIndex_], (ReadableDelegation[])) returns (ReadableDelegation[] memory readableDelegations_) {
                if (readableDelegations_.length == 0) {
                    rewrittenContexts_[batchIndex_] = _permissionContexts[batchIndex_];
                    continue;
                }

                // Convert to standard delegations
                Delegation[] memory standardDelegations_ = new Delegation[](readableDelegations_.length);

                for (uint256 delegationIndex_; delegationIndex_ < readableDelegations_.length; ++delegationIndex_) {
                    ReadableDelegation memory readableDelegation_ = readableDelegations_[delegationIndex_];
                    
                    // Convert readable terms to caveats
                    Caveat[] memory caveats_ = new Caveat[](readableDelegation_.readableTerms.length);
                    for (uint256 termIndex_; termIndex_ < readableDelegation_.readableTerms.length; ++termIndex_) {
                        ReadableTerm memory term_ = readableDelegation_.readableTerms[termIndex_];
                        address enforcer_ = termsToEnforcer[term_.permissionName];
                        if (enforcer_ == address(0)) revert("Unknown permission type");
                        
                        // Convert readable terms to caveats using enforcer's conversion method
                        ReadableTerm[] memory singleTerm_ = new ReadableTerm[](1);
                        singleTerm_[0] = term_;
                        Caveat[] memory convertedCaveats_ = ICaveatEnforcer(enforcer_)._convertReadableTermsToCaveats(singleTerm_);
                        
                        // Take first caveat since we only passed one term
                        caveats_[termIndex_] = convertedCaveats_[0];
                    }

                    standardDelegations_[delegationIndex_] = Delegation({
                        delegate: readableDelegation_.delegate,
                        delegator: readableDelegation_.delegator,
                        authority: readableDelegation_.authority, 
                        caveats: caveats_,
                        salt: readableDelegation_.salt,
                        signature: readableDelegation_.signature
                    });
                }

                rewrittenContexts_[batchIndex_] = abi.encode(standardDelegations_);
            } catch {
                // If decoding as ReadableDelegation fails, assume it's already a standard Delegation
                rewrittenContexts_[batchIndex_] = _permissionContexts[batchIndex_];
            }
        }

        _;
    }

    /**
     * @inheritdoc DelegationManager
     */
    function redeemDelegations(
        bytes[] calldata _permissionContexts,
        ModeCode[] calldata _modes,
        bytes[] calldata _executionCallDatas
    ) external override whenNotPaused _decodeReadableTerms {
        super.redeemDelegations(_permissionContexts, _modes, _executionCallDatas);
    }
}
