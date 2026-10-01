#!/usr/bin/env bash
set -euo pipefail

RPC_URL="${ARC_RPC_URL:-https://rpc.mainnet.arc.io}"
PROBE_DIR="${ARC_PQ_PROBE_DIR:-}"
CAST_BIN="${CAST_BIN:-cast}"
CARGO_BIN="${CARGO_BIN:-cargo}"
VERIFIER="0x1800000000000000000000000000000000000004"
EXPECTED_CHAIN_ID="5042"
TRUE_RESULT="$(printf '0x%064x' 1)"
FALSE_RESULT="$(printf '0x%064x' 0)"

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

[[ -n "$PROBE_DIR" && -f "$PROBE_DIR/Cargo.toml" ]] || fail 'set ARC_PQ_PROBE_DIR to the Arc PQ probe'
command -v "$CAST_BIN" >/dev/null 2>&1 || fail "missing executable cast: $CAST_BIN"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/interlock-arc-v2-proof.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT

# These are deterministic test-only seeds. They are never production credentials.
printf '\001%.0s' {1..16} > "$fixture_root/old-seed"
printf '\004%.0s' {1..16} >> "$fixture_root/old-seed"
printf '\007%.0s' {1..16} >> "$fixture_root/old-seed"
printf '\004%.0s' {1..16} > "$fixture_root/new-seed"
printf '\007%.0s' {1..16} >> "$fixture_root/new-seed"
printf '\012%.0s' {1..16} >> "$fixture_root/new-seed"

old_key="$($CARGO_BIN run --quiet --manifest-path "$PROBE_DIR/Cargo.toml" -- --public-key-from-seed "$fixture_root/old-seed")"
new_key="$($CARGO_BIN run --quiet --manifest-path "$PROBE_DIR/Cargo.toml" -- --public-key-from-seed "$fixture_root/new-seed")"

vault="0x4444444444444444444444444444444444444444"
recipient="0x5555555555555555555555555555555555555555"
tampered_recipient="0x6666666666666666666666666666666666666666"
amount=1000000000000000000
nonce=0
deadline=2000000000
ready_at=1999999000
request_nonce=0

chain_id="$($CAST_BIN chain-id --rpc-url "$RPC_URL" | tr -d '[:space:]')"
[[ "$chain_id" == "$EXPECTED_CHAIN_ID" ]] || fail "expected chain ID $EXPECTED_CHAIN_ID, got $chain_id"
printf '[PASS] Arc chain ID: %s\n' "$chain_id"
verifier_code="$($CAST_BIN code "$VERIFIER" --rpc-url "$RPC_URL" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
[[ "$verifier_code" == "0xef" ]] || fail "PQ verifier marker expected 0xef, got $verifier_code"
printf '[PASS] PQ verifier present: %s\n' "$VERIFIER"

digest_for() {
    local tag="$1"
    shift
    local encoded
    encoded="$($CAST_BIN abi-encode 'f(bytes32,uint256,address,address,uint256,uint256,uint256)' "$tag" "$EXPECTED_CHAIN_ID" "$vault" "$recipient" "$amount" "$nonce" "$deadline")"
    $CAST_BIN keccak "$encoded" | tr '[:upper:]' '[:lower:]'
}

payment_tag="$($CAST_BIN keccak 'INTERLOCK_PAYMENT_V2')"
payment_digest="$(digest_for "$payment_tag")"
tampered_amount_encoded="$($CAST_BIN abi-encode 'f(bytes32,uint256,address,address,uint256,uint256,uint256)' "$payment_tag" "$EXPECTED_CHAIN_ID" "$vault" "$recipient" $((amount + 1)) "$nonce" "$deadline")"
tampered_amount_digest="$($CAST_BIN keccak "$tampered_amount_encoded" | tr '[:upper:]' '[:lower:]')"
tampered_recipient_encoded="$($CAST_BIN abi-encode 'f(bytes32,uint256,address,address,uint256,uint256,uint256)' "$payment_tag" "$EXPECTED_CHAIN_ID" "$vault" "$tampered_recipient" "$amount" "$nonce" "$deadline")"
tampered_recipient_digest="$($CAST_BIN keccak "$tampered_recipient_encoded" | tr '[:upper:]' '[:lower:]')"

sign() {
    "$CARGO_BIN" run --quiet --manifest-path "$PROBE_DIR/Cargo.toml" -- --sign-digest "$1" "$2"
}

call_verifier() {
    local key="$1"
    local digest="$2"
    local signature="$3"
    local calldata
    calldata="$($CAST_BIN calldata 'verifySlhDsaSha2128s(bytes,bytes,bytes)' "$key" "$digest" "$signature")"
    "$CAST_BIN" call "$VERIFIER" --data "$calldata" --rpc-url "$RPC_URL" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
}

valid_signature="$(sign "$payment_digest" "$fixture_root/old-seed")"
[[ "$(call_verifier "$old_key" "$payment_digest" "$valid_signature")" == "$TRUE_RESULT" ]] || fail 'V2 valid payment rejected by Arc verifier'
printf '[PASS] V2 valid payment digest/signature accepted by Arc verifier\n'
[[ "$(call_verifier "$old_key" "$tampered_amount_digest" "$valid_signature")" == "$FALSE_RESULT" ]] || fail 'V2 tampered amount accepted'
printf '[PASS] V2 tampered amount rejected by Arc verifier\n'
[[ "$(call_verifier "$old_key" "$tampered_recipient_digest" "$valid_signature")" == "$FALSE_RESULT" ]] || fail 'V2 tampered recipient accepted'
printf '[PASS] V2 tampered recipient rejected by Arc verifier\n'

rotation_tag="$($CAST_BIN keccak 'INTERLOCK_ROTATION_V2')"
rotation_encoded="$($CAST_BIN abi-encode 'f(bytes32,uint256,address,bytes32,bytes32,uint256,uint256)' "$rotation_tag" "$EXPECTED_CHAIN_ID" "$vault" "$old_key" "$new_key" 0 "$deadline")"
rotation_digest="$($CAST_BIN keccak "$rotation_encoded" | tr '[:upper:]' '[:lower:]')"
old_rotation_signature="$(sign "$rotation_digest" "$fixture_root/old-seed")"
new_rotation_signature="$(sign "$rotation_digest" "$fixture_root/new-seed")"
[[ "$(call_verifier "$old_key" "$rotation_digest" "$old_rotation_signature")" == "$TRUE_RESULT" ]] || fail 'V2 old rotation proof rejected'
[[ "$(call_verifier "$new_key" "$rotation_digest" "$new_rotation_signature")" == "$TRUE_RESULT" ]] || fail 'V2 new rotation proof rejected'
printf '[PASS] V2 old-key rotation approval and new-key proof accepted\n'

activation_tag="$($CAST_BIN keccak 'INTERLOCK_RECOVERY_ACTIVATE_V2')"
activation_encoded="$($CAST_BIN abi-encode 'f(bytes32,uint256,address,bytes32,uint256,uint256,uint256)' "$activation_tag" "$EXPECTED_CHAIN_ID" "$vault" "$new_key" "$request_nonce" "$ready_at" "$deadline")"
activation_digest="$($CAST_BIN keccak "$activation_encoded" | tr '[:upper:]' '[:lower:]')"
activation_signature="$(sign "$activation_digest" "$fixture_root/new-seed")"
[[ "$(call_verifier "$new_key" "$activation_digest" "$activation_signature")" == "$TRUE_RESULT" ]] || fail 'V2 recovery activation proof rejected'
printf '[PASS] V2 delayed-recovery new-key proof accepted\n'

printf '%s\n' 'REAL ARC V2 PQ CHECK PASSED (read-only; no deployment or transaction submission)'
