// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";

import { StorageUtilsLib } from "../utils/StorageUtilsLib.t.sol";

contract StorageUtilsLibTest is Test {
    function testToBool() public {
        uint8 one_ = 1;
        uint8 zero_ = 0;

        bytes memory t_ = abi.encode(one_);
        bytes memory f_ = abi.encode(zero_);

        assertTrue(StorageUtilsLib.toBool(t_, 31));
        assertFalse(StorageUtilsLib.toBool(f_, 31));

        t_ = abi.encodePacked(one_);
        f_ = abi.encodePacked(zero_);

        assertTrue(StorageUtilsLib.toBool(t_, 0));
        assertFalse(StorageUtilsLib.toBool(f_, 0));
    }
}
