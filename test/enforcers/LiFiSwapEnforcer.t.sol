// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Caveat, Delegation, Execution } from "../../src/utils/Types.sol";
import { CaveatEnforcerBaseTest } from "./CaveatEnforcerBaseTest.t.sol";
import { LiFiSwapEnforcer } from "../../src/enforcers/LiFiSwapEnforcer.sol";
import { LiFiSwapQuoteLib } from "../../src/libraries/LiFiSwapQuoteLib.sol";
import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { MockLiFiDiamond } from "../utils/MockLiFiDiamond.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

contract LiFiSwapEnforcerTest is CaveatEnforcerBaseTest {
    LiFiSwapEnforcer public lifiSwapEnforcer;
    MockLiFiDiamond public mockDiamond;
    BasicERC20 public usdc;
    BasicERC20 public wbtc;

    address public alice;
    address public bob;
    address public quoteSignerAddress;
    uint256 public quoteSignerPrivateKey;

    bytes32 public dummyDelegationHash = keccak256("lifi-swap-delegation");
    address public redeemer = address(0xBEEF);

    uint256 public periodAmount = 1000;
    uint256 public periodDuration = 1 days;
    uint256 public startDate;
    uint256 public slippageBps = 50;
    uint256 public inputAmount = 500;
    uint256 public expectedAmountOut = 100;
    uint256 public minAmountOut = 100;

    uint256 public constant LIFI_CHAIN_ID_BTC = 20_000_000_000_001;

    function setUp() public override {
        super.setUp();
        lifiSwapEnforcer = new LiFiSwapEnforcer();
        vm.label(address(lifiSwapEnforcer), "LiFi Swap Enforcer");

        mockDiamond = new MockLiFiDiamond();
        vm.label(address(mockDiamond), "Mock LiFi Diamond");

        alice = address(users.alice.deleGator);
        bob = address(users.bob.deleGator);

        (quoteSignerAddress, quoteSignerPrivateKey) = makeAddrAndKey("QuoteSigner");

        usdc = new BasicERC20(alice, "USD Coin", "USDC", 1_000_000 ether);
        wbtc = new BasicERC20(address(this), "Wrapped BTC", "WBTC", 0);

        startDate = block.timestamp;
    }

    ////////////////////// Valid cases //////////////////////

    function test_beforeHook_acceptsValidSameChainQuote() public {
        _runBeforeHook(_buildTerms(block.chainid), _buildQuote(block.chainid), _buildSwapCalldata(block.chainid));
    }

    function test_beforeHook_acceptsValidNearBtcQuote() public {
        bytes32 btcRecipient_ = 0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e12030f; // non-clean (BTC)
        (LiFiSwapQuoteLib.Terms memory terms_, LiFiSwapQuoteLib.SignedLiFiQuote memory quote_) = _btcTermsAndQuote(btcRecipient_);
        bytes memory bridgeCalldata_ = _buildNearBtcCalldata(btcRecipient_);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, bridgeCalldata_);
        bytes memory args_ =
            _encodeArgsWithRoute(LiFiSwapQuoteLib.RouteKind.NearBtc, quote_, bridgeCalldata_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_crossChain_afterHook_skipsBalanceCheck() public {
        bytes32 btcRecipient_ = 0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e12030f;
        (LiFiSwapQuoteLib.Terms memory terms_, LiFiSwapQuoteLib.SignedLiFiQuote memory quote_) = _btcTermsAndQuote(btcRecipient_);
        bytes memory bridgeCalldata_ = _buildNearBtcCalldata(btcRecipient_);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, bridgeCalldata_);
        bytes memory args_ =
            _encodeArgsWithRoute(LiFiSwapQuoteLib.RouteKind.NearBtc, quote_, bridgeCalldata_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );

        // afterHook silently no-ops for cross-chain (no on-chain balance to verify on the source chain).
        vm.prank(address(delegationManager));
        lifiSwapEnforcer.afterHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    ////////////////////// Calldata verification: EVM cross-chain (EvmBridge) //////////////////////

    function test_beforeHook_acceptsValidEvmBridgeQuote() public {
        uint256 destChain_ = 1; // Ethereum mainnet (different from the test's block.chainid)
        bytes32 evmRecipient_ = bytes32(uint256(uint160(alice)));
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(destChain_);
        terms_.outputRecipient = evmRecipient_;

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(destChain_);
        quote_.outputRecipient = evmRecipient_;

        bytes memory bridgeCalldata_ = _buildEvmBridgeCalldata(alice, destChain_);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, bridgeCalldata_);
        bytes memory args_ =
            _encodeArgsWithRoute(LiFiSwapQuoteLib.RouteKind.EvmBridge, quote_, bridgeCalldata_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_revert_evmBridge_nonEvmSentinelReceiver() public {
        // BridgeData.receiver == NON_EVM_ADDRESS must be rejected on the EVM route even if terms pin a
        // clean EVM recipient (closes the sentinel edge).
        uint256 destChain_ = 1;
        bytes32 evmRecipient_ = bytes32(uint256(uint160(alice)));
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(destChain_);
        terms_.outputRecipient = evmRecipient_;

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(destChain_);
        quote_.outputRecipient = evmRecipient_;

        // Calldata carries the non-EVM sentinel as receiver (a non-EVM bridge calldata shape).
        bytes memory bridgeCalldata_ = _buildEvmBridgeCalldata(LiFiSwapQuoteLib.NON_EVM_ADDRESS, destChain_);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, bridgeCalldata_);
        bytes memory args_ =
            _encodeArgsWithRoute(LiFiSwapQuoteLib.RouteKind.EvmBridge, quote_, bridgeCalldata_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:non-evm-sentinel-receiver");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_revert_evmBridge_destChainMismatch() public {
        uint256 destChainTerms_ = 1;
        uint256 destChainCalldata_ = 42161; // calldata routes elsewhere
        bytes32 evmRecipient_ = bytes32(uint256(uint160(alice)));
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(destChainTerms_);
        terms_.outputRecipient = evmRecipient_;

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(destChainTerms_);
        quote_.outputRecipient = evmRecipient_;

        bytes memory bridgeCalldata_ = _buildEvmBridgeCalldata(alice, destChainCalldata_);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, bridgeCalldata_);
        bytes memory args_ =
            _encodeArgsWithRoute(LiFiSwapQuoteLib.RouteKind.EvmBridge, quote_, bridgeCalldata_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:calldata-dest-chain-mismatch");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_revert_evmBridge_recipientMismatch() public {
        uint256 destChain_ = 1;
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(destChain_);
        terms_.outputRecipient = bytes32(uint256(uint160(alice)));

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(destChain_);
        quote_.outputRecipient = bytes32(uint256(uint160(alice)));

        // Calldata routes the funds to bob, not alice.
        bytes memory bridgeCalldata_ = _buildEvmBridgeCalldata(bob, destChain_);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, bridgeCalldata_);
        bytes memory args_ =
            _encodeArgsWithRoute(LiFiSwapQuoteLib.RouteKind.EvmBridge, quote_, bridgeCalldata_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:calldata-recipient-mismatch");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    ////////////////////// Calldata verification: LayerSwap BTC //////////////////////

    function test_beforeHook_acceptsValidLayerSwapBtcQuote() public {
        bytes32 btcRecipient_ = 0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e12030f;
        (LiFiSwapQuoteLib.Terms memory terms_, LiFiSwapQuoteLib.SignedLiFiQuote memory quote_) = _btcTermsAndQuote(btcRecipient_);
        bytes memory bridgeCalldata_ = _buildLayerSwapBtcCalldata(btcRecipient_);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, bridgeCalldata_);
        bytes memory args_ =
            _encodeArgsWithRoute(LiFiSwapQuoteLib.RouteKind.LayerSwapBtc, quote_, bridgeCalldata_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_revert_layerSwapBtc_recipientMismatch() public {
        bytes32 btcRecipientTerms_ = 0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e12030f;
        bytes32 btcRecipientCalldata_ = 0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e1203ff; // differs
        (LiFiSwapQuoteLib.Terms memory terms_, LiFiSwapQuoteLib.SignedLiFiQuote memory quote_) = _btcTermsAndQuote(btcRecipientTerms_);
        bytes memory bridgeCalldata_ = _buildLayerSwapBtcCalldata(btcRecipientCalldata_);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, bridgeCalldata_);
        bytes memory args_ =
            _encodeArgsWithRoute(LiFiSwapQuoteLib.RouteKind.LayerSwapBtc, quote_, bridgeCalldata_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:calldata-recipient-mismatch");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_revert_nearBtc_recipientMismatch() public {
        bytes32 btcRecipientTerms_ = 0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e12030f;
        bytes32 btcRecipientCalldata_ = 0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e1203ff;
        (LiFiSwapQuoteLib.Terms memory terms_, LiFiSwapQuoteLib.SignedLiFiQuote memory quote_) = _btcTermsAndQuote(btcRecipientTerms_);
        bytes memory bridgeCalldata_ = _buildNearBtcCalldata(btcRecipientCalldata_);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, bridgeCalldata_);
        bytes memory args_ =
            _encodeArgsWithRoute(LiFiSwapQuoteLib.RouteKind.NearBtc, quote_, bridgeCalldata_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:calldata-recipient-mismatch");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    ////////////////////// Calldata verification: lying-enum cross-checks //////////////////////

    function test_revert_lyingEnum_nearSelectorWithEvmBridgeRoute() public {
        // Real Near calldata (NON_EVM receiver) but enum claims EvmBridge. The EVM decode reads the
        // non-EVM sentinel and must reject it.
        bytes32 btcRecipient_ = 0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e12030f;
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(LIFI_CHAIN_ID_BTC);
        terms_.outputRecipient = bytes32(uint256(uint160(alice))); // clean EVM to pass the shape check
        terms_.outputAssetId = bytes32(uint256(0x1234));

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(LIFI_CHAIN_ID_BTC);
        quote_.outputRecipient = bytes32(uint256(uint160(alice)));
        quote_.outputAssetId = terms_.outputAssetId;

        bytes memory bridgeCalldata_ = _buildNearBtcCalldata(btcRecipient_);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, bridgeCalldata_);
        bytes memory args_ =
            _encodeArgsWithRoute(LiFiSwapQuoteLib.RouteKind.EvmBridge, quote_, bridgeCalldata_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:non-evm-sentinel-receiver");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_revert_lyingEnum_nearSelectorWithSameChainRoute() public {
        // Near (cross-chain) calldata but enum claims SameChain. SameChain requires dest == block.chainid.
        bytes32 btcRecipient_ = 0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e12030f;
        (LiFiSwapQuoteLib.Terms memory terms_, LiFiSwapQuoteLib.SignedLiFiQuote memory quote_) = _btcTermsAndQuote(btcRecipient_);
        bytes memory bridgeCalldata_ = _buildNearBtcCalldata(btcRecipient_);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, bridgeCalldata_);
        bytes memory args_ =
            _encodeArgsWithRoute(LiFiSwapQuoteLib.RouteKind.SameChain, quote_, bridgeCalldata_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:route-dest-chain-mismatch");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_revert_nearBtc_wrongSelector() public {
        // Enum claims NearBtc but the calldata selector is LayerSwap's.
        bytes32 btcRecipient_ = 0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e12030f;
        (LiFiSwapQuoteLib.Terms memory terms_, LiFiSwapQuoteLib.SignedLiFiQuote memory quote_) = _btcTermsAndQuote(btcRecipient_);
        bytes memory bridgeCalldata_ = _buildLayerSwapBtcCalldata(btcRecipient_);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, bridgeCalldata_);
        bytes memory args_ =
            _encodeArgsWithRoute(LiFiSwapQuoteLib.RouteKind.NearBtc, quote_, bridgeCalldata_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:route-selector-mismatch");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_revert_sameChain_wrongSelector() public {
        // SameChain route but calldata uses a Near (cross-chain) selector.
        bytes32 btcRecipient_ = 0x050c01161e111701130c030c1a1b0d10060310180f1d100f110418040e12030f;
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        terms_.outputRecipient = bytes32(uint256(uint160(alice)));

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        quote_.outputRecipient = bytes32(uint256(uint160(alice)));

        bytes memory bridgeCalldata_ = _buildNearBtcCalldata(btcRecipient_);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, bridgeCalldata_);
        bytes memory args_ =
            _encodeArgsWithRoute(LiFiSwapQuoteLib.RouteKind.SameChain, quote_, bridgeCalldata_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:route-selector-mismatch");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_periodBudget_resetsOnNewPeriod() public {
        _runBeforeHook(_buildTerms(block.chainid), _buildQuote(block.chainid), _buildSwapCalldata(block.chainid));

        vm.warp(block.timestamp + periodDuration + 1);

        _runBeforeHook(_buildTerms(block.chainid), _buildQuote(block.chainid), _buildSwapCalldata(block.chainid));
    }

    ////////////////////// Revert cases //////////////////////

    function test_revert_invalidTermsLength() public {
        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapQuoteLib:invalid-terms-length");
        lifiSwapEnforcer.beforeHook(new bytes(283), hex"", singleDefaultMode, hex"", dummyDelegationHash, alice, redeemer);
    }

    function test_revert_invalidTarget() public {
        bytes memory execData_ = _encodeSingleExecution(address(0xdead), 0, _buildSwapCalldata(block.chainid));
        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-target");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(_buildTerms(block.chainid)),
            _encodeArgs(_buildQuote(block.chainid), _buildSwapCalldata(block.chainid), dummyDelegationHash),
            singleDefaultMode,
            execData_,
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revert_calldataHashMismatch() public {
        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        quote_.calldataHash = keccak256("tampered");
        // Build args directly (not via _encodeArgs, which would overwrite the tampered hash) but still
        // prepend the RouteKind so _decodeArgs succeeds.
        bytes memory args_ = abi.encode(
            LiFiSwapQuoteLib.RouteKind.SameChain,
            quote_,
            _signQuote(quoteSignerPrivateKey, quote_, dummyDelegationHash)
        );

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:calldata-hash-mismatch");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(_buildTerms(block.chainid)),
            args_,
            singleDefaultMode,
            _encodeSingleExecution(address(mockDiamond), 0, _buildSwapCalldata(block.chainid)),
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revert_expiredQuote() public {
        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        quote_.expiration = block.timestamp;

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:quote-expired");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(_buildTerms(block.chainid)),
            _encodeArgs(quote_, _buildSwapCalldata(block.chainid), dummyDelegationHash),
            singleDefaultMode,
            _encodeSingleExecution(address(mockDiamond), 0, _buildSwapCalldata(block.chainid)),
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revert_invalidQuoteSignature() public {
        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        bytes memory badSignature_ = _signQuote(quoteSignerPrivateKey + 1, quote_, dummyDelegationHash);
        bytes memory args_ = abi.encode(LiFiSwapQuoteLib.RouteKind.SameChain, quote_, badSignature_);

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-quote-signature");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(_buildTerms(block.chainid)),
            args_,
            singleDefaultMode,
            _encodeSingleExecution(address(mockDiamond), 0, _buildSwapCalldata(block.chainid)),
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revert_slippageExceeded() public {
        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        quote_.minAmountOut = 90;

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:slippage-exceeded");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(_buildTerms(block.chainid)),
            _encodeArgs(quote_, _buildSwapCalldata(block.chainid), dummyDelegationHash),
            singleDefaultMode,
            _encodeSingleExecution(address(mockDiamond), 0, _buildSwapCalldata(block.chainid)),
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revert_periodAmountExceeded() public {
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        terms_.periodAmount = 500;
        bytes memory encodedTerms_ = LiFiSwapQuoteLib.encodeTerms(terms_);
        bytes32 delegationHash_ = keccak256("period-exceeded");

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        bytes memory callData_ = _buildSwapCalldata(block.chainid);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, callData_);

        vm.prank(address(delegationManager));
        lifiSwapEnforcer.beforeHook(
            encodedTerms_, _encodeArgs(quote_, callData_, delegationHash_), singleDefaultMode, execData_, delegationHash_, alice, redeemer
        );

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:period-amount-exceeded");
        lifiSwapEnforcer.beforeHook(
            encodedTerms_, _encodeArgs(quote_, callData_, delegationHash_), singleDefaultMode, execData_, delegationHash_, alice, redeemer
        );
    }

    function test_revert_invalidOutputRecipient() public {
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        quote_.outputRecipient = bytes32(uint256(uint160(bob)));

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-output-recipient");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_),
            _encodeArgs(quote_, _buildSwapCalldata(block.chainid), dummyDelegationHash),
            singleDefaultMode,
            _encodeSingleExecution(address(mockDiamond), 0, _buildSwapCalldata(block.chainid)),
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revert_invalidDestinationChain() public {
        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(LIFI_CHAIN_ID_BTC);

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-destination-chain");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(_buildTerms(block.chainid)),
            _encodeArgs(quote_, _buildSwapCalldata(block.chainid), dummyDelegationHash),
            singleDefaultMode,
            _encodeSingleExecution(address(mockDiamond), 0, _buildSwapCalldata(block.chainid)),
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revertWithInvalidCallTypeMode() public {
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        lifiSwapEnforcer.beforeHook(hex"", hex"", batchDefaultMode, hex"", bytes32(0), address(0), address(0));
    }

    function test_revert_zeroQuoteSigner() public {
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        terms_.quoteSigner = address(0);

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        bytes memory callData_ = _buildSwapCalldata(block.chainid);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, callData_);
        bytes memory args_ = abi.encode(
            LiFiSwapQuoteLib.RouteKind.SameChain, quote_, _signQuote(quoteSignerPrivateKey, quote_, dummyDelegationHash)
        );

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-zero-quote-signer");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_revert_slippageBpsEqualsDenominator() public {
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        terms_.slippageBps = LiFiSwapQuoteLib.BPS_DENOMINATOR;

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-slippage-bps");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_),
            _encodeArgs(_buildQuote(block.chainid), _buildSwapCalldata(block.chainid), dummyDelegationHash),
            singleDefaultMode,
            _encodeSingleExecution(address(mockDiamond), 0, _buildSwapCalldata(block.chainid)),
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function test_revert_quoteReplayAcrossDelegations() public {
        bytes32 delegationHashA_ = keccak256("delegation-a");
        bytes32 delegationHashB_ = keccak256("delegation-b");

        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        bytes memory callData_ = _buildSwapCalldata(block.chainid);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, callData_);

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        bytes memory argsForA_ = _encodeArgs(quote_, callData_, delegationHashA_);

        vm.prank(address(delegationManager));
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), argsForA_, singleDefaultMode, execData_, delegationHashA_, alice, redeemer
        );

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-quote-signature");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), argsForA_, singleDefaultMode, execData_, delegationHashB_, alice, redeemer
        );
    }

    function test_revert_afterHookInBatchMode() public {
        vm.expectRevert("CaveatEnforcer:invalid-call-type");
        lifiSwapEnforcer.afterHook(hex"", hex"", batchDefaultMode, hex"", bytes32(0), address(0), address(0));
    }

    ////////////////////// Native ETH support //////////////////////

    function test_nativeEthOutput_sameChain() public {
        // Terms with native ETH output (outputAssetId = bytes32(0))
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        terms_.outputAssetId = bytes32(0);

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        quote_.outputAssetId = bytes32(0);

        // Build calldata for swapTokensSingleV3ERC20ToNative (ERC20 in, native ETH out)
        MockLiFiDiamond.SwapData memory swapData_ = MockLiFiDiamond.SwapData({
            callTo: address(0),
            approveTo: address(0),
            sendingAssetId: address(usdc),
            receivingAssetId: address(0),
            fromAmount: inputAmount,
            callData: hex"",
            requiresDeposit: false
        });
        bytes memory swapCalldata_ = abi.encodeWithSelector(
            MockLiFiDiamond.swapTokensSingleV3ERC20ToNative.selector,
            bytes32(uint256(1)),
            "",
            "",
            payable(alice),
            minAmountOut,
            swapData_
        );

        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, swapCalldata_);
        bytes memory args_ = _encodeArgs(quote_, swapCalldata_, dummyDelegationHash);

        // Fund the mock diamond with ETH to send as output
        vm.deal(address(mockDiamond), minAmountOut);
        // Alice approves USDC for the swap
        vm.prank(alice);
        usdc.approve(address(mockDiamond), inputAmount);

        // beforeHook — should accept native ETH output
        vm.prank(address(delegationManager));
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );

        // Simulate the actual swap (delegation manager would execute this)
        uint256 aliceEthBefore_ = alice.balance;
        vm.prank(alice);
        mockDiamond.swapTokensSingleV3ERC20ToNative(bytes32(uint256(1)), "", "", payable(alice), minAmountOut, swapData_);
        assertEq(alice.balance, aliceEthBefore_ + minAmountOut, "alice should receive native ETH");

        // afterHook — should verify via recipient.balance (not IERC20.balanceOf)
        vm.prank(address(delegationManager));
        lifiSwapEnforcer.afterHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_nativeEthInput() public {
        // Terms with native ETH input (inputToken = address(0))
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        terms_.inputToken = address(0);

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        quote_.inputToken = address(0);

        // Build calldata for swapTokensSingleV3NativeToERC20 (native ETH in, ERC20 out)
        MockLiFiDiamond.SwapData memory swapData_ = MockLiFiDiamond.SwapData({
            callTo: address(wbtc),
            approveTo: address(wbtc),
            sendingAssetId: address(0),
            receivingAssetId: address(wbtc),
            fromAmount: inputAmount,
            callData: hex"",
            requiresDeposit: false
        });
        bytes memory swapCalldata_ = abi.encodeWithSelector(
            MockLiFiDiamond.swapTokensSingleV3NativeToERC20.selector,
            bytes32(uint256(1)),
            "",
            "",
            payable(alice),
            minAmountOut,
            swapData_
        );

        // Execution carries value == inputAmount (native ETH input)
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), inputAmount, swapCalldata_);
        bytes memory args_ = _encodeArgs(quote_, swapCalldata_, dummyDelegationHash);

        // Fund the mock diamond with wbtc (output token) and alice with ETH
        wbtc.mint(address(mockDiamond), minAmountOut);
        vm.deal(alice, inputAmount);

        // beforeHook — should accept value == inputAmount for native ETH input
        vm.prank(address(delegationManager));
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );

        // Simulate the actual swap (delegation manager would execute this with msg.value)
        uint256 aliceWbtcBefore_ = wbtc.balanceOf(alice);
        vm.prank(alice);
        mockDiamond.swapTokensSingleV3NativeToERC20{value: inputAmount}(
            bytes32(uint256(1)), "", "", payable(alice), minAmountOut, swapData_
        );
        assertEq(wbtc.balanceOf(alice), aliceWbtcBefore_ + minAmountOut, "alice should receive wbtc");

        // afterHook — should verify via IERC20.balanceOf (output is ERC20)
        vm.prank(address(delegationManager));
        lifiSwapEnforcer.afterHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_revert_nativeEthInput_wrongValue() public {
        // Terms with native ETH input
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        terms_.inputToken = address(0);

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        quote_.inputToken = address(0);

        // Build calldata for swapTokensSingleV3NativeToERC20
        MockLiFiDiamond.SwapData memory swapData_ = MockLiFiDiamond.SwapData({
            callTo: address(wbtc),
            approveTo: address(wbtc),
            sendingAssetId: address(0),
            receivingAssetId: address(wbtc),
            fromAmount: inputAmount,
            callData: hex"",
            requiresDeposit: false
        });
        bytes memory swapCalldata_ = abi.encodeWithSelector(
            MockLiFiDiamond.swapTokensSingleV3NativeToERC20.selector,
            bytes32(uint256(1)),
            "",
            "",
            payable(alice),
            minAmountOut,
            swapData_
        );

        // Execution carries WRONG value (0 instead of inputAmount)
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, swapCalldata_);
        bytes memory args_ = _encodeArgs(quote_, swapCalldata_, dummyDelegationHash);

        // beforeHook — should revert because value != inputAmount for native ETH input
        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-native-value");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    function test_revert_zeroOutputRecipient_stillRejected() public {
        // outputRecipient == bytes32(0) is still invalid even with native ETH support
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        terms_.outputRecipient = bytes32(0);

        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        quote_.outputRecipient = bytes32(0);

        bytes memory swapCalldata_ = _buildSwapCalldata(block.chainid);
        bytes memory execData_ = _encodeSingleExecution(address(mockDiamond), 0, swapCalldata_);
        bytes memory args_ = _encodeArgs(quote_, swapCalldata_, dummyDelegationHash);

        vm.prank(address(delegationManager));
        vm.expectRevert("LiFiSwapEnforcer:invalid-zero-output-recipient");
        lifiSwapEnforcer.beforeHook(
            LiFiSwapQuoteLib.encodeTerms(terms_), args_, singleDefaultMode, execData_, dummyDelegationHash, alice, redeemer
        );
    }

    ////////////////////// Integration //////////////////////

    function test_integration_sameChainSwap() public {
        bytes32 recipient_ = bytes32(uint256(uint160(alice)));
        LiFiSwapQuoteLib.Terms memory terms_ = _buildTerms(block.chainid);
        terms_.outputRecipient = recipient_;

        bytes memory swapCalldata_ = _buildSwapCalldata(block.chainid);
        LiFiSwapQuoteLib.SignedLiFiQuote memory quote_ = _buildQuote(block.chainid);
        quote_.outputRecipient = recipient_;
        quote_.calldataHash = keccak256(swapCalldata_);

        wbtc.mint(address(mockDiamond), minAmountOut);
        vm.prank(alice);
        usdc.approve(address(mockDiamond), inputAmount);

        bytes memory termsBytes_ = LiFiSwapQuoteLib.encodeTerms(terms_);

        Caveat[] memory caveats_ = new Caveat[](1);
        caveats_[0] = Caveat({ args: hex"", enforcer: address(lifiSwapEnforcer), terms: termsBytes_ });

        Delegation memory delegation_ = Delegation({
            delegate: bob,
            delegator: alice,
            authority: ROOT_AUTHORITY,
            caveats: caveats_,
            salt: 0,
            signature: hex""
        });
        bytes32 delegationHash_ = EncoderLib._getDelegationHash(delegation_);
        caveats_[0].args = _encodeArgs(quote_, swapCalldata_, delegationHash_);
        delegation_ = signDelegation(users.alice, delegation_);

        uint256 usdcBefore_ = usdc.balanceOf(alice);
        uint256 wbtcBefore_ = wbtc.balanceOf(alice);

        Execution memory execution_ = Execution({ target: address(mockDiamond), value: 0, callData: swapCalldata_ });
        invokeDelegation_UserOp(users.bob, _singleDelegation(delegation_), execution_);

        assertEq(usdc.balanceOf(alice), usdcBefore_ - inputAmount);
        assertEq(wbtc.balanceOf(alice), wbtcBefore_ + minAmountOut);
    }

    function _getEnforcer() internal view override returns (ICaveatEnforcer) {
        return ICaveatEnforcer(address(lifiSwapEnforcer));
    }

    function _buildTerms(uint256 _destinationChainId) internal view returns (LiFiSwapQuoteLib.Terms memory terms_) {
        terms_ = LiFiSwapQuoteLib.Terms({
            lifiDiamond: address(mockDiamond),
            inputToken: address(usdc),
            outputAssetId: bytes32(uint256(uint160(address(wbtc)))),
            outputRecipient: bytes32(uint256(uint160(alice))),
            destinationChainId: _destinationChainId,
            quoteSigner: quoteSignerAddress,
            periodAmount: periodAmount,
            periodDuration: periodDuration,
            startDate: startDate,
            slippageBps: slippageBps
        });
    }

    function _buildQuote(uint256 _destinationChainId) internal view returns (LiFiSwapQuoteLib.SignedLiFiQuote memory quote_) {
        bytes memory swapCalldata_ = _buildSwapCalldata(block.chainid);
        quote_ = LiFiSwapQuoteLib.SignedLiFiQuote({
            delegator: alice,
            lifiDiamond: address(mockDiamond),
            inputToken: address(usdc),
            outputAssetId: bytes32(uint256(uint160(address(wbtc)))),
            outputRecipient: bytes32(uint256(uint160(alice))),
            destinationChainId: _destinationChainId,
            inputAmount: inputAmount,
            expectedAmountOut: expectedAmountOut,
            minAmountOut: minAmountOut,
            calldataHash: keccak256(swapCalldata_),
            expiration: block.timestamp + 1 hours
        });
    }

    function _buildSwapCalldata(uint256) internal view returns (bytes memory) {
        MockLiFiDiamond.SwapData memory swapData_ = MockLiFiDiamond.SwapData({
            callTo: address(wbtc),
            approveTo: address(wbtc),
            sendingAssetId: address(usdc),
            receivingAssetId: address(wbtc),
            fromAmount: inputAmount,
            callData: hex"",
            requiresDeposit: true
        });

        return abi.encodeWithSelector(
            MockLiFiDiamond.swapTokensSingleV3ERC20ToERC20.selector,
            bytes32(uint256(1)),
            "",
            "",
            payable(alice),
            minAmountOut,
            swapData_
        );
    }

    ////////////////////// Calldata fixture builders (mirror LiFi struct layouts) //////////////////////
    // Local mirrors of ILiFi.BridgeData, NEARIntentsData, LayerSwapData, LibSwap.SwapData so tests can
    // build faithful LiFi calldata without importing the lifinance/contracts repo. Field order/types match
    // the real structs, so abi.encodeWithSelector produces byte-identical calldata the enforcer decodes.

    bytes4 private constant SEL_NEAR_SWAP = 0x3110c7b9;
    bytes4 private constant SEL_LAYERSWAP_SWAP = 0x4c279d6b;
    bytes4 private constant SEL_EVM_BRIDGE_FAKE = 0x12345678; // EvmBridge path is selector-agnostic

    struct BridgeDataMirror {
        bytes32 transactionId;
        string bridge;
        string integrator;
        address referrer;
        address sendingAssetId;
        address receiver;
        uint256 minAmount;
        uint256 destinationChainId;
        bool hasSourceSwaps;
        bool hasDestinationCall;
    }

    struct SwapDataMirror {
        address callTo;
        address approveTo;
        address sendingAssetId;
        address receivingAssetId;
        uint256 fromAmount;
        bytes callData;
        bool requiresDeposit;
    }

    struct NearIntentsDataMirror {
        bytes32 nonEVMReceiver;
        address depositAddress;
        bytes32 quoteId;
        uint256 deadline;
        uint256 minAmountOut;
        address refundRecipient;
        bytes signature;
    }

    struct LayerSwapDataMirror {
        bytes32 requestId;
        address depositoryReceiver;
        address refundRecipient;
        bytes32 nonEVMReceiver;
        bytes signature;
        uint256 deadline;
    }

    function _bridgeData(address _receiver, uint256 _destChainId, bool _hasSourceSwaps)
        internal
        view
        returns (BridgeDataMirror memory)
    {
        return BridgeDataMirror({
            transactionId: bytes32(uint256(1)),
            bridge: "test",
            integrator: "lifi-api",
            referrer: address(0),
            sendingAssetId: address(usdc),
            receiver: _receiver,
            minAmount: inputAmount,
            destinationChainId: _destChainId,
            hasSourceSwaps: _hasSourceSwaps,
            hasDestinationCall: false
        });
    }

    function _sourceSwap() internal view returns (SwapDataMirror memory) {
        return SwapDataMirror({
            callTo: address(0),
            approveTo: address(0),
            sendingAssetId: address(usdc),
            receivingAssetId: address(usdc),
            fromAmount: inputAmount,
            callData: hex"",
            requiresDeposit: false
        });
    }

    /// @dev NEAR swap+bridge calldata (hasSourceSwaps=true). nonEVMReceiver is the 1st struct field.
    function _buildNearBtcCalldata(bytes32 _btcRecipient) internal view returns (bytes memory) {
        SwapDataMirror[] memory swaps_ = new SwapDataMirror[](1);
        swaps_[0] = _sourceSwap();
        NearIntentsDataMirror memory near_ = NearIntentsDataMirror({
            nonEVMReceiver: _btcRecipient,
            depositAddress: address(0xBEEF),
            quoteId: bytes32(uint256(2)),
            deadline: block.timestamp + 1 hours,
            minAmountOut: minAmountOut,
            refundRecipient: alice,
            signature: hex""
        });
        return abi.encodeWithSelector(SEL_NEAR_SWAP, _bridgeData(LiFiSwapQuoteLib.NON_EVM_ADDRESS, LIFI_CHAIN_ID_BTC, true), swaps_, near_);
    }

    /// @dev LayerSwap swap+bridge calldata (hasSourceSwaps=true). nonEVMReceiver is the 4th struct field.
    function _buildLayerSwapBtcCalldata(bytes32 _btcRecipient) internal view returns (bytes memory) {
        SwapDataMirror[] memory swaps_ = new SwapDataMirror[](1);
        swaps_[0] = _sourceSwap();
        LayerSwapDataMirror memory ls_ = LayerSwapDataMirror({
            requestId: bytes32(uint256(3)),
            depositoryReceiver: address(0xCAFE),
            refundRecipient: alice,
            nonEVMReceiver: _btcRecipient,
            signature: hex"",
            deadline: block.timestamp + 1 hours
        });
        return abi.encodeWithSelector(
            SEL_LAYERSWAP_SWAP, _bridgeData(LiFiSwapQuoteLib.NON_EVM_ADDRESS, LIFI_CHAIN_ID_BTC, true), swaps_, ls_
        );
    }

    /// @dev EVM cross-chain bridge calldata (selector-agnostic; receiver is a real EVM address).
    function _buildEvmBridgeCalldata(address _receiver, uint256 _destChainId) internal view returns (bytes memory) {
        return abi.encodeWithSelector(SEL_EVM_BRIDGE_FAKE, _bridgeData(_receiver, _destChainId, false), bytes32(uint256(0)));
    }

    function _btcTermsAndQuote(bytes32 _btcRecipient)
        internal
        view
        returns (LiFiSwapQuoteLib.Terms memory terms_, LiFiSwapQuoteLib.SignedLiFiQuote memory quote_)
    {
        terms_ = _buildTerms(LIFI_CHAIN_ID_BTC);
        terms_.outputRecipient = _btcRecipient;
        terms_.outputAssetId = bytes32(uint256(0x1234));
        quote_ = _buildQuote(LIFI_CHAIN_ID_BTC);
        quote_.outputRecipient = _btcRecipient;
        quote_.outputAssetId = terms_.outputAssetId;
    }

    function _encodeArgs(
        LiFiSwapQuoteLib.SignedLiFiQuote memory _quote,
        bytes memory _callData,
        bytes32 _delegationHash
    )
        internal
        view
        returns (bytes memory)
    {
        return _encodeArgsWithRoute(_deriveRouteKind(_quote), _quote, _callData, _delegationHash);
    }

    function _encodeArgsWithRoute(
        LiFiSwapQuoteLib.RouteKind _routeKind,
        LiFiSwapQuoteLib.SignedLiFiQuote memory _quote,
        bytes memory _callData,
        bytes32 _delegationHash
    )
        internal
        view
        returns (bytes memory)
    {
        _quote.calldataHash = keccak256(_callData);
        return abi.encode(_routeKind, _quote, _signQuote(quoteSignerPrivateKey, _quote, _delegationHash));
    }

    /// @dev Mirrors the CLI derive-from-quote helper: same-chain vs EVM cross-chain vs non-EVM (BTC).
    /// Non-EVM recipients require an explicit route (Near/LayerSwap) since the bridge cannot be derived
    /// from the quote alone — callers must use `_encodeArgsWithRoute` for those.
    function _deriveRouteKind(LiFiSwapQuoteLib.SignedLiFiQuote memory _quote)
        internal
        view
        returns (LiFiSwapQuoteLib.RouteKind)
    {
        if (_quote.destinationChainId == block.chainid) {
            return LiFiSwapQuoteLib.RouteKind.SameChain;
        }
        if (LiFiSwapQuoteLib.isCleanEvmAddress(_quote.outputRecipient)) {
            return LiFiSwapQuoteLib.RouteKind.EvmBridge;
        }
        revert("LiFiSwapEnforcerTest:non-evm-route-requires-explicit-kind");
    }

    function _signQuote(
        uint256 _privateKey,
        LiFiSwapQuoteLib.SignedLiFiQuote memory _quote,
        bytes32 _delegationHash
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 ethSignedMessageHash_ =
            MessageHashUtils.toEthSignedMessageHash(LiFiSwapQuoteLib.hashQuote(_quote, _delegationHash));
        (uint8 v_, bytes32 r_, bytes32 s_) = vm.sign(_privateKey, ethSignedMessageHash_);
        return abi.encodePacked(r_, s_, v_);
    }

    function _encodeSingleExecution(address _target, uint256 _value, bytes memory _callData)
        internal
        pure
        returns (bytes memory)
    {
        return ExecutionLib.encodeSingle(_target, _value, _callData);
    }

    function _runBeforeHook(
        LiFiSwapQuoteLib.Terms memory _terms,
        LiFiSwapQuoteLib.SignedLiFiQuote memory _quote,
        bytes memory _callData
    )
        internal
    {
        _runBeforeHookWithExecution(
            LiFiSwapQuoteLib.encodeTerms(_terms),
            _quote,
            _encodeSingleExecution(address(mockDiamond), 0, _callData)
        );
    }

    function _runBeforeHookWithExecution(
        bytes memory _terms,
        LiFiSwapQuoteLib.SignedLiFiQuote memory _quote,
        bytes memory _execData,
        bytes memory _callData
    )
        internal
    {
        vm.prank(address(delegationManager));
        lifiSwapEnforcer.beforeHook(
            _terms,
            _encodeArgs(_quote, _callData, dummyDelegationHash),
            singleDefaultMode,
            _execData,
            dummyDelegationHash,
            alice,
            redeemer
        );
    }

    function _runBeforeHookWithExecution(
        bytes memory _terms,
        LiFiSwapQuoteLib.SignedLiFiQuote memory _quote,
        bytes memory _execData
    )
        internal
    {
        _runBeforeHookWithExecution(_terms, _quote, _execData, _sliceCallData(_execData));
    }

    function _sliceCallData(bytes memory _execData) private pure returns (bytes memory callData_) {
        require(_execData.length >= 52, "invalid exec data");
        callData_ = new bytes(_execData.length - 52);
        for (uint256 i = 0; i < callData_.length; ++i) {
            callData_[i] = _execData[i + 52];
        }
    }

    function _singleDelegation(Delegation memory _delegation) internal pure returns (Delegation[] memory delegations_) {
        delegations_ = new Delegation[](1);
        delegations_[0] = _delegation;
    }
}
