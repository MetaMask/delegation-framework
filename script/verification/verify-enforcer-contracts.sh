#!/usr/bin/env bash
# verify-enforcer-contracts.sh
#
# Usage:
#   ./verify-enforcer-contracts.sh
#
# Verifies an array of "enforcer" contracts across multiple chains.
# Assumes no constructor arguments, no libraries. 
# Each contract must be at the same index in the ENFORCERS and ADDRESSES arrays.
# Update the script with changes in enforcer names or new enforcers before using it.

set -e

# Load environment variables
set -o allexport
source ../../.env
set +o allexport

# Load shared logic
source verify-utils.sh

###############################################################################
# Hard-coded arrays for enforcers:
###############################################################################
ENFORCERS=(
  "AllowedCalldataEnforcer"
  "AllowedMethodsEnforcer"
  "AllowedTargetsEnforcer"
  "ArgsEqualityCheckEnforcer"
  "BlockNumberEnforcer"
  "DeployedEnforcer"
  "ERC20BalanceGteEnforcer"
  "ERC20TransferAmountEnforcer"
  "ERC721BalanceGteEnforcer"
  "ERC721TransferEnforcer"
  "ERC1155BalanceGteEnforcer"
  "IdEnforcer"
  "LimitedCallsEnforcer"
  "NativeBalanceGteEnforcer"
  "NativeTokenTransferAmountEnforcer"
  "NonceEnforcer"
  "OwnershipTransferEnforcer"
  "RedeemerEnforcer"
  "TimestampEnforcer"
  "ValueLteEnforcer"
)

ADDRESSES=(
  "0x1111111111111111111111111111111111111111"
  "0x2222222222222222222222222222222222222222"
  "0x3333333333333333333333333333333333333333"
  "0x4444444444444444444444444444444444444444"
  "0x5555555555555555555555555555555555555555"
  "0x6666666666666666666666666666666666666666"
  "0x7777777777777777777777777777777777777777"
  "0x8888888888888888888888888888888888888888"
  "0x9999999999999999999999999999999999999999"
  "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  "0xcccccccccccccccccccccccccccccccccccccccc"
  "0xdddddddddddddddddddddddddddddddddddddddd"
  "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  "0xffffffffffffffffffffffffffffffffffffffff"
  "0x0000000000000000000000000000000000000000"
  "0x1212121212121212121212121212121212121212"
  "0x1313131313131313131313131313131313131313"
  "0x1414141414141414141414141414141414141414"
  "0x1515151515151515151515151515151515151515"
)

###############################################################################
# Iterate & Verify
###############################################################################
len=${#ENFORCERS[@]}

for (( i=0; i<"$len"; i++ )); do
  CONTRACT_NAME="${ENFORCERS[$i]}"
  ADDRESS="${ADDRESSES[$i]}"

  echo "-------------------------------------------"
  echo "Verifying enforcer: $CONTRACT_NAME at $ADDRESS"
  echo "-------------------------------------------"

  # We assume each Enforcer is in `src/enforcers/<Name>.sol:<Name>`
  CONTRACT_PATH="src/enforcers/$CONTRACT_NAME.sol"

  verify_across_chains \
    "$CONTRACT_PATH" \
    "$CONTRACT_NAME" \
    "$ADDRESS" \
    ""  \
    ""  # No library references
done
