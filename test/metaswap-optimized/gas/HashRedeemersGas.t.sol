// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;
import {Test, console2} from "forge-std/Test.sol";

contract HashRedeemersGas is Test {
    uint256 constant REDEEMERS_OFFSET = 234;

    function test_compare() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        bytes memory wire = bytes.concat(
            new bytes(234), bytes20(a), bytes20(b), bytes20(a), bytes20(b), new bytes(10)
        );
        T t = new T();
        (uint256 c1,) = t.measureCompact(wire, 4);
        (uint256 r1,) = t.measureReadable(wire, 4);
        (uint256 c2, bytes32 h1) = t.measureCompact(wire, 4);
        (uint256 r2, bytes32 h2) = t.measureReadable(wire, 4);
        assertEq(h1, h2);
        console2.log("compact_warm", c2);
        console2.log("readable_warm", r2);
        console2.log("delta", int256(r2) - int256(c2));
        console2.log("compact_cold", c1);
        console2.log("readable_cold", r1);
    }
}

contract T {
    uint256 constant REDEEMERS_OFFSET = 234;
    address d; uint256 c; uint8 op;
    function measureCompact(bytes calldata w, uint256 count) external returns (uint256, bytes32) {
        op = 1; c = count; (bool ok, bytes memory ret) = address(this).call(w); require(ok); return abi.decode(ret, (uint256, bytes32));
    }
    function measureReadable(bytes calldata w, uint256 count) external returns (uint256, bytes32) {
        op = 2; c = count; (bool ok, bytes memory ret) = address(this).call(w); require(ok); return abi.decode(ret, (uint256, bytes32));
    }
    fallback() external {
        uint256 g0 = gasleft();
        bytes32 h = op == 1 ? _compact(c) : _readable(c);
        bytes memory out = abi.encode(g0 - gasleft(), h);
        assembly { return(add(out, 0x20), mload(out)) }
    }
    function _compact(uint256 redeemerCount_) private pure returns (bytes32 hash_) {
        assembly ("memory-safe") {
            let words := mload(0x40)
            for { let i := 0 } lt(i, redeemerCount_) { i := add(i, 1) } {
                let word := calldataload(add(REDEEMERS_OFFSET, mul(i, 20)))
                mstore(add(words, shl(5, i)), shr(96, word))
            }
            hash_ := keccak256(words, shl(5, redeemerCount_))
        }
    }
    function _readable(uint256 redeemerCount_) private pure returns (bytes32 redeemersHash_) {
        assembly ("memory-safe") {
            let packedRedeemers := mload(0x40)
            for { let index := 0 } lt(index, redeemerCount_) { index := add(index, 1) } {
                let calldataOffset := add(REDEEMERS_OFFSET, mul(index, 20))
                let addressWord := calldataload(calldataOffset)
                let redeemer := shr(96, addressWord)
                mstore(add(packedRedeemers, mul(index, 32)), redeemer)
            }
            let packedLength := mul(redeemerCount_, 32)
            redeemersHash_ := keccak256(packedRedeemers, packedLength)
        }
    }
}
