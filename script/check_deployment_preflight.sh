#!/usr/bin/env bash
set -euo pipefail

# Read-only Arc deployment cost and balance report. It never signs, funds, or
# submits a transaction and accepts no wallet secret.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORGE_BIN="${FORGE_BIN:-forge}"
CAST_BIN="${CAST_BIN:-cast}"
RPC_URL="${ARC_RPC_URL:-https://rpc.mainnet.arc.io}"
EXPECTED_CHAIN_ID="5042"
GAS_BUFFER_BPS="${INTERLOCK_GAS_BUFFER_BPS:-20000}"
DEPLOYER="${INTERLOCK_DEPLOYER:-${1:-}}"
PQ_PUBLIC_KEY="${INTERLOCK_PQ_PUBLIC_KEY:-${2:-}}"
TEST_FIXTURE_OLD_KEY="0x03030303030303030303030303030303d627c8bad26269965d3ad40ca4457a26"
TEST_FIXTURE_NEW_KEY="0x0606060606060606060606060606060649206e7d5262ff4073bc5bc26b89b761"

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

if [[ -z "$DEPLOYER" || -z "$PQ_PUBLIC_KEY" ]]; then
    printf 'Usage: INTERLOCK_DEPLOYER=0x... INTERLOCK_PQ_PUBLIC_KEY=0x... %s\n' \
        "${BASH_SOURCE[0]}" >&2
    exit 2
fi
if [[ ! -x "$FORGE_BIN" || ! -x "$CAST_BIN" ]]; then
    fail "forge/cast binaries are not available"
fi
if ! command -v bc >/dev/null 2>&1; then
    fail "bc is required for exact balance arithmetic"
fi
if [[ ! "$DEPLOYER" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    fail "deployer must be exactly a 20-byte hex address"
fi
if [[ ! "$PQ_PUBLIC_KEY" =~ ^0x[0-9a-fA-F]{64}$ || "$PQ_PUBLIC_KEY" =~ ^0x0+$ ]]; then
    fail "PQ public key must be exactly 32 nonzero bytes"
fi
pq_key_lower="$(printf '%s' "$PQ_PUBLIC_KEY" | tr '[:upper:]' '[:lower:]')"
if [[ "$pq_key_lower" == "$TEST_FIXTURE_OLD_KEY" || "$pq_key_lower" == "$TEST_FIXTURE_NEW_KEY" ]]; then
    fail "recognized deterministic Arc probe key; generate a fresh production key"
fi
if [[ ! "$GAS_BUFFER_BPS" =~ ^[0-9]+$ || "$GAS_BUFFER_BPS" -lt 10000 ]]; then
    fail "INTERLOCK_GAS_BUFFER_BPS must be an integer of at least 10000"
fi

cd "$ROOT_DIR"
printf '[INFO] RPC: %s\n' "$RPC_URL"
printf '[INFO] address under review: %s\n' "$DEPLOYER"

chain_id="$("$CAST_BIN" chain-id --rpc-url "$RPC_URL" | tr -d '[:space:]')"
[[ "$chain_id" == "$EXPECTED_CHAIN_ID" ]] || fail "expected chain ID 5042, got $chain_id"
printf '[PASS] Arc chain ID: %s\n' "$chain_id"

native_balance="$("$CAST_BIN" balance --rpc-url "$RPC_URL" "$DEPLOYER" | tr -d '[:space:]')"
[[ "$native_balance" =~ ^[0-9]+$ ]] || fail "native balance was not an integer: $native_balance"
printf '[INFO] current native USDC balance: %s raw units (%s USDC)\n' \
    "$native_balance" "$("$CAST_BIN" from-wei "$native_balance" ether | tr -d '[:space:]')"

"$FORGE_BIN" build >/dev/null
bytecode="$("$FORGE_BIN" inspect InterlockVault bytecode | tr -d '[:space:]')"
constructor_args="$("$CAST_BIN" abi-encode 'constructor(bytes32)' "$PQ_PUBLIC_KEY" | tr -d '[:space:]')"
[[ "$bytecode" =~ ^0x[0-9a-fA-F]+$ && "$bytecode" != "0x" ]] || fail "invalid creation bytecode"
[[ "$constructor_args" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "invalid constructor encoding"
creation_data="${bytecode}${constructor_args#0x}"

gas_estimate="$("$CAST_BIN" estimate --rpc-url "$RPC_URL" --from "$DEPLOYER" --create "$creation_data" | tr -d '[:space:]')"
gas_price="$("$CAST_BIN" gas-price --rpc-url "$RPC_URL" | tr -d '[:space:]')"
[[ "$gas_estimate" =~ ^[0-9]+$ ]] || fail "gas estimate was not an integer: $gas_estimate"
[[ "$gas_price" =~ ^[0-9]+$ ]] || fail "gas price was not an integer: $gas_price"

estimated_cost="$(printf '%s * %s\n' "$gas_estimate" "$gas_price" | bc)"
required_balance="$(printf '%s * %s / 10000\n' "$estimated_cost" "$GAS_BUFFER_BPS" | bc)"
printf '[PASS] deployment gas estimate: %s\n' "$gas_estimate"
printf '[INFO] current gas price: %s raw native units\n' "$gas_price"
printf '[INFO] estimated deployment cost: %s raw native USDC\n' "$estimated_cost"
printf '[INFO] conservative required balance (%s bps): %s raw native USDC\n' \
    "$GAS_BUFFER_BPS" "$required_balance"

enough="$(printf '%s >= %s\n' "$native_balance" "$required_balance" | bc)"
if [[ "$enough" == "1" ]]; then
    printf '[PASS] reviewed address meets the conservative deployment balance threshold\n'
else
    printf '[WARN] reviewed address is below the conservative deployment balance threshold\n'
fi

printf '%s\n' 'PREFLIGHT COMPLETE (read-only; no signing, funding, or broadcast)'
