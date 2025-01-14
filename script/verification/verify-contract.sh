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
CONTRACT_NAME="HybridDeleGator"
CONTRACT_PATH="src/$CONTRACT_NAME.sol"
ADDRESS="0xf4E57F579ad8169D0d4Da7AedF71AC3f83e8D2b4"

# Example: you can encode constructor arguments with cast directly here:
CONSTRUCTOR_ARGS=$(cast abi-encode \
  "constructor(address, address)" \
  "0x739309deED0Ae184E66a427ACa432aE1D91d022e" \
  "0x0000000071727De22E5E9d8BAf0edAc6f37da032")

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
