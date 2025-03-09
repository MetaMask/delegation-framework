// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";

import { EIP712_DOMAIN_TYPEHASH, DELEGATION_TYPEHASH, CAVEAT_TYPEHASH } from "../../src/utils/Constants.sol";

contract TypehashTest is Test {
    ////////////////////////////// State //////////////////////////////

    string public caveat = "Caveat(address enforcer,bytes terms)";
    string public delegation = "Delegation(address delegate,address delegator,bytes32 authority,Caveat[] caveats,uint256 salt)";
    string public eip712Domain = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";

    function test_CaveatTypehash() public {
        assertEq(CAVEAT_TYPEHASH, _hashPacked(caveat));
    }

    function test_DelegationTypehash() public {
        string[] memory types_ = new string[](2);
        types_[0] = delegation;
        types_[1] = caveat;
        string memory complete_ = _append(types_);
        assertEq(DELEGATION_TYPEHASH, _hashPacked(complete_));
    }

    function test_EIP712DomainTypehash() public {
        assertEq(EIP712_DOMAIN_TYPEHASH, _hashPacked(eip712Domain));
    }

    ////////////////////// Utils //////////////////////

    function _hashPacked(string memory _message) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_message));
    }

    function _append(string[] memory _message) internal pure returns (string memory main_) {
        main_ = _message[0];
        for (uint256 i = 1; i < _message.length; i++) {
            main_ = string(abi.encodePacked(main_, _message[i]));
        }
    }
}
