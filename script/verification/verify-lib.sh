#!/usr/bin/env bash
# verify-lib.sh
#
# Usage:
#   ./verify-lib.sh
#
# Verifies a library deployed at the same address across multiple chains.
# Has no constructor arguments.

set -e

# Load environment variables
set -o allexport
source ../../.env
set +o allexport

# Load shared logic
source verify-utils.sh

# Example for contract verfication
###############################################################################

CONTRACT_PATH="lib/SCL/src/lib/libSCL_RIP7212.sol"
CONTRACT_NAME="SCL_RIP7212"
ADDRESS="0xCCD3B747F3DBd349fa3af4eBC7d0C31aE6f21dd1"

# No constructor, no external library references
CONSTRUCTOR_ARGS=""
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
