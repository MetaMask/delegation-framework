// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

library AccountSorterLib {
    ////////////////////////////// External Methods //////////////////////////////

    function sortAddressesWithPrivateKeys(
        address[] memory addresses,
        uint256[] memory privateKeys
    )
        external
        pure
        returns (address[] memory, uint256[] memory)
    {
        require(addresses.length == privateKeys.length, "AccountSorterLib:lengths-mismatch");
        _quickSort(addresses, privateKeys, int256(0), int256(addresses.length - 1));
        return (addresses, privateKeys);
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    function _quickSort(address[] memory arr, uint256[] memory privateKeys, int256 left, int256 right) internal pure {
        if (left < right) {
            int256 pivotIndex = _partition(arr, privateKeys, left, right);
            _quickSort(arr, privateKeys, left, pivotIndex - 1);
            _quickSort(arr, privateKeys, pivotIndex + 1, right);
        }
    }

    function _partition(
        address[] memory arr,
        uint256[] memory privateKeys,
        int256 left,
        int256 right
    )
        internal
        pure
        returns (int256)
    {
        address pivot = arr[uint256(right)];
        int256 i = left - 1;

        for (int256 j = left; j < right; j++) {
            if (arr[uint256(j)] <= pivot) {
                i++;
                (arr[uint256(i)], arr[uint256(j)]) = (arr[uint256(j)], arr[uint256(i)]);
                (privateKeys[uint256(i)], privateKeys[uint256(j)]) = (privateKeys[uint256(j)], privateKeys[uint256(i)]);
            }
        }

        (arr[uint256(i + 1)], arr[uint256(right)]) = (arr[uint256(right)], arr[uint256(i + 1)]);
        (privateKeys[uint256(i + 1)], privateKeys[uint256(right)]) = (privateKeys[uint256(right)], privateKeys[uint256(i + 1)]);

        return i + 1;
    }
}
