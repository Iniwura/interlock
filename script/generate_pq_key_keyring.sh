#!/usr/bin/env bash
set -euo pipefail
umask 077

# Generate a fresh SLH-DSA-SHA2-128s key. The random GPG passphrase is held
# only in process memory, stored directly in Secret Service, and piped to GPG.
# It is never printed, placed in an environment variable, or written to disk.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_DIR="${ARC_PQ_PROBE_DIR:-}"
GPG_BIN="${GPG_BIN:-gpg}"
SECRET_TOOL_BIN="${SECRET_TOOL_BIN:-secret-tool}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
CARGO_BIN="${CARGO_BIN:-cargo}"
KEY_DIR="${1:-}"
KEYRING_SERVICE="${INTERLOCK_PQ_KEYRING_SERVICE:-interlock-pq}"
KEYRING_ID="${INTERLOCK_PQ_KEYRING_ID:-}"

if [[ -z "$KEY_DIR" ]]; then
    printf 'Usage: %s /absolute/path/outside-the-repository\n' "${BASH_SOURCE[0]}" >&2
    exit 2
fi
if [[ -z "$PROBE_DIR" ]]; then
    printf 'set ARC_PQ_PROBE_DIR to the separately checked-out Arc PQ probe\n' >&2
    exit 2
fi
if [[ -z "$KEYRING_ID" ]]; then
    printf 'set INTERLOCK_PQ_KEYRING_ID to a private local keyring identifier\n' >&2
    exit 2
fi
if [[ ! -f "$PROBE_DIR/Cargo.toml" ]]; then
    printf 'missing Arc PQ probe Cargo.toml: %s\n' "$PROBE_DIR/Cargo.toml" >&2
    exit 1
fi
for executable in "$GPG_BIN" "$SECRET_TOOL_BIN" "$OPENSSL_BIN"; do
    if ! command -v "$executable" >/dev/null 2>&1; then
        printf 'missing executable: %s\n' "$executable" >&2
        exit 1
    fi
done

KEY_DIR="$(realpath -m -- "$KEY_DIR")"
case "$KEY_DIR/" in
    "$ROOT_DIR/"*)
        printf 'refusing to write PQ private material inside the Interlock repository: %s\n' "$KEY_DIR" >&2
        exit 1
        ;;
esac

PUBLIC_PATH="$KEY_DIR/slh-dsa-sha2-128s.public-key"
ENCRYPTED_PATH="$KEY_DIR/slh-dsa-sha2-128s.private-seed.gpg"
if [[ -e "$PUBLIC_PATH" || -e "$ENCRYPTED_PATH" ]]; then
    printf 'refusing to overwrite an existing PQ key output: %s\n' "$KEY_DIR" >&2
    exit 1
fi

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/interlock-pq-keyring.XXXXXX")"
seed_path="$staging_dir/slh-dsa-sha2-128s.private-seed"
passphrase=""
keyring_stored=0
completed=0

secure_remove() {
    if [[ -f "$seed_path" ]]; then
        if command -v shred >/dev/null 2>&1; then
            shred --force --remove --zero -- "$seed_path"
        else
            rm -f -- "$seed_path"
        fi
    fi
    rm -rf -- "$staging_dir"
    if [[ "$completed" == 0 ]]; then
        if [[ "$keyring_stored" == 1 ]]; then
            "$SECRET_TOOL_BIN" clear service "$KEYRING_SERVICE" key-id "$KEYRING_ID" \
                >/dev/null 2>&1 || true
        fi
        rm -f -- "$PUBLIC_PATH" "$ENCRYPTED_PATH"
        rmdir -- "$KEY_DIR" 2>/dev/null || true
    fi
    unset passphrase
}
on_signal() {
    secure_remove
    exit 130
}
trap secure_remove EXIT
trap on_signal HUP INT TERM

mkdir -p -- "$KEY_DIR"
chmod 700 -- "$KEY_DIR"

"$CARGO_BIN" run --quiet --manifest-path "$PROBE_DIR/Cargo.toml" -- \
    --generate-secure-key "$staging_dir" >/dev/null
cp -- "$staging_dir/slh-dsa-sha2-128s.public-key" "$PUBLIC_PATH"
chmod 644 -- "$PUBLIC_PATH"

passphrase="$("$OPENSSL_BIN" rand -base64 48 | tr -d '\r\n')"
[[ "${#passphrase}" -ge 64 ]]

"$SECRET_TOOL_BIN" clear service "$KEYRING_SERVICE" key-id "$KEYRING_ID" \
    >/dev/null 2>&1 || true
if ! printf '%s' "$passphrase" | "$SECRET_TOOL_BIN" store \
    --label='Interlock PQ production signing passphrase' \
    service "$KEYRING_SERVICE" key-id "$KEYRING_ID" >/dev/null 2>&1; then
    printf 'Secret Service store failed\n' >&2
    exit 1
fi
keyring_stored=1

if ! printf '%s' "$passphrase" | "$GPG_BIN" --batch --yes \
    --pinentry-mode loopback --passphrase-fd 0 --symmetric \
    --cipher-algo AES256 --no-symkey-cache \
    --output "$ENCRYPTED_PATH" "$seed_path" >/dev/null 2>&1; then
    printf 'GPG encryption failed\n' >&2
    exit 1
fi
chmod 600 -- "$ENCRYPTED_PATH"
[[ -s "$ENCRYPTED_PATH" ]]

completed=1
secure_remove
trap - EXIT
key="$(tr -d '[:space:]' < "$PUBLIC_PATH")"
[[ "$key" =~ ^0x[0-9a-fA-F]{64}$ ]]
printf '%s\n' "$key"
