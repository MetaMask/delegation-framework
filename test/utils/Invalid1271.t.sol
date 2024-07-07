// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

contract Invalid1271Returns is IERC1271 {
    /**
     * @inheritdoc IERC1271
     * @dev This contract always returns false.
     */
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return 0x00000000;
    }
}

contract Invalid1271Reverts is IERC1271 {
    /**
     * @inheritdoc IERC1271
     * @dev This contract always reverts
     */
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        revert("Error");
    }
}
