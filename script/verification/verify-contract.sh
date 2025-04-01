#!/usr/bin/env bash
# verify-contract.sh
#
# Usage:
#   ./verify-contract.sh
#
# Verifies a standard contract (with optional constructor arguments) 
# across multiple chains.

set -e

# Load environment variables
set -o allexport
source ../../.env
set +o allexport

# Load shared logic
source ./verify-utils.sh

# Example for contract verfication
###############################################################################
CONTRACT_NAME="NativeTokenPaymentEnforcer"
CONTRACT_PATH="src/enforcers/$CONTRACT_NAME.sol"
ADDRESS="0x4803a326ddED6dDBc60e659e5ed12d85c7582811"

# Example: you can encode constructor arguments with cast directly here:

CONSTRUCTOR_ARGS=$(cast abi-encode \
  "constructor(address,address)" \
  "0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3" \
  "0x44B8C6ae3C304213c3e298495e12497Ed3E56E41" \
  )

# No external library references
LIB_STRING=""

###############################################################################
# Call the shared function
###############################################################################
verify_across_chains \
  "$CONTRACT_PATH" \
  "$CONTRACT_NAME" \
  "$ADDRESS" \
  "$CONSTRUCTOR_ARGS" \
  "$LIB_STRING"
