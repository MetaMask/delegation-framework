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
  560048     # hoodi
  59144      # linea
  59141      # linea-sepolia
  8453       # base
  84532      # base-sepolia
  10         # optimism
  11155420   # optimism-sepolia
  42161      # arbitrum
  42170      # arbitrum nova
  421614     # arbitrum-sepolia
  137        # polygon
  80002      # polygon-amoy
  100        # gnosis
  10200      # gnosis-chiado
  56         # binance
  97         # binance-testnet
  80094      # berachain
  80069      # berachain-testnet
  130        # unichain
  1301       # unichain-sepolia
  10143      # monad-testnet
  5115       # citrea-testnet
  57073      # ink
  763373     # ink-sepolia
  1329       # sei
  1328       # sei-testnet
  146        # sonic
  14601      # sonic-testnet
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
        1)        config=("$ETHERSCAN_API_KEY" "etherscan" "$MAINNET_RPC_URL" "https://etherscan.io/") ;; # ethereum
        11155111) config=("$ETHERSCAN_API_KEY" "etherscan" "$SEPOLIA_RPC_URL" "https://sepolia.etherscan.io/") ;;  # sepolia
        560048)   config=("$ETHERSCAN_API_KEY" "etherscan" "$HOODI_RPC_URL" "https://hoodi.etherscan.io/") ;; # hoodi
        59144)    config=("$ETHERSCAN_API_KEY" "etherscan" "$LINEA_RPC_URL" "https://lineascan.build/") ;; # linea
        59141)    config=("$ETHERSCAN_API_KEY" "etherscan" "$LINEA_SEPOLIA_RPC_URL" "https://sepolia.lineascan.build/") ;; # linea-sepolia
        8453)     config=("$ETHERSCAN_API_KEY" "etherscan" "$BASE_RPC_URL" "https://basescan.org/")  ;; # base
        84532)    config=("$ETHERSCAN_API_KEY" "etherscan" "$BASE_SEPOLIA_RPC_URL" "https://sepolia.basescan.org/")  ;; # base-sepolia
        10)       config=("$ETHERSCAN_API_KEY" "etherscan" "$OPTIMISM_RPC_URL" "https://optimistic.etherscan.io/") ;; # optimism
        11155420) config=("$ETHERSCAN_API_KEY" "etherscan" "$OPTIMISM_SEPOLIA_RPC_URL" "https://sepolia-optimism.etherscan.io/") ;; # optimism-sepolia
        42161)    config=("$ETHERSCAN_API_KEY" "etherscan" "$ARBITRUM_RPC_URL" "https://arbiscan.io/")   ;; # arbitrum
        42170)    config=("$ETHERSCAN_API_KEY" "etherscan" "$ARBITRUM_NOVA_RPC_URL" "")   ;; # arbitrum nova
        421614)   config=("$ETHERSCAN_API_KEY" "etherscan" "$ARBITRUM_SEPOLIA_RPC_URL" "https://sepolia.arbiscan.io/") ;; # arbitrum-sepolia
        137)      config=("$ETHERSCAN_API_KEY" "etherscan" "$POLYGON_RPC_URL" "https://polygonscan.com/") ;; # polygon
        80002)    config=("$ETHERSCAN_API_KEY" "etherscan" "$POLYGON_AMOY_RPC_URL" "https://amoy.polygonscan.com/") ;; # polygon-amoy
        100)      config=("$ETHERSCAN_API_KEY" "etherscan" "$GNOSIS_RPC_URL" "https://gnosisscan.io/") ;; # gnosis
        10200)    config=("$GNOSISSCAN_API_KEY" "blockscout" "$GNOSIS_CHIADO_RPC_URL" "https://gnosis-chiado.blockscout.com/api") ;; # gnosis-chiado
        56)       config=("$ETHERSCAN_API_KEY" "etherscan" "$BINANCE_RPC_URL" "https://bscscan.com/") ;; # binance
        97)       config=("$ETHERSCAN_API_KEY" "etherscan" "$BINANCE_TESTNET_RPC_URL" "https://testnet.bscscan.com/") ;; # binance-testnet
        80094)    config=("$BERACHAIN_API_KEY" "custom" "$BERACHAIN_RPC_URL" "https://api.berascan.com/api") ;; # berachain
        80069)    config=("$BERACHAIN_API_KEY" "custom" "$BERACHAIN_TESTNET_RPC_URL" "https://api-testnet.berascan.com/api") ;; # berachain-testnet
        130)      config=("$UNICHAIN_API_KEY" "custom" "$UNICHAIN_RPC_URL" "https://api.uniscan.xyz/api") ;; # unichain
        1301)     config=("$UNICHAIN_API_KEY" "custom" "$UNICHAIN_SEPOLIA_RPC_URL" "https://api-sepolia.uniscan.xyz/api") ;; # unichain-sepolia
        10143)    config=("$ETHERSCAN_API_KEY" "etherscan" "$MONAD_TESTNET_RPC_URL" "") ;; # unichain-sepolia
        5115)     config=("key" "blockscout" "$CITREA_TESTNET_RPC_URL" "https://explorer.testnet.citrea.xyz/api") ;; # citrea-testnet
        57073)    config=("key" "blockscout" "$INK_RPC_URL" "https://explorer.inkonchain.com/api") ;; # ink
        763373)   config=("key" "blockscout" "$INK_SEPOLIA_RPC_URL" "https://explorer-sepolia.inkonchain.com/api") ;; # ink-sepolia
        1329)     config=("key" "custom" "$SEI_RPC_URL" "https://seitrace.com/pacific-1/api") ;; # sei
        1328)     config=("key" "custom" "$SEI_TESTNET_RPC_URL" "https://seitrace.com/atlantic-2/api") ;; # sei-testnet
        146)      config=("$ETHERSCAN_API_KEY" "etherscan" "$SONIC_RPC_URL" "https://api.etherscan.io/v2/api?chainid=146") ;; # sonic
        14601)    config=("$ETHERSCAN_API_KEY" "etherscan" "$SONIC_TESTNET_RPC_URL" "https://api.etherscan.io/v2/api?chainid=14601") ;; # sonic-testnet
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
        --num-of-optimizations 200
      )

       # Only add if verifier is not custom, the custom verifier is simpler
      if [[ "$verifier" != "custom" ]]; then
        cmd+=( --rpc-url "$rpc_url" )
        cmd+=( --chain-id "$chain_id" )
        cmd+=( --verifier "$verifier" )
      fi

      # Only add etherscan-api-key if verifier is etherscan or custom
      if { [[ "$verifier" == "etherscan" ]] || [[ "$verifier" == "custom" ]]; } && [[ "$api_key" != "key" ]]; then
        cmd+=( --etherscan-api-key "$api_key" )
      fi

      # Only add verifier-url if verifier is blockscout or custom
      if [[ "$verifier" == "blockscout" ]] || [[ "$verifier" == "custom" ]]; then
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