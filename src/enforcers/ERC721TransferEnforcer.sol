// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import { ModeCode } from "../utils/Types.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

contract ERC721TransferEnforcer is CaveatEnforcer {
    error UnauthorizedTransfer();

    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode,
        bytes calldata executionCallData,
        bytes32,
        address,
        address
    ) public virtual override {
        (address permittedContract, uint256 permittedTokenId) = getTermsInfo(_terms);
        (address target, uint256 _value, bytes calldata callData_) = ExecutionLib.decodeSingle(executionCallData);
        bytes4 selector = bytes4(callData_[0:4]);
        // Decode the remaining callData into NFT transfer parameters
        if (callData_.length < 100) {
            revert("ERC721TransferEnforcer:invalid-calldata-length");
        }
        
        address from;
        address to;
        uint256 transferTokenId;
        
        if (callData_.length < 100) {
            revert("ERC721TransferEnforcer:invalid-calldata-length");
        }
        
        (from, to, transferTokenId) = abi.decode(callData_[4:], (address, address, uint256));
        
        if (from == address(0) || to == address(0)) {
            revert("ERC721TransferEnforcer:invalid-address");
        }

        if (from == address(0) || to == address(0)) {
            revert("ERC721TransferEnforcer:invalid-address");
        }
        if (target != permittedContract) {
            revert("ERC721TransferEnforcer:unauthorized-contract-target");
        } else if (selector != IERC721.transferFrom.selector) {
            revert("ERC721TransferEnforcer:unauthorized-selector");
        } else if (transferTokenId != permittedTokenId) {
            revert("ERC721TransferEnforcer:unauthorized-token-id");
        }
    }

    function afterHook(
        bytes calldata,
        bytes calldata,
        ModeCode,
        bytes calldata,
        bytes32,
        address,
        address
    ) public virtual override {}

    function getTermsInfo(bytes calldata _terms) public pure returns (address permittedContract, uint256 permittedTokenId) {
        if (_terms.length != 52) revert("ERC721TransferEnforcer:invalid-terms-length");
        permittedContract = address(bytes20(_terms[:20]));
        permittedTokenId = uint256(bytes32(_terms[20:]));
    }
}
