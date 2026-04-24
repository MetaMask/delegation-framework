#!/usr/bin/env bash
# verify-contract.sh
#
# Usage:
#   ./verify-contract.sh
#
# Verifies multiple contracts (with optional constructor arguments) 
# across multiple chains.

set -e

# Load environment variables
set -o allexport
source ../../.env
set +o allexport

# Load shared logic
source ./verify-utils.sh

##########################################
# Helper functions for contract configuration
##########################################

# Function to encode constructor arguments
encode_args() {
    local signature="$1"
    shift
    cast abi-encode "$signature" "$@"
}

# Function to add a contract to verify
add_contract() {
    local name="$1"
    local path="$2"
    local address="$3"
    local constructor_args="$4"
    local lib_string="$5"
    
    # Add to contracts array
    CONTRACTS+=("$name:$path:$address:$constructor_args:$lib_string")
}

##########################################
# Contract Configurations
##########################################

# Initialize empty array
declare -a CONTRACTS

# DelegationManager
add_contract \
    "DelegationManager" \
    "src/DelegationManager.sol" \
    "0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3" \
    "$(encode_args "constructor(address)" \
        "0xB0403B32f54d0Bd752113f4009e8B534C6669f44")" \
    ""

# MultiSigDeleGator
add_contract \
    "MultiSigDeleGator" \
    "src/MultiSigDeleGator.sol" \
    "0x56a9EdB16a0105eb5a4C54f4C062e2868844f3A7" \
    "$(encode_args "constructor(address,address)" \
        "0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3" \
        "0x0000000071727De22E5E9d8BAf0edAc6f37da032")" \
    ""

# EIP7702StatelessDeleGator
add_contract \
    "EIP7702StatelessDeleGator" \
    "src/EIP7702/EIP7702StatelessDeleGator.sol" \
    "0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B" \
    "$(encode_args "constructor(address,address)" \
        "0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3" \
        "0x0000000071727De22E5E9d8BAf0edAc6f37da032")" \
    ""

# NativeTokenPaymentEnforcer
add_contract \
    "NativeTokenPaymentEnforcer" \
    "src/enforcers/NativeTokenPaymentEnforcer.sol" \
    "0x4803a326ddED6dDBc60e659e5ed12d85c7582811" \
    "$(encode_args "constructor(address,address)" \
        "0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3" \
        "0x44B8C6ae3C304213c3e298495e12497Ed3E56E41")" \
    ""

# LogicalOrWrapperEnforcer
add_contract \
    "LogicalOrWrapperEnforcer" \
    "src/enforcers/LogicalOrWrapperEnforcer.sol" \
    "0xE1302607a3251AF54c3a6e69318d6aa07F5eB46c" \
    "$(encode_args "constructor(address)" \
        "0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3")" \
    ""

# DelegationMetaSwapAdapter
# Constructor args (in order): owner, swapApiSigner, delegationManager, metaSwap, weth
add_contract \
    "DelegationMetaSwapAdapter" \
    "src/helpers/DelegationMetaSwapAdapter.sol" \
    "0xbb56322416A4E3C1f64Eb4ace298Cce9FD376D35" \
    "$(encode_args "constructor(address,address,address,address,address)" \
        "0xbA560d1320983bC9Da64d3A14d0E912A4cE549a6" \
        "0xbA560d1320983bC9Da64d3A14d0E912A4cE549a6" \
        "0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3" \
        "0x9dDA6Ef3D919c9bC8885D5560999A3640431e8e6" \
        "0x3aAB2285ddcDdaD8edf438C1bAB47e1a9D05a9b4")" \
    ""

# SimpleFactory
add_contract \
    "SimpleFactory" \
    "src/utils/SimpleFactory.sol" \
    "0x69Aa2f9fe1572F1B640E1bbc512f5c3a734fc77c" \
    "" \
    ""

# Add more contracts here:
# add_contract "ContractName" "path/to/contract.sol" "0xAddress" "$(encode_args "constructor(type)" "value")" ""

##########################################
# Process Contracts
##########################################

# Process each contract
for contract in "${CONTRACTS[@]}"; do
    # Split the configuration string
    IFS=':' read -r name path address constructor_args lib_string <<< "$contract"
    
    echo "============================================="
    echo "Verifying contract: $name"
    echo "============================================="
    
    # Call the shared function
    verify_across_chains \
        "$path" \
        "$name" \
        "$address" \
        "$constructor_args" \
        "$lib_string"
    
    echo "============================================="
    echo "Completed verification for: $name"
    echo "============================================="
    echo
done
