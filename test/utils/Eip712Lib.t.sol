// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

library Eip712Lib {
    bytes32 internal constant DOMAIN_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice Generates the hash used for generating the EIP712 typed data hash to be signed.
    function createEip712DomainSeparator(
        string memory _name,
        string memory _version,
        uint256 _chainId,
        address _contract
    )
        public
        pure
        returns (bytes32 domainSeparator_)
    {
        return keccak256(abi.encode(DOMAIN_TYPE_HASH, keccak256(bytes(_name)), keccak256(bytes(_version)), _chainId, _contract));
    }
}
