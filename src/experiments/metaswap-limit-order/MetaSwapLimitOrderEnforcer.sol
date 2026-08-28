// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { CaveatEnforcer } from "../../enforcers/CaveatEnforcer.sol";
import { ModeCode } from "../../utils/Types.sol";
import { MetaSwapLimitOrderLib } from "./MetaSwapLimitOrderLib.sol";

/**
 * @title MetaSwapLimitOrderEnforcer
 * @notice Enforces a one-shot, dynamically routed MetaSwap limit order on the canonical DelegationManager.
 */
contract MetaSwapLimitOrderEnforcer is CaveatEnforcer {
    mapping(address manager => mapping(bytes32 delegationHash => bool used)) public usedDelegations;

    event LimitOrderUsed(address indexed manager, bytes32 indexed delegationHash, address indexed maker);

    error DelegationAlreadyUsed();

    /**
     * @notice Validates maker-signed terms and consumes the order before execution.
     * @param _terms ABI-encoded {MetaSwapLimitOrderLib.Terms}.
     * @param _mode ERC-7579 batch/default mode.
     * @param _executionCallData Exact transfer followed by a bounded adapter call.
     * @param _delegationHash One-shot order identifier.
     * @param _delegator Maker account.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32 _delegationHash,
        address _delegator,
        address
    )
        public
        override
    {
        if (usedDelegations[msg.sender][_delegationHash]) revert DelegationAlreadyUsed();

        MetaSwapLimitOrderLib.Terms memory terms_ = abi.decode(_terms, (MetaSwapLimitOrderLib.Terms));
        MetaSwapLimitOrderLib.validateTerms(terms_);
        MetaSwapLimitOrderLib.validateExecution(terms_, _mode, _executionCallData);

        usedDelegations[msg.sender][_delegationHash] = true;
        emit LimitOrderUsed(msg.sender, _delegationHash, _delegator);
    }

    /**
     * @notice Decodes maker-signed order terms.
     * @param _terms ABI-encoded {MetaSwapLimitOrderLib.Terms}.
     * @return terms_ Decoded terms.
     */
    function getTermsInfo(bytes calldata _terms) external pure returns (MetaSwapLimitOrderLib.Terms memory terms_) {
        terms_ = abi.decode(_terms, (MetaSwapLimitOrderLib.Terms));
    }
}
