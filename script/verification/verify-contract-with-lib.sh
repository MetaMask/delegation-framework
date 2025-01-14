#!/usr/bin/env bash
# verify-contract-with-lib.sh
# 
# Usage:
#   ./verify-contract-with-lib.sh
# 
# This script verifies a contract with an external library reference.
# Customize the variables below as needed.

set -e

# Load environment variables (API keys, etc.)
set -o allexport
source ../../.env
set +o allexport

# Load shared logic
source verify-utils.sh

###############################################################################
# User Configuration
###############################################################################

CONTRACT_NAME="HybridDeleGator"
CONTRACT_PATH="src/$CONTRACT_NAME.sol"
ADDRESS="0xf4E57F579ad8169D0d4Da7AedF71AC3f83e8D2b4"

LIB_FILE="lib/SCL/src/lib/libSCL_RIP7212.sol"
LIB_NAME="SCL_RIP7212"
LIB_ADDRESS="0x06d0e66B5c97398a14eF4227d107C24A588CDb40"

# Example constructor arguments (encoded with cast)
CONSTRUCTOR_ARGS=$(cast abi-encode \
  "constructor(address, address)" \
  "0x739309deED0Ae184E66a427ACa432aE1D91d022e" \
  "0x0000000071727De22E5E9d8BAf0edAc6f37da032")

# Build library string
LIB_STRING="$LIB_FILE:$LIB_NAME:$LIB_ADDRESS"

###############################################################################
# Call the shared function
###############################################################################
verify_across_chains \
  "$CONTRACT_PATH" \
  "$CONTRACT_NAME" \
  "$ADDRESS" \
  "$CONSTRUCTOR_ARGS" \
  "$LIB_STRING"
