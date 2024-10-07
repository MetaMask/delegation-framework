// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IEntryPoint } from "@account-abstraction/interfaces/IEntryPoint.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { Delegation, Caveat } from "../src/utils/Types.sol";
import { DelegationManager } from "../src/DelegationManager.sol";
import { SigningUtilsLib } from "../test/utils/SigningUtilsLib.t.sol";
import { EncoderLib } from "../src/libraries/EncoderLib.sol";
import { MultiSigDeleGator } from "../src/MultiSigDeleGator.sol";
import { HybridDeleGator } from "../src/HybridDeleGator.sol";
import { IDelegationManager } from "../src/interfaces/IDelegationManager.sol";

// This is the domain struct used for EIP712 signing.
struct Domain {
    string name;
    string version;
    uint256 chainId;
    address verifyingContract;
}

/**
 * @title SignDelegation
 * @notice Produces a signature for a given delegation and private key.
 * @dev Fill in necessary config in the run function and inside the .env file.
 * @dev forge script script/SignDelegation.s.sol
 */
contract SignDelegation is Script {
    using MessageHashUtils for bytes32;

    // Constant value dependent on the DelegationManager implementation
    bytes32 ROOT_AUTHORITY = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    bytes32 salt;
    address signer;
    uint256 privateKey;

    function setUp() public {
        privateKey = vm.envUint("SIGNER_PRIVATE_KEY");
        console2.log("~~~");
        console2.log("Signer:");
        console2.log(vm.addr(privateKey));
    }

    function run() public view {
        console2.log("~~~");

        ///////////////////////////////////////////// Config /////////////////////////////////////////////

        // The domain of the DelegationManager that this delegation is tied to
        Domain memory domain = Domain({
            name: "DelegationManager",
            version: "1",
            chainId: 31337,
            verifyingContract: address(0x687137B4C3C05F90c2e372DCd7700f088d1De708)
        });

        // The delegation to sign
        Caveat[] memory caveats = new Caveat[](0);
        Delegation memory delegation = Delegation({
            delegate: address(0x6c722F91Fd91219a4939e4f5176a119388Cc556b),
            delegator: address(0x8741DD57847F94E519820cD54D5F90eC2FB7F6b9),
            authority: ROOT_AUTHORITY,
            caveats: caveats,
            salt: 0,
            signature: hex""
        });

        /////////////////////////////////////////////////////////////////////////////////////////////////

        // Compute the hash of the delegation to sign
        bytes32 domainSeparator_ = computeDomainSeparator(domain);

        // For testing purposes to validate alignment with external SDKs.
        // bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        // bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(domainSeparator_, delegationHash_);
        // console2.log("domainSeparator_:");
        // console2.logBytes32(domainSeparator_);
        // console2.log("delegationHash_:");
        // console2.logBytes32(delegationHash_);
        // console2.log("typedDataHash_:");
        // console2.logBytes32(typedDataHash_);

        bytes memory signature_ = signDelegation(delegation, domainSeparator_, privateKey);

        console2.log("Signature:");
        console2.logBytes(signature_);
    }

    function signDelegation(
        Delegation memory delegation_,
        bytes32 domainSeparator_,
        uint256 privateKey_
    )
        public
        pure
        returns (bytes memory signature_)
    {
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        bytes32 typedDataHash_ = MessageHashUtils.toTypedDataHash(domainSeparator_, delegationHash_);
        signature_ = SigningUtilsLib.signHash_EOA(privateKey_, typedDataHash_);
    }

    function computeDomainSeparator(Domain memory domain_) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(domain_.name)),
                keccak256(bytes(domain_.version)),
                domain_.chainId,
                domain_.verifyingContract
            )
        );
    }
}
