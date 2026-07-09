#!/usr/bin/env bash
#
# Fetches fresh SIGNED quotes from the new swap API and regenerates the new-API test fixtures:
#   1. GETs https://bridge.dev-api.cx.metamask.io/getQuote (signQuotes=true) for the 3 Linea pairs:
#        - ERC20  -> ERC20  (USDC -> WETH)
#        - NATIVE -> ERC20  (ETH  -> USDC)
#        - ERC20  -> NATIVE (USDC -> ETH)
#   2. Rebuilds test/helpers/data/new_api_fixtures.json (same shape consumed by the generator), capturing the
#      CURRENT Linea block number via `cast block-number` as meta.fetchedAtLineaBlock.
#   3. Runs scripts/generate_new_api_fixtures.py, which regenerates
#      test/helpers/DelegationMetaSwapAdapterNewApiFixtures.t.sol.
#
# IMPORTANT: the fork block pin used by DelegationMetaSwapAdapterNewApiForkTest is the generated constant
# NEW_API_FORK_BLOCK, which comes from meta.fetchedAtLineaBlock. Because this script captures the block number
# at fetch time, re-running it updates the fork pin ALONGSIDE the fresh quotes automatically — never bump the
# fork block without re-fetching quotes (and vice versa), or the quoted amounts will not match on-chain
# liquidity and the fork tests will produce false failures.
#
# EXPIRATION / TIMING: the API returns `sigExpiration` as a UNIX timestamp in SECONDS with a short TTL
# (~5 minutes observed), and the adapter's on-chain check (block.timestamp >= expiration => SignatureExpired)
# genuinely enforces it. That makes fetch->pin timing matter: the pinned block's timestamp MUST be earlier than
# every quote's sigExpiration, or the fork tests will revert with SignatureExpired. This script fetches the
# quotes and captures the block in one run precisely so the pinned timestamp lands inside the TTL window; if a
# run is unusually slow (or the fork setUp guard trips later), simply re-run this script to re-fetch and re-pin
# together.
#
# Requirements: curl, jq, cast (foundry), python3.
#
# Usage:
#   ./scripts/fetch_new_api_signed_quotes.sh
#   LINEA_RPC_URL=<url> ./scripts/fetch_new_api_signed_quotes.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_JSON="${REPO_ROOT}/test/helpers/data/new_api_fixtures.json"

API_BASE="https://bridge.dev-api.cx.metamask.io/getQuote"
CHAIN_ID=59144
# Arbitrary EOA used only to request quotes. The MetaSwap architecture pays the swap output to msg.sender
# (the adapter), so the quoted walletAddress should not affect on-chain execution. If an aggregator ever
# embeds it as a recipient in trade.data, the fork tests will surface it as a real compatibility finding.
WALLET_ADDRESS="0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
SLIPPAGE=2
USDC="0x176211869cA2b568f2A7D4EE941E073a821EE1ff"
WETH="0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f"
NATIVE="0x0000000000000000000000000000000000000000"
USDC_AMOUNT="1000000000"          # 1,000 USDC (6 decimals)
NATIVE_AMOUNT="1000000000000000000" # 1 ETH

LINEA_RPC_URL="${LINEA_RPC_URL:-https://rpc.linea.build}"
QUERY_PARAMS="slippage=${SLIPPAGE}&insufficientBal=true&signQuotes=true"

for tool in curl jq cast python3; do
    command -v "${tool}" > /dev/null || { echo "error: ${tool} is required" >&2; exit 1; }
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fetch_pair() {
    # fetch_pair <pairLabel> <srcToken> <destToken> <srcTokenAmount>
    local pair="$1" src="$2" dest="$3" amount="$4"
    local url="${API_BASE}?walletAddress=${WALLET_ADDRESS}&srcChainId=${CHAIN_ID}&destChainId=${CHAIN_ID}"
    url+="&srcTokenAddress=${src}&destTokenAddress=${dest}&srcTokenAmount=${amount}&${QUERY_PARAMS}"

    echo "Fetching ${pair} quotes..." >&2
    local raw="${TMP_DIR}/${pair}_raw.json"
    curl -sSf --max-time 120 "${url}" > "${raw}"

    # SILENT-FILTER GUARD: the jq filter below keeps only signed, MetaSwap-format quotes (selector 0x5f575529).
    # Any quote the API returns in a different shape is a quote the CURRENT adapter cannot execute — that is a
    # potential COMPATIBILITY FINDING, not noise, so it must be surfaced loudly rather than silently excluded.
    local total_count filtered_count
    total_count="$(jq 'length' "${raw}")"
    filtered_count="$(jq '[ .[]
                            | select(.signature != null and .sigExpiration != null)
                            | select(.trade.data | ascii_downcase | startswith("0x5f575529"))
                          ] | length' "${raw}")"
    echo "  ${pair}: ${filtered_count}/${total_count} quotes are signed MetaSwap-format quotes" >&2
    if [ "${filtered_count}" -ne "${total_count}" ]; then
        echo "WARNING: ${pair}: DROPPED $((total_count - filtered_count)) quote(s) that are unsigned or not" >&2
        echo "         IMetaSwap.swap calldata. The CURRENT DelegationMetaSwapAdapter cannot execute these —" >&2
        echo "         investigate them as potential adapter/API compatibility findings before trusting the" >&2
        echo "         regenerated fixtures. Dropped quotes:" >&2
        jq -c '[ .[]
                 | select((.signature == null) or (.sigExpiration == null)
                          or ((.trade.data | ascii_downcase | startswith("0x5f575529")) | not))
                 | { aggregator: .quote.bridgeId,
                     quoteId: .quoteId,
                     signed: (.signature != null and .sigExpiration != null),
                     tradeTo: .trade.to,
                     tradeDataSelector: (.trade.data[0:10]) }
               ] | .[]' "${raw}" >&2
    fi

    jq \
        --arg pair "${pair}" \
        --arg src "${src}" \
        --arg dest "${dest}" \
        --arg amount "${amount}" \
        '[ .[]
           | select(.signature != null and .sigExpiration != null)
           | select(.trade.data | ascii_downcase | startswith("0x5f575529"))  # IMetaSwap.swap selector only
           | {
               pair: $pair,
               aggregator: .quote.bridgeId,
               quoteId: .quoteId,
               srcToken: $src,
               destToken: $dest,
               srcTokenAmount: $amount,
               destTokenAmount: (.quote.destTokenAmount | tostring),
               minDestTokenAmount: (.quote.minDestTokenAmount | tostring),
               tradeTo: .trade.to,
               tradeValue: (.trade.value | tostring),
               apiData: .trade.data,
               sigExpiration: .sigExpiration,
               signature: .signature
             }
         ]' "${raw}"
}

fetch_pair "ERC20_TO_ERC20" "${USDC}" "${WETH}" "${USDC_AMOUNT}" > "${TMP_DIR}/erc20_to_erc20.json"
fetch_pair "NATIVE_TO_ERC20" "${NATIVE}" "${USDC}" "${NATIVE_AMOUNT}" > "${TMP_DIR}/native_to_erc20.json"
fetch_pair "ERC20_TO_NATIVE" "${USDC}" "${NATIVE}" "${USDC_AMOUNT}" > "${TMP_DIR}/erc20_to_native.json"

# Capture the current Linea block: this becomes the fork pin for the fork tests (see header note).
echo "Fetching current Linea block number..." >&2
LINEA_BLOCK="$(cast block-number --rpc-url "${LINEA_RPC_URL}")"

jq -n \
    --arg source "${API_BASE}?signQuotes=true" \
    --argjson block "${LINEA_BLOCK}" \
    --argjson chainId "${CHAIN_ID}" \
    --arg walletAddress "${WALLET_ADDRESS}" \
    --arg queryParams "${QUERY_PARAMS}" \
    --arg usdc "${USDC}" \
    --arg weth "${WETH}" \
    --slurpfile a "${TMP_DIR}/erc20_to_erc20.json" \
    --slurpfile b "${TMP_DIR}/native_to_erc20.json" \
    --slurpfile c "${TMP_DIR}/erc20_to_native.json" \
    '{
        meta: {
            source: $source,
            fetchedAtLineaBlock: $block,
            chainId: $chainId,
            # SIGNER PIN: this is the swap API signing key observed on bridge.dev-api.cx.metamask.io (a DEV
            # environment whose key can rotate independently of production). The generator re-derives the signer
            # from every fresh signature and FAILS if it no longer matches this pin. If that happens, the dev
            # API key most likely rotated: update this constant (and re-check the deployed swapApiSigner) rather
            # than suspecting a contract incompatibility. InvalidApiSignature failures after a refresh usually
            # mean key rotation, not adapter breakage.
            expectedSigner: "0xe672B534ccf9876a7554a1dD1685a2a5C2Cc8e8C",
            metaSwap: "0x9dDA6Ef3D919c9bC8885D5560999A3640431e8e6",
            delegationManager: "0x739309deED0Ae184E66a427ACa432aE1D91d022e",
            hybridDeleGatorImpl: "0xf4E57F579ad8169D0d4Da7AedF71AC3f83e8D2b4",
            entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
            walletAddressUsedInQuote: $walletAddress,
            queryParams: $queryParams,
            usdc: $usdc,
            weth: $weth
        },
        quotes: ($a[0] + $b[0] + $c[0])
    }' > "${OUT_JSON}"

QUOTE_COUNT="$(jq '.quotes | length' "${OUT_JSON}")"
echo "Wrote ${OUT_JSON} (${QUOTE_COUNT} signed quotes, Linea block ${LINEA_BLOCK})" >&2

if [ "${QUOTE_COUNT}" -ne 15 ]; then
    echo "warning: expected 15 quotes (3 pairs x 5 aggregators), got ${QUOTE_COUNT}." >&2
    echo "         The aggregator set returned by the API may have changed; if so, update the fork test" >&2
    echo "         function list in test/helpers/DelegationMetaSwapAdapterNewApi.t.sol to match the new" >&2
    echo "         fixture getters." >&2
fi

python3 "${REPO_ROOT}/scripts/generate_new_api_fixtures.py" "${OUT_JSON}"

echo "Done. Run 'forge fmt && forge build' and then the test suites:" >&2
echo "  forge test --match-contract DelegationMetaSwapAdapterNewApiSignatureCompatTest" >&2
echo "  FOUNDRY_PROFILE=linea-fork LINEA_RPC_URL=<archive rpc> forge test --match-contract DelegationMetaSwapAdapterNewApiForkTest" >&2
echo "  (FOUNDRY_PROFILE=linea-fork is REQUIRED: under the default london profile the fork tests self-skip" >&2
echo "   and report '16 skipped', validating nothing.)" >&2
