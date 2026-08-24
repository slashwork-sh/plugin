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
#   SLASHWORK_OFFLOAD_VERSION   release tag to install (default: the pin below).
#                               Naming one is a deliberate choice, so it installs
#                               that tag even if it is older than what is on disk.
#   SLASHWORK_BIN_DIR           install directory (default: ~/.slashwork/bin)
set -u

VERSION="${SLASHWORK_OFFLOAD_VERSION:-offload-v0.5.0}"
# Whether the caller named a version. Without one we only ever move forward; with
# one, they asked for that exact tag and a rollback is the point.
VERSION_FORCED=$([ -n "${SLASHWORK_OFFLOAD_VERSION:-}" ] && echo 1 || echo 0)
REPO="slashwork-sh/plugin"
BIN_DIR="${SLASHWORK_BIN_DIR:-${HOME}/.slashwork/bin}"
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
        # Windows under Git Bash, MSYS2, or Cygwin, which report `uname -s` as
        # MINGW64_NT-10.0-22631, MSYS_NT-10.0, and CYGWIN_NT-10.0 respectively.
        # Every arch maps to the x86_64 build: the release ships no ARM64
        # Windows binary because Windows on ARM runs x64 under emulation.
        MINGW* | MSYS* | CYGWIN*) echo x86_64-pc-windows-msvc ;;
        *) return 1 ;;
    esac
}

# The binary's filename, inside the release archive and on disk. Windows targets
# carry .exe; nothing else does. Pure, and kept beside resolve_target so the two
# platform facts live together.
bin_name() {
    case "$1" in
        *-pc-windows-*) echo slashwork-offload.exe ;;
        *) echo slashwork-offload ;;
    esac
}

# Sortable rank for an `offload-vX.Y.Z` tag: major, then minor and patch in
# three zero-padded digits each, so ordering is numeric per field and 0.10.0
# outranks 0.9.0 the way a lexical compare would not. Any prerelease suffix is
# dropped (0.4.1-rc1 ranks as 0.4.1). Returns non-zero for anything that does
# not parse. Kept identical to plugins/work/hooks/install-core.sh.
version_rank() {
    v="${1#offload-v}"
    maj="${v%%.*}"
    rest="${v#*.}"
    min="${rest%%.*}"
    pat="${rest#*.}"
    pat="${pat%%[!0-9]*}"
    for n in "$maj" "$min" "$pat"; do
        case "$n" in
            '' | *[!0-9]*) return 1 ;;
        esac
    done
    printf '%d%03d%03d\n' "$maj" "$min" "$pat"
}

# True when the pinned version should replace what is already on disk. Only ever
# moves forward, because every console on the machine shares one
# ~/.slashwork/bin and an older installer must not drag a newer core backwards.
# Kept identical to plugins/work/hooks/install-core.sh.
should_install() { # should_install <marker on disk> <version pinned here>
    [ -n "$1" ] || return 0
    [ "$1" != "$2" ] || return 1
    have=$(version_rank "$1") || return 0
    want=$(version_rank "$2") || return 1
    [ "$want" -gt "$have" ]
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
    bin_file=$(bin_name "$target")
    BIN="${BIN_DIR}/${bin_file}"

    if [ -x "$BIN" ] && [ "$VERSION_FORCED" = 0 ]; then
        marker=$(cat "$MARKER" 2>/dev/null || echo '')
        if ! should_install "$marker" "$VERSION"; then
            if [ "$marker" = "$VERSION" ]; then
                log "already at $VERSION -> $BIN"
            else
                log "keeping newer $marker -> $BIN (this installer pins $VERSION)"
            fi
            return 0
        fi
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
    mv "$tmp/$bin_file" "$BIN" || return 1
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
