// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

contract ERC721TransferEnforcer is CaveatEnforcer {
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
        onlySingleExecutionMode(_mode)
    {
        (address permittedContract_, uint256 permittedTokenId_) = getTermsInfo(_terms);
        (address target_,, bytes calldata callData_) = ExecutionLib.decodeSingle(_executionCallData);
        bytes4 selector_ = bytes4(callData_[0:4]);

        // Decode the remaining callData into NFT transfer parameters
        if (callData_.length < 100) {
            revert("ERC721TransferEnforcer:invalid-calldata-length");
        }

        address from_;
        address to_;
        uint256 transferTokenId_;
        (from_, to_, transferTokenId_) = abi.decode(callData_[4:], (address, address, uint256));

        if (from_ == address(0) || to_ == address(0)) {
            revert("ERC721TransferEnforcer:invalid-address");
        }

        if (target_ != permittedContract_) {
            revert("ERC721TransferEnforcer:unauthorized-contract-target");
        } else if (selector_ != IERC721.transferFrom.selector) {
            revert("ERC721TransferEnforcer:unauthorized-selector");
        } else if (transferTokenId_ != permittedTokenId_) {
            revert("ERC721TransferEnforcer:unauthorized-token-id");
        }
    }

    function getTermsInfo(bytes calldata _terms) public pure returns (address permittedContract_, uint256 permittedTokenId_) {
        if (_terms.length != 52) revert("ERC721TransferEnforcer:invalid-terms-length");
        permittedContract_ = address(bytes20(_terms[:20]));
        permittedTokenId_ = uint256(bytes32(_terms[20:]));
    }
}
