// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BytesLib } from "@bytes-utils/BytesLib.sol";
import { EntryPoint } from "@account-abstraction/core/EntryPoint.sol";

import { BasicERC20 } from "../utils/BasicERC20.t.sol";
import { DelegationMetaSwapAdapter } from "../../src/helpers/DelegationMetaSwapAdapter.sol";
import { IMetaSwap } from "../../src/helpers/interfaces/IMetaSwap.sol";
import { IDelegationManager } from "../../src/interfaces/IDelegationManager.sol";
import { DelegationManager } from "../../src/DelegationManager.sol";
import { HybridDeleGator } from "../../src/HybridDeleGator.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";
import { Delegation } from "../../src/utils/Types.sol";
import { DelegationMetaSwapAdapterBaseTest, DelegationMetaSwapAdapterSignatureTest } from "./DelegationMetaSwapAdapter.t.sol";
import { DelegationMetaSwapAdapterNewApiFixtures } from "./DelegationMetaSwapAdapterNewApiFixtures.t.sol";

import "forge-std/Test.sol";

/**
 * @title DelegationMetaSwapAdapterNewApiTestHelpers
 * @notice Shared decoding helpers for the new-API compatibility tests. They mirror, byte for byte, the way
 *         DelegationMetaSwapAdapter._decodeApiData parses `apiData`, so any incompatibility between the new API
 *         payloads and the CURRENT (unmodified) contract shows up here and in the fork tests.
 */
abstract contract DelegationMetaSwapAdapterNewApiTestHelpers is DelegationMetaSwapAdapterNewApiFixtures {
    /// @dev Full decoding of the aggregator `swapData` (the contract only consumes a subset of these fields).
    struct NewApiSwapData {
        IERC20 tokenFrom;
        IERC20 tokenTo;
        uint256 amountFrom;
        uint256 amountTo;
        bytes metadata;
        uint256 feeAmount;
        address feeWallet;
        bool feeTo;
    }

    /**
     * @dev Decodes `apiData` exactly like DelegationMetaSwapAdapter._decodeApiData does: selector + top-level
     *      (aggregatorId, tokenFrom, amountFrom, swapData).
     */
    function _decodeNewApiData(bytes memory _apiData)
        internal
        pure
        returns (bytes4 selector_, string memory aggregatorId_, IERC20 tokenFrom_, uint256 amountFrom_, bytes memory swapData_)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            selector_ := mload(add(_apiData, 0x20))
        }
        bytes memory paramTerms_ = BytesLib.slice(_apiData, 4, _apiData.length - 4);
        (aggregatorId_, tokenFrom_, amountFrom_, swapData_) = abi.decode(paramTerms_, (string, IERC20, uint256, bytes));
    }

    /**
     * @dev Decodes the aggregator `swapData` exactly like DelegationMetaSwapAdapter._decodeApiData does
     *      (address(0) prepended because of the Swaps API format), returning ALL fields including fee data.
     */
    function _decodeNewApiSwapData(bytes memory _swapData) internal pure returns (NewApiSwapData memory swap_) {
        (, // address(0)
            swap_.tokenFrom,
            swap_.tokenTo,
            swap_.amountFrom,
            swap_.amountTo,
            swap_.metadata,
            swap_.feeAmount,
            swap_.feeWallet,
            swap_.feeTo
        ) =
            abi.decode(
                abi.encodePacked(abi.encode(address(0)), _swapData),
                (address, IERC20, IERC20, uint256, uint256, bytes, uint256, address, bool)
            );
    }

    /// @dev Label prefix used in assertion messages, e.g. "ERC20_TO_ERC20/okx".
    function _fixtureLabel(NewApiFixture memory _fixture) internal pure returns (string memory) {
        return string.concat(_fixture.pair, "/", _fixture.aggregator);
    }
}

/**
 * @title DelegationMetaSwapAdapterNewApiSignatureCompatTest
 * @notice NON-FORK tests (no RPC needed) proving that the REAL signatures returned by the new signed-quote API
 *         (bridge.dev-api.cx.metamask.io/getQuote?signQuotes=true) validate against the CURRENT, unmodified
 *         DelegationMetaSwapAdapter configured with the dev-API signer (expected to match production).
 * @dev CRITICAL: nothing in this contract is signed locally. Every signature/expiration comes verbatim from the
 *      API fixtures — locally re-signing would defeat the entire purpose of the compatibility suite.
 * @dev SCOPE: the fixtures come from the DEV endpoint, so seconds-unit sigExpiration and the signer are proven
 *      for dev only. Rolling out against production still requires confirming the production endpoint also emits
 *      seconds-unit sigExpiration and that the deployed adapter's swapApiSigner matches (see the ForkTest SCOPE
 *      note below).
 */
contract DelegationMetaSwapAdapterNewApiSignatureCompatTest is Test, DelegationMetaSwapAdapterNewApiTestHelpers {
    DelegationMetaSwapAdapterSignatureTest public adapter;

    function setUp() public {
        // Harness configured with the REAL dev-API signer (recovered from the fixtures' signatures; expected to
        // match production, but confirm the deployed adapter's swapApiSigner at rollout).
        adapter = new DelegationMetaSwapAdapterSignatureTest(
            address(this), NEW_API_SWAP_API_SIGNER, address(0x123), address(0x456), address(0x789)
        );
    }

    ////////////////////////////// Helpers //////////////////////////////

    function _toSigData(NewApiFixture memory _fixture) internal pure returns (DelegationMetaSwapAdapter.SignatureData memory) {
        // apiData, sigExpiration (UNIX seconds) and signature are used VERBATIM — no local signing.
        return DelegationMetaSwapAdapter.SignatureData({
            apiData: _fixture.apiData, expiration: _fixture.sigExpiration, signature: _fixture.signature
        });
    }

    ////////////////////////////// Signature compatibility //////////////////////////////

    /// @notice All 15 real API signatures (3 pairs x 5 aggregators) pass _validateSignature verbatim with the
    /// dev-API signer configured. This is the core zero-contract-changes signature compatibility proof.
    function test_newApi_validateSignature_allFixtures() public view {
        for (uint256 i = 0; i < NEW_API_FIXTURE_COUNT; ++i) {
            NewApiFixture memory fixture_ = _getNewApiFixture(i);
            // Reverts (failing the test) if the API signature is not valid for the current contract logic.
            adapter.exposedValidateSignature(_toSigData(fixture_));
        }
    }

    /// @notice Flipping a single byte of apiData must invalidate every fixture's signature (InvalidApiSignature),
    /// proving the signatures actually cover the full apiData payload.
    function test_newApi_validateSignature_tamperedApiData_reverts() public {
        for (uint256 i = 0; i < NEW_API_FIXTURE_COUNT; ++i) {
            NewApiFixture memory fixture_ = _getNewApiFixture(i);
            DelegationMetaSwapAdapter.SignatureData memory sigData_ = _toSigData(fixture_);

            // Flip one byte in the middle of the payload.
            uint256 index_ = sigData_.apiData.length / 2;
            sigData_.apiData[index_] = bytes1(uint8(sigData_.apiData[index_]) ^ 0xff);

            vm.expectRevert(DelegationMetaSwapAdapter.InvalidApiSignature.selector);
            adapter.exposedValidateSignature(sigData_);
        }
    }

    /// @notice The real API signatures must NOT validate on an adapter configured with a different signer.
    function test_newApi_validateSignature_wrongSigner_reverts() public {
        DelegationMetaSwapAdapterSignatureTest wrongSignerAdapter_ = new DelegationMetaSwapAdapterSignatureTest(
            address(this), makeAddr("NotTheSwapApiSigner"), address(0x123), address(0x456), address(0x789)
        );

        for (uint256 i = 0; i < NEW_API_FIXTURE_COUNT; ++i) {
            NewApiFixture memory fixture_ = _getNewApiFixture(i);
            vm.expectRevert(DelegationMetaSwapAdapter.InvalidApiSignature.selector);
            wrongSignerAdapter_.exposedValidateSignature(_toSigData(fixture_));
        }
    }

    /**
     * @notice EXPIRATION SEMANTICS — sigExpiration is a UNIX timestamp in SECONDS, the same unit as
     * block.timestamp, so the contract's expiry check is FUNCTIONAL.
     *
     * The API returns `sigExpiration` as a UNIX timestamp in SECONDS (~5 minute TTL observed) and signs
     * keccak256(abi.encode(apiData, sigExpiration)) with that value, so it MUST be passed on-chain verbatim.
     * The contract compares it directly against block.timestamp:
     *
     *     if (block.timestamp >= _signatureData.expiration) revert SignatureExpired();
     *
     * Because both sides are now in seconds, this check genuinely enforces the quote's TTL on-chain: a quote
     * validates strictly before its expiration instant and is rejected from that instant onward (the boundary
     * is inclusive, >=). Stale quotes are now genuinely rejected on-chain — an intentional API improvement.
     *
     * HISTORICAL NOTE: quotes signed before this API change (and by the old API) carried MILLISECOND
     * expirations (e.g. ~1.78e12; see test_validateSignature_hardcodedSignature in
     * DelegationMetaSwapAdapter.t.sol, expiration 1745454591251). The contract has no unit validation — it
     * trusts whatever value the signer signed — so those millisecond quotes validated but never effectively
     * expired (block.timestamp would only reach the raw millisecond value around year ~58,000). The switch to
     * seconds is what makes the existing, unmodified check bite.
     */
    function test_newApi_expirationIsSeconds_enforcedOnChain() public {
        NewApiFixture memory fixture_ = _getNewApiFixture(0);
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = _toSigData(fixture_);

        // One second before the expiration instant: the quote still validates.
        vm.warp(fixture_.sigExpiration - 1);
        adapter.exposedValidateSignature(sigData_);

        // At the expiration instant the quote is rejected — the boundary is inclusive (>=).
        vm.warp(fixture_.sigExpiration);
        vm.expectRevert(DelegationMetaSwapAdapter.SignatureExpired.selector);
        adapter.exposedValidateSignature(sigData_);

        // Long after expiration the quote stays rejected: stale quotes are now genuinely refused on-chain
        // (under the old millisecond semantics this warp would still have validated).
        vm.warp(fixture_.sigExpiration + 30 days);
        vm.expectRevert(DelegationMetaSwapAdapter.SignatureExpired.selector);
        adapter.exposedValidateSignature(sigData_);
    }

    ////////////////////////////// Decode compatibility //////////////////////////////

    /// @notice All 15 new-API payloads decode cleanly under the exact rules of the contract's _decodeApiData and
    /// satisfy every invariant the contract reverts on (InvalidSwapFunctionSelector, TokenFromMismatch,
    /// AmountFromMismatch, InvalidIdenticalTokens), plus consistency with the quote metadata.
    function test_newApi_decodeCompat_allFixtures() public {
        for (uint256 i = 0; i < NEW_API_FIXTURE_COUNT; ++i) {
            NewApiFixture memory fixture_ = _getNewApiFixture(i);
            string memory label_ = _fixtureLabel(fixture_);

            (bytes4 selector_, string memory aggregatorId_, IERC20 tokenFrom_, uint256 amountFrom_, bytes memory swapData_) =
                _decodeNewApiData(fixture_.apiData);
            NewApiSwapData memory swap_ = _decodeNewApiSwapData(swapData_);

            // Contract revert condition: InvalidSwapFunctionSelector.
            assertEq(selector_, IMetaSwap.swap.selector, string.concat(label_, ": apiData selector must be IMetaSwap.swap"));

            // Contract revert condition: TokenFromMismatch.
            assertEq(
                address(swap_.tokenFrom), address(tokenFrom_), string.concat(label_, ": swapData tokenFrom must match apiData")
            );

            // Contract revert condition: AmountFromMismatch (only enforced when the fee is taken from tokenFrom).
            if (!swap_.feeTo) {
                assertEq(
                    swap_.feeAmount + swap_.amountFrom,
                    amountFrom_,
                    string.concat(label_, ": feeAmount + swapAmountFrom must equal amountFrom when feeTo is false")
                );
            }

            // Contract revert condition: InvalidIdenticalTokens.
            assertTrue(address(tokenFrom_) != address(swap_.tokenTo), string.concat(label_, ": tokenFrom must differ from tokenTo"));

            // Aggregator id must be a non-empty string (it is whitelisted by hash in the fork tests).
            assertGt(bytes(aggregatorId_).length, 0, string.concat(label_, ": aggregatorId must not be empty"));

            // Consistency between the decoded payload and the quote metadata returned by the API.
            assertEq(address(tokenFrom_), fixture_.srcToken, string.concat(label_, ": decoded tokenFrom must match quote srcToken"));
            assertEq(
                address(swap_.tokenTo), fixture_.destToken, string.concat(label_, ": decoded tokenTo must match quote destToken")
            );
            assertEq(amountFrom_, fixture_.srcTokenAmount, string.concat(label_, ": decoded amountFrom must match srcTokenAmount"));
            assertEq(
                swap_.amountTo,
                fixture_.minDestTokenAmount,
                string.concat(label_, ": decoded amountTo must match minDestTokenAmount")
            );

            // The trade always targets the MetaSwap contract the adapter is wired to, and only carries value for
            // native tokenFrom.
            assertEq(fixture_.tradeTo, NEW_API_META_SWAP, string.concat(label_, ": trade.to must be the MetaSwap contract"));
            assertEq(
                fixture_.tradeValue,
                fixture_.srcToken == address(0) ? amountFrom_ : 0,
                string.concat(label_, ": trade.value must equal amountFrom for native swaps and 0 otherwise")
            );
        }
    }

    ////////////////////////////// Fixture-set coverage invariants //////////////////////////////

    /**
     * @notice Set-level invariants over the AUTOGENERATED fixtures, so a refresh via
     * scripts/fetch_new_api_signed_quotes.sh that silently loses coverage fails loudly instead of quietly
     * weakening the compatibility verdict:
     *   - the full 3 pairs x 5 aggregators matrix is present (15 unique pair/aggregator combinations);
     *   - both fee modes are represented: at least one feeTo=true payload (fee taken from the OUTPUT token,
     *     exempt from AmountFromMismatch) and one feeTo=false payload (fee taken from tokenFrom, exercising the
     *     AmountFromMismatch invariant);
     *   - every sigExpiration is an ABSOLUTE UNIX timestamp in SECONDS, bounded on BOTH sides: < 1e11 catches an
     *     accidental API flip back to milliseconds (which would silently disarm the on-chain expiry check again),
     *     and > 1.7e9 catches a flip to a RELATIVE TTL or garbage value (e.g. `300` seconds), which would
     *     otherwise pass every non-fork test — the boundary test warps relative to the fixture value, so only
     *     the fork suite's setUp guard (deferred to the FOUNDRY_PROFILE=linea-fork CI step) would notice.
     */
    function test_newApi_fixtureSetCoverageInvariants() public {
        assertEq(NEW_API_FIXTURE_COUNT, 15, "fixture set must cover the full 3 pairs x 5 aggregators matrix");

        string[3] memory pairs_ = ["ERC20_TO_ERC20", "NATIVE_TO_ERC20", "ERC20_TO_NATIVE"];
        uint256[3] memory pairCounts_;
        bytes32[] memory seenCombos_ = new bytes32[](NEW_API_FIXTURE_COUNT);
        uint256 feeToTrueCount_;
        uint256 feeToFalseCount_;

        for (uint256 i = 0; i < NEW_API_FIXTURE_COUNT; ++i) {
            NewApiFixture memory fixture_ = _getNewApiFixture(i);
            string memory label_ = _fixtureLabel(fixture_);

            // Seconds-unit guard: a UNIX-seconds timestamp stays < 1e11 until year ~5138, while a millisecond
            // one is ~1.7e12 already. A fixture failing this means the API flipped back to milliseconds and the
            // on-chain expiry check would be inert again.
            assertLt(fixture_.sigExpiration, 1e11, string.concat(label_, ": sigExpiration must be UNIX SECONDS, not ms"));
            // Absolute-timestamp guard: any plausible fetch time is past Nov 2023 (1.7e9). A fixture failing this
            // means sigExpiration became a RELATIVE TTL (e.g. 300) or garbage — small values would still pass the
            // validate-at-default-timestamp and unit-agnostic boundary tests, hiding the regression until the
            // fork suite runs.
            assertGt(
                fixture_.sigExpiration,
                1_700_000_000,
                string.concat(label_, ": sigExpiration must be an absolute UNIX-seconds timestamp, not a relative TTL")
            );

            (,,,, bytes memory swapData_) = _decodeNewApiData(fixture_.apiData);
            NewApiSwapData memory swap_ = _decodeNewApiSwapData(swapData_);
            if (swap_.feeTo) feeToTrueCount_++;
            else feeToFalseCount_++;

            bytes32 combo_ = keccak256(abi.encode(fixture_.pair, fixture_.aggregator));
            for (uint256 j = 0; j < i; ++j) {
                assertTrue(seenCombos_[j] != combo_, string.concat(label_, ": duplicate pair/aggregator combination"));
            }
            seenCombos_[i] = combo_;

            bool knownPair_;
            for (uint256 k = 0; k < pairs_.length; ++k) {
                if (keccak256(bytes(fixture_.pair)) == keccak256(bytes(pairs_[k]))) {
                    pairCounts_[k]++;
                    knownPair_ = true;
                }
            }
            assertTrue(knownPair_, string.concat(label_, ": unknown pair label"));
        }

        for (uint256 k = 0; k < pairs_.length; ++k) {
            assertEq(pairCounts_[k], 5, string.concat(pairs_[k], ": expected 5 aggregators for this pair"));
        }
        assertGt(feeToTrueCount_, 0, "fixture set must contain at least one feeTo=true payload (fee on output token)");
        assertGt(feeToFalseCount_, 0, "fixture set must contain at least one feeTo=false payload (fee on tokenFrom)");
    }
}

/**
 * @title DelegationMetaSwapAdapterNewApiForkTest
 * @notice FORK tests replaying the 15 real signed quotes (3 pairs x 5 aggregators) end to end through
 *         swapByDelegation on a Linea fork pinned at the block the quotes were fetched (NEW_API_FORK_BLOCK).
 *         The adapter is constructed with the REAL dev-API signer (expected to match production) and the
 *         SignatureData is built from the fixture verbatim — nothing is signed locally.
 * @dev When the fixtures are refreshed (scripts/fetch_new_api_signed_quotes.sh) the fork block pin is
 *      regenerated together with the quotes, keeping on-chain liquidity consistent with the quoted amounts.
 * @dev EVM VERSION: this suite requires a post-London executor spec because the live Linea aggregator
 *      contracts (1inch v6 executor, KyberSwap, Mayan, Relay) use post-London opcodes such as PUSH0, which
 *      revert with `EvmError: NotActivated` under the repo's default `evm_version = "london"`. The suite
 *      SELF-SKIPS (vm.skip, before any RPC access) when the executor is pre-Shanghai, so a plain `forge test`
 *      (locally and in CI) stays green without running it. Run it for real with:
 *          FOUNDRY_PROFILE=linea-fork forge test --match-contract DelegationMetaSwapAdapterNewApiForkTest
 *      (or pass `--evm-version prague`). CI runs it that way in a dedicated step (.github/workflows/test.yml).
 *      The okx6 tests are the only ones that happen to pass under london.
 * @dev SCOPE: this suite proves CODE-level compatibility only. It deploys a FRESH adapter configured with
 *      NEW_API_SWAP_API_SIGNER and whitelists each fixture's aggregator id and tokens itself. It deliberately
 *      does NOT check the owner-side configuration of any already-deployed adapter instance (its swapApiSigner,
 *      aggregator-id whitelist or token whitelist); rolling the new API out against a deployed adapter still
 *      requires verifying/updating that configuration (e.g. whitelisting the new aggregator ids such as okx6,
 *      oneInchV6FeeDynamic, kyberSwapFeeDynamic, mayanFeeDynamic, relayAdapterV3, relayNativeAdapterV3).
 */
contract DelegationMetaSwapAdapterNewApiForkTest is DelegationMetaSwapAdapterBaseTest, DelegationMetaSwapAdapterNewApiTestHelpers {
    uint256 public mainnetFork;
    IDelegationManager public constant DELEGATION_MANAGER_FORK = IDelegationManager(0x739309deED0Ae184E66a427ACa432aE1D91d022e);
    HybridDeleGator public constant HYBRID_DELEGATOR_IMPL_FORK =
        HybridDeleGator(payable(0xf4E57F579ad8169D0d4Da7AedF71AC3f83e8D2b4));
    EntryPoint public constant ENTRY_POINT_FORK = EntryPoint(payable(0x0000000071727De22E5E9d8BAf0edAc6f37da032));

    /// @dev True when the runtime executor spec is pre-Shanghai (default profile, evm_version = "london"), in
    /// which case every test in this suite self-skips instead of failing with EvmError: NotActivated.
    bool public forkSuiteUnsupported;

    /// @dev Skips the test (instead of failing) when the executor spec cannot run live Linea aggregator bytecode.
    modifier requiresPostLondonExecutor() {
        vm.skip(forkSuiteUnsupported);
        _;
    }

    function setUp() public override {
        // GATING: probe the runtime executor spec BEFORE touching any RPC. Under the repo's default profile
        // (evm_version = "london") the live Linea aggregator contracts cannot execute (PUSH0 -> NotActivated),
        // so the whole suite self-skips and plain `forge test` runs stay green with no network access.
        forkSuiteUnsupported = !_executorSupportsPostLondon();
        if (forkSuiteUnsupported) return;

        // *** Create the fork before any other setup runs ***
        // The block MUST stay pinned to NEW_API_FORK_BLOCK (the block the signed quotes were fetched at) so the
        // on-chain liquidity matches the quotes. Do not bump this block without re-fetching fixtures.
        mainnetFork = vm.createSelectFork(vm.envOr("LINEA_RPC_URL", string("https://rpc.linea.build")), NEW_API_FORK_BLOCK);

        // GUARD: sigExpiration is a UNIX timestamp in SECONDS with a short TTL (~5 min observed), and the
        // adapter enforces it on-chain (block.timestamp >= expiration => SignatureExpired). The pinned fork
        // block's timestamp must therefore precede EVERY fixture's expiration, or the replays would revert with
        // SignatureExpired for a timing reason that reads like a compatibility failure. Fail loudly here instead.
        for (uint256 i = 0; i < NEW_API_FIXTURE_COUNT; ++i) {
            require(
                block.timestamp < _getNewApiFixture(i).sigExpiration,
                "DelegationMetaSwapAdapterNewApiForkTest: pinned fork block is at/after quote expiration - re-run "
                "scripts/fetch_new_api_signed_quotes.sh which re-fetches quotes and re-pins the block together"
            );
        }

        super.setUp();
    }

    /// @dev Detects whether the runtime executor supports post-London opcodes by executing PUSH0 (0x5f,
    /// Shanghai): `PUSH0 PUSH0 RETURN` succeeds on Shanghai+ and reverts with NotActivated on London.
    function _executorSupportsPostLondon() private returns (bool supported_) {
        address probe_ = makeAddr("push0Probe");
        vm.etch(probe_, hex"5f5ff3");
        (supported_,) = probe_.call("");
    }

    ////////////////////////////// ERC20 -> ERC20 //////////////////////////////

    function test_newApi_swap_Erc20ToErc20_okx6() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_Erc20ToErc20_okx());
    }

    function test_newApi_swap_Erc20ToErc20_oneInchV6FeeDynamic() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_Erc20ToErc20_oneInch());
    }

    function test_newApi_swap_Erc20ToErc20_kyberSwapFeeDynamic() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_Erc20ToErc20_kyberswap());
    }

    function test_newApi_swap_Erc20ToErc20_mayanFeeDynamic() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_Erc20ToErc20_mayan());
    }

    function test_newApi_swap_Erc20ToErc20_relayAdapterV3() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_Erc20ToErc20_relay());
    }

    ////////////////////////////// Native -> ERC20 //////////////////////////////

    function test_newApi_swap_NativeToErc20_okx6() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_NativeToErc20_okx());
    }

    function test_newApi_swap_NativeToErc20_oneInchV6FeeDynamic() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_NativeToErc20_oneInch());
    }

    function test_newApi_swap_NativeToErc20_kyberSwapFeeDynamic() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_NativeToErc20_kyberswap());
    }

    function test_newApi_swap_NativeToErc20_mayanFeeDynamic() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_NativeToErc20_mayan());
    }

    function test_newApi_swap_NativeToErc20_relayNativeAdapterV3() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_NativeToErc20_relayNative());
    }

    ////////////////////////////// ERC20 -> Native //////////////////////////////

    function test_newApi_swap_Erc20ToNative_okx6() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_Erc20ToNative_okx());
    }

    function test_newApi_swap_Erc20ToNative_oneInchV6FeeDynamic() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_Erc20ToNative_oneInch());
    }

    function test_newApi_swap_Erc20ToNative_kyberSwapFeeDynamic() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_Erc20ToNative_kyberswap());
    }

    function test_newApi_swap_Erc20ToNative_mayanFeeDynamic() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_Erc20ToNative_mayan());
    }

    function test_newApi_swap_Erc20ToNative_relayAdapterV3() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_Erc20ToNative_relay());
    }

    ////////////////////////////// Token whitelist not enforced //////////////////////////////

    /// @notice Same end-to-end replay but through the useTokenWhitelist=false path: the owner never whitelists
    /// the tokens and the delegation's ArgsEqualityCheckEnforcer terms commit to WHITELIST_NOT_ENFORCED. This is
    /// the production flow that works without owner-side token whitelisting, exercised with a real API payload.
    function test_newApi_swap_Erc20ToErc20_okx6_whitelistNotEnforced() public requiresPostLondonExecutor {
        _runNewApiForkSwap(_newApiFixture_Erc20ToErc20_okx(), false);
    }

    ////////////////////////////// Internal helpers //////////////////////////////

    /**
     * @dev Runs a full swapByDelegation flow for the given fixture: sets up the fork contracts from the fixture's
     *      apiData, builds the vault -> subVault -> adapter delegation chain, replays the REAL SignatureData
     *      verbatim and asserts the vault's balances moved as quoted.
     */
    function _runNewApiForkSwap(NewApiFixture memory _fixture) internal {
        _runNewApiForkSwap(_fixture, true);
    }

    function _runNewApiForkSwap(NewApiFixture memory _fixture, bool _useTokenWhitelist) internal {
        string memory label_ = _fixtureLabel(_fixture);
        bytes memory swapData_ = _setUpNewApiForkContracts(_fixture.apiData, _useTokenWhitelist);
        NewApiSwapData memory swap_ = _decodeNewApiSwapData(swapData_);

        // Sanity: the quote metadata matches what the contract decodes out of apiData.
        assertEq(address(tokenA), _fixture.srcToken, string.concat(label_, ": decoded tokenFrom mismatch"));
        assertEq(address(tokenB), _fixture.destToken, string.concat(label_, ": decoded tokenTo mismatch"));
        assertEq(amountFrom, _fixture.srcTokenAmount, string.concat(label_, ": decoded amountFrom mismatch"));
        assertEq(amountTo, _fixture.minDestTokenAmount, string.concat(label_, ": decoded amountTo mismatch"));
        assertEq(_fixture.tradeTo, NEW_API_META_SWAP, string.concat(label_, ": quote trade.to is not the MetaSwap contract"));

        Delegation[] memory delegations_ = new Delegation[](2);
        Delegation memory vaultDelegation_ = _getVaultDelegation();
        Delegation memory subVaultDelegation_ = _getSubVaultDelegation(EncoderLib._getDelegationHash(vaultDelegation_));
        delegations_[1] = vaultDelegation_;
        delegations_[0] = subVaultDelegation_;

        uint256 vaultTokenFromBalanceBefore_ = _balanceOf(address(tokenA), address(vault.deleGator));
        uint256 vaultTokenToBalanceBefore_ = _balanceOf(address(tokenB), address(vault.deleGator));
        uint256 feeWalletTokenToBalanceBefore_ = _balanceOf(address(tokenB), swap_.feeWallet);

        // The REAL API signature data, replayed VERBATIM (apiData + seconds-unit sigExpiration + signature).
        // This only validates because the fork is pinned at the fetch-time block, whose timestamp is inside the
        // quote's ~5 min TTL window (see the setUp guard).
        DelegationMetaSwapAdapter.SignatureData memory sigData_ = DelegationMetaSwapAdapter.SignatureData({
            apiData: _fixture.apiData, expiration: _fixture.sigExpiration, signature: _fixture.signature
        });

        vm.prank(address(subVault.deleGator));
        delegationMetaSwapAdapter.swapByDelegation(sigData_, delegations_, _useTokenWhitelist);

        uint256 vaultTokenFromUsed_ = vaultTokenFromBalanceBefore_ - _balanceOf(address(tokenA), address(vault.deleGator));
        uint256 vaultTokenToObtained_ = _balanceOf(address(tokenB), address(vault.deleGator)) - vaultTokenToBalanceBefore_;

        assertEq(vaultTokenFromUsed_, amountFrom, string.concat(label_, ": vault should spend exactly amountFrom"));

        // The decoded amountTo is the quote's minimum output. API SEMANTIC: for feeTo=true quotes the quoted
        // minDestTokenAmount is GROSS of the fee — MetaSwap's aggregator adapter enforces the swap-level minimum
        // first and only then pays feeAmount (in the OUTPUT token) to feeWallet, so the vault can net as little
        // as amountTo - feeAmount. The tolerance is pinned to the fee by asserting the feeWallet received
        // exactly feeAmount, so it cannot mask an aggregator under-delivering to the vault.
        if (swap_.feeTo) {
            assertEq(
                _balanceOf(address(tokenB), swap_.feeWallet) - feeWalletTokenToBalanceBefore_,
                swap_.feeAmount,
                string.concat(label_, ": feeWallet should receive exactly feeAmount when feeTo is true")
            );
        }
        uint256 minAmountOut_ = swap_.feeTo ? amountTo - swap_.feeAmount : amountTo;
        assertGe(vaultTokenToObtained_, minAmountOut_, string.concat(label_, ": vault should receive at least the quoted minimum"));
    }

    /**
     * @dev Configures the fork contracts from the fixture's apiData, mirroring the original fork test setup but
     *      with the adapter constructed with the REAL dev-API signer (NEW_API_SWAP_API_SIGNER, expected to match
     *      production).
     */
    function _setUpNewApiForkContracts(bytes memory _apiData, bool _useTokenWhitelist) private returns (bytes memory swapData_) {
        // Overriding values with the Linea mainnet deployments
        entryPoint = ENTRY_POINT_FORK;
        delegationMetaSwapAdapter = new DelegationMetaSwapAdapter(
            owner,
            NEW_API_SWAP_API_SIGNER,
            DELEGATION_MANAGER_FORK,
            IMetaSwap(NEW_API_META_SWAP),
            address(argsEqualityCheckEnforcer)
        );
        delegationManager = DelegationManager(address(DELEGATION_MANAGER_FORK));
        hybridDeleGatorImpl = HYBRID_DELEGATOR_IMPL_FORK;

        users = _createUsers();
        vault = users.alice;
        subVault = users.bob;

        string memory aggregatorId_;
        IERC20 tokenFrom_;
        IERC20 tokenTo_;
        uint256 amountFrom_;
        uint256 amountTo_;
        (aggregatorId_, tokenFrom_, amountFrom_, swapData_) = _decodeApiData(_apiData);

        _whiteListAggregatorId(aggregatorId_);

        (, tokenTo_,, amountTo_) = _decodeApiSwapData(swapData_);
        tokenA = BasicERC20(address(tokenFrom_));
        tokenB = BasicERC20(address(tokenTo_));
        amountFrom = amountFrom_;
        amountTo = amountTo_;

        if (_useTokenWhitelist) {
            _updateAllowedTokens();
        } else {
            // useTokenWhitelist=false path: the owner never whitelists the tokens; instead the delegation's
            // ArgsEqualityCheckEnforcer terms must commit to the whitelist-not-enforced args the adapter passes.
            argsEqualityEnforcerTerms = abi.encode(WHITELIST_NOT_ENFORCED);
        }

        if (address(tokenFrom_) != address(0)) {
            deal(address(tokenFrom_), address(vault.deleGator), 1_000_000 ether);
        }
        // For native tokenFrom the vault's DeleGator already holds 100 ether (see BaseTest.createUser).
    }

    /// @dev Returns `_account`'s balance of `_token` (native balance when `_token` is address(0)).
    function _balanceOf(address _token, address _account) private view returns (uint256) {
        if (_token == address(0)) return _account.balance;
        return IERC20(_token).balanceOf(_account);
    }
}
