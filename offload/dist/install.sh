#!/usr/bin/env sh
# Install the slashwork-offload core binary into ~/.slashwork/bin.
#
# This is the installer for harnesses that are not Claude Code (Hermes,
# OpenClaw, anything else that shells out to the core). The Claude Code plugin
# installs the same binary from its own SessionStart hook
# (plugins/work/hooks/install-core.sh); the two are kept in step by
# install_test.sh, which fails if their pinned version or platform mapping drift
# apart.
#
# Run it directly:
#
#   curl -fsSL https://raw.githubusercontent.com/slashwork-sh/plugin/main/offload/dist/install.sh | sh
#
# Unlike the SessionStart hook, this exits non-zero on failure: a person ran it
# and wants to know it did not work.
#
# Env:
#   SLASHWORK_OFFLOAD_VERSION   release tag to install (default: the pin below)
#   SLASHWORK_BIN_DIR           install directory (default: ~/.slashwork/bin)
set -u

VERSION="${SLASHWORK_OFFLOAD_VERSION:-offload-v0.2.0}"
REPO="slashwork-sh/plugin"
BIN_DIR="${SLASHWORK_BIN_DIR:-${HOME}/.slashwork/bin}"
BIN="${BIN_DIR}/slashwork-offload"
MARKER="${BIN_DIR}/.version"

log() { printf 'slashwork-offload install: %s\n' "$1" >&2; }

# Map (os, arch) to the Rust target triple in the release asset names. Pure and
# argument-driven so install_test.sh can exercise it without a network. Kept
# identical to plugins/work/hooks/install-core.sh.
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
        log "build from source instead: cargo install --git https://github.com/${REPO} --root ~/.slashwork slashwork-offload"
        return 1
    }

    if [ -x "$BIN" ] && [ "$(cat "$MARKER" 2>/dev/null)" = "$VERSION" ]; then
        log "already at $VERSION -> $BIN"
        return 0
    fi

    # The archive is slashwork-offload-<target>.tar.gz; its checksum ships as a
    # sibling named slashwork-offload-<target>.sha256 (the archive stem plus
    # .sha256, NOT <archive>.tar.gz.sha256), matching taiki-e's `checksum: sha256`.
    asset="slashwork-offload-${target}.tar.gz"
    checksum="slashwork-offload-${target}.sha256"
    base="https://github.com/${REPO}/releases/download/${VERSION}"
    tmp=$(mktemp -d) || return 1
    trap 'rm -rf "$tmp"' EXIT

    log "downloading $VERSION for $target"
    curl -fsSL -o "$tmp/$asset" "$base/$asset" || {
        log "download failed: $base/$asset"
        return 1
    }
    curl -fsSL -o "$tmp/$checksum" "$base/$checksum" || {
        log "checksum download failed: $base/$checksum"
        return 1
    }

    # Verify before anything lands on disk: this binary holds the user's token
    # and talks to the coordinator, so an unverified download is not worth
    # running.
    want=$(cut -d' ' -f1 <"$tmp/$checksum")
    got=$(sha256_of "$tmp/$asset") || { log "no sha256 tool (need sha256sum or shasum)"; return 1; }
    [ "$want" = "$got" ] || { log "checksum mismatch (want $want, got $got)"; return 1; }

    mkdir -p "$BIN_DIR" || return 1
    tar -xzf "$tmp/$asset" -C "$tmp" || { log "extract failed"; return 1; }
    mv "$tmp/slashwork-offload" "$BIN" || return 1
    chmod +x "$BIN"
    printf '%s\n' "$VERSION" >"$MARKER"
    log "installed $VERSION -> $BIN"

    case ":${PATH}:" in
        *":${BIN_DIR}:"*) ;;
        *) log "add it to PATH:  export PATH=\"${BIN_DIR}:\$PATH\"" ;;
    esac
    log "next: slashwork-offload login"
}

# Skip the install run when sourced for testing (install_test.sh sets this to
# reuse the pure functions above without hitting the network).
if [ "${SLASHWORK_INSTALL_LIB:-}" != "1" ]; then
    install || exit 1
fi
