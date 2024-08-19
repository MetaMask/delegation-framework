// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";

import { Caveat, Delegation } from "../../src/utils/Types.sol";
import { DELEGATION_TYPEHASH, CAVEAT_TYPEHASH } from "../../src/utils/Constants.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

contract EncoderLibTest is Test {
    ////////////////////////////// State //////////////////////////////

    // Hardcoding to avoid issues with changes in the addresses
    address public aliceMultisigDelegatorAddr = 0x5E0B4Bfa0B55932A3587E648c3552a6515bA56b1;
    address public bobMultisigDelegatorAddr = 0x88e3925A1E07598a499dC669515881D061857cdb;
    address public blockNumberEnforcerAddr = 0x76025d09bf6aC34F5c9F859912baC5F65BB97001;
    address public timestampEnforcerAddr = 0x6F29F39ba24d0dAF942680248c5f00730f9f52Ef;
    address public allowTargetsEnforcerAddr = 0x7e713BC29EbAfcbE64d1682cD7289714998a90f1;

    ////////////////////// Tests //////////////////////

    function test_shouldEncodeOneDelegation() public {
        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: blockNumberEnforcerAddr, terms: abi.encodePacked(uint128(1), uint128(100)) });
        Delegation memory delegation_ = Delegation({
            delegate: bobMultisigDelegatorAddr,
            delegator: aliceMultisigDelegatorAddr,
            authority: keccak256("ROOT_AUTHORITY"),
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 obtained_ = EncoderLib._getDelegationHash(delegation_);

        bytes32 hardcoded_ = bytes32(0x17b386a868324fe36266f1d32ef4a68e5f89e53aa8023de79567843ab9e8fb54);
        assertEq(obtained_, hardcoded_);
    }

    function test_ShouldEncodeOneCaveat() public {
        Caveat memory caveat =
            Caveat({ args: hex"", enforcer: allowTargetsEnforcerAddr, terms: abi.encodePacked(aliceMultisigDelegatorAddr) });
        bytes32 obtained = EncoderLib._getCaveatPacketHash(caveat);
        bytes32 expected = getCaveatPacketHash(caveat);
        assertEq(obtained, expected);
        bytes32 hardcoded = bytes32(0x973aad287fdc46b4b022335f1282984f5da8deee226ab84e594e3b7c3071a379);
        assertEq(obtained, hardcoded);
    }

    function test_ShouldEncodeAnArrayOfCaveats() public {
        Caveat[] memory caveats = new Caveat[](2);
        caveats[0] =
            Caveat({ args: hex"", enforcer: allowTargetsEnforcerAddr, terms: abi.encodePacked(aliceMultisigDelegatorAddr) });
        caveats[1] = Caveat({ args: hex"", enforcer: blockNumberEnforcerAddr, terms: abi.encodePacked(uint128(1), uint128(100)) });

        bytes32 obtained = EncoderLib._getCaveatArrayPacketHash(caveats);
        bytes32 expected = getCaveatArrayPacketHash(caveats);
        assertEq(obtained, expected);
        bytes32 hardcoded = bytes32(0x6c132d7477be706e424d1309fe04c4580c7a01680f5e94521b288d4aa185389f);
        assertEq(obtained, hardcoded);
    }

    ////////////////////// Utils //////////////////////

    /**
     * Gas intensive function to get the hash of a Caveat.
     */
    function getCaveatPacketHash(Caveat memory _input) public pure returns (bytes32) {
        bytes memory encoded = abi.encode(CAVEAT_TYPEHASH, _input.enforcer, keccak256(_input.terms));
        return keccak256(encoded);
    }

    /**
     * Gas intensive function to get the hash of a Caveat array.
     */
    function getCaveatArrayPacketHash(Caveat[] memory _input) public pure returns (bytes32) {
        bytes memory encoded;
        for (uint256 i = 0; i < _input.length; ++i) {
            encoded = abi.encodePacked(encoded, getCaveatPacketHash(_input[i]));
        }
        return keccak256(encoded);
    }
}
