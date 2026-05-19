// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Vm } from "forge-std/Vm.sol";

import { TreasuryManagerChainConfig } from "./TreasuryManagerChainTypes.sol";
import { TreasuryManagerConfigArbitrum } from "./chains/TreasuryManagerConfig.arbitrum.s.sol";
import { TreasuryManagerConfigAvalanche } from "./chains/TreasuryManagerConfig.avalanche.s.sol";
import { TreasuryManagerConfigBase } from "./chains/TreasuryManagerConfig.base.s.sol";
import { TreasuryManagerConfigBsc } from "./chains/TreasuryManagerConfig.bsc.s.sol";
import { TreasuryManagerConfigEthereum } from "./chains/TreasuryManagerConfig.ethereum.s.sol";
import { TreasuryManagerConfigLinea } from "./chains/TreasuryManagerConfig.linea.s.sol";
import { TreasuryManagerConfigMonad } from "./chains/TreasuryManagerConfig.monad.s.sol";
import { TreasuryManagerConfigOptimism } from "./chains/TreasuryManagerConfig.optimism.s.sol";
import { TreasuryManagerConfigPolygon } from "./chains/TreasuryManagerConfig.polygon.s.sol";
import { TreasuryManagerConfigSei } from "./chains/TreasuryManagerConfig.sei.s.sol";
import { TreasuryManagerConfigZksync } from "./chains/TreasuryManagerConfig.zksync.s.sol";

/// @dev Selects `TreasuryManagerChainConfig` from `DEPLOY_CHAIN` (lowercase ASCII, e.g. `linea`, `ethereum`).
library TreasuryManagerChainConfigRouter {
    bytes32 internal constant H_ARBITRUM = keccak256(bytes("arbitrum"));
    bytes32 internal constant H_AVALANCHE = keccak256(bytes("avalanche"));
    bytes32 internal constant H_BASE = keccak256(bytes("base"));
    bytes32 internal constant H_BSC = keccak256(bytes("bsc"));
    bytes32 internal constant H_ETHEREUM = keccak256(bytes("ethereum"));
    bytes32 internal constant H_LINEA = keccak256(bytes("linea"));
    bytes32 internal constant H_MONAD = keccak256(bytes("monad"));
    bytes32 internal constant H_OPTIMISM = keccak256(bytes("optimism"));
    bytes32 internal constant H_POLYGON = keccak256(bytes("polygon"));
    bytes32 internal constant H_SEI = keccak256(bytes("sei"));
    bytes32 internal constant H_ZKSYNC = keccak256(bytes("zksync"));

    function load(Vm vm_) internal view returns (TreasuryManagerChainConfig memory c) {
        bytes32 h = keccak256(bytes(vm_.envString("DEPLOY_CHAIN")));
        if (h == H_ETHEREUM) return TreasuryManagerConfigEthereum.get();
        if (h == H_BSC) return TreasuryManagerConfigBsc.get();
        if (h == H_POLYGON) return TreasuryManagerConfigPolygon.get();
        if (h == H_BASE) return TreasuryManagerConfigBase.get();
        if (h == H_ARBITRUM) return TreasuryManagerConfigArbitrum.get();
        if (h == H_LINEA) return TreasuryManagerConfigLinea.get();
        if (h == H_AVALANCHE) return TreasuryManagerConfigAvalanche.get();
        if (h == H_ZKSYNC) return TreasuryManagerConfigZksync.get();
        if (h == H_SEI) return TreasuryManagerConfigSei.get();
        if (h == H_OPTIMISM) return TreasuryManagerConfigOptimism.get();
        if (h == H_MONAD) return TreasuryManagerConfigMonad.get();
        revert("TreasuryManagerChainConfigRouter: unknown DEPLOY_CHAIN");
    }
}
