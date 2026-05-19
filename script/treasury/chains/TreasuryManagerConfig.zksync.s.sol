// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { TreasuryManager } from "../../../src/helpers/TreasuryManager.sol";
import { TreasuryManagerChainConfig } from "../TreasuryManagerChainTypes.sol";
import { TreasuryManagerChainSkeleton } from "../TreasuryManagerChainSkeleton.sol";
import { TreasuryManagerPairLimitBuilder as PairLimitBuilder } from "../TreasuryManagerPairLimitBuilder.sol";
import { TreasuryManagerChainBridgeDefaults } from "../TreasuryManagerChainBridgeDefaults.sol";

/// @dev zkSync Era (chain id 324). Native ETH for TreasuryManager policies uses `address(0)` (`ETH` below).
///      `base(..., WETH)` passes canonical wrapped Ether for the manager’s `weth` immutable (aliases with `address(0)`).
///      `ETH_L2` (`0x…800A`) is the zkSync Era L2 ETH token address from your list — kept for integrations / reference;
///      `_pairLimits` uses `ETH` (`address(0)`) for native routes only.
library TreasuryManagerConfigZksync {
    /// @dev Default max signed slippage / price impact for pair policies (1e18 = 1%). Same defaults as Ethereum config.
    uint120 internal constant DEFAULT_MAX_SLIPPAGE = 1e18;
    uint120 internal constant DEFAULT_MAX_PRICE_IMPACT = 1e18;

    uint256 internal constant ZKSYNC_ERA_CHAIN_ID = 324;

    /// @dev Native ETH (`address(0)`).
    address internal constant ETH = address(0);

    /// @dev zkSync Era “Ether” / L2 ETH representation (`0x…800A`), distinct from `address(0)` in your source list.
    address internal constant ETH_L2 = 0x000000000000000000000000000000000000800A;

    /// @dev Wrapped Ether — passed to `TreasuryManagerChainSkeleton.base` as wrapped native.
    address internal constant WETH = 0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91;

    address internal constant WBTC = 0xBBeB516fb02a01611cBBE0453Fe3c580D7281011;

    /// @dev Bridged USDC (USDC.e-style).
    address internal constant USDC_E = 0x3355df6D4c9C3035724Fd0e3914dE96A5a83aaf4;

    address internal constant USDT = 0x493257fD37EDB34451f62EDf8D2a0C418852bA4C;

    /// @dev Native USDC on zkSync Era.
    address internal constant USDC = 0x1d17CBcF0D6D143135aE902365D2E5e2A16538D4;

    /// @dev `transfer` / `swap` / `wrapStEth` payout allowlist (`isDestWalletAllowed`). Edit before broadcast.
    function _sameChainDestWallets() private pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = 0x3EFC72fF137A5603Ce2E7108a70e56CAb49bf1e2;
    }

    /// @dev Bridge signed-destination allowlist for Ethereum (`isBridgeDestWalletAllowed[1]`). Edit before broadcast.
    function _bridgeDestWallets() private pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = 0x3EFC72fF137A5603Ce2E7108a70e56CAb49bf1e2;
    }

    function get() internal pure returns (TreasuryManagerChainConfig memory c) {
        c = TreasuryManagerChainSkeleton.base(ZKSYNC_ERA_CHAIN_ID, WETH);
        // `DeployTreasuryManager` — REQUIRED before `--broadcast` on this chain: uncomment each line and set addresses.
        // c.delegationManager = address(0);
        // c.metaSwap = address(0);
        // c.metaBridge = address(0);
        // c.apiSigner = address(0);
        // Optional: relayer EOAs/contracts for `transfer` / `swap` / `bridge` / `wrapStEth`. Omit block to configure later via
        // owner. c.allowedCallers = new address[](1);
        // c.allowedCallers[0] = address(0);
        c.pairLimits = _pairLimits();
        TreasuryManagerChainBridgeDefaults.applyStandardAllowlistsAndBridgeTopology(c, _sameChainDestWallets(), _bridgeDestWallets());
    }

    /// @dev Pair policies use `DEFAULT_MAX_SLIPPAGE` / `DEFAULT_MAX_PRICE_IMPACT`; tune per pair later if needed.
    function _pairLimits() private pure returns (TreasuryManager.PairLimitInput[] memory inputs_) {
        inputs_ = new TreasuryManager.PairLimitInput[](8);
        inputs_[0] = PairLimitBuilder.pair(ETH, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[1] = PairLimitBuilder.pair(USDC, ETH, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[2] = PairLimitBuilder.pair(WBTC, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[3] = PairLimitBuilder.pair(USDT, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[4] = PairLimitBuilder.pair(USDT, ETH, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[5] = PairLimitBuilder.pair(WBTC, ETH, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[6] = PairLimitBuilder.pair(ETH, USDC_E, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[7] = PairLimitBuilder.pair(USDC_E, ETH, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
    }
}
