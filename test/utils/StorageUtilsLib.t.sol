// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Vm } from "forge-std/Vm.sol";
import { BytesLib } from "@bytes-utils/BytesLib.sol";

/**
 * @title Storage Utils Library
 * @notice Basic utility functions for testing storage.
 */
library StorageUtilsLib {
    address private constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    /**
     * @notice Converts a chunk of bytes to a boolean
     * @param _bytes the bytes to convert
     * @param _start the starting position in the bytes
     */
    function toBool(bytes memory _bytes, uint256 _start) public pure returns (bool) {
        bytes memory data_ = BytesLib.slice(_bytes, _start, 1);

        require(data_.length == 1, "Invalid data length");

        bool result_;
        assembly {
            result_ := mload(add(data_, 32))
        }

        return result_;
    }

    /**
     * @notice Computes the storage location of a contract's namespaced storage slot.
     * @dev https://eips.ethereum.org/EIPS/eip-7201
     * @dev https://ethereum-magicians.org/t/eip-7201-namespaced-storage-layout
     * @dev NOTE: Sept 27 2023; There's a discussion going on to whether or not the additional hash manipulation is necessary.
     * Keeping it for now to be in line with the EIP.
     * @param _key The key to compute the deterministic storage location for
     */
    function getStorageLocation(string memory _key) public pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(_key))) - 1)) & ~bytes32(uint256(0xff));
    }

    /**
     * @notice Converts a bytes32 value to an address
     * @param _value The value to convert to an address
     */
    function toAddress(bytes32 _value) public pure returns (address) {
        return address(uint160(uint256(_value)));
    }

    /**
     * @notice This method loads an address array from a contract's storage.
     * @param _addr The contract to read an array from
     * @param _location The location that the array is stored in memory
     * @dev The storage of the array != the storage of the elements
     */
    function loadFullArray(address _addr, uint256 _location) public view returns (address[] memory) {
        // Load the start slot from storage
        bytes32 slotVal_ = vm.load(_addr, bytes32(_location));
        // The first slot contains the size of the array
        uint256 arrayLength_ = uint256(slotVal_);

        // Initialize an array in memory to hold the values we retrieve from storage
        address[] memory fullArr_ = new address[](arrayLength_);
        // Calculate the start of the contiguous section in storage containing the array contents
        bytes32 startSlot_ = keccak256(abi.encodePacked(_location));
        // Iterate through the slots containing the array contents and store them in memory;
        for (uint256 i = 0; i < arrayLength_; i++) {
            slotVal_ = vm.load(_addr, bytes32(uint256(startSlot_) + i));
            fullArr_[i] = address(uint160(uint256(slotVal_)));
        }
        return fullArr_;
    }
}
