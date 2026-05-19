// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { TreasuryManager } from "../../../src/helpers/TreasuryManager.sol";
import { TreasuryManagerChainConfig } from "../TreasuryManagerChainTypes.sol";
import { TreasuryManagerChainSkeleton } from "../TreasuryManagerChainSkeleton.sol";
import { TreasuryManagerPairLimitBuilder as PairLimitBuilder } from "../TreasuryManagerPairLimitBuilder.sol";
import { TreasuryManagerChainBridgeDefaults } from "../TreasuryManagerChainBridgeDefaults.sol";

/// @dev Optimism (OP Mainnet, chain id 10). Native asset is ETH (`address(0)` in TreasuryManager policy keys).
///      `base(..., WETH)` supplies canonical wrapped Ether for the manager’s `weth` immutable (aliases with `address(0)`).
///      Constants `USDC_E`, `sUSD` are included for allowlists / extra pairs; eight pairs are seeded in `_pairLimits`.
library TreasuryManagerConfigOptimism {
    /// @dev Default max signed slippage / price impact for pair policies (1e18 = 1%). Same defaults as Ethereum config.
    uint120 internal constant DEFAULT_MAX_SLIPPAGE = 1e18;
    uint120 internal constant DEFAULT_MAX_PRICE_IMPACT = 1e18;

    uint256 internal constant OPTIMISM_CHAIN_ID = 10;

    /// @dev Native ETH.
    address internal constant ETH = address(0);

    /// @dev Wrapped Ether — passed to `TreasuryManagerChainSkeleton.base` as wrapped native.
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    address internal constant WBTC = 0x68f180fcCe6836688e9084f035309E29Bf0A2095;

    /// @dev Bridged USDC.e (legacy bridged USDC).
    address internal constant USDC_E = 0x7F5c764cBc14f9669B88837ca1490cCa17c31607;

    address internal constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;

    address internal constant SUSD = 0x8c6f28f2F1A3C87F0f938b96d27520d9751ec8d9;

    /// @dev Optimism (OP) governance token.
    address internal constant OP = 0x4200000000000000000000000000000000000042;

    address internal constant USDT = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;

    /// @dev Native USDC (Circle native issuance on OP).
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

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
        c = TreasuryManagerChainSkeleton.base(OPTIMISM_CHAIN_ID, WETH);
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
        inputs_[7] = PairLimitBuilder.pair(OP, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
    }
}
