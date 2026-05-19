// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { TreasuryManager } from "../../../src/helpers/TreasuryManager.sol";
import { TreasuryManagerChainConfig } from "../TreasuryManagerChainTypes.sol";
import { TreasuryManagerChainSkeleton } from "../TreasuryManagerChainSkeleton.sol";
import { TreasuryManagerPairLimitBuilder as PairLimitBuilder } from "../TreasuryManagerPairLimitBuilder.sol";
import { TreasuryManagerChainBridgeDefaults } from "../TreasuryManagerChainBridgeDefaults.sol";

/// @dev Linea — example `pairLimits`; set protocol addresses before broadcast.
library TreasuryManagerConfigLinea {
    /// @dev Default max signed slippage / price impact for pair policies (1e18 = 1%). Same defaults as Ethereum config.
    uint120 internal constant DEFAULT_MAX_SLIPPAGE = 10e18;
    uint120 internal constant DEFAULT_MAX_PRICE_IMPACT = 10e18;

    address internal constant ETH = address(0);
    address internal constant WETH = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;
    address internal constant USDC = 0x176211869cA2b568f2A7D4EE941E073a821EE1ff;
    address internal constant USDT = 0xA219439258ca9da29E9Cc4cE5596924745e12B93;
    address internal constant DAI = 0x4AF15ec2A0BD43Db75dd04E62FAA3B8EF36b00d5;
    address internal constant WBTC = 0x3aAB2285ddcDdaD8edf438C1bAB47e1a9D05a9b4;

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
        c = TreasuryManagerChainSkeleton.base(59144, WETH);
        c.delegationManager = 0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3;
        c.metaSwap = 0x9dDA6Ef3D919c9bC8885D5560999A3640431e8e6;
        c.metaBridge = 0xE3d0d2607182Af5B24f5C3C2E4990A053aDd64e3;
        c.apiSigner = 0x24ddEB9245cbBDE6BC3dfd14AA7df88374C1e0fC; // Cubist Quote Signer
        c.allowedCallers = new address[](1);
        c.allowedCallers[0] = 0x8BfEB19507eec4C597538e0444253501166081De; // Cubist TX Signer
        c.pairLimits = _pairLimits();
        TreasuryManagerChainBridgeDefaults.applyStandardAllowlistsAndBridgeTopology(
            c, _sameChainDestWallets(), _bridgeDestWallets()
        );
    }

    function _pairLimits() private pure returns (TreasuryManager.PairLimitInput[] memory inputs_) {
        inputs_ = new TreasuryManager.PairLimitInput[](4);
        inputs_[0] = PairLimitBuilder.pair(ETH, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[1] = PairLimitBuilder.pair(USDT, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[2] = PairLimitBuilder.pair(DAI, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[3] = PairLimitBuilder.pair(WBTC, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
    }
}
