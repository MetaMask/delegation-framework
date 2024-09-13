#!/bin/bash

################################################################################
# Verifies contracts across multiple chains
# - Requires contracts to be at the same address on every chain
# - Requires the appropriate API keys to be set in .env
# - Requires the contracts to have no constructor arguments
################################################################################

# Note: Array lengths must line up
ENFORCERS=()
ADDRESSES=()

# sepolia, linea-sepolia, linea, base, optimism, arbitrum, polygon
CHAIN_IDS=(11155111 59141 59144 8453 10 42161 137)

set -o allexport
source .env
set +o allexport

# Function to get the appropriate API key based on chain ID
get_api_key() {
    case $1 in
        11155111) echo "$ETHERSCAN_API_KEY" ;;
        59144) echo "$LINEASCAN_API_KEY" ;;
        59141) echo "$LINEASCAN_API_KEY" ;;
        8453) echo "$BASESCAN_API_KEY" ;;
        10) echo "$OPTIMISTIC_ETHERSCAN_API_KEY" ;;
        42161) echo "$ARBISCAN_API_KEY" ;;
        137) echo "$POLYGONSCAN_API_KEY" ;;
        *) echo "Unknown chain ID" && return 1 ;;
    esac
}
for ((i=0; i<${#ENFORCERS[@]}; i++)); do
    echo "Iteration $i"
    echo "-------------------------------------------"

    CONTRACT=${ENFORCERS[i]}
    ADDRESS=${ADDRESSES[i]}

    for CHAIN_ID in "${CHAIN_IDS[@]}"
    do
        API_KEY=$(get_api_key $CHAIN_ID)

        echo "Verifying $CONTRACT at $ADDRESS on $CHAIN_ID..."

        forge verify-contract \
            --chain-id $CHAIN_ID \
            --num-of-optimizations 200 \
            --watch \
            --etherscan-api-key $API_KEY \
            $ADDRESS \
            src/enforcers/$CONTRACT.sol:$CONTRACT

        echo "Verification of $CONTRACT on $CHAIN_ID completed."
        echo "-------------------------------------------"
    done
done
