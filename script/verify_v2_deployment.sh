#!/usr/bin/env bash
set -euo pipefail

RPC_URL="${ARC_RPC_URL:-https://rpc.mainnet.arc.io}"
CAST_BIN="${CAST_BIN:-cast}"
FACTORY="${1:-}"
VAULT="${2:-}"
EXPECTED_OWNER="${3:-}"
EXPECTED_KEY="${4:-}"

fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }
command -v "$CAST_BIN" >/dev/null 2>&1 || fail "missing cast binary: $CAST_BIN"
[[ "$FACTORY" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail 'factory address must be 20-byte hex'
[[ "$VAULT" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail 'vault address must be 20-byte hex'
[[ "$EXPECTED_OWNER" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail 'owner address must be 20-byte hex'
[[ "$EXPECTED_KEY" =~ ^0x[0-9a-fA-F]{64}$ && "$EXPECTED_KEY" != 0x$(printf '0%.0s' {1..64}) ]] || fail 'PQ key must be nonzero 32-byte hex'

chain_id="$($CAST_BIN chain-id --rpc-url "$RPC_URL" | tr -d '[:space:]')"
[[ "$chain_id" == "$EXPECTED_CHAIN_ID" ]] || fail "chain ID expected $EXPECTED_CHAIN_ID, got $chain_id"
code="$($CAST_BIN code "$VAULT" --rpc-url "$RPC_URL" | tr -d '[:space:]')"
[[ "$code" != '0x' ]] || fail 'vault has no deployed bytecode'
owner="$($CAST_BIN call "$VAULT" 'owner()(address)' --rpc-url "$RPC_URL")"
key="$($CAST_BIN call "$VAULT" 'pqPublicKey()(bytes32)' --rpc-url "$RPC_URL")"
nonce="$($CAST_BIN call "$VAULT" 'nonce()(uint256)' --rpc-url "$RPC_URL")"
balance="$($CAST_BIN balance "$VAULT" --rpc-url "$RPC_URL")"
verifier="$($CAST_BIN call "$VAULT" 'ARC_PQ_VERIFIER()(address)' --rpc-url "$RPC_URL")"

[[ "${owner,,}" == "${EXPECTED_OWNER,,}" ]] || fail "owner mismatch: $owner"
[[ "${key,,}" == "${EXPECTED_KEY,,}" ]] || fail "PQ key mismatch: $key"
[[ "$nonce" == '0' ]] || fail "fresh vault nonce expected 0, got $nonce"
[[ "${verifier,,}" == '0x1800000000000000000000000000000000000004' ]] || fail "verifier mismatch: $verifier"
printf '[PASS] V2 vault bytecode, owner, PQ key, nonce, balance, verifier, and chain verified\n'
printf 'factory=%s\nvault=%s\nowner=%s\npq_key=%s\nnonce=%s\nbalance=%s\n' "$FACTORY" "$VAULT" "$owner" "$key" "$nonce" "$balance"
