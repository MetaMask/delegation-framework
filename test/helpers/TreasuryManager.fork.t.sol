// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * Fork tests driven by `test/helpers/resources/MetaSwapAndMetaBridgeQuotes.json`.
 *
 * Delegation redemption uses the **deployed** MetaMask Delegation Toolkit contracts from `documents/Deployments.md`
 * (same deterministic addresses on supported chains). **Important:** `BaseTest.setUp()` deploys a *local*
 * `DelegationManager` and a *new* `HybridDeleGator` implementation, so immutables do not match the fork. After
 * `createSelectFork`, `_initHarnessAfterFork` calls `super.setUp()` then rebinds `entryPoint`, `delegationManager`, and
 * `hybridDeleGatorImpl` to the on-chain deployment (same idea as `DelegationMetaSwapAdapterForkTest._setUpForkContracts`)
 * and runs `_createUsers()` again so ERC-1967 proxies use the deployed Hybrid implementation.
 *
 * Required RPC env vars for each quoted `srcChainId` (unset → `ForkRpcUrlUnset`): `MAINNET_RPC_URL`, `LINEA_RPC_URL`,
 * `POLYGON_RPC_URL`, `BASE_RPC_URL`. Foundry loads `.env` from the project root when present.
 *
 * Swap output checks: `request.slippagePercentE18` matches `TreasuryManager` (1e18 = 1%). Minimum acceptable
 * destination tokens = `destTokenAmount * (MAX_PERCENT - slippage) / MAX_PERCENT` vs `bestQuote.destTokenAmount`.
 *
 * MetaSwap / MetaBridge contract addresses per chain come from `test/helpers/resources/MetaSwapAndMetaBridgeAddresses.json`
 * (`_metaSwapAt` / `_metaBridgeAt`).
 *
 * **Funding test balances:** `deal(token, alice, amount)` uses Forge stdstore to locate `balanceOf` storage. Tokens with
 * non-standard balance layout break that lookup: Circle FiatToken (native USDC on Polygon / Base, behind proxies) triggers
 * `stdStorage find(StdStorage): Slot(s) not found`, and Lido stETH derives `balanceOf` from shares so no direct slot exists.
 * `_dealErc20ToAlice` handles these cases by impersonating a known whale (Aave V3 aUSDC aToken for Polygon / Base USDC;
 * wstETH contract for mainnet stETH) and `transfer`-ing the amount to Alice's deleGator.
 */

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { BaseTest } from "../utils/BaseTest.t.sol";
import { Implementation, SignatureType, TestUser } from "../utils/Types.t.sol";
import { Caveat, Delegation } from "../../src/utils/Types.sol";
import { DelegationManager } from "../../src/DelegationManager.sol";
import { TreasuryManager } from "../../src/helpers/TreasuryManager.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { IMetaBridge } from "../../src/helpers/interfaces/IMetaBridge.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";
import { HybridDeleGator } from "../../src/HybridDeleGator.sol";

contract TreasuryManagerForkTest is BaseTest {
    using stdJson for string;
    using Strings for uint256;

    error ForkRpcUrlUnset(string envVar);

    // --- Deployed toolkit (see documents/Deployments.md) ---
    /// @dev `documents/Deployments.md` v1.3.0 — deterministic across chains.
    address internal constant DELEGATION_MANAGER_DEPLOYED = 0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3;
    /// @dev ERC-4337 v0.6 EntryPoint (same address on chains where these fork tests run).
    EntryPoint internal constant ENTRY_POINT_DEPLOYED = EntryPoint(payable(0x0000000071727De22E5E9d8BAf0edAc6f37da032));
    /// @dev On-chain Hybrid implementation — immutables must match `DELEGATION_MANAGER_DEPLOYED`.
    HybridDeleGator internal constant HYBRID_DELEGATOR_IMPL_DEPLOYED =
        HybridDeleGator(payable(0x48dBe696A4D990079e039489bA2053B36E8FFEC4));
    address internal constant REDEEMER_ENFORCER_DEPLOYED = 0xE144b0b2618071B4E56f746313528a669c7E65c5;
    address internal constant ERC20_TRANSFER_AMOUNT_ENFORCER_DEPLOYED = 0xf100b0819427117EcF76Ed94B358B1A5b5C6D2Fc;
    address internal constant NATIVE_TRANSFER_AMOUNT_ENFORCER_DEPLOYED = 0xF71af580b9c3078fbc2BBF16FbB8EEd82b330320;

    string internal constant MetaSwapAndMetaBridgeQuotes = "test/helpers/resources/MetaSwapAndMetaBridgeQuotes.json";
    string internal constant ROUTER_ADDRESSES_JSON = "test/helpers/resources/MetaSwapAndMetaBridgeAddresses.json";

    /// @dev Loaded in `_initHarnessAfterFork` — MetaSwap / MetaBridge per chain id from `ROUTER_ADDRESSES_JSON`.
    string internal routerAddressesJson;

    // --- Scenario indices (`MetaSwapAndMetaBridgeQuotes.json` → `scenarios[]`) ---
    uint256 internal constant SC_SWAP_ETH_USDC = 0;
    uint256 internal constant SC_SWAP_WETH_USDC = 1;
    /// @dev Wrap flow; no MetaMask bridge API quote consumed. `forkContext.srcBlockNumber` still pins the fork height.
    uint256 internal constant SC_WRAP_STETH_WSTETH = 2;
    uint256 internal constant SC_SWAP_DAI_USDC = 3;
    uint256 internal constant SC_SWAP_LINEA_DAI_USDC = 4;
    uint256 internal constant SC_BRIDGE_LINEA_USDC_ETH = 5;
    uint256 internal constant SC_BRIDGE_POLYGON_USDC_ETH = 6;
    uint256 internal constant SC_BRIDGE_LINEA_ETH_ETH = 7;
    uint256 internal constant SC_BRIDGE_BASE_USDC_ETH = 8;
    uint256 internal constant SC_SWAP_WSTETH_USDC = 9;

    // --- Canonical tokens (quoted chains) ---
    address internal constant WETH_MAINNET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC_MAINNET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant STETH_MAINNET = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH_MAINNET = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant DAI_MAINNET = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address internal constant WETH_LINEA = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;

    address internal constant WETH_POLYGON = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;

    address internal constant WETH_BASE = 0x4200000000000000000000000000000000000006;

    /// @dev Circle native USDC on Polygon PoS / Base — Forge `deal` often cannot resolve `balanceOf` storage slots.
    address internal constant NATIVE_USDC_POLYGON = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address internal constant NATIVE_USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @dev USDC whales for `deal` fallback funding. The Aave V3 aUSDC aTokens custody the underlying
    ///      USDC deposited into the pool, so their `balanceOf(aToken)` on the underlying ERC20 stays high
    ///      (millions of USDC) and tracks total deposits rather than idle reserves.
    address internal constant USDC_WHALE_POLYGON = 0xA4D94019934D8333Ef880ABFFbF2FDd611C762BD; // aUSDC (Aave V3 Polygon)
    address internal constant USDC_WHALE_BASE = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB; // aUSDC (Aave V3 Base)

    address internal constant BRIDGE_DEST_FROM_QUOTES = 0x3EFC72fF137A5603Ce2E7108a70e56CAb49bf1e2;

    // --- Harness ---
    TreasuryManager internal treasury;

    address internal forkOwner = makeAddr("forkOwner");
    address internal caller = makeAddr("forkCaller");
    address internal destSwap = makeAddr("forkDestSwap");

    uint256 internal signerPk;
    address internal apiSigner;

    constructor() {
        IMPLEMENTATION = Implementation.Hybrid;
        SIGNATURE_TYPE = SignatureType.RawP256;
    }

    /// @dev Fork tests select chain/block themselves; avoid running `BaseTest.setUp` on the wrong chain.
    function setUp() public override { }

    // ==================== Ethereum mainnet (`forkContext.srcChainId == 1`) ====================

    function testFork_mainnet_swap_ETH_to_USDC_scenario0() public {
        string memory json = _readQuotesForkAndInitHarness(SC_SWAP_ETH_USDC);

        _deployMainnetTreasury();
        _configureSwapActor(destSwap);
        _ownerAllowSwapPair(IERC20(address(0)), IERC20(USDC_MAINNET));

        (IERC20 tokenFrom, uint256 amount, bytes memory tradeData) = _readSwapPullAndTrade(json, SC_SWAP_ETH_USDC);
        assertEq(address(tokenFrom), address(0));

        vm.deal(address(users.alice.deleGator), amount);

        TreasuryManager.SignatureData memory sig = _signTreasuryApi(json, SC_SWAP_ETH_USDC, tradeData, destSwap);

        Delegation[] memory delegations_ = _pullDelegations(address(treasury), users.alice, tokenFrom, amount, true);

        vm.startPrank(caller);
        treasury.swap(sig, delegations_);
        vm.stopPrank();
    }

    function testFork_mainnet_swap_WETH_to_USDC_scenario1() public {
        string memory json = _readQuotesForkAndInitHarness(SC_SWAP_WETH_USDC);

        _deployMainnetTreasury();
        _configureSwapActor(destSwap);
        _ownerAllowSwapPair(IERC20(WETH_MAINNET), IERC20(USDC_MAINNET));

        (IERC20 tokenFrom, uint256 amount, bytes memory tradeData) = _readSwapPullAndTrade(json, SC_SWAP_WETH_USDC);

        deal(address(tokenFrom), address(users.alice.deleGator), amount);

        TreasuryManager.SignatureData memory sig = _signTreasuryApi(json, SC_SWAP_WETH_USDC, tradeData, destSwap);

        Delegation[] memory delegations_ = _pullDelegations(address(treasury), users.alice, tokenFrom, amount, false);

        uint256 usdcBefore = IERC20(USDC_MAINNET).balanceOf(destSwap);
        vm.prank(caller);
        treasury.swap(sig, delegations_);
        uint256 received = IERC20(USDC_MAINNET).balanceOf(destSwap) - usdcBefore;

        uint256 quotedOut = json.readUint(_key(SC_SWAP_WETH_USDC, "bestQuote.destTokenAmount"));
        assertGe(received, _minDestAfterSlippage(json, SC_SWAP_WETH_USDC, quotedOut));
    }

    /// @dev `swap(stETH, ...)` would always fail 1-wei-short because `_redeemTransfer` uses
    ///      `expectedAmount_ == transferAmount_` and stETH's share math rounds down. `wrapStEth`
    ///      is the intended path: it allows any under-credit (expected = 0) and wraps whatever
    ///      arrived to wstETH before forwarding. No MetaMask API quote is consumed.
    function testFork_mainnet_wrapStEth_to_wstETH_scenario2() public {
        string memory json = _readQuotesForkAndInitHarness(SC_WRAP_STETH_WSTETH);

        _deployMainnetTreasury();

        vm.startPrank(forkOwner);
        treasury.updateAllowedCallers(_singleAddr(caller), _singleBool(true));
        treasury.updateAllowedDestWallets(_singleAddr(destSwap), _singleBool(true));
        vm.stopPrank();

        address stEth = json.readAddress(_key(SC_WRAP_STETH_WSTETH, "request.srcTokenAddress"));
        address wstEth = json.readAddress(_key(SC_WRAP_STETH_WSTETH, "request.destTokenAddress"));
        uint256 amount = json.readUint(_key(SC_WRAP_STETH_WSTETH, "request.srcTokenAmount"));
        assertEq(stEth, STETH_MAINNET);
        assertEq(wstEth, WSTETH_MAINNET);

        _dealErc20ToAlice(stEth, amount);

        Delegation[] memory delegations_ = _pullDelegations(address(treasury), users.alice, IERC20(stEth), amount, false);

        uint256 wstEthBefore = IERC20(wstEth).balanceOf(destSwap);
        vm.prank(caller);
        uint256 wstEthSent = treasury.wrapStEth(delegations_, amount, destSwap);
        uint256 wstEthDelta = IERC20(wstEth).balanceOf(destSwap) - wstEthBefore;

        assertGt(wstEthSent, 0, "wrapStEth: zero wstEth minted");
        assertEq(wstEthDelta, wstEthSent, "wrapStEth: dest did not receive the minted wstETH");
    }

    function testFork_mainnet_swap_DAI_to_USDC_scenario3() public {
        string memory json = _readQuotesForkAndInitHarness(SC_SWAP_DAI_USDC);

        _deployMainnetTreasury();
        _configureSwapActor(destSwap);
        _ownerAllowSwapPair(IERC20(DAI_MAINNET), IERC20(USDC_MAINNET));

        (IERC20 tokenFrom, uint256 amount, bytes memory tradeData) = _readSwapPullAndTrade(json, SC_SWAP_DAI_USDC);

        deal(address(tokenFrom), address(users.alice.deleGator), amount);

        TreasuryManager.SignatureData memory sig = _signTreasuryApi(json, SC_SWAP_DAI_USDC, tradeData, destSwap);

        Delegation[] memory delegations_ = _pullDelegations(address(treasury), users.alice, tokenFrom, amount, false);

        uint256 usdcBefore = IERC20(USDC_MAINNET).balanceOf(destSwap);
        vm.prank(caller);
        treasury.swap(sig, delegations_);
        uint256 received = IERC20(USDC_MAINNET).balanceOf(destSwap) - usdcBefore;

        uint256 quotedOut = json.readUint(_key(SC_SWAP_DAI_USDC, "bestQuote.destTokenAmount"));
        assertGe(received, _minDestAfterSlippage(json, SC_SWAP_DAI_USDC, quotedOut));
    }

    function testFork_mainnet_swap_wstETH_to_USDC_scenario9() public {
        string memory json = _readQuotesForkAndInitHarness(SC_SWAP_WSTETH_USDC);

        _deployMainnetTreasury();
        _configureSwapActor(destSwap);
        _ownerAllowSwapPair(IERC20(WSTETH_MAINNET), IERC20(USDC_MAINNET));

        (IERC20 tokenFrom, uint256 amount, bytes memory tradeData) = _readSwapPullAndTrade(json, SC_SWAP_WSTETH_USDC);
        assertEq(address(tokenFrom), WSTETH_MAINNET);

        deal(address(tokenFrom), address(users.alice.deleGator), amount);

        TreasuryManager.SignatureData memory sig = _signTreasuryApi(json, SC_SWAP_WSTETH_USDC, tradeData, destSwap);

        Delegation[] memory delegations_ = _pullDelegations(address(treasury), users.alice, tokenFrom, amount, false);

        uint256 usdcBefore = IERC20(USDC_MAINNET).balanceOf(destSwap);
        vm.prank(caller);
        treasury.swap(sig, delegations_);
        uint256 received = IERC20(USDC_MAINNET).balanceOf(destSwap) - usdcBefore;

        uint256 quotedOut = json.readUint(_key(SC_SWAP_WSTETH_USDC, "bestQuote.destTokenAmount"));
        assertGe(received, _minDestAfterSlippage(json, SC_SWAP_WSTETH_USDC, quotedOut));
    }

    // ==================== Linea (`59144`) ====================

    function testFork_linea_swap_DAI_to_USDC_scenario4() public {
        string memory json = _readQuotesForkAndInitHarness(SC_SWAP_LINEA_DAI_USDC);

        _deployLineaTreasury();

        address lineaDai = json.readAddress(_key(SC_SWAP_LINEA_DAI_USDC, "request.srcTokenAddress"));
        address lineaUsdc = json.readAddress(_key(SC_SWAP_LINEA_DAI_USDC, "request.destTokenAddress"));

        _configureSwapActor(destSwap);
        _ownerAllowSwapPair(IERC20(lineaDai), IERC20(lineaUsdc));

        (IERC20 tokenFrom, uint256 amount, bytes memory tradeData) = _readSwapPullAndTrade(json, SC_SWAP_LINEA_DAI_USDC);

        deal(address(tokenFrom), address(users.alice.deleGator), amount);

        TreasuryManager.SignatureData memory sig = _signTreasuryApi(json, SC_SWAP_LINEA_DAI_USDC, tradeData, destSwap);

        Delegation[] memory delegations_ = _pullDelegations(address(treasury), users.alice, tokenFrom, amount, false);

        uint256 outBefore = IERC20(lineaUsdc).balanceOf(destSwap);
        vm.prank(caller);
        treasury.swap(sig, delegations_);
        uint256 received = IERC20(lineaUsdc).balanceOf(destSwap) - outBefore;

        uint256 quotedOut = json.readUint(_key(SC_SWAP_LINEA_DAI_USDC, "bestQuote.destTokenAmount"));
        assertGe(received, _minDestAfterSlippage(json, SC_SWAP_LINEA_DAI_USDC, quotedOut));
    }

    function testFork_linea_bridge_USDC_to_mainnet_USDC_scenario5() public {
        string memory json = _readQuotesForkAndInitHarness(SC_BRIDGE_LINEA_USDC_ETH);

        address lineaUsdc = json.readAddress(_key(SC_BRIDGE_LINEA_USDC_ETH, "request.srcTokenAddress"));
        uint256 amt = json.readUint(_key(SC_BRIDGE_LINEA_USDC_ETH, "request.srcTokenAmount"));

        _deployLineaTreasury();

        _configureBridgeToMainnetUsdc(lineaUsdc);

        bytes memory apiData = json.readBytes(_key(SC_BRIDGE_LINEA_USDC_ETH, "bestQuote.tradeData"));
        TreasuryManager.SignatureData memory sig =
            _signTreasuryApi(json, SC_BRIDGE_LINEA_USDC_ETH, apiData, BRIDGE_DEST_FROM_QUOTES);

        _dealErc20ToAlice(lineaUsdc, amt);

        Delegation[] memory delegations_ = _pullDelegations(address(treasury), users.alice, IERC20(lineaUsdc), amt, false);

        vm.prank(caller);
        treasury.bridge(sig, delegations_);
    }

    function testFork_linea_bridge_ETH_to_mainnet_ETH_scenario7() public {
        string memory json = _readQuotesForkAndInitHarness(SC_BRIDGE_LINEA_ETH_ETH);

        uint256 amt = json.readUint(_key(SC_BRIDGE_LINEA_ETH_ETH, "request.srcTokenAmount"));

        _deployLineaTreasury();

        _configureBridgeToMainnetEth(address(0));

        bytes memory apiData = json.readBytes(_key(SC_BRIDGE_LINEA_ETH_ETH, "bestQuote.tradeData"));
        TreasuryManager.SignatureData memory sig = _signTreasuryApi(json, SC_BRIDGE_LINEA_ETH_ETH, apiData, BRIDGE_DEST_FROM_QUOTES);

        vm.deal(address(users.alice.deleGator), amt);

        Delegation[] memory delegations_ = _pullDelegations(address(treasury), users.alice, IERC20(address(0)), amt, true);

        vm.prank(caller);
        treasury.bridge(sig, delegations_);
    }

    // ==================== Polygon (`137`) ====================

    function testFork_polygon_bridge_USDC_to_mainnet_USDC_scenario6() public {
        string memory json = _readQuotesForkAndInitHarness(SC_BRIDGE_POLYGON_USDC_ETH);

        address polyUsdc = json.readAddress(_key(SC_BRIDGE_POLYGON_USDC_ETH, "request.srcTokenAddress"));
        uint256 amt = json.readUint(_key(SC_BRIDGE_POLYGON_USDC_ETH, "request.srcTokenAmount"));

        _deployPolygonTreasury();

        _configureBridgeToMainnetUsdc(polyUsdc);

        bytes memory apiData = json.readBytes(_key(SC_BRIDGE_POLYGON_USDC_ETH, "bestQuote.tradeData"));
        TreasuryManager.SignatureData memory sig =
            _signTreasuryApi(json, SC_BRIDGE_POLYGON_USDC_ETH, apiData, BRIDGE_DEST_FROM_QUOTES);

        _dealErc20ToAlice(polyUsdc, amt);

        Delegation[] memory delegations_ = _pullDelegations(address(treasury), users.alice, IERC20(polyUsdc), amt, false);

        vm.prank(caller);
        treasury.bridge(sig, delegations_);
    }

    // ==================== Base (`8453`) ====================

    function testFork_base_bridge_USDC_to_mainnet_USDC_scenario8() public {
        string memory json = _readQuotesForkAndInitHarness(SC_BRIDGE_BASE_USDC_ETH);

        address baseUsdc = json.readAddress(_key(SC_BRIDGE_BASE_USDC_ETH, "request.srcTokenAddress"));
        uint256 amt = json.readUint(_key(SC_BRIDGE_BASE_USDC_ETH, "request.srcTokenAmount"));

        _deployBaseTreasury();

        _configureBridgeToMainnetUsdc(baseUsdc);

        bytes memory apiData = json.readBytes(_key(SC_BRIDGE_BASE_USDC_ETH, "bestQuote.tradeData"));
        TreasuryManager.SignatureData memory sig = _signTreasuryApi(json, SC_BRIDGE_BASE_USDC_ETH, apiData, BRIDGE_DEST_FROM_QUOTES);

        _dealErc20ToAlice(baseUsdc, amt);

        Delegation[] memory delegations_ = _pullDelegations(address(treasury), users.alice, IERC20(baseUsdc), amt, false);

        vm.prank(caller);
        treasury.bridge(sig, delegations_);
    }

    // ==================== Internal harness ====================

    /// @dev See file-level comment: `deal(erc20)` fails on tokens with non-standard balance storage
    ///      (Circle native USDC on Polygon / Base behind proxies; Lido stETH rebasing via shares).
    ///      Those branches impersonate a whale and `transfer` instead.
    function _dealErc20ToAlice(address token, uint256 amount) internal {
        if (block.chainid == 137 && token == NATIVE_USDC_POLYGON) {
            vm.startPrank(USDC_WHALE_POLYGON);
            require(IERC20(token).transfer(address(users.alice.deleGator), amount), "native USDC transfer (Polygon)");
            vm.stopPrank();
            return;
        }
        if (block.chainid == 8453 && token == NATIVE_USDC_BASE) {
            vm.startPrank(USDC_WHALE_BASE);
            require(IERC20(token).transfer(address(users.alice.deleGator), amount), "native USDC transfer (Base)");
            vm.stopPrank();
            return;
        }
        // Lido stETH: `balanceOf = _getPooledEthByShares(_sharesOf[a])`, so stdstore cannot find a direct
        // balance slot. wstETH holds essentially all wrapped stETH supply (the wrapper custodies the
        // underlying stETH), making it a reliable whale at any reasonable fork block.
        if (block.chainid == 1 && token == STETH_MAINNET) {
            vm.startPrank(WSTETH_MAINNET);
            require(IERC20(token).transfer(address(users.alice.deleGator), amount), "stETH transfer from wstETH");
            vm.stopPrank();
            return;
        }
        deal(token, address(users.alice.deleGator), amount);
    }

    /// @param scenarioIdx_ Index into `MetaSwapAndMetaBridgeQuotes` scenarios (see `_forkSrcChain`).
    /// @return json Loaded quote JSON for that scenario.
    function _readQuotesForkAndInitHarness(uint256 scenarioIdx_) internal returns (string memory json) {
        json = vm.readFile(MetaSwapAndMetaBridgeQuotes);
        _forkSrcChain(json, scenarioIdx_);
        _initHarnessAfterFork();
    }

    function _initHarnessAfterFork() internal {
        super.setUp();
        entryPoint = ENTRY_POINT_DEPLOYED;
        vm.label(address(entryPoint), "EntryPoint (deployed)");
        delegationManager = DelegationManager(DELEGATION_MANAGER_DEPLOYED);
        vm.label(address(delegationManager), "Delegation Manager (deployed)");
        hybridDeleGatorImpl = HYBRID_DELEGATOR_IMPL_DEPLOYED;
        vm.label(address(hybridDeleGatorImpl), "Hybrid DeleGator (deployed impl)");
        ROOT_AUTHORITY = delegationManager.ROOT_AUTHORITY();
        ANY_DELEGATE = delegationManager.ANY_DELEGATE();
        users = _createUsers();
        (apiSigner, signerPk) = makeAddrAndKey("forkApiSigner");
        routerAddressesJson = vm.readFile(ROUTER_ADDRESSES_JSON);
    }

    function _routerKey(string memory section, uint256 chainId, string memory field) internal pure returns (string memory) {
        return string.concat(".", section, ".", chainId.toString(), ".", field);
    }

    function _metaSwapAt(uint256 chainId) internal view returns (address) {
        return routerAddressesJson.readAddress(_routerKey("MetaSwap", chainId, "METASWAP"));
    }

    function _metaBridgeAt(uint256 chainId) internal view returns (address) {
        return routerAddressesJson.readAddress(_routerKey("MetaBridge", chainId, "METABRIDGE"));
    }

    /**
     * @param chainId_ Source chain; MetaSwap / MetaBridge addresses from `ROUTER_ADDRESSES_JSON`.
     * @param weth_ Chain canonical WETH (`TreasuryManager.weth`).
     * @param stEth_ Mainnet stETH, or `address(0)` when not applicable.
     * @param wstEth_ Mainnet wstETH, or `address(0)` when not applicable.
     */
    function _deployTreasury(uint256 chainId_, IERC20 weth_, address stEth_, address wstEth_) internal {
        vm.startPrank(forkOwner);
        treasury = new TreasuryManager(forkOwner);
        treasury.initialize(
            apiSigner,
            IDelegationManager(DELEGATION_MANAGER_DEPLOYED),
            IMetaSwap(_metaSwapAt(chainId_)),
            IMetaBridge(_metaBridgeAt(chainId_)),
            weth_,
            stEth_,
            wstEth_
        );
        vm.stopPrank();
    }

    function _deployMainnetTreasury() internal {
        _deployTreasury(1, IERC20(WETH_MAINNET), STETH_MAINNET, WSTETH_MAINNET);
    }

    function _deployLineaTreasury() internal {
        _deployTreasury(59144, IERC20(WETH_LINEA), address(0), address(0));
    }

    function _deployPolygonTreasury() internal {
        _deployTreasury(137, IERC20(WETH_POLYGON), address(0), address(0));
    }

    function _deployBaseTreasury() internal {
        _deployTreasury(8453, IERC20(WETH_BASE), address(0), address(0));
    }

    /// @param dest_ Same-chain swap output receiver (allowlisted via `updateAllowedDestWallets`).
    function _configureSwapActor(address dest_) internal {
        vm.startPrank(forkOwner);
        treasury.updateAllowedCallers(_singleAddr(caller), _singleBool(true));
        treasury.updateAllowedDestWallets(_singleAddr(dest_), _singleBool(true));
        vm.stopPrank();
    }

    function _ownerAllowSwapPair(IERC20 tokenFrom, IERC20 tokenTo) internal {
        vm.prank(forkOwner);
        treasury.setPairLimits(_pairLimits(tokenFrom, tokenTo, true));
    }

    /// @dev L2 → mainnet (`destinationChainId == 1`): caller, chain 1 enabled, `updateAllowedBridgeDestWallets` for
    ///      `BRIDGE_DEST_FROM_QUOTES`, and one enabled `bridgeRouteLimits` entry per `(sourceTokenFrom_, 1, destToken_)`.
    function _configureBridgeToMainnet(address sourceTokenFrom_, address[] memory destChain1Tokens_) internal {
        vm.startPrank(forkOwner);
        treasury.updateAllowedCallers(_singleAddr(caller), _singleBool(true));
        treasury.updateDestinationChains(_singleChain(1), _singleBool(true));
        treasury.updateAllowedBridgeDestWallets(1, _singleAddr(BRIDGE_DEST_FROM_QUOTES), _singleBool(true));

        TreasuryManager.BridgeRouteLimitInput[] memory routes_ =
            new TreasuryManager.BridgeRouteLimitInput[](destChain1Tokens_.length);
        for (uint256 i; i < destChain1Tokens_.length; ++i) {
            routes_[i] = TreasuryManager.BridgeRouteLimitInput({
                sourceTokenFrom: IERC20(sourceTokenFrom_),
                destinationChainId: 1,
                destinationTokenTo: destChain1Tokens_[i],
                limit: TreasuryManager.PairLimit({ maxSlippage: uint120(100e18), maxPriceImpact: uint120(100e18), enabled: true })
            });
        }
        treasury.setBridgeRouteLimits(routes_);
        vm.stopPrank();
    }

    function _configureBridgeToMainnetUsdc(address sourceTokenFrom_) internal {
        _configureBridgeToMainnet(sourceTokenFrom_, _singleAddr(USDC_MAINNET));
    }

    /// @dev Mainnet bridge payout as native ETH and/or WETH (`quotes` use `BRIDGE_DEST_FROM_QUOTES`).
    function _configureBridgeToMainnetEth(address sourceTokenFrom_) internal {
        address[] memory tok = new address[](2);
        tok[0] = address(0);
        tok[1] = WETH_MAINNET;
        _configureBridgeToMainnet(sourceTokenFrom_, tok);
    }

    /**
     * @dev Leaf delegation: `delegate` = treasury (the redeemer). Caveats: transfer-amount + `RedeemerEnforcer` against
     *      deployed enforcer contracts from Deployments.md.
     */
    function _pullDelegations(
        address treasury_,
        TestUser memory vault_,
        IERC20 tokenFrom_,
        uint256 amount_,
        bool nativePull_
    )
        internal
        view
        returns (Delegation[] memory delegations_)
    {
        Caveat[] memory caveats_ = new Caveat[](2);
        if (nativePull_) {
            caveats_[0] = Caveat({ args: hex"", enforcer: NATIVE_TRANSFER_AMOUNT_ENFORCER_DEPLOYED, terms: abi.encode(amount_) });
        } else {
            caveats_[0] = Caveat({
                args: hex"",
                enforcer: ERC20_TRANSFER_AMOUNT_ENFORCER_DEPLOYED,
                terms: bytes.concat(bytes20(uint160(address(tokenFrom_))), bytes32(amount_))
            });
        }
        caveats_[1] = Caveat({ args: hex"", enforcer: REDEEMER_ENFORCER_DEPLOYED, terms: abi.encodePacked(treasury_) });

        Delegation memory unsigned_ = Delegation({
            delegate: treasury_,
            delegator: address(vault_.deleGator),
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });

        delegations_ = new Delegation[](1);
        delegations_[0] = signDelegation(vault_, unsigned_);
    }

    /// @param rpcEnvVar_ Name of env var holding the HTTP RPC URL (for `ForkRpcUrlUnset` + `vm.envOr`).
    function _forkAtRpcEnv(string memory rpcEnvVar_, uint256 blockNumber_) internal {
        string memory url = vm.envOr(rpcEnvVar_, string(""));
        if (bytes(url).length == 0) revert ForkRpcUrlUnset(rpcEnvVar_);
        vm.createSelectFork(url, blockNumber_);
        assertEq(block.number, blockNumber_, "fork height must match MetaSwapAndMetaBridgeQuotes forkContext");
    }

    /// @dev Sources **chain + block** from `forkContext` in `MetaSwapAndMetaBridgeQuotes.json` (not `request`), so the
    ///      fork matches the quote capture.
    function _forkSrcChain(string memory json, uint256 scenarioIdx) internal {
        uint256 chainId = json.readUint(_key(scenarioIdx, "forkContext.srcChainId"));
        uint256 blk = _readForkSrcBlockNumber(json, scenarioIdx);

        if (chainId == 1) {
            _forkAtRpcEnv("MAINNET_RPC_URL", blk);
            return;
        }
        if (chainId == 59144) {
            _forkAtRpcEnv("LINEA_RPC_URL", blk);
            return;
        }
        if (chainId == 137) {
            _forkAtRpcEnv("POLYGON_RPC_URL", blk);
            return;
        }
        if (chainId == 8453) {
            _forkAtRpcEnv("BASE_RPC_URL", blk);
            return;
        }
        revert("unsupported chain in quote json");
    }

    /// @dev `forkContext.srcBlockNumber` is stored as a decimal string in the JSON (e.g. `"24986565"`).
    function _readForkSrcBlockNumber(string memory json, uint256 scenarioIdx) internal pure returns (uint256) {
        return vm.parseUint(json.readString(_key(scenarioIdx, "forkContext.srcBlockNumber")));
    }

    /// @dev Lower bound on acceptable destination amount vs Explorer `destTokenAmount`, using signed slippage tolerance
    ///      (`request.slippagePercentE18`: 1e18 = 1%, same as `TreasuryManager.MAX_PERCENT` scale).
    function _minDestAfterSlippage(
        string memory json,
        uint256 scenarioIdx,
        uint256 quotedDestAmount
    )
        internal
        pure
        returns (uint256 minDest_)
    {
        uint256 slip = vm.parseUint(json.readString(_key(scenarioIdx, "request.slippagePercentE18")));
        uint256 cap = 100e18; // must match `TreasuryManager.MAX_PERCENT` (1e18 = 1%)
        require(slip <= cap, "fork test: slippage exceeds MAX_PERCENT");
        minDest_ = quotedDestAmount * (cap - slip) / cap;
    }

    function _readSwapPullAndTrade(
        string memory json,
        uint256 scenarioIdx
    )
        internal
        pure
        returns (IERC20 tokenFrom, uint256 amount, bytes memory tradeData)
    {
        address rawFrom = json.readAddress(_key(scenarioIdx, "request.srcTokenAddress"));
        amount = json.readUint(_key(scenarioIdx, "request.srcTokenAmount"));
        tradeData = json.readBytes(_key(scenarioIdx, "bestQuote.tradeData"));
        tokenFrom = IERC20(rawFrom);
    }

    /// @dev Same EIP-191 tuple as `TreasuryManager` swap/bridge.
    function _signTreasuryApi(
        string memory json,
        uint256 scenarioIdx,
        bytes memory apiData,
        address dest_
    )
        internal
        view
        returns (TreasuryManager.SignatureData memory s)
    {
        uint256 exp = block.timestamp + 365 days;
        int120 slip = int120(vm.parseInt(json.readString(_key(scenarioIdx, "request.slippagePercentE18"))));
        int120 impact = int120(vm.parseInt(json.readString(_key(scenarioIdx, "bestQuote.priceImpact.priceImpactPercentE18"))));

        bytes32 messageHash = keccak256(abi.encode(apiData, exp, slip, impact, dest_));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(signerPk, ethSignedMessageHash);

        s = TreasuryManager.SignatureData({
            apiData: apiData,
            expiration: exp,
            slippage: slip,
            priceImpact: impact,
            destWalletAddress: dest_,
            signature: abi.encodePacked(r, s_, v)
        });
    }

    function _key(uint256 scenarioIdx, string memory rel) internal pure returns (string memory) {
        return string.concat(".scenarios[", scenarioIdx.toString(), "].", rel);
    }

    function _singleAddr(address a) internal pure returns (address[] memory o) {
        o = new address[](1);
        o[0] = a;
    }

    function _singleBool(bool b) internal pure returns (bool[] memory o) {
        o = new bool[](1);
        o[0] = b;
    }

    function _singleChain(uint256 chainId) internal pure returns (uint256[] memory c) {
        c = new uint256[](1);
        c[0] = chainId;
    }

    function _pairLimits(IERC20 a, IERC20 b, bool enabled) internal pure returns (TreasuryManager.PairLimitInput[] memory pin) {
        pin = new TreasuryManager.PairLimitInput[](1);
        pin[0] = TreasuryManager.PairLimitInput({
            tokenFrom: a,
            tokenTo: b,
            limit: TreasuryManager.PairLimit({ maxSlippage: uint120(100e18), maxPriceImpact: uint120(100e18), enabled: enabled })
        });
    }
}
