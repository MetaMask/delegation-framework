#!/usr/bin/env bash
# verify-metaswap-intent-delegation-manager.sh
#
# Usage:
#   ./verify-metaswap-intent-delegation-manager.sh
#
# Experimental. Verifies MetaSwapIntentDelegationManager across configured chains.
# Requires in .env:
#   META_SWAP_INTENT_DELEGATION_MANAGER_ADDRESS
#   SIGNATURE_MODE   # 0 = DirectECDSA, 1 = ERC1271

set -e

set -o allexport
source ../../.env
set +o allexport

source ./verify-utils.sh

encode_args() {
    local signature="$1"
    shift
    cast abi-encode "$signature" "$@"
}

declare -a CONTRACTS

add_contract() {
    local name="$1"
    local path="$2"
    local address="$3"
    local constructor_args="$4"
    local lib_string="$5"
    CONTRACTS+=("$name:$path:$address:$constructor_args:$lib_string")
}

MODE="${SIGNATURE_MODE:-0}"

add_contract \
    "MetaSwapIntentDelegationManager" \
    "src/MetaSwapIntentDelegationManager.sol" \
    "${META_SWAP_INTENT_DELEGATION_MANAGER_ADDRESS}" \
    "$(encode_args "constructor(uint8)" "$MODE")" \
    ""

for contract in "${CONTRACTS[@]}"; do
    IFS=':' read -r name path address constructor_args lib_string <<< "$contract"

    echo "============================================="
    echo "Verifying contract: $name"
    echo "============================================="

    verify_across_chains \
        "$path" \
        "$name" \
        "$address" \
        "$constructor_args" \
        "$lib_string"

    echo "============================================="
    echo "Completed verification for: $name"
    echo "============================================="
    echo
done
