// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MetaSwapManager as Eip7710DirectRouteManager } from "../../../src/metaswap/eip7710-direct-route/MetaSwapManager.sol";
import { PackedManagerGasTest } from "./PackedManagerGas.t.sol";

/// @notice EIP-7710 direct-route manager. Limit sends route bytes instead of the batch.
contract Eip7710DirectRouteManagerGasTest is PackedManagerGasTest {
    function _comparisonName() internal pure override returns (string memory) {
        return "Eip7710DirectRouteManager";
    }

    function _deploy() internal override returns (address) {
        return address(new Eip7710DirectRouteManager());
    }

    function _limitUsesRoute() internal pure override returns (bool) {
        return true;
    }

    function _usesRedeemDelegations() internal pure override returns (bool) {
        return true;
    }
}