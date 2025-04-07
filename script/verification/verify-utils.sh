#!/usr/bin/env bash
# verify-utils.sh
#
# This file holds shared logic for verifying contracts across multiple chains.

#################################
# Default Chains to Iterate Over
#################################
CHAIN_IDS=(
  1          # ethereum
  11155111   # sepolia
  59141      # linea-sepolia
  59144      # linea
  8453       # base
  84532      # base-sepolia
  10         # optimism
  42161      # arbitrum
  137        # polygon
  100        # gnosis
  56         # binance
)

##########################################
# FUNCTION: get_api_key(chain_id)
#
# Fetch the appropriate API key based on
# the chain ID from environment variables.
##########################################
get_api_key() {
    local chain_id="$1"
    case "$chain_id" in
        1) echo "$ETHERSCAN_API_KEY" ;; # ethereum
        11155111) echo "$ETHERSCAN_API_KEY" ;;  # sepolia
        59141)    echo "$LINEASCAN_API_KEY" ;; # linea-sepolia
        59144)    echo "$LINEASCAN_API_KEY" ;; # linea
        8453)     echo "$BASESCAN_API_KEY"  ;; # base
        84532)    echo "$BASESCAN_API_KEY"  ;; # base-sepolia
        10)       echo "$OPTIMISTIC_API_KEY" ;; # optimism
        42161)    echo "$ARBISCAN_API_KEY"   ;; # arbitrum
        137)      echo "$POLYGONSCAN_API_KEY" ;; # polygon
        100)      echo "$GNOSISSCAN_API_KEY" ;; # gnosis
        56)       echo "$BINANCESCAN_API_KEY" ;; # binance
        *)
            echo "Unknown chain ID: $chain_id" >&2
            return 1
        ;;
    esac
}

#########################################################################
# FUNCTION: verify_across_chains
#
# Parameters:
#   1) contract_file: e.g. src/MyContract.sol
#   2) contract_name: e.g. MyContract
#   3) contract_address: Deployed address (0x...)
#   4) encoded_constructor_args: Optional; pass "" if none
#   5) library_string: Optional; pass "" if none
#
# Usage: verify_across_chains "$file" "$name" "$address" "$constructor_args" "$lib_string"
#
# Where 'lib_string' might look like:
#   "lib/SCL/src/lib/libSCL_RIP7212.sol:SCL_RIP7212:0x06d0e66B..."
#
#########################################################################
verify_across_chains() {
  local contract_file="$1"
  local contract_name="$2"
  local contract_address="$3"
  local constructor_args="$4"       # Could be empty
  local library_string="$5"         # Could be empty

  for chain_id in "${CHAIN_IDS[@]}"; do
      echo "============================================="
      echo "Verifying $contract_name at $contract_address on chain: $chain_id"
      echo "============================================="
      local api_key
      api_key="$(get_api_key "$chain_id")"

      # Build the base forge verify command
      local cmd=(
        forge verify-contract
        --chain-id "$chain_id"
        --num-of-optimizations 200
        --watch
        --etherscan-api-key "$api_key"
        "$contract_address"
        "$contract_file:$contract_name"
      )

      # If we have constructor args
      if [[ -n "$constructor_args" ]]; then
        cmd+=( --constructor-args "$constructor_args" )
      fi

      # If we have a library string
      if [[ -n "$library_string" ]]; then
        cmd+=( --libraries "$library_string" )
      fi

      echo "Running: ${cmd[*]}"
      "${cmd[@]}"

      echo "Verification of $contract_name on chain $chain_id completed."
      echo
  done
}
