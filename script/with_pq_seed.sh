#!/usr/bin/env bash
set -euo pipefail
umask 077

# Decrypt an encrypted PQ seed only for a single signer command. The GPG
# passphrase is retrieved from Secret Service through a pipe; it never enters
# stdout, shell history, an environment variable, or a plaintext file.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPG_BIN="${GPG_BIN:-gpg}"
SECRET_TOOL_BIN="${SECRET_TOOL_BIN:-secret-tool}"
KEYRING_SERVICE="${INTERLOCK_PQ_KEYRING_SERVICE:-interlock-pq}"
KEYRING_ID="${INTERLOCK_PQ_KEYRING_ID:-}"
ENCRYPTED_SEED="${1:-}"

if [[ -z "$ENCRYPTED_SEED" || $# -lt 2 ]]; then
    printf 'Usage: %s /path/to/slh-dsa-sha2-128s.private-seed.gpg signer-command [args...]\n' \
        "${BASH_SOURCE[0]}" >&2
    exit 2
fi
shift
if [[ -z "$KEYRING_ID" ]]; then
    printf 'set INTERLOCK_PQ_KEYRING_ID to a private local keyring identifier\n' >&2
    exit 2
fi

if [[ ! -f "$ENCRYPTED_SEED" ]]; then
    printf 'encrypted PQ seed not found: %s\n' "$ENCRYPTED_SEED" >&2
    exit 1
fi
if [[ "$ENCRYPTED_SEED" == "$ROOT_DIR/"* ]]; then
    printf 'refusing to read PQ seed material from inside the Interlock repository\n' >&2
    exit 1
fi
if ! command -v "$GPG_BIN" >/dev/null 2>&1; then
    printf 'missing GnuPG executable: %s\n' "$GPG_BIN" >&2
    exit 1
fi
if ! command -v "$SECRET_TOOL_BIN" >/dev/null 2>&1; then
    printf 'missing Secret Service client: %s\n' "$SECRET_TOOL_BIN" >&2
    exit 1
fi

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/interlock-pq-sign.XXXXXX")"
seed_path="$staging_dir/slh-dsa-sha2-128s.private-seed"

secure_remove() {
    if [[ -f "$seed_path" ]]; then
        if command -v shred >/dev/null 2>&1; then
            shred --force --remove --zero -- "$seed_path"
        else
            rm -f -- "$seed_path"
        fi
    fi
    rm -rf -- "$staging_dir"
}
on_signal() {
    secure_remove
    exit 130
}
trap secure_remove EXIT
trap on_signal HUP INT TERM

"$SECRET_TOOL_BIN" lookup service "$KEYRING_SERVICE" key-id "$KEYRING_ID" \
    | tr -d '\r\n' \
    | "$GPG_BIN" --batch --pinentry-mode loopback --passphrase-fd 0 \
        --decrypt --no-symkey-cache --output "$seed_path" "$ENCRYPTED_SEED"
chmod 600 -- "$seed_path"
[[ -s "$seed_path" ]]

"$@" "$seed_path"
