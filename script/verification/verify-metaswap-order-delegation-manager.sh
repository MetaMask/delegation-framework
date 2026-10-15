#!/usr/bin/env bash
# verify-metaswap-order-delegation-manager.sh
#
# Usage:
#   ./verify-metaswap-order-delegation-manager.sh
#
# Verifies MetaSwapOrderDelegationManager across configured chains.
# The constructor takes no arguments.
# Requires in .env:
#   META_SWAP_ORDER_DELEGATION_MANAGER_ADDRESS

set -e

# Load environment variables
set -o allexport
source ../../.env
set +o allexport

# Load shared logic
source ./verify-utils.sh

##########################################
# Helper functions for contract configuration
##########################################

# Function to add a contract to verify
add_contract() {
    local name="$1"
    local path="$2"
    local address="$3"
    local constructor_args="$4"
    local lib_string="$5"

    # Add to contracts array
    CONTRACTS+=("$name:$path:$address:$constructor_args:$lib_string")
}

##########################################
# Contract Configurations
##########################################

# Initialize empty array
declare -a CONTRACTS

# MetaSwapOrderDelegationManager
add_contract \
    "MetaSwapOrderDelegationManager" \
    "src/MetaSwapOrderDelegationManager.sol" \
    "${META_SWAP_ORDER_DELEGATION_MANAGER_ADDRESS}" \
    "" \
    ""

##########################################
# Process Contracts
##########################################

# Process each contract
for contract in "${CONTRACTS[@]}"; do
    # Split the configuration string
    IFS=':' read -r name path address constructor_args lib_string <<< "$contract"

    echo "============================================="
    echo "Verifying contract: $name"
    echo "============================================="

    # Call the shared function
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
