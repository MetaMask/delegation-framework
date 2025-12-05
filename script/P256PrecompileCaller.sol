// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title P256PrecompileCaller
 * @notice Simple contract to call the P256 precompile at address 0x100
 * @dev This contract provides a simple interface to test the EIP-7951 P256 precompile
 */
contract P256PrecompileCaller {
    // P256 Precompile address (EIP-7951)
    address constant P256_PRECOMPILE = address(0x100);

    /**
     * @notice Calls the P256 precompile with the provided input
     * @param input The encoded input data: abi.encode(message_hash, r, s, x, y)
     * @return success Whether the call succeeded
     * @return ret The return data from the precompile
     */
    function callPrecompile(bytes memory input) public view returns (bool success, bytes memory ret) {
        (success, ret) = P256_PRECOMPILE.staticcall(input);
    }
}
