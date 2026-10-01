#!/usr/bin/env bash
set -euo pipefail

RPC_URL="${ARC_RPC_URL:-https://rpc.mainnet.arc.io}"
PROBE_DIR="${ARC_PQ_PROBE_DIR:-}"
CAST_BIN="${CAST_BIN:-cast}"
CARGO_BIN="${CARGO_BIN:-cargo}"
VERIFIER="0x1800000000000000000000000000000000000004"
EXPECTED_CHAIN_ID="5042"
EXPECTED_SELECTOR="0xbf4db8ba"
TRUE_RESULT="$(printf '0x%064x' 1)"
FALSE_RESULT="$(printf '0x%064x' 0)"

if ! command -v "$CAST_BIN" >/dev/null 2>&1; then
    printf 'missing executable cast binary: %s\n' "$CAST_BIN" >&2
    exit 1
fi
if [[ -z "$PROBE_DIR" ]]; then
    printf 'set ARC_PQ_PROBE_DIR to the separately checked-out Arc PQ probe\n' >&2
    exit 2
fi
if [[ ! -f "$PROBE_DIR/Cargo.toml" ]]; then
    printf 'missing Arc PQ probe Cargo.toml: %s\n' "$PROBE_DIR/Cargo.toml" >&2
    exit 1
fi

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/interlock-arc-proof.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
fixture_dir="$fixture_root/fixtures"

"$CARGO_BIN" run --quiet --manifest-path "$PROBE_DIR/Cargo.toml" -- \
    --interlock-fixtures "$fixture_dir"

chain_id="$("$CAST_BIN" chain-id --rpc-url "$RPC_URL" | tr -d '[:space:]')"
if [[ "$chain_id" != "$EXPECTED_CHAIN_ID" ]]; then
    printf '[FAIL] Arc chain ID: expected %s, got %s\n' "$EXPECTED_CHAIN_ID" "$chain_id" >&2
    exit 1
fi
printf '[PASS] Arc chain ID: %s\n' "$chain_id"

verifier_code="$("$CAST_BIN" code "$VERIFIER" --rpc-url "$RPC_URL" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
if [[ "$verifier_code" != "0xef" ]]; then
    printf '[FAIL] PQ verifier precompile marker: expected 0xef, got %s\n' "$verifier_code" >&2
    exit 1
fi
printf '[PASS] PQ verifier precompile is present at %s\n' "$VERIFIER"

fixture_selector="$(cut -c1-10 "$fixture_dir/payment-valid.hex" | tr '[:upper:]' '[:lower:]')"
if [[ "$fixture_selector" != "$EXPECTED_SELECTOR" ]]; then
    printf '[FAIL] verifier ABI selector: expected %s, got %s\n' "$EXPECTED_SELECTOR" "$fixture_selector" >&2
    exit 1
fi
printf '[PASS] verifier ABI selector: %s\n' "$fixture_selector"

manifest_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 == key { print $2 }' "$fixture_dir/manifest.txt"
}

vault_address="$(manifest_value vault)"
recipient_address="$(manifest_value recipient)"
amount="$(manifest_value amount)"
valid_deadline="$(manifest_value valid_deadline)"
expired_deadline="$(manifest_value expired_deadline)"
old_public_key="$(manifest_value old_public_key)"
new_public_key="$(manifest_value new_public_key)"
expected_payment_digest="$(manifest_value valid_payment_digest)"
expected_rotation_digest="$(manifest_value valid_rotation_digest)"
latest_timestamp="$($CAST_BIN block latest --field timestamp --rpc-url "$RPC_URL" | tr -d '[:space:]')"
if ! [[ "$latest_timestamp" =~ ^[0-9]+$ ]] || (( latest_timestamp <= expired_deadline )); then
    printf '[FAIL] expired deadline %s is not before current Arc timestamp %s\n' \
        "$expired_deadline" "$latest_timestamp" >&2
    exit 1
fi
if (( latest_timestamp >= valid_deadline )); then
    printf '[FAIL] valid deadline %s is not after current Arc timestamp %s\n' \
        "$valid_deadline" "$latest_timestamp" >&2
    exit 1
fi
printf '[PASS] Arc timestamp %s is between expired deadline %s and valid deadline %s\n' \
    "$latest_timestamp" "$expired_deadline" "$valid_deadline"

payment_tag="$($CAST_BIN keccak 'INTERLOCK_PAYMENT_V1')"
payment_encoded="$($CAST_BIN abi-encode \
    'f(bytes32,uint256,address,address,uint256,uint256,uint256)' \
    "$payment_tag" "$EXPECTED_CHAIN_ID" "$vault_address" "$recipient_address" \
    "$amount" 0 "$valid_deadline")"
payment_digest="$($CAST_BIN keccak "$payment_encoded" | tr '[:upper:]' '[:lower:]')"
if [[ "$payment_digest" != "$expected_payment_digest" ]]; then
    printf '[FAIL] payment digest: Solidity ABI hash %s != Rust fixture %s\n' \
        "$payment_digest" "$expected_payment_digest" >&2
    exit 1
fi
printf '[PASS] payment digest matches Solidity abi.encode: %s\n' "$payment_digest"

rotation_tag="$($CAST_BIN keccak 'INTERLOCK_ROTATION_V1')"
rotation_encoded="$($CAST_BIN abi-encode \
    'f(bytes32,uint256,address,bytes32,bytes32,uint256,uint256)' \
    "$rotation_tag" "$EXPECTED_CHAIN_ID" "$vault_address" "$old_public_key" \
    "$new_public_key" 1 "$valid_deadline")"
rotation_digest="$($CAST_BIN keccak "$rotation_encoded" | tr '[:upper:]' '[:lower:]')"
if [[ "$rotation_digest" != "$expected_rotation_digest" ]]; then
    printf '[FAIL] rotation digest: Solidity ABI hash %s != Rust fixture %s\n' \
        "$rotation_digest" "$expected_rotation_digest" >&2
    exit 1
fi
printf '[PASS] rotation digest matches Solidity abi.encode: %s\n' "$rotation_digest"

call_verifier() {
    local fixture="$1"
    local calldata
    calldata="$(tr -d '\r\n' < "$fixture")"
    "$CAST_BIN" call "$VERIFIER" --data "$calldata" --rpc-url "$RPC_URL" \
        | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
}

expect_result() {
    local fixture_name="$1"
    local expected="$2"
    local description="$3"
    local actual
    actual="$(call_verifier "$fixture_dir/$fixture_name.hex")"
    if [[ "$actual" != "$expected" ]]; then
        printf '[FAIL] %s: expected %s, got %s\n' "$description" "$expected" "$actual" >&2
        exit 1
    fi
    printf '[PASS] %s => %s\n' "$description" "$actual"
}

expect_result payment-valid "$TRUE_RESULT" 'valid payment authorization'
expect_result payment-tampered-amount "$FALSE_RESULT" 'tampered payment amount'
expect_result payment-tampered-recipient "$FALSE_RESULT" 'tampered payment recipient'
expect_result payment-expired "$TRUE_RESULT" 'expired digest remains cryptographically valid at verifier'

replay_first="$(call_verifier "$fixture_dir/payment-replay.hex")"
replay_second="$(call_verifier "$fixture_dir/payment-replay.hex")"
if [[ "$replay_first" != "$TRUE_RESULT" || "$replay_second" != "$TRUE_RESULT" ]]; then
    printf '[FAIL] replay fixture: expected verifier results %s then %s, got %s then %s\n' \
        "$TRUE_RESULT" "$TRUE_RESULT" "$replay_first" "$replay_second" >&2
    exit 1
fi
printf '[PASS] replay fixture returns true twice (%s, %s); nonce replay protection belongs to InterlockVault\n' \
    "$replay_first" "$replay_second"

expect_result rotation-old-valid "$TRUE_RESULT" 'valid rotation approval by old PQ key'
expect_result rotation-new-valid "$TRUE_RESULT" 'valid rotation proof by new PQ key'
expect_result rotation-new-tampered "$FALSE_RESULT" 'tampered rotation digest under new PQ key'

printf '%s\n' '--- deterministic fixture manifest ---'
sed -n '1,40p' "$fixture_dir/manifest.txt"
printf '%s\n' 'REAL ARC PQ CHECK PASSED (read-only; no contract deployment or transaction submission)'
