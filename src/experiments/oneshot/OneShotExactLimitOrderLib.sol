// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { Execution } from "../../utils/Types.sol";

library OneShotExactLimitOrderLib {
    uint256 internal constant ONE_SHOT_LIMIT = 1;

    function encodeCombinedEnforcerTerms(Execution[] memory _executions) internal pure returns (bytes memory) {
        return abi.encodePacked(ONE_SHOT_LIMIT, ExecutionLib.encodeBatch(_executions));
    }

    function encodeTimestampTerms(uint128 _validAfter, uint128 _validBefore) internal pure returns (bytes memory) {
        return abi.encodePacked(_validAfter, _validBefore);
    }
}
