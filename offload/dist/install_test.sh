#!/usr/bin/env bash
# Tests the standalone core installer with no network: the pure platform
# mapping, and that it has not drifted from the Claude Code SessionStart
# installer. Two scripts install the same binary, so a change to one that misses
# the other would leave harnesses on different core versions.
#
#   bash offload/dist/install_test.sh
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
HOOK_INSTALLER="$REPO_ROOT/plugins/work/hooks/install-core.sh"

# shellcheck source=offload/dist/install.sh disable=SC1091
SLASHWORK_INSTALL_LIB=1 . "$DIR/install.sh"

fails=0
checks=0
check() { # check <label> <expected> <os> <arch>
    checks=$((checks + 1))
    got="$(resolve_target "$3" "$4" 2>/dev/null)" || got="<unsupported>"
    if [ "$got" = "$2" ]; then
        printf 'PASS: %s\n' "$1"
    else
        printf 'FAIL: %s (want %s, got %s)\n' "$1" "$2" "$got"
        fails=$((fails + 1))
    fi
}

check_equal() { # check_equal <label> <expected> <got>
    checks=$((checks + 1))
    if [ "$3" = "$2" ]; then
        printf 'PASS: %s\n' "$1"
    else
        printf 'FAIL: %s (want %s, got %s)\n' "$1" "$2" "$3"
        fails=$((fails + 1))
    fi
}

check "macos arm64"                 aarch64-apple-darwin      Darwin arm64
check "macos x86_64"                x86_64-apple-darwin       Darwin x86_64
check "linux x86_64"                x86_64-unknown-linux-gnu  Linux  x86_64
check "linux aarch64"               aarch64-unknown-linux-gnu Linux  aarch64
check "linux arm64 alias"           aarch64-unknown-linux-gnu Linux  arm64
# Windows: Git Bash, MSYS2, and Cygwin each report a different `uname -s`, and
# every Windows arch takes the x86_64 build (ARM64 emulates x64).
check "windows git bash"            x86_64-pc-windows-msvc    MINGW64_NT-10.0-22631 x86_64
check "windows msys2"               x86_64-pc-windows-msvc    MSYS_NT-10.0    x86_64
check "windows cygwin"              x86_64-pc-windows-msvc    CYGWIN_NT-10.0  x86_64
check "windows on arm"              x86_64-pc-windows-msvc    MINGW64_NT-10.0 aarch64
check "unsupported arch (riscv)"    "<unsupported>"           Linux  riscv64
check "unsupported darwin arch"     "<unsupported>"           Darwin i386
check "unsupported os (freebsd)"    "<unsupported>"           FreeBSD x86_64

check_equal "windows binary has .exe"  slashwork-offload.exe "$(bin_name x86_64-pc-windows-msvc)"
check_equal "macos binary has no .exe" slashwork-offload     "$(bin_name aarch64-apple-darwin)"

# The version the standalone installer pins, with any env override ignored.
standalone_version=$(grep -m1 '^VERSION=' "$DIR/install.sh" | sed 's/.*:-\([^}]*\)}.*/\1/')
hook_version=$(grep -m1 '^VERSION=' "$HOOK_INSTALLER" | cut -d'"' -f2)
check_equal "pinned version matches the Claude Code installer" "$hook_version" "$standalone_version"

# Both must fetch the same asset and checksum names, or one of them 404s on a
# release the other installs fine.
for name in 'slashwork-offload-${target}.tar.gz' 'slashwork-offload-${target}.sha256'; do
    standalone_has=$(grep -cF "$name" "$DIR/install.sh")
    hook_has=$(grep -cF "$name" "$HOOK_INSTALLER")
    checks=$((checks + 1))
    if [ "$standalone_has" -gt 0 ] && [ "$hook_has" -gt 0 ]; then
        printf 'PASS: both installers use %s\n' "$name"
    else
        printf 'FAIL: asset name %s missing (standalone=%s hook=%s)\n' "$name" "$standalone_has" "$hook_has"
        fails=$((fails + 1))
    fi
done

# The two installers must agree on every platform they resolve, not just on the
# version and asset names. Source the hook installer in a subshell (so its
# functions do not clobber the standalone ones already sourced here) and compare
# both mappings across the full matrix. Without this, adding a platform to one
# installer and not the other silently leaves that platform working under Claude
# Code and broken under the standalone install, or the reverse.
for pair in \
    "Darwin arm64" "Darwin x86_64" \
    "Linux x86_64" "Linux aarch64" \
    "MINGW64_NT-10.0-22631 x86_64" "MSYS_NT-10.0 x86_64" "CYGWIN_NT-10.0 x86_64" \
    "FreeBSD x86_64"; do
    # shellcheck disable=SC2086
    set -- $pair
    standalone=$(resolve_target "$1" "$2" 2>/dev/null) || standalone="<unsupported>"
    hook=$(
        # shellcheck source=plugins/work/hooks/install-core.sh disable=SC1091
        SLASHWORK_INSTALL_LIB=1 . "$HOOK_INSTALLER"
        resolve_target "$1" "$2" 2>/dev/null || echo "<unsupported>"
    )
    check_equal "installers agree on $1/$2" "$standalone" "$hook"
done

# Both installers write the same shared ~/.slashwork/bin, so they must also agree
# on when to overwrite it. If only one of them learned to refuse a downgrade, the
# other still drags every console on the machine backwards.
for trip in \
    "offload-v0.3.0 offload-v0.4.0" \
    "offload-v0.4.0 offload-v0.3.0" \
    "offload-v0.4.0 offload-v0.4.0" \
    "offload-v0.1.0 offload-v0.4.0" \
    "offload-v0.9.0 offload-v0.10.0" \
    "offload-v0.10.0 offload-v0.9.0" \
    "not-a-version offload-v0.4.0"; do
    # shellcheck disable=SC2086
    set -- $trip
    if should_install "$1" "$2"; then standalone=yes; else standalone=no; fi
    hook=$(
        # shellcheck source=plugins/work/hooks/install-core.sh disable=SC1091
        SLASHWORK_INSTALL_LIB=1 . "$HOOK_INSTALLER"
        if should_install "$1" "$2"; then echo yes; else echo no; fi
    )
    check_equal "installers agree: on $1, pin $2" "$standalone" "$hook"
done

# A person running this wants a failure to be visible, unlike the SessionStart
# hook which must always exit 0.
checks=$((checks + 1))
if grep -q 'install || exit 1' "$DIR/install.sh"; then
    printf 'PASS: standalone installer exits non-zero on failure\n'
else
    printf 'FAIL: standalone installer must exit non-zero on failure\n'
    fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then
    printf '\nALL PASS (%d checks)\n' "$checks"
    exit 0
fi
printf '\n%d/%d FAILED\n' "$fails" "$checks"
exit 1
