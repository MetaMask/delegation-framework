// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { TreasuryManager } from "../../../src/helpers/TreasuryManager.sol";
import { TreasuryManagerChainConfig } from "../TreasuryManagerChainTypes.sol";
import { TreasuryManagerChainSkeleton } from "../TreasuryManagerChainSkeleton.sol";
import { TreasuryManagerPairLimitBuilder as PairLimitBuilder } from "../TreasuryManagerPairLimitBuilder.sol";
import { TreasuryManagerChainBridgeDefaults } from "../TreasuryManagerChainBridgeDefaults.sol";

/// @dev Ethereum mainnet — set protocol addresses before broadcast. Default pair caps (edit later): 1e18 / 1e18.
library TreasuryManagerConfigEthereum {
    /// @dev Default max signed slippage / price impact (1e18 = 1%). Replace per pair in `_pairLimits` when ready.
    uint120 internal constant DEFAULT_MAX_SLIPPAGE = 1e18;
    uint120 internal constant DEFAULT_MAX_PRICE_IMPACT = 1e18;

    // Ether — native (canonicalized with WETH for policy keys; use ETH→USDC only, not WETH→USDC).
    address internal constant ETH = address(0);
    // Wrapped BTC
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    // Coinbase Wrapped BTC
    address internal constant CB_BTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    // USDS Stablecoin
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    // Dai Stablecoin
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    // USD Coin
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // Gemini dollar
    address internal constant GUSD = 0x056Fd409E1d7A124BD7017459dFEa2F387b6d5Cd;
    // Uniswap
    address internal constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    // Maker Token
    address internal constant MKR = 0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2;
    // Aave Token
    address internal constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    // Compound
    address internal constant COMP = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    // Synthetix Network Token
    address internal constant SNX = 0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F;
    // SushiToken
    address internal constant SUSHI = 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2;
    // 0x Protocol Token
    address internal constant ZRX = 0xE41d2489571d322189246DaFA5ebDe1F4699F498;
    // Curve DAO Token
    address internal constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    // yearn.finance
    address internal constant YFI = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
    // Balancer
    address internal constant BAL = 0xba100000625a3754423978a60c9317c58a424e3D;
    // ChainLink Token
    address internal constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    // Polygon Token
    address internal constant POL = 0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6;
    // Matic Token
    address internal constant MATIC = 0x7D1AfA7B718fb893dB30A3aBc0Cfc608AaCfeBB0;
    // Wrapped Ether
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // renBTC
    address internal constant REN_BTC = 0xEB4C2781e4ebA804CE9a9803C67d0893436bB27D;
    // Compound Dai
    address internal constant CDAI = 0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643;
    // TrueUSD
    address internal constant TUSD = 0x0000000000085d4780B73119b644AE5ecd22b376;
    // Binance USD
    address internal constant BUSD = 0x4Fabb145d64652a948d72533023f6E7A623C7C53;
    // Paxos Standard
    address internal constant PAX = 0x8E870D67F660D95d5be530380D0eC0bd388289E1;
    // Ampleforth
    address internal constant AMPL = 0xD46bA6D942050d489DBd938a2C909A5d5039A161;
    // Liquity USD
    address internal constant LUSD = 0x5f98805A4E8be255a32880FDeC7F6728C6568bA0;
    // Celsius
    address internal constant CEL = 0xaaAEBE6Fe48E54f431b0C390CfaF0b017d09D42d;
    // Bancor Network Token
    address internal constant BNT = 0x1F573D6Fb3F13d689FF844B4cE37794d79a7FF1C;
    // 1INCH Token
    address internal constant ONE_INCH = 0x111111111117dC0aa78b770fA6A738034120C302;
    // Republic Token
    address internal constant REN = 0x408e41876cCCDC0F92210600ef50372656052a38;
    // Fantom Token
    address internal constant FTM = 0x4E15361FD6b4BB609Fa63C81A2be19d873717870;
    // Cream
    address internal constant CREAM = 0x2ba592F78dB6436527729929AAf6c908497cB200;
    // Decentraland MANA
    address internal constant MANA = 0x0F5D2fB29fb7d3CFeE444a200298f468908cC942;
    // Graph Token
    address internal constant GRT = 0xc944E90C64B2c07662A292be6244BDf05Cda44a7;
    // Basic Attention Token
    address internal constant BAT = 0x0D8775F648430679A709E98d2b0Cb6250d2887EF;
    // OMG Network Token
    address internal constant OMG = 0xd26114cd6EE289AccF82350c8d8487fedB8A0C07;
    // FTX Token
    address internal constant FTT = 0x50D1c9771902476076eCFc8B2A83Ad6b9355a4c9;
    // HEX
    address internal constant HEX = 0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39;
    // Quant
    address internal constant QNT = 0x4a220E6096B25EADb88358cb44068A3248254675;
    // Telcoin
    address internal constant TEL = 0x467Bccd9d29f223BcE8043b84E8C8B282827790F;
    // WOO Network
    address internal constant WOO = 0x4691937a7508860F876c9c0a2a617E7d9E945D4B;
    // DeFi Pulse Index
    address internal constant DPI = 0x1494CA1F11D487c2bBe4543E90080AeBa4BA3C2b;
    // Axie Infinity
    address internal constant AXS = 0xBB0E17EF65F82Ab018d8EDd776e8DD940327B28b;
    // Augur
    address internal constant REP = 0x1985365e9f78359a9B6AD760e32412f4a445E862;
    // Smooth Love Potion
    address internal constant SLP = 0xCC8Fa225D80b9c7D42F96e9570156c65D6cAAa25;
    // Lido DAO Token
    address internal constant LDO = 0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32;
    // Tether USD
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    // The Sandbox
    address internal constant SAND = 0x3845badAde8e6dFF049820680d1F14bD3903a5d0;
    // Gala
    address internal constant GALA = 0x15D4c048F83bd7e37d49eA4C83a07267Ec4203dA;
    // Spell Token
    address internal constant SPELL = 0x090185f2135308BaD17527004364eBcC2D37e5F6;
    // Shiba Inu
    address internal constant SHIB = 0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE;
    // Ethereum Name Service
    address internal constant ENS = 0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72;
    // Strong
    address internal constant STRONG = 0x990f341946A3fdB507aE7e52d17851B87168017c;
    // Reserve Rights
    address internal constant RSR = 0x8762db106B2c2A0bccB3A80d1Ed41273552616E8;
    // UFO Gaming
    address internal constant UFO = 0x249e38Ea4102D0cf8264d3701f1a0E39C4f2DC3B;
    // Merit Circle
    address internal constant MC = 0x949D48EcA67b17269629c7194F4b727d4Ef9E5d6;
    // Lido Staked ETH
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    // Wrapped Lido Staked ETH
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

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
        c = TreasuryManagerChainSkeleton.base(1, WETH);
        c.stEth = STETH;
        c.wstEth = WSTETH;
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

    /// @dev Every listed asset → USDC with default caps (no `WETH`→USDC row: same policy key as `ETH`→USDC after canon).
    function _pairLimits() private pure returns (TreasuryManager.PairLimitInput[] memory inputs_) {
        inputs_ = new TreasuryManager.PairLimitInput[](58);
        uint256 p;
        inputs_[p++] = PairLimitBuilder.pair(ETH, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(WBTC, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(CB_BTC, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(USDS, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(DAI, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(GUSD, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(UNI, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(MKR, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(AAVE, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(COMP, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(SNX, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(SUSHI, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(ZRX, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(CRV, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(YFI, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(BAL, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(LINK, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(POL, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(MATIC, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(REN_BTC, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(CDAI, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(TUSD, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(BUSD, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(PAX, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(AMPL, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(LUSD, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(CEL, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(BNT, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(ONE_INCH, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(REN, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(FTM, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(CREAM, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(MANA, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(GRT, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(BAT, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(OMG, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(FTT, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(HEX, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(QNT, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(TEL, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(WOO, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(DPI, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(AXS, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(REP, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(SLP, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(LDO, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(USDT, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(SAND, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(GALA, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(SPELL, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(SHIB, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(ENS, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(STRONG, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(RSR, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(UFO, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(MC, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(STETH, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
        inputs_[p++] = PairLimitBuilder.pair(WSTETH, USDC, DEFAULT_MAX_SLIPPAGE, DEFAULT_MAX_PRICE_IMPACT);
    }
}
