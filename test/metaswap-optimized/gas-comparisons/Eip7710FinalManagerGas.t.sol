// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { MetaSwapManager as Eip7710FinalManager } from "../../../src/metaswap/eip7710-final/MetaSwapManager.sol";
import { PackedManagerGasTest } from "./PackedManagerGas.t.sol";

/// @notice EIP-7710 final manager. `redeemDelegations`, batch in `executionCallDatas`.
contract Eip7710FinalManagerGasTest is PackedManagerGasTest {
    function _comparisonName() internal pure override returns (string memory) {
        return "Eip7710FinalManager";
    }

    function _deploy() internal override returns (address) {
        return address(new Eip7710FinalManager());
    }

    function _limitUsesRoute() internal pure override returns (bool) {
        return false;
    }

    function _usesRedeemDelegations() internal pure override returns (bool) {
        return true;
    }
}
