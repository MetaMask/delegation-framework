// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MetaSwapManager as FinalManager } from "../../../src/metaswap/final/MetaSwapManager.sol";
import { PackedManagerGasTest } from "./PackedManagerGas.t.sol";

/// @notice Packed final manager. Exact batch in calldata, limit batch in calldata.
contract FinalManagerGasTest is PackedManagerGasTest {
    function _comparisonName() internal pure override returns (string memory) {
        return "FinalManager";
    }

    function _deploy() internal override returns (address) {
        return address(new FinalManager());
    }

    function _limitUsesRoute() internal pure override returns (bool) {
        return false;
    }

    function _usesRedeemDelegations() internal pure override returns (bool) {
        return false;
    }
}
