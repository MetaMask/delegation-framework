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
  "BlockNumberEnforcer"
  "DeployedEnforcer"
  "ERC20BalanceChangeEnforcer"
  "ERC20TransferAmountEnforcer"
  "ERC20PeriodTransferEnforcer"
  "ERC20StreamingEnforcer"
  "ERC721BalanceChangeEnforcer"
  "ERC721TransferEnforcer"
  "ERC1155BalanceChangeEnforcer"
  "ExactCalldataBatchEnforcer"
  "ExactCalldataEnforcer"
  "ExactExecutionBatchEnforcer"
  "ExactExecutionEnforcer"
  "IdEnforcer"
  "LimitedCallsEnforcer"
  "MultiTokenPeriodEnforcer"
  "NativeBalanceChangeEnforcer"
  "ArgsEqualityCheckEnforcer"
  "NativeTokenTransferAmountEnforcer"
  "NativeTokenStreamingEnforcer"
  "NativeTokenPeriodTransferEnforcer"
  "NonceEnforcer"
  "OwnershipTransferEnforcer"
  "RedeemerEnforcer"
  "SpecificActionERC20TransferBatchEnforcer"
  "TimestampEnforcer"
  "ValueLteEnforcer"
  "ERC20MultiOperationIncreaseBalanceEnforcer"
  "ERC721MultiOperationIncreaseBalanceEnforcer"
  "ERC1155MultiOperationIncreaseBalanceEnforcer"
  "NativeTokenMultiOperationIncreaseBalanceEnforcer"
)

ADDRESSES=(
  "0xc2b0d624c1c4319760C96503BA27C347F3260f55"
  "0x2c21fD0Cb9DC8445CB3fb0DC5E7Bb0Aca01842B5"
  "0x7F20f61b1f09b08D970938F6fa563634d65c4EeB"
  "0x5d9818dF0AE3f66e9c3D0c5029DAF99d1823ca6c"
  "0x24ff2AA430D53a8CD6788018E902E098083dcCd2"
  "0xcdF6aB796408598Cea671d79506d7D48E97a5437"
  "0xf100b0819427117EcF76Ed94B358B1A5b5C6D2Fc"
  "0x474e3Ae7E169e940607cC624Da8A15Eb120139aB"
  "0x56c97aE02f233B29fa03502Ecc0457266d9be00e"
  "0x8aFdf96eDBbe7e1eD3f5Cd89C7E084841e12A09e"
  "0x3790e6B7233f779b09DA74C72b6e94813925b9aF"
  "0x63c322732695cAFbbD488Fc6937A0A7B66fC001A"
  "0x982FD5C86BBF425d7d1451f974192d4525113DfD"
  "0x99F2e9bF15ce5eC84685604836F71aB835DBBdED"
  "0x1e141e455d08721Dd5BCDA1BaA6Ea5633Afd5017"
  "0x146713078D39eCC1F5338309c28405ccf85Abfbb"
  "0xC8B5D93463c893401094cc70e66A206fb5987997"
  "0x04658B29F6b82ed55274221a06Fc97D318E25416"
  "0xFB2f1a9BD76d3701B730E5d69C3219D42D80eBb7"
  "0xbD7B277507723490Cd50b12EaaFe87C616be6880"
  "0x44B8C6ae3C304213c3e298495e12497Ed3E56E41"
  "0xF71af580b9c3078fbc2BBF16FbB8EEd82b330320"
  "0xD10b97905a320b13a0608f7E9cC506b56747df19"
  "0x9BC0FAf4Aca5AE429F4c06aEEaC517520CB16BD9"
  "0xDE4f2FAC4B3D87A1d9953Ca5FC09FCa7F366254f"
  "0x7EEf9734E7092032B5C56310Eb9BbD1f4A524681"
  "0xE144b0b2618071B4E56f746313528a669c7E65c5"
  "0x6649b61c873F6F9686A1E1ae9ee98aC380c7bA13"
  "0x1046bb45C8d673d4ea75321280DB34899413c069"
  "0x92Bf12322527cAA612fd31a0e810472BBB106A8F"
  "0xeaA1bE91F0ea417820a765df9C5BE542286BFfDC"
  "0x44877cDAFC0d529ab144bb6B0e202eE377C90229"
  "0x9eB86bbdaA71D4D8d5Fb1B8A9457F04D3344797b"
  "0xaD551E9b971C1b0c02c577bFfCFAA20b81777276"
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
