// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

/**
 * @title ERC721TransferEnforcer
 * @notice This enforcer restricts the action of a UserOp to the transfer of a specific ERC721 token.
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 */
contract ERC721TransferEnforcer is CaveatEnforcer {
    bytes4 private constant SAFE_TRANSFER_FROM_SELECTOR_1 = bytes4(keccak256("safeTransferFrom(address,address,uint256)"));
    bytes4 private constant SAFE_TRANSFER_FROM_SELECTOR_2 = bytes4(keccak256("safeTransferFrom(address,address,uint256,bytes)"));

    /**
     * @notice Enforces that the contract and tokenId are permitted for transfer
     * @param _terms abi encoded address of the contract and uint256 of the tokenId
     * @param _mode The execution mode. (Must be Single callType, Default execType)
     * @param _executionCallData the call data of the transferFrom call
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32,
        address,
        address
    )
        public
        virtual
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        (address permittedContract_, uint256 permittedTokenId_) = getTermsInfo(_terms);
        (address target_,, bytes calldata callData_) = ExecutionLib.decodeSingle(_executionCallData);

        // Decode the remaining callData into NFT transfer parameters
        // The calldata should be at least 100 bytes (4 bytes for the selector + 96 bytes for the parameters)
        if (callData_.length < 100) {
            revert("ERC721TransferEnforcer:invalid-calldata-length");
        }

        // Decode the remaining callData into NFT transfer parameters
        (address from_, address to_, uint256 transferTokenId_) = abi.decode(callData_[4:], (address, address, uint256));

        if (from_ == address(0) || to_ == address(0)) {
            revert("ERC721TransferEnforcer:invalid-address");
        }

        bytes4 selector_ = bytes4(callData_[0:4]);

        if (target_ != permittedContract_) {
            revert("ERC721TransferEnforcer:unauthorized-contract-target");
        }

        if (
            selector_ != IERC721.transferFrom.selector && selector_ != SAFE_TRANSFER_FROM_SELECTOR_1
                && selector_ != SAFE_TRANSFER_FROM_SELECTOR_2
        ) {
            revert("ERC721TransferEnforcer:unauthorized-selector");
        }

        if (transferTokenId_ != permittedTokenId_) {
            revert("ERC721TransferEnforcer:unauthorized-token-id");
        }
    }

    function getTermsInfo(bytes calldata _terms) public pure returns (address permittedContract_, uint256 permittedTokenId_) {
        if (_terms.length != 52) revert("ERC721TransferEnforcer:invalid-terms-length");
        permittedContract_ = address(bytes20(_terms[:20]));
        permittedTokenId_ = uint256(bytes32(_terms[20:]));
    }
}
