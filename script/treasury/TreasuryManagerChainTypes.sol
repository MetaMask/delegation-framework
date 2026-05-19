// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { TreasuryManager } from "../../src/helpers/TreasuryManager.sol";

/// @dev One `updateAllowedBridgeDestWallets` batch.
struct BridgeAddrBatch {
    uint256 destinationChainId;
    address[] addresses;
    bool[] statuses;
}

/// @dev All chain-local inputs for `DeployTreasuryManager`. Edit per-network files under `script/treasury/chains/`.
struct TreasuryManagerChainConfig {
    /// @dev Expected `block.chainId` for the RPC you broadcast on (script reverts on mismatch).
    uint256 evmChainId;
    address delegationManager;
    address metaSwap;
    address metaBridge;
    address weth;
    address apiSigner;
    address stEth;
    address wstEth;
    address[] allowedCallers;
    /// @dev Swap pair caps + `enabled` flag. Build entries with `TreasuryManagerPairLimitBuilder.pair`.
    TreasuryManager.PairLimitInput[] pairLimits;
    /// @dev Bridge route caps + `enabled` flag (per `(sourceTokenFrom, destinationChainId, destinationTokenTo)`).
    TreasuryManager.BridgeRouteLimitInput[] bridgeRouteLimits;
    /// @dev Same-chain `transfer` / `swap` / `wrapStEth` payout allowlist (`isDestWalletAllowed`).
    address[] allowedDestWallets;
    bool[] allowedDestWalletStatuses;
    uint256[] destinationChainIds;
    bool[] destinationChainStatuses;
    /// @dev Per-destination-chain bridge payout wallets (`isBridgeDestWalletAllowed`); not used for transfer/swap.
    BridgeAddrBatch[] bridgeDestWalletBatches;
}
