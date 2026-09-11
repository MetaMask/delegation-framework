#!/usr/bin/env bash
# verify-metaswap-order-delegation-manager.sh
#
# Usage:
#   ./verify-metaswap-order-delegation-manager.sh
#
# Experimental. Verifies MetaSwapOrderDelegationManager across configured chains.
# Requires in .env:
#   META_SWAP_ORDER_DELEGATION_MANAGER_ADDRESS

set -e

set -o allexport
source ../../.env
set +o allexport

source ./verify-utils.sh

declare -a CONTRACTS

add_contract() {
    local name="$1"
    local path="$2"
    local address="$3"
    local constructor_args="$4"
    local lib_string="$5"
    CONTRACTS+=("$name:$path:$address:$constructor_args:$lib_string")
}

add_contract \
    "MetaSwapOrderDelegationManager" \
    "src/MetaSwapOrderDelegationManager.sol" \
    "${META_SWAP_ORDER_DELEGATION_MANAGER_ADDRESS}" \
    "" \
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
