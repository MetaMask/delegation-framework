// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { TreasuryManagerChainConfig, BridgeAddrBatch } from "./TreasuryManagerChainTypes.sol";

/// @dev Minimal bridge topology for treasury deploy configs: **Ethereum (chain id 1) only** as destination chain and
///      payout-wallet allowlist. Output-token gating is enforced per route via `bridgeRouteLimits` configured separately
///      in each chain file. Pass same-chain and bridge wallet lists explicitly from each `TreasuryManagerConfig*.s.sol`
///      (e.g. `_sameChainDestWallets()` and `_bridgeDestWallets()`).
library TreasuryManagerChainBridgeDefaults {
    error EmptySameChainDestWallets();
    error EmptyBridgeDestWallets();

    uint256 internal constant DEST_ETHEREUM = 1;

    /// @param sameChainDestWallets_ Non-empty list for `isDestWalletAllowed` (transfer / swap / wrapStEth payouts).
    /// @param bridgeDestWallets_ Non-empty list for `isBridgeDestWalletAllowed[DEST_ETHEREUM]` (signed bridge dest).
    function applyStandardAllowlistsAndBridgeTopology(
        TreasuryManagerChainConfig memory c,
        address[] memory sameChainDestWallets_,
        address[] memory bridgeDestWallets_
    )
        internal
        pure
    {
        if (sameChainDestWallets_.length == 0) revert EmptySameChainDestWallets();
        if (bridgeDestWallets_.length == 0) revert EmptyBridgeDestWallets();
        _apply(c, sameChainDestWallets_, bridgeDestWallets_);
    }

    function _apply(
        TreasuryManagerChainConfig memory c,
        address[] memory sameChainDestWallets_,
        address[] memory bridgeDestWallets_
    )
        private
        pure
    {
        uint256 nSame_ = sameChainDestWallets_.length;
        uint256 nBridge_ = bridgeDestWallets_.length;

        c.destinationChainIds = new uint256[](1);
        c.destinationChainIds[0] = DEST_ETHEREUM;
        c.destinationChainStatuses = new bool[](1);
        c.destinationChainStatuses[0] = true;

        c.allowedDestWallets = sameChainDestWallets_;
        c.allowedDestWalletStatuses = _allTrue(nSame_);

        c.bridgeDestWalletBatches = new BridgeAddrBatch[](1);
        c.bridgeDestWalletBatches[0].destinationChainId = DEST_ETHEREUM;
        c.bridgeDestWalletBatches[0].addresses = bridgeDestWallets_;
        c.bridgeDestWalletBatches[0].statuses = _allTrue(nBridge_);
    }

    function _allTrue(uint256 n_) private pure returns (bool[] memory st_) {
        st_ = new bool[](n_);
        for (uint256 i_; i_ < n_; ++i_) {
            st_[i_] = true;
        }
    }
}
