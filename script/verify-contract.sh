#!/bin/bash

################################################################################
# Verifies a contract across multiple chains
# - Requires the contract to be at the same address on every chain
# - Requires the appropriate API keys to be set in .env
################################################################################

# Example usage:
# CONTRACT=DelegationManager
# ADDRESS=0x0000000000000000000000000000000000000000
# CONSTRUCTOR="constructor(string,string,uint256,uint256)" "ForgeUSD" "FUSD" 18 1000000000000000000000

CONTRACT=NativeTokenPaymentEnforcer
ADDRESS=0x87Fe18EbF99e42fcE8A03a25F1d20E119407f8e7
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address, address)" "0x56D56e07e3d6Ee5a24e30203A37a0a460f42D7A3" "0x7378dE585998d3E18Ce147867C335C25B3dB8Ee5")

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

for CHAIN_ID in "${CHAIN_IDS[@]}"
    do
        API_KEY=$(get_api_key $CHAIN_ID)

        echo "Verifying $CONTRACT at $ADDRESS on $CHAIN_ID..."

        forge verify-contract \
            --chain-id $CHAIN_ID \
            --num-of-optimizations 200 \
            --watch \
            --constructor-args $CONSTRUCTOR_ARGS \
            --etherscan-api-key $API_KEY \
            $ADDRESS \
            src/enforcers/$CONTRACT.sol:$CONTRACT

        echo "Verification of $CONTRACT on $CHAIN_ID completed."
        echo "-------------------------------------------"
    done
