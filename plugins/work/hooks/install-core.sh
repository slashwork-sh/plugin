#!/usr/bin/env sh
# Fetch and install the pinned slashwork-offload core binary into
# ~/.slashwork/bin. Idempotent: re-running with the same pinned version is a
# no-op, so the slashwork-work plugin's SessionStart hook runs it on every start
# and it does real work only on the first start after a version bump.
#
# The binaries are published by .github/workflows/release.yml on an `offload-v*`
# tag. Until the first release is cut, the download 404s; the offloader then
# stays inert, exactly as it does without a token. This script ALWAYS exits 0 (a
# SessionStart hook must never surface an error or block the session); any
# failure just leaves the caller a clean "no binary" state, and intercept.sh
# falls back to a local spawn.
set -u

VERSION="offload-v0.1.0"
REPO="slashwork-sh/plugin"
BIN_DIR="${HOME}/.slashwork/bin"
BIN="${BIN_DIR}/slashwork-offload"
MARKER="${BIN_DIR}/.version"

log() { printf 'slashwork-offload install: %s\n' "$1" >&2; }

# Map (os, arch) to the Rust target triple in the release asset names. Pure and
# argument-driven so install_test.sh can exercise it without a network.
resolve_target() {
    case "$1" in
        Darwin)
            case "$2" in
                arm64) echo aarch64-apple-darwin ;;
                x86_64) echo x86_64-apple-darwin ;;
                *) return 1 ;;
            esac
            ;;
        Linux)
            case "$2" in
                aarch64 | arm64) echo aarch64-unknown-linux-gnu ;;
                x86_64) echo x86_64-unknown-linux-gnu ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        return 1
    fi
}

install() {
    command -v curl >/dev/null 2>&1 || { log "curl not found"; return 1; }
    command -v tar >/dev/null 2>&1 || { log "tar not found"; return 1; }
    target=$(resolve_target "$(uname -s)" "$(uname -m)") || {
        log "unsupported platform $(uname -s)/$(uname -m)"
        return 1
    }

    # Idempotent: already at the pinned version.
    if [ -x "$BIN" ] && [ "$(cat "$MARKER" 2>/dev/null)" = "$VERSION" ]; then
        return 0
    fi

    asset="slashwork-offload-${target}.tar.gz"
    base="https://github.com/${REPO}/releases/download/${VERSION}"
    tmp=$(mktemp -d) || return 1
    trap 'rm -rf "$tmp"' EXIT

    curl -fsSL -o "$tmp/$asset" "$base/$asset" || {
        log "download failed: $base/$asset"
        return 1
    }
    curl -fsSL -o "$tmp/$asset.sha256" "$base/$asset.sha256" || {
        log "checksum download failed"
        return 1
    }

    want=$(cut -d' ' -f1 <"$tmp/$asset.sha256")
    got=$(sha256_of "$tmp/$asset") || { log "no sha256 tool"; return 1; }
    [ "$want" = "$got" ] || { log "checksum mismatch (want $want, got $got)"; return 1; }

    mkdir -p "$BIN_DIR"
    tar -xzf "$tmp/$asset" -C "$tmp" || { log "extract failed"; return 1; }
    mv "$tmp/slashwork-offload" "$BIN" || return 1
    chmod +x "$BIN"
    printf '%s\n' "$VERSION" >"$MARKER"
    log "installed $VERSION -> $BIN"
}

# Skip the install run when sourced for testing (install-core_test.sh sets this
# to reuse the pure functions above without hitting the network). Otherwise run
# it, but always exit 0: this is a SessionStart hook, and a non-zero exit would
# surface a session-start error for what is a best-effort, fail-to-local install.
if [ "${SLASHWORK_INSTALL_LIB:-}" != "1" ]; then
    install || true
fi
