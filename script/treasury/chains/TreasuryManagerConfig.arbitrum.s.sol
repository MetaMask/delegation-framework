// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { TreasuryManager } from "../../../src/helpers/TreasuryManager.sol";
import { TreasuryManagerChainConfig } from "../TreasuryManagerChainTypes.sol";
import { TreasuryManagerChainSkeleton } from "../TreasuryManagerChainSkeleton.sol";
import { TreasuryManagerPairLimitBuilder as PairLimitBuilder } from "../TreasuryManagerPairLimitBuilder.sol";
import { TreasuryManagerChainBridgeDefaults } from "../TreasuryManagerChainBridgeDefaults.sol";

/// @dev Arbitrum One (chain id 42161). Native asset is ETH (`address(0)` in TreasuryManager policy keys).
///      `base(..., WETH)` supplies canonical wrapped Ether for the manager’s `weth` immutable (aliases with `address(0)`).
///      `USDC_E` and `ARB` are included for allowlists / extra pairs; eight pairs are seeded in `_pairLimits`.
library TreasuryManagerConfigArbitrum {
    /// @dev Default max signed slippage / price impact for pair policies (1e18 = 1%). Same defaults as Ethereum config.
    uint120 internal constant DEFAULT_MAX_SLIPPAGE = 1e18;
    uint120 internal constant DEFAULT_MAX_PRICE_IMPACT = 1e18;

    uint256 internal constant ARBITRUM_ONE_CHAIN_ID = 42161;

    /// @dev Native ETH.
    address internal constant ETH = address(0);

    /// @dev Wrapped Ether — passed to `TreasuryManagerChainSkeleton.base` as wrapped native.
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    address internal constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    address internal constant CB_BTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    /// @dev Bridged USDC.e.
    address internal constant USDC_E = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;

    /// @dev Native USDC on Arbitrum One.
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    address internal constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;

    address internal constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    address internal constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;

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
        c = TreasuryManagerChainSkeleton.base(ARBITRUM_ONE_CHAIN_ID, WETH);
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
        inputs_[5] = PairLimitBuilder.pair(DAI, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[6] = PairLimitBuilder.pair(DAI, ETH, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[7] = PairLimitBuilder.pair(CB_BTC, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
    }
}
