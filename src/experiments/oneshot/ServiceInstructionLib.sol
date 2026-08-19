// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ServiceInstructionTypes } from "./ServiceInstructionTypes.sol";

library ServiceInstructionLib {
    bytes32 internal constant SERVICE_INSTRUCTION_TYPEHASH = 0x39e6f995c25cda51a838cf40330c1bdcf2c97fe8ca2f5b2f706c7a404fc76eb7;

    string internal constant SERVICE_DOMAIN_NAME = "LimitOrderQuoteService";
    string internal constant SERVICE_DOMAIN_VERSION = "1";

    function hashServiceInstruction(ServiceInstructionTypes.ServiceInstruction memory _instruction)
        internal
        pure
        returns (bytes32 hash_)
    {
        assembly ("memory-safe") {
            let ptr_ := _instruction
            let buf_ := mload(0x40)
            mstore(buf_, SERVICE_INSTRUCTION_TYPEHASH)
            for { let w_ := 0 } lt(w_, 15) { w_ := add(w_, 1) } {
                mstore(add(buf_, mul(add(w_, 1), 0x20)), mload(add(ptr_, mul(w_, 0x20))))
            }
            hash_ := keccak256(buf_, 0x200)
            mstore(0x40, add(buf_, 0x200))
        }
    }

    function encodeMakerBoundsTerms(ServiceInstructionTypes.MakerBounds memory _bounds) internal pure returns (bytes memory) {
        return abi.encode(_bounds);
    }

    function decodeMakerBoundsTerms(bytes calldata _terms)
        internal
        pure
        returns (ServiceInstructionTypes.MakerBounds memory bounds_)
    {
        bounds_ = abi.decode(_terms, (ServiceInstructionTypes.MakerBounds));
    }

    function serviceDomainSeparator(address _verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(SERVICE_DOMAIN_NAME)),
                keccak256(bytes(SERVICE_DOMAIN_VERSION)),
                block.chainid,
                _verifyingContract
            )
        );
    }

    function recoverSigner(
        ServiceInstructionTypes.ServiceInstruction memory _instruction,
        bytes memory _signature,
        address _verifyingContract
    )
        internal
        view
        returns (address signer_)
    {
        bytes32 digest_ =
            MessageHashUtils.toTypedDataHash(serviceDomainSeparator(_verifyingContract), hashServiceInstruction(_instruction));
        signer_ = ECDSA.recover(digest_, _signature);
    }
}
