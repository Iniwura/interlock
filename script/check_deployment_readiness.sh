#!/usr/bin/env bash
set -euo pipefail

# Read-only deployment gate. It accepts only a public deployer address and a
# public PQ verification key. It never accepts, reads, or prints a private key.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORGE_BIN="${FORGE_BIN:-forge}"
CAST_BIN="${CAST_BIN:-cast}"
RPC_URL="${ARC_RPC_URL:-https://rpc.mainnet.arc.io}"
EXPECTED_CHAIN_ID="5042"
VERIFIER="0x1800000000000000000000000000000000000004"
TEST_FIXTURE_OLD_KEY="0x03030303030303030303030303030303d627c8bad26269965d3ad40ca4457a26"
TEST_FIXTURE_NEW_KEY="0x0606060606060606060606060606060649206e7d5262ff4073bc5bc26b89b761"

DEPLOYER="${INTERLOCK_DEPLOYER:-${1:-}}"
PQ_PUBLIC_KEY="${INTERLOCK_PQ_PUBLIC_KEY:-${2:-}}"

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

if [[ -z "$DEPLOYER" || -z "$PQ_PUBLIC_KEY" ]]; then
    printf 'Usage: INTERLOCK_DEPLOYER=0x... INTERLOCK_PQ_PUBLIC_KEY=0x... %s\n' \
        "${BASH_SOURCE[0]}" >&2
    exit 2
fi
if [[ ! -x "$FORGE_BIN" ]]; then
    fail "missing executable forge binary: $FORGE_BIN"
fi
if [[ ! -x "$CAST_BIN" ]]; then
    fail "missing executable cast binary: $CAST_BIN"
fi

if [[ ! "$DEPLOYER" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    fail "expected deployer must be exactly a 20-byte hex address"
fi
if [[ ! "$PQ_PUBLIC_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    fail "PQ public key must be exactly 32 bytes of hex"
fi
if [[ "$PQ_PUBLIC_KEY" =~ ^0x0+$ ]]; then
    fail "PQ public key must be nonzero"
fi
pq_key_lower="$(printf '%s' "$PQ_PUBLIC_KEY" | tr '[:upper:]' '[:lower:]')"
if [[ "$pq_key_lower" == "$TEST_FIXTURE_OLD_KEY" || "$pq_key_lower" == "$TEST_FIXTURE_NEW_KEY" ]]; then
    fail "recognized deterministic Arc probe key; generate a fresh production key"
fi

cd "$ROOT_DIR"

printf '[INFO] RPC: %s\n' "$RPC_URL"
printf '[INFO] expected deployer/owner: %s\n' "$DEPLOYER"
printf '[INFO] PQ public key: 32 bytes (public material only)\n'

chain_id="$("$CAST_BIN" chain-id --rpc-url "$RPC_URL" | tr -d '[:space:]')"
if [[ "$chain_id" != "$EXPECTED_CHAIN_ID" ]]; then
    fail "Arc chain ID expected $EXPECTED_CHAIN_ID, got $chain_id"
fi
printf '[PASS] Arc chain ID is %s\n' "$chain_id"

verifier_code="$("$CAST_BIN" code "$VERIFIER" --rpc-url "$RPC_URL" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
if [[ "$verifier_code" != "0xef" ]]; then
    fail "PQ verifier precompile expected 0xef, got $verifier_code"
fi
printf '[PASS] PQ verifier responds at %s\n' "$VERIFIER"

printf '%s\n' '[INFO] Running the independent real-Arc PQ fixture check (read-only)'
ARC_RPC_URL="$RPC_URL" "$ROOT_DIR/script/real_arc_pq_check.sh"

"$FORGE_BIN" build >/dev/null
bytecode="$("$FORGE_BIN" inspect InterlockVault bytecode | tr -d '[:space:]')"
if [[ ! "$bytecode" =~ ^0x[0-9a-fA-F]+$ || "$bytecode" == "0x" ]]; then
    fail "InterlockVault creation bytecode is empty or malformed"
fi
printf '[PASS] InterlockVault creation bytecode builds cleanly (%s bytes)\n' \
    "$(((${#bytecode} - 2) / 2))"

constructor_args="$("$CAST_BIN" abi-encode 'constructor(bytes32)' "$PQ_PUBLIC_KEY" | tr -d '[:space:]')"
if [[ ! "$constructor_args" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    fail "constructor(bytes32) encoding is not exactly one ABI word"
fi
printf '[PASS] constructor args encode as one 32-byte ABI word\n'

creation_data="${bytecode}${constructor_args#0x}"
gas_estimate="$("$CAST_BIN" estimate --rpc-url "$RPC_URL" --from "$DEPLOYER" --create "$creation_data" | tr -d '[:space:]')"
if [[ ! "$gas_estimate" =~ ^[0-9]+$ ]]; then
    fail "eth_estimateGas returned a non-numeric result: $gas_estimate"
fi
printf '[PASS] read-only deployment gas estimate: %s\n' "$gas_estimate"

printf '%s\n' '[INFO] Running parameterized forge script without --broadcast'
script_output="$("$FORGE_BIN" script script/DeployInterlockVault.s.sol:DeployInterlockVault \
    --sig 'run(address,bytes32)' "$DEPLOYER" "$PQ_PUBLIC_KEY" \
    --rpc-url "$RPC_URL" --chain-id "$EXPECTED_CHAIN_ID" --sender "$DEPLOYER" -vv 2>&1)" || {
    printf '%s\n' "$script_output" >&2
    fail "forge script dry run failed"
}
if [[ "$script_output" != *"ONCHAIN EXECUTION COMPLETE & SUCCESSFUL"* &&
      "$script_output" != *"SIMULATION COMPLETE"* &&
      "$script_output" != *"Estimated gas"* ]]; then
    printf '%s\n' "$script_output"
    fail "forge script did not report a successful simulation"
fi
printf '[PASS] forge script simulation completed; no transaction was broadcast\n'

printf '%s\n' 'DEPLOYMENT READINESS PASSED (read-only; no deployment, signer, or secret material used)'
