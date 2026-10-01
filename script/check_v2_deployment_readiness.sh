#!/usr/bin/env bash
set -euo pipefail

# Public-only V2 factory deployment gate. It never accepts or prints a secret.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORGE_BIN="${FORGE_BIN:-forge}"
CAST_BIN="${CAST_BIN:-cast}"
RPC_URL="${ARC_RPC_URL:-https://rpc.mainnet.arc.io}"
EXPECTED_CHAIN_ID="5042"
VERIFIER="0x1800000000000000000000000000000000000004"
DEPLOYER="${INTERLOCK_DEPLOYER:-${1:-}}"

fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }
command -v "$FORGE_BIN" >/dev/null 2>&1 || fail "missing forge binary: $FORGE_BIN"
command -v "$CAST_BIN" >/dev/null 2>&1 || fail "missing cast binary: $CAST_BIN"
[[ "$DEPLOYER" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail 'expected a public 20-byte deployer address'

cd "$ROOT_DIR"
chain_id="$($CAST_BIN chain-id --rpc-url "$RPC_URL" | tr -d '[:space:]')"
[[ "$chain_id" == "$EXPECTED_CHAIN_ID" ]] || fail "Arc chain ID expected $EXPECTED_CHAIN_ID, got $chain_id"
printf '[PASS] Arc chain ID: %s\n' "$chain_id"
verifier_code="$($CAST_BIN code "$VERIFIER" --rpc-url "$RPC_URL" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
[[ "$verifier_code" == '0xef' ]] || fail "PQ verifier expected 0xef, got $verifier_code"
printf '[PASS] PQ verifier present: %s\n' "$VERIFIER"

"$FORGE_BIN" build >/dev/null
bytecode="$($FORGE_BIN inspect InterlockFactory bytecode | tr -d '[:space:]')"
[[ "$bytecode" =~ ^0x[0-9a-fA-F]+$ && "$bytecode" != '0x' ]] || fail 'factory bytecode is empty or malformed'
printf '[PASS] factory bytecode builds cleanly (%s bytes)\n' "$(((${#bytecode} - 2) / 2))"
gas_estimate="$($CAST_BIN estimate --rpc-url "$RPC_URL" --from "$DEPLOYER" --create "$bytecode" | tr -d '[:space:]')"
[[ "$gas_estimate" =~ ^[0-9]+$ ]] || fail "factory eth_estimateGas returned: $gas_estimate"
printf '[PASS] factory deployment gas estimate: %s\n' "$gas_estimate"

simulation_output="$($FORGE_BIN script script/DeployInterlockFactory.s.sol:DeployInterlockFactory \
    --sig 'run(address)' "$DEPLOYER" --rpc-url "$RPC_URL" --chain-id "$EXPECTED_CHAIN_ID" \
    --sender "$DEPLOYER" -vv 2>&1)" || { printf '%s\n' "$simulation_output" >&2; fail 'factory simulation failed'; }
if [[ "$simulation_output" != *'ONCHAIN EXECUTION COMPLETE & SUCCESSFUL'* &&
      "$simulation_output" != *'SIMULATION COMPLETE'* &&
      "$simulation_output" != *'Estimated gas'* ]]; then
    printf '%s\n' "$simulation_output"
    fail 'factory simulation did not report success'
fi
printf '%s\n' 'V2 FACTORY READINESS PASSED (read-only; no broadcast)'
