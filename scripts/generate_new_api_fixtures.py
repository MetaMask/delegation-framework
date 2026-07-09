#!/usr/bin/env python3
"""
Generates test/helpers/DelegationMetaSwapAdapterNewApiFixtures.t.sol from a JSON file of
signed quotes captured from the new swap API (bridge.dev-api.cx.metamask.io/getQuote).

Usage:
    python3 scripts/generate_new_api_fixtures.py [path/to/new_api_fixtures.json]

Defaults to test/helpers/data/new_api_fixtures.json (relative to the repo root, which is
assumed to be the parent directory of this script's directory).

The JSON file is produced by scripts/fetch_new_api_signed_quotes.sh and has the shape:
    {
      "meta": {
        "fetchedAtLineaBlock": <uint>,     # emitted as NEW_API_FORK_BLOCK; the fork tests pin this block
        "expectedSigner": "0x...",         # emitted as NEW_API_SWAP_API_SIGNER
        "metaSwap": "0x...",
        "usdc": "0x...",
        "weth": "0x...",
        ...
      },
      "quotes": [
        {
          "pair": "ERC20_TO_ERC20" | "NATIVE_TO_ERC20" | "ERC20_TO_NATIVE",
          "aggregator": "okx" | "1inch" | "kyberswap" | "mayan" | "relay" | "relay_native",
          "quoteId": "...",
          "srcToken": "0x...", "destToken": "0x...",
          "srcTokenAmount": "<dec>", "destTokenAmount": "<dec>", "minDestTokenAmount": "<dec>",
          "tradeTo": "0x...", "tradeValue": "0x<hex>",
          "apiData": "0x5f575529...",      # IMetaSwap.swap calldata, verbatim from trade.data
          "sigExpiration": <uint, UNIX SECONDS>,   # ~5 min TTL observed; the on-chain expiry check enforces it
          "signature": "0x...",            # 65-byte ECDSA signature, verbatim from the API
        }, ...
      ]
    }

IMPORTANT: the signatures/expirations are embedded VERBATIM. Nothing is re-signed here; the
generated fixtures are only useful for validating the REAL API signer against the on-chain
signature checks. When quotes are re-fetched, the fork block pin (meta.fetchedAtLineaBlock)
is refreshed too, so the fork tests always run against a block consistent with the quotes.
"""

import json
import os
import re
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
DEFAULT_JSON = os.path.join(REPO_ROOT, "test", "helpers", "data", "new_api_fixtures.json")
OUTPUT_SOL = os.path.join(REPO_ROOT, "test", "helpers", "DelegationMetaSwapAdapterNewApiFixtures.t.sol")

PAIR_TO_CAMEL = {
    "ERC20_TO_ERC20": "Erc20ToErc20",
    "NATIVE_TO_ERC20": "NativeToErc20",
    "ERC20_TO_NATIVE": "Erc20ToNative",
}

# Solidity identifiers cannot start with a digit and cannot contain '_>' etc.
AGGREGATOR_TO_IDENT = {
    "1inch": "oneInch",
    "relay_native": "relayNative",
}


def to_checksum(address: str) -> str:
    """Checksum an address, preferring `cast` (always available in this Foundry repo)."""
    address = address.lower()
    if address == "0x" + "0" * 40:
        return "address(0)"
    try:
        out = subprocess.run(
            ["cast", "to-check-sum-address", address], capture_output=True, text=True, check=True
        ).stdout.strip()
        if re.fullmatch(r"0x[0-9a-fA-F]{40}", out):
            return out
    except (OSError, subprocess.CalledProcessError):
        pass
    # Fallback: trust the casing in the JSON (the fetch script stores checksummed addresses).
    return address


def aggregator_ident(aggregator: str) -> str:
    ident = AGGREGATOR_TO_IDENT.get(aggregator, aggregator)
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", ident):
        raise ValueError(f"Cannot derive a Solidity identifier from aggregator {aggregator!r}")
    return ident


def parse_uint(value) -> int:
    if isinstance(value, int):
        return value
    value = str(value)
    return int(value, 16) if value.startswith("0x") else int(value)


def hex_literal(value: str) -> str:
    value = value.lower()
    if not value.startswith("0x"):
        raise ValueError(f"Expected 0x-prefixed hex, got {value[:16]!r}")
    return f'hex"{value[2:]}"'


def _cast(*args: str) -> str:
    return subprocess.run(["cast", *args], capture_output=True, text=True, check=True).stdout.strip()


def verify_expected_signer(meta: dict, quotes: list) -> None:
    """Recover the signer of every quote's signature and assert it matches meta.expectedSigner.

    meta.expectedSigner is a PINNED constant in scripts/fetch_new_api_signed_quotes.sh, and the quotes come from
    bridge.dev-api.cx.metamask.io — a DEV environment whose signing key can rotate independently of production.
    Without this check, a key rotation would regenerate fixtures that confidently document the WRONG signer, and
    the signature-compat tests would then fail with InvalidApiSignature — which reads exactly like the genuine
    contract-incompatibility signal the suite exists to detect. Verifying here turns that failure mode into an
    actionable error at refresh time.

    The verification mirrors DelegationMetaSwapAdapter._validateSignature exactly:
        signer == ecrecover(toEthSignedMessageHash(keccak256(abi.encode(apiData, sigExpiration))), signature)
    (`cast wallet verify` applies the EIP-191 personal-sign prefix to the 32-byte inner hash.)
    """
    expected = meta["expectedSigner"]
    try:
        for i, quote in enumerate(quotes):
            encoded = _cast("abi-encode", "f(bytes,uint256)", quote["apiData"], str(parse_uint(quote["sigExpiration"])))
            inner_hash = _cast("keccak", encoded)
            try:
                result = _cast("wallet", "verify", "--address", expected, inner_hash, quote["signature"])
            except subprocess.CalledProcessError:
                result = ""
            if "Validation succeeded" not in result:
                sys.exit(
                    f"error: quote {i} ({quote['pair']}/{quote['aggregator']}) does NOT recover to the pinned "
                    f"expectedSigner {expected}.\n"
                    "       The dev API signing key has most likely ROTATED (dev-api quotes are environment-"
                    "specific).\n"
                    "       Update expectedSigner in scripts/fetch_new_api_signed_quotes.sh (and re-check the "
                    "deployed adapter's swapApiSigner) — this is almost certainly NOT a contract incompatibility."
                )
    except OSError:
        print(
            "warning: `cast` unavailable; skipping signer recovery check. The Solidity test "
            "test_newApi_validateSignature_allFixtures still enforces it on-chain-equivalently.",
            file=sys.stderr,
        )
        return
    print(f"Verified: all {len(quotes)} signatures recover to expectedSigner {expected}")


def main() -> None:
    json_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_JSON
    with open(json_path) as f:
        data = json.load(f)

    meta = data["meta"]
    quotes = data["quotes"]

    verify_expected_signer(meta, quotes)

    checksums = {}

    def addr(a: str) -> str:
        key = a.lower()
        if key not in checksums:
            checksums[key] = to_checksum(a)
        return checksums[key]

    fixture_fns = []
    getter_cases = []
    seen_names = set()

    for index, quote in enumerate(quotes):
        pair = quote["pair"]
        fn_name = f"_newApiFixture_{PAIR_TO_CAMEL[pair]}_{aggregator_ident(quote['aggregator'])}"
        if fn_name in seen_names:
            raise ValueError(f"Duplicate fixture name {fn_name}; add a disambiguator")
        seen_names.add(fn_name)
        getter_cases.append(f"        if (_index == {index}) return {fn_name}();")

        api_data = quote["apiData"]
        assert api_data.lower().startswith("0x5f575529"), f"{fn_name}: apiData is not IMetaSwap.swap calldata"
        signature = quote["signature"]
        assert len(signature) == 2 + 65 * 2, f"{fn_name}: signature is not 65 bytes"

        fixture_fns.append(
            f"""    /// @dev index {index} | quoteId {quote["quoteId"]} | apiData {len(api_data) // 2 - 1} bytes
    function {fn_name}() internal pure returns (NewApiFixture memory) {{
        return NewApiFixture({{
            pair: "{pair}",
            aggregator: "{quote["aggregator"]}",
            quoteId: "{quote["quoteId"]}",
            srcToken: {addr(quote["srcToken"])},
            destToken: {addr(quote["destToken"])},
            srcTokenAmount: {parse_uint(quote["srcTokenAmount"])},
            destTokenAmount: {parse_uint(quote["destTokenAmount"])},
            minDestTokenAmount: {parse_uint(quote["minDestTokenAmount"])},
            tradeTo: {addr(quote["tradeTo"])},
            tradeValue: {parse_uint(quote["tradeValue"])},
            apiData: {hex_literal(api_data)},
            sigExpiration: {parse_uint(quote["sigExpiration"])},
            signature: {hex_literal(signature)}
        }});
    }}"""
        )

    newline = "\n"
    sol = f"""// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

/**
 * @title DelegationMetaSwapAdapterNewApiFixtures
 * @notice AUTOGENERATED by scripts/generate_new_api_fixtures.py — DO NOT EDIT BY HAND.
 *         Refresh with scripts/fetch_new_api_signed_quotes.sh (re-fetches signed quotes and re-runs the generator).
 *
 * Real signed quotes captured VERBATIM from the new swap API:
 *   {meta.get("source", "https://bridge.dev-api.cx.metamask.io/getQuote?signQuotes=true")}
 *   query params: {meta.get("queryParams", "")}
 *   wallet address used in quotes: {meta.get("walletAddressUsedInQuote", "")}
 *   fetched at Linea (chain {meta.get("chainId", 59144)}) block {meta["fetchedAtLineaBlock"]}
 *
 * `apiData` is the IMetaSwap.swap calldata (trade.data), `signature`/`sigExpiration` are the API's
 * signature over keccak256(abi.encode(apiData, sigExpiration)) (EIP-191 personal-sign) and its
 * expiration. NOTE: sigExpiration is a UNIX timestamp in SECONDS (~5 min TTL observed), so the
 * adapter's on-chain expiry check (block.timestamp >= expiration => SignatureExpired) genuinely
 * enforces it. Fork tests still replay fine because the fork pins the block captured at fetch
 * time, whose timestamp precedes every sigExpiration.
 * Nothing here is locally signed; the whole point of these fixtures is validating the REAL API
 * signer ({meta["expectedSigner"]}) against DelegationMetaSwapAdapter as deployed.
 */
abstract contract DelegationMetaSwapAdapterNewApiFixtures {{
    struct NewApiFixture {{
        string pair;
        string aggregator;
        string quoteId;
        address srcToken;
        address destToken;
        uint256 srcTokenAmount;
        uint256 destTokenAmount;
        uint256 minDestTokenAmount;
        address tradeTo;
        uint256 tradeValue;
        bytes apiData;
        uint256 sigExpiration; // UNIX timestamp in SECONDS (on-chain expiry is enforced; ~5 min TTL)
        bytes signature;
    }}

    uint256 internal constant NEW_API_FIXTURE_COUNT = {len(quotes)};

    /// @dev Linea block at which the quotes were fetched. Fork tests must pin this block so on-chain
    /// liquidity matches the quotes. Refreshing quotes via scripts/fetch_new_api_signed_quotes.sh
    /// updates this constant automatically.
    uint256 internal constant NEW_API_FORK_BLOCK = {meta["fetchedAtLineaBlock"]};

    /// @dev The dev-API swap signer the quotes' signatures recover to (expected to match production; confirm the
    /// deployed adapter's swapApiSigner and the production endpoint's seconds-unit sigExpiration at rollout).
    address internal constant NEW_API_SWAP_API_SIGNER = {addr(meta["expectedSigner"])};

    address internal constant NEW_API_META_SWAP = {addr(meta["metaSwap"])};
    address internal constant NEW_API_USDC = {addr(meta["usdc"])};
    address internal constant NEW_API_WETH = {addr(meta["weth"])};

    function _getNewApiFixture(uint256 _index) internal pure returns (NewApiFixture memory) {{
{newline.join(getter_cases)}
        revert("DelegationMetaSwapAdapterNewApiFixtures: index out of bounds");
    }}

{(newline + newline).join(fixture_fns)}
}}
"""

    with open(OUTPUT_SOL, "w") as f:
        f.write(sol)
    print(f"Wrote {OUTPUT_SOL} ({len(quotes)} fixtures, fork block {meta['fetchedAtLineaBlock']})")


if __name__ == "__main__":
    main()
