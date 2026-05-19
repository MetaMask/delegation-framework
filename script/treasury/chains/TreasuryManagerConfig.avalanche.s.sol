// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { TreasuryManager } from "../../../src/helpers/TreasuryManager.sol";
import { TreasuryManagerChainConfig } from "../TreasuryManagerChainTypes.sol";
import { TreasuryManagerChainSkeleton } from "../TreasuryManagerChainSkeleton.sol";
import { TreasuryManagerPairLimitBuilder as PairLimitBuilder } from "../TreasuryManagerPairLimitBuilder.sol";
import { TreasuryManagerChainBridgeDefaults } from "../TreasuryManagerChainBridgeDefaults.sol";

/// @dev Avalanche C-Chain (chain id 43114). Native gas token is AVAX (`address(0)` in TreasuryManager policy keys).
///      `base(..., WAVAX)` supplies wrapped native for the manager’s `weth` immutable (aliases with `address(0)`).
///      Constants `USDC_E`, `DAI_E`, `BUSD`, `USD_T` are included as your source-of-truth addresses for allowlists /
///      extra pairs; only eight pairs are seeded in `_pairLimits`.
library TreasuryManagerConfigAvalanche {
    /// @dev Default max signed slippage / price impact for pair policies (1e18 = 1%). Same defaults as Ethereum config.
    uint120 internal constant DEFAULT_MAX_SLIPPAGE = 1e18;
    uint120 internal constant DEFAULT_MAX_PRICE_IMPACT = 1e18;

    uint256 internal constant AVALANCHE_C_CHAIN_ID = 43114;

    /// @dev Native AVAX.
    address internal constant AVAX_NATIVE = address(0);

    /// @dev Wrapped AVAX — passed to `TreasuryManagerChainSkeleton.base` as wrapped native.
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    /// @dev Wrapped ETH (bridged).
    address internal constant WETH_E = 0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB;

    /// @dev Wrapped BTC (bridged).
    address internal constant WBTC_E = 0x50b7545627a5162F82A992c33b87aDc75187B218;

    /// @dev Native USDC on Avalanche.
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;

    /// @dev Bridged USDC.e.
    address internal constant USDC_E = 0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664;

    /// @dev Bridged DAI.e.
    address internal constant DAI_E = 0xd586E7F844cEa2F87f50152665BCbc2C279D8d70;

    /// @dev DAI (native deployment on C-Chain).
    address internal constant DAI = 0xbA7dEebBFC5fA1100Fb055a87773e1E99Cd3507a;

    address internal constant BUSD = 0x19860CCB0A68fd4213aB9D8266F7bBf05A8dDe98;

    /// @dev Bridged USDT.e.
    address internal constant USDT_E = 0xc7198437980c041c805A1EDcbA50c1Ce5db95118;

    /// @dev Tether Token (USDt).
    address internal constant USD_T = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;

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
        c = TreasuryManagerChainSkeleton.base(AVALANCHE_C_CHAIN_ID, WAVAX);
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
        inputs_[0] = PairLimitBuilder.pair(AVAX_NATIVE, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[1] = PairLimitBuilder.pair(USDC, AVAX_NATIVE, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[2] = PairLimitBuilder.pair(WETH_E, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[3] = PairLimitBuilder.pair(USDT_E, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[4] = PairLimitBuilder.pair(USDT_E, AVAX_NATIVE, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[5] = PairLimitBuilder.pair(DAI, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[6] = PairLimitBuilder.pair(DAI, AVAX_NATIVE, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[7] = PairLimitBuilder.pair(WBTC_E, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
    }
}
