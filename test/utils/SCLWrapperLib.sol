// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { SCL_RIP7212 } from "@SCL/lib/libSCL_RIP7212.sol";

contract SCL_Wrapper {
    fallback(bytes calldata input) external returns (bytes memory) {
        if ((input.length != 160)) {
            return abi.encode(0);
        }
        bytes32 message = bytes32(input[0:32]);
        uint256 r = uint256(bytes32(input[32:64]));
        uint256 s = uint256(bytes32(input[64:96]));
        uint256 Qx = uint256(bytes32(input[96:128]));
        uint256 Qy = uint256(bytes32(input[128:160]));

        return abi.encode(SCL_RIP7212.verify(message, r, s, Qx, Qy));
    }
}
