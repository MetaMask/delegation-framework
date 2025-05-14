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
  59144      # linea
  59141      # linea-sepolia
  8453       # base
  84532      # base-sepolia
  10         # optimism
  11155420   # optimism-sepolia
  42161      # arbitrum
  421614     # arbitrum-sepolia
  137        # polygon
  100        # gnosis
  10200      # gnosis-chiado
  56         # binance
  97         # binance-testnet
  80069      # berachain-testnet
)

##########################################
# FUNCTION: get_chain_config(chain_id)
#
# Fetch the appropriate API key, verifier, RPC URL, and verifier URL
# based on the chain ID from environment variables.
#
# Returns: array with [api_key, verifier, rpc_url, verifier_url]
##########################################
get_chain_config() {
    local chain_id="$1"
    local -a config
    case "$chain_id" in
        1) config=("$ETHERSCAN_API_KEY" "etherscan" "$MAINNET_RPC_URL" "https://etherscan.io/") ;; # ethereum
        11155111) config=("$ETHERSCAN_API_KEY" "etherscan" "$SEPOLIA_RPC_URL" "https://sepolia.etherscan.io/") ;;  # sepolia
        59144)    config=("$LINEASCAN_API_KEY" "etherscan" "$LINEA_RPC_URL" "https://lineascan.build/") ;; # linea
        59141)    config=("$LINEASCAN_API_KEY" "etherscan" "$LINEA_SEPOLIA_RPC_URL" "https://sepolia.lineascan.build/") ;; # linea-sepolia
        8453)     config=("$BASESCAN_API_KEY" "etherscan" "$BASE_RPC_URL" "https://basescan.org/")  ;; # base
        84532)    config=("$BASESCAN_API_KEY" "etherscan" "$BASE_SEPOLIA_RPC_URL" "https://sepolia.basescan.org/")  ;; # base-sepolia
        10)       config=("$OPTIMISTIC_API_KEY" "etherscan" "$OPTIMISM_RPC_URL" "https://optimistic.etherscan.io/") ;; # optimism
        11155420) config=("$OPTIMISTIC_API_KEY" "etherscan" "$OPTIMISM_SEPOLIA_RPC_URL" "https://sepolia-optimism.etherscan.io/") ;; # optimism-sepolia
        42161)    config=("$ARBISCAN_API_KEY" "etherscan" "$ARBITRUM_RPC_URL" "https://arbiscan.io/")   ;; # arbitrum
        421614)   config=("$ARBISCAN_API_KEY" "etherscan" "$ARBITRUM_SEPOLIA_RPC_URL" "https://sepolia.arbiscan.io/") ;; # arbitrum-sepolia
        137)      config=("$POLYGONSCAN_API_KEY" "etherscan" "$POLYGON_RPC_URL" "https://polygonscan.com/") ;; # polygon
        100)      config=("$GNOSISSCAN_API_KEY" "etherscan" "$GNOSIS_RPC_URL" "https://gnosisscan.io/") ;; # gnosis
        10200) config=("$GNOSISSCAN_API_KEY" "blockscout" "$GNOSIS_CHIADO_RPC_URL" "https://gnosis-chiado.blockscout.com/api") ;; # gnosis-chiado
        56)       config=("$BINANCESCAN_API_KEY" "etherscan" "$BINANCE_RPC_URL" "https://bscscan.com/") ;; # binance
        97)       config=("$BINANCESCAN_API_KEY" "etherscan" "$BINANCE_TESTNET_RPC_URL" "https://testnet.bscscan.com/") ;; # binance-testnet
        80069)    config=("$BERACHAIN_API_KEY" "etherscan" "$BERACHAIN_TESTNET_RPC_URL" "https://testnet.berascan.com/") ;; # berachain-testnet
        *)
            echo "Unknown chain ID: $chain_id" >&2
            return 1
        ;;
    esac
    echo "${config[@]}"
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
      
      # Get all chain config values at once
      local -a config
      config=($(get_chain_config "$chain_id"))
      local api_key="${config[0]}"
      local verifier="${config[1]}"
      local rpc_url="${config[2]}"
      local verifier_url="${config[3]}"
      # Build the base forge verify command
      local cmd=(
        forge verify-contract
        --rpc-url "$rpc_url"
        --chain-id "$chain_id"
        --num-of-optimizations 200
        --verifier "$verifier"
      )

      # Only add etherscan-api-key if verifier is etherscan
      if [[ "$verifier" == "etherscan" ]]; then
        cmd+=( --etherscan-api-key "$api_key" )
      fi

      # Only add verifier-url if verifier is blockscout
      if [[ "$verifier" == "blockscout" ]]; then
        cmd+=( --verifier-url "$verifier_url" )
      fi

      cmd+=( --watch "$contract_address" "$contract_file:$contract_name" )

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
