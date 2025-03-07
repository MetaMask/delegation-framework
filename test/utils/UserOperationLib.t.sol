// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { PackedUserOperation } from "../../src/utils/Types.sol";
import { Eip712Lib } from "./Eip712Lib.t.sol";

library UserOperationLib {
    /// @dev The typehash for the PackedUserOperation struct
    bytes32 public constant PACKED_USER_OP_TYPEHASH = keccak256(
        "PackedUserOperation(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,address entryPoint)"
    );

    /**
     * Provides the typed data hash for a PackedUserOperation
     * @param _userOp the PackedUserOperation to hash
     */
    function getPackedUserOperationHash(PackedUserOperation calldata _userOp, address _entryPoint) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PACKED_USER_OP_TYPEHASH,
                _userOp.sender,
                _userOp.nonce,
                keccak256(_userOp.initCode),
                keccak256(_userOp.callData),
                _userOp.accountGasLimits,
                _userOp.preVerificationGas,
                _userOp.gasFees,
                keccak256(_userOp.paymasterAndData),
                _entryPoint
            )
        );
    }

    /**
     * Returns the Eip712 typed data hash for a PackedUserOperation to be signed.
     * @param _name the name of the Eip712 domain
     * @param _version the version of the Eip712 domain
     * @param _chainId the chain id of the contract
     * @param _contract the address of the verifying contract
     * @param _userOp the User Operation to hash
     */
    function getPackedUserOperationTypedDataHash(
        string memory _name,
        string memory _version,
        uint256 _chainId,
        address _contract,
        PackedUserOperation calldata _userOp,
        address _entryPoint
    )
        public
        pure
        returns (bytes32)
    {
        return MessageHashUtils.toTypedDataHash(
            Eip712Lib.createEip712DomainSeparator(_name, _version, _chainId, _contract),
            getPackedUserOperationHash(_userOp, _entryPoint)
        );
    }
}
