// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { Action } from "../utils/Types.sol";

/**
 * @title ERC20TransferAmountEnforcer
 * @dev This contract enforces the transfer limit for ERC20 tokens.
 */
contract ERC20TransferAmountEnforcer is CaveatEnforcer {
    ////////////////////////////// State //////////////////////////////

    mapping(address delegationManager => mapping(bytes32 delegationHash => uint256 amount)) public spentMap;

    ////////////////////////////// Events //////////////////////////////
    event IncreasedSpentMap(
        address indexed sender, address indexed redeemer, bytes32 indexed delegationHash, uint256 limit, uint256 spent
    );

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Allows the delegator to specify a maximum sum of the contract token to transfer on their behalf.
     * @dev This function enforces the transfer limit before the transaction is performed.
     * @param _terms The ERC20 token address, and the numeric maximum amount that the recipient may transfer on the signer's
     * behalf.
     * @param _action The transaction the delegate might try to perform.
     * @param _delegationHash The hash of the delegation being operated on.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        Action calldata _action,
        bytes32 _delegationHash,
        address,
        address _redeemer
    )
        public
        override
    {
        require(_action.data.length == 68, "ERC20TransferAmountEnforcer:invalid-action-length");

        (address allowedContract_, uint256 limit_) = getTermsInfo(_terms);
        address targetContract_ = _action.to;
        bytes4 allowedMethod_ = IERC20.transfer.selector;

        require(allowedContract_ == targetContract_, "ERC20TransferAmountEnforcer:invalid-contract");

        bytes4 targetSig_ = bytes4(_action.data[0:4]);
        require(targetSig_ == allowedMethod_, "ERC20TransferAmountEnforcer:invalid-method");

        uint256 sending_ = uint256(bytes32(_action.data[36:68]));

        uint256 spent_ = spentMap[msg.sender][_delegationHash] += sending_;
        require(spent_ <= limit_, "ERC20TransferAmountEnforcer:allowance-exceeded");

        emit IncreasedSpentMap(msg.sender, _redeemer, _delegationHash, limit_, spent_);
    }

    /**
     * @notice Decodes the terms used in this CaveatEnforcer.
     * @param _terms encoded data that is used during the execution hooks.
     * @return allowedContract_ The address of the ERC20 token contract.
     * @return maxTokens_ The maximum number of tokens that the delegate is allowed to transfer.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (address allowedContract_, uint256 maxTokens_) {
        require(_terms.length == 52, "ERC20TransferAmountEnforcer:invalid-terms-length");

        allowedContract_ = address((bytes20(_terms[:20])));
        maxTokens_ = uint256(bytes32(_terms[20:]));
    }
}
