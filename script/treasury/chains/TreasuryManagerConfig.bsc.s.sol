// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { TreasuryManager } from "../../../src/helpers/TreasuryManager.sol";
import { TreasuryManagerChainConfig } from "../TreasuryManagerChainTypes.sol";
import { TreasuryManagerChainSkeleton } from "../TreasuryManagerChainSkeleton.sol";
import { TreasuryManagerPairLimitBuilder as PairLimitBuilder } from "../TreasuryManagerPairLimitBuilder.sol";
import { TreasuryManagerChainBridgeDefaults } from "../TreasuryManagerChainBridgeDefaults.sol";

/// @dev BNB Smart Chain (chain id 56). Native gas token is BNB (`address(0)` in TreasuryManager policy keys).
///      `base(..., WBNB)` supplies wrapped native for the manager’s `weth` immutable (aliases with `address(0)`).
library TreasuryManagerConfigBsc {
    /// @dev Default max signed slippage / price impact for pair policies (1e18 = 1%). Same defaults as Ethereum config.
    uint120 internal constant DEFAULT_MAX_SLIPPAGE = 1e18;
    uint120 internal constant DEFAULT_MAX_PRICE_IMPACT = 1e18;

    uint256 internal constant BSC_CHAIN_ID = 56;

    /// @dev Native BNB (TreasuryManager native alias).
    address internal constant BNB_NATIVE = address(0);

    /// @dev Wrapped BNB — passed to `TreasuryManagerChainSkeleton.base` as wrapped native.
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    /// @dev Bridged Ethereum (ERC-20 ETH on BSC).
    address internal constant ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;

    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    address internal constant DAI = 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3;

    address internal constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;

    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    address internal constant ASTER = 0x000Ae314E2A2172a039B26378814C252734f556A;

    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    address internal constant MATIC = 0xCC42724C6683B7E57334c4E856f4c9965ED682bD;

    address internal constant AVAX = 0x1CE0c2827e2eF14D5C4f29a091d735A204794041;

    address internal constant APX = 0x78F5d389F5CDCcFc41594aBaB4B0Ed02F31398b3;

    address internal constant USDF = 0x5A110fC00474038f6c02E89C707D638602EA44B5;

    address internal constant STBL = 0x8dEdf84656fa932157e27C060D8613824e7979e3;

    address internal constant SOL = 0x570A5D26f7765Ecb712C0924E4De545B89fD43dF;

    address internal constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;

    address internal constant JMPT = 0x88D7e9B65dC24Cf54f5eDEF929225FC3E1580C25;

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
        c = TreasuryManagerChainSkeleton.base(BSC_CHAIN_ID, WBNB);
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
        inputs_[0] = PairLimitBuilder.pair(BNB_NATIVE, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[1] = PairLimitBuilder.pair(USDC, BNB_NATIVE, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[2] = PairLimitBuilder.pair(ETH, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[3] = PairLimitBuilder.pair(USDT, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[4] = PairLimitBuilder.pair(USDT, BNB_NATIVE, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[5] = PairLimitBuilder.pair(DAI, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[6] = PairLimitBuilder.pair(DAI, BNB_NATIVE, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[7] = PairLimitBuilder.pair(CAKE, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
    }
}
