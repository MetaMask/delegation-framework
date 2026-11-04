// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MetaSwapManager as DirectRouteManager } from "../../../src/metaswap/direct-route/MetaSwapManager.sol";
import { PackedManagerGasTest } from "./PackedManagerGas.t.sol";

/// @notice Packed direct-route manager. Exact batch in calldata. Limit sends route bytes.
contract DirectRouteManagerGasTest is PackedManagerGasTest {
    function _comparisonName() internal pure override returns (string memory) {
        return "DirectRouteManager";
    }

    function _deploy() internal override returns (address) {
        return address(new DirectRouteManager());
    }

    function _limitUsesRoute() internal pure override returns (bool) {
        return true;
    }

    function _usesRedeemDelegations() internal pure override returns (bool) {
        return false;
    }
}
