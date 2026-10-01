#!/usr/bin/env bash
set -euo pipefail

# Post-deployment read-only verification. No transaction or signer is used.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAST_BIN="${CAST_BIN:-cast}"
RPC_URL="${ARC_RPC_URL:-https://rpc.mainnet.arc.io}"
EXPECTED_CHAIN_ID="5042"
EXPECTED_VERIFIER="0x1800000000000000000000000000000000000004"
VAULT="${INTERLOCK_VAULT:-${1:-}}"
EXPECTED_OWNER="${INTERLOCK_DEPLOYER:-${2:-}}"
EXPECTED_PQ_KEY="${INTERLOCK_PQ_PUBLIC_KEY:-${3:-}}"

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

if [[ -z "$VAULT" || -z "$EXPECTED_OWNER" || -z "$EXPECTED_PQ_KEY" ]]; then
    printf 'Usage: INTERLOCK_VAULT=0x... INTERLOCK_DEPLOYER=0x... INTERLOCK_PQ_PUBLIC_KEY=0x... %s\n' \
        "${BASH_SOURCE[0]}" >&2
    exit 2
fi
if [[ ! -x "$CAST_BIN" ]]; then
    fail "missing executable cast binary: $CAST_BIN"
fi
if [[ ! "$VAULT" =~ ^0x[0-9a-fA-F]{40}$ || ! "$EXPECTED_OWNER" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    fail "vault and expected owner must be 20-byte hex addresses"
fi
if [[ ! "$EXPECTED_PQ_KEY" =~ ^0x[0-9a-fA-F]{64}$ || "$EXPECTED_PQ_KEY" =~ ^0x0+$ ]]; then
    fail "expected PQ key must be exactly 32 nonzero bytes"
fi

lower() { tr '[:upper:]' '[:lower:]'; }
cd "$ROOT_DIR"

chain_id="$("$CAST_BIN" chain-id --rpc-url "$RPC_URL" | tr -d '[:space:]')"
[[ "$chain_id" == "$EXPECTED_CHAIN_ID" ]] || fail "expected chain ID 5042, got $chain_id"
printf '[PASS] chain ID: %s\n' "$chain_id"

code="$("$CAST_BIN" code "$VAULT" --rpc-url "$RPC_URL" | tr -d '[:space:]')"
[[ "$code" =~ ^0x[0-9a-fA-F]+$ && "$code" != "0x" ]] || fail "vault has no deployed bytecode"
printf '[PASS] deployed bytecode exists at %s\n' "$VAULT"

owner="$("$CAST_BIN" call "$VAULT" 'owner()(address)' --rpc-url "$RPC_URL" | tr -d '[:space:]' | lower)"
expected_owner_lower="$(printf '%s' "$EXPECTED_OWNER" | lower)"
[[ "$owner" == "$expected_owner_lower" ]] || fail "owner mismatch: got $owner"
printf '[PASS] owner: %s\n' "$owner"

pq_key="$("$CAST_BIN" call "$VAULT" 'pqPublicKey()(bytes32)' --rpc-url "$RPC_URL" | tr -d '[:space:]' | lower)"
expected_key_lower="$(printf '%s' "$EXPECTED_PQ_KEY" | lower)"
[[ "$pq_key" == "$expected_key_lower" ]] || fail "PQ key mismatch: got $pq_key"
printf '[PASS] pqPublicKey matches expected public key\n'

nonce="$("$CAST_BIN" call "$VAULT" 'nonce()(uint256)' --rpc-url "$RPC_URL" | tr -d '[:space:]')"
[[ "$nonce" == "0" ]] || fail "expected nonce 0 immediately after deployment, got $nonce"
printf '[PASS] nonce: %s\n' "$nonce"

contract_balance="$("$CAST_BIN" call "$VAULT" 'balance()(uint256)' --rpc-url "$RPC_URL" | tr -d '[:space:]')"
native_balance="$("$CAST_BIN" balance --rpc-url "$RPC_URL" "$VAULT" | tr -d '[:space:]')"
[[ "$contract_balance" =~ ^[0-9]+$ && "$native_balance" =~ ^[0-9]+$ ]] || fail "balance read was not numeric"
[[ "$contract_balance" == "$native_balance" ]] || fail "contract balance and native balance differ"
printf '[PASS] vault balance: %s raw native USDC units\n' "$native_balance"

verifier="$("$CAST_BIN" call "$VAULT" 'ARC_PQ_VERIFIER()(address)' --rpc-url "$RPC_URL" | tr -d '[:space:]' | lower)"
[[ "$verifier" == "$EXPECTED_VERIFIER" ]] || fail "ARC_PQ_VERIFIER mismatch: got $verifier"
printf '[PASS] ARC_PQ_VERIFIER: %s\n' "$verifier"

printf '%s\n' 'POST-DEPLOYMENT VERIFICATION PASSED (read-only)'
