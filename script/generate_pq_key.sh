#!/usr/bin/env bash
set -euo pipefail
umask 077

# Generate a fresh SLH-DSA-SHA2-128s key outside the repository. The private
# seed exists only in a temporary staging directory and is encrypted with
# GnuPG before that directory is destroyed. GnuPG prompts for the passphrase;
# no passphrase flag, environment variable, or shell-history entry is used.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_DIR="${ARC_PQ_PROBE_DIR:-}"
GPG_BIN="${GPG_BIN:-gpg}"
CARGO_BIN="${CARGO_BIN:-cargo}"
KEY_DIR="${1:-}"

secure_remove() {
    local path="$1"
    if [[ -f "$path" ]]; then
        if command -v shred >/dev/null 2>&1; then
            shred --force --remove --zero -- "$path"
        else
            rm -f -- "$path"
        fi
    fi
}

staging_dir=""
cleanup() {
    if [[ -n "$staging_dir" && -d "$staging_dir" ]]; then
        secure_remove "$staging_dir/slh-dsa-sha2-128s.private-seed"
        rm -rf -- "$staging_dir"
    fi
}
on_signal() {
    cleanup
    exit 130
}
trap cleanup EXIT
trap on_signal HUP INT TERM

if [[ -z "$KEY_DIR" ]]; then
    printf 'Usage: %s /absolute/path/outside-the-repository\n' "${BASH_SOURCE[0]}" >&2
    exit 2
fi
if [[ -z "$PROBE_DIR" ]]; then
    printf 'set ARC_PQ_PROBE_DIR to the separately checked-out Arc PQ probe\n' >&2
    exit 2
fi
if [[ ! -f "$PROBE_DIR/Cargo.toml" ]]; then
    printf 'missing Arc PQ probe Cargo.toml: %s\n' "$PROBE_DIR/Cargo.toml" >&2
    exit 1
fi
if ! command -v "$GPG_BIN" >/dev/null 2>&1; then
    printf 'missing GnuPG executable: %s\n' "$GPG_BIN" >&2
    exit 1
fi

KEY_DIR="$(realpath -m -- "$KEY_DIR")"
case "$KEY_DIR/" in
    "$ROOT_DIR/"*)
        printf 'refusing to write PQ private material inside the Interlock repository: %s\n' "$KEY_DIR" >&2
        exit 1
        ;;
esac

public_path="$KEY_DIR/slh-dsa-sha2-128s.public-key"
encrypted_path="$KEY_DIR/slh-dsa-sha2-128s.private-seed.gpg"
if [[ -e "$public_path" || -e "$encrypted_path" ]]; then
    printf 'refusing to overwrite an existing PQ key output: %s\n' "$KEY_DIR" >&2
    exit 1
fi

mkdir -p -- "$KEY_DIR"
chmod 700 -- "$KEY_DIR"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/interlock-pq-key.XXXXXX")"

"$CARGO_BIN" run --quiet --manifest-path "$PROBE_DIR/Cargo.toml" -- \
    --generate-secure-key "$staging_dir"

cp -- "$staging_dir/slh-dsa-sha2-128s.public-key" "$public_path"
chmod 644 -- "$public_path"

printf '%s\n' 'GnuPG will now request the encryption passphrase through its protected prompt.'
"$GPG_BIN" --symmetric --cipher-algo AES256 --no-symkey-cache \
    --output "$encrypted_path" "$staging_dir/slh-dsa-sha2-128s.private-seed"
chmod 600 -- "$encrypted_path"

if [[ ! -s "$encrypted_path" ]]; then
    printf 'GnuPG produced an empty encrypted seed file\n' >&2
    exit 1
fi

secure_remove "$staging_dir/slh-dsa-sha2-128s.private-seed"
printf '%s\n' 'Fresh PQ key created with encrypted private seed at rest.'
printf 'Public key file: %s\n' "$public_path"
printf 'Encrypted private seed: %s\n' "$encrypted_path"
printf '%s\n' 'The private seed was not printed. Keep the passphrase separate from this directory.'
