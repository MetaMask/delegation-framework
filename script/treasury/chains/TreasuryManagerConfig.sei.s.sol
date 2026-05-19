// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { TreasuryManager } from "../../../src/helpers/TreasuryManager.sol";
import { TreasuryManagerChainConfig } from "../TreasuryManagerChainTypes.sol";
import { TreasuryManagerChainSkeleton } from "../TreasuryManagerChainSkeleton.sol";
import { TreasuryManagerPairLimitBuilder as PairLimitBuilder } from "../TreasuryManagerPairLimitBuilder.sol";
import { TreasuryManagerChainBridgeDefaults } from "../TreasuryManagerChainBridgeDefaults.sol";

/// @dev Sei EVM (Pacific-1). Native gas token is SEI (`address(0)` in TreasuryManager policy keys).
///
///      `TreasuryManagerChainSkeleton.base(..., WSEI)` passes **wrapped native** into the manager’s `weth` immutable
///      (canonicalized with native `address(0)`). Bridged **Wrapped Ethereum** is a separate ERC-20 (`WETH` below).
library TreasuryManagerConfigSei {
    /// @dev Default max signed slippage / price impact for pair policies (1e18 = 1%). Same defaults as Ethereum config.
    uint120 internal constant DEFAULT_MAX_SLIPPAGE = 1e18;
    uint120 internal constant DEFAULT_MAX_PRICE_IMPACT = 1e18;

    /// @dev Pacific-1 EVM chain id (confirm against https://docs.sei.io when deploying).
    uint256 internal constant SEI_EVM_CHAIN_ID = 1329;

    /// @dev Native SEI — TreasuryManager uses `address(0)` for native balance / policy keys (same as ETH alias).
    address internal constant SEI_NATIVE = address(0);

    /// @dev Wrapped SEI — use as `base(..., WSEI)` wrapped-native parameter for `TreasuryManager`.
    address internal constant WSEI = 0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7;

    /// @dev Wrapped Ethereum (bridged ETH on Sei); not the chain native wrapper — do not substitute for `WSEI` in `base()`.
    address internal constant WETH = 0x160345fC359604fC6e70E3c5fAcbdE5F7A9342d8;

    /// @dev Noble USDC (USDC.n).
    address internal constant USDC_N = 0x3894085Ef7Ff0f0aeDf52E2A2704928d1Ec074F1;

    address internal constant USDC = 0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392;

    address internal constant USDT0 = 0x9151434b16b9763660705744891fA906F660EcC5;

    /// @dev USDT.kava.
    address internal constant USDT_KAVA = 0xB75D0B03c06A926e488e2659DF1A861F860bD3d1;

    address internal constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;

    /// @dev Synax Stablecoin (syUSD).
    address internal constant SYUSD = 0x059A6b0bA116c63191182a0956cF697d0d2213eC;

    address internal constant MILLI = 0x95597EB8D227a7c4B4f5E807a815C5178eE6dBE1;

    /// @dev DragonSwap (DRG).
    address internal constant DRG = 0x0a526e425809aEA71eb279d24ae22Dee6C92A4Fe;

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
        c = TreasuryManagerChainSkeleton.base(SEI_EVM_CHAIN_ID, WSEI);
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
        inputs_[0] = PairLimitBuilder.pair(SEI_NATIVE, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[1] = PairLimitBuilder.pair(USDC, SEI_NATIVE, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[2] = PairLimitBuilder.pair(WETH, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[3] = PairLimitBuilder.pair(USDT0, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[4] = PairLimitBuilder.pair(USDT0, SEI_NATIVE, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[5] = PairLimitBuilder.pair(WBTC, SEI_NATIVE, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[6] = PairLimitBuilder.pair(WBTC, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[7] = PairLimitBuilder.pair(WSEI, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
    }
}
