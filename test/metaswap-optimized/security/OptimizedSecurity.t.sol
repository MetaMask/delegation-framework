// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { OrderManagerAdapter, FinalAdapter } from "../utils/OptimizedAdapters.t.sol";
import { OptimizedPackedParsingSuite, OptimizedSecuritySuite } from "./OptimizedSecuritySuite.t.sol";

contract OrderManagerSecurityTest is OptimizedSecuritySuite, OrderManagerAdapter { }

contract FinalCombinedSecurityTest is OptimizedSecuritySuite, FinalAdapter { }

contract FinalCombinedParsingTest is OptimizedPackedParsingSuite, FinalAdapter {
    constructor() {
        usesLengthPrefixedSignature = false;
    }

    /// @dev `selector | header | settlement fields | validAfter | validUntil`.
    function _limitRedeemerCountOffset() internal pure override returns (uint256) {
        return 233;
    }
}
