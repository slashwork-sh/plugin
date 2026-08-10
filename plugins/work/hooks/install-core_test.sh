#!/usr/bin/env bash
# Tests the pure platform-detection logic in install-core.sh with no network.
# Sources it in library mode (SLASHWORK_INSTALL_LIB=1 skips the install() run) so
# resolve_target can be exercised with fixed (os, arch) pairs.
#
#   bash plugins/work/hooks/install-core_test.sh
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=plugins/work/hooks/install-core.sh disable=SC1091
SLASHWORK_INSTALL_LIB=1 . "$DIR/install-core.sh"

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

check "macos arm64"                 aarch64-apple-darwin      Darwin arm64
check "macos x86_64"                x86_64-apple-darwin       Darwin x86_64
check "linux x86_64"                x86_64-unknown-linux-gnu  Linux  x86_64
check "linux aarch64"               aarch64-unknown-linux-gnu Linux  aarch64
check "linux arm64 alias"           aarch64-unknown-linux-gnu Linux  arm64
# Windows: Git Bash, MSYS2, and Cygwin each report a different `uname -s`, and
# every Windows arch takes the x86_64 build (ARM64 emulates x64).
check "windows git bash"            x86_64-pc-windows-msvc    MINGW64_NT-10.0-22631 x86_64
check "windows git bash 32-bit"     x86_64-pc-windows-msvc    MINGW32_NT-10.0 i686
check "windows msys2"               x86_64-pc-windows-msvc    MSYS_NT-10.0    x86_64
check "windows cygwin"              x86_64-pc-windows-msvc    CYGWIN_NT-10.0  x86_64
check "windows on arm"              x86_64-pc-windows-msvc    MINGW64_NT-10.0 aarch64
check "unsupported arch (riscv)"    "<unsupported>"           Linux  riscv64
check "unsupported darwin arch"     "<unsupported>"           Darwin i386
check "unsupported os (freebsd)"    "<unsupported>"           FreeBSD x86_64

# bin_name: only Windows targets carry .exe.
namecheck() { # namecheck <label> <expected> <target>
    checks=$((checks + 1))
    got="$(bin_name "$3")"
    if [ "$got" = "$2" ]; then
        printf 'PASS: %s\n' "$1"
    else
        printf 'FAIL: %s (want %s, got %s)\n' "$1" "$2" "$got"
        fails=$((fails + 1))
    fi
}

namecheck "windows binary has .exe"  slashwork-offload.exe x86_64-pc-windows-msvc
namecheck "macos binary has no .exe" slashwork-offload     aarch64-apple-darwin
namecheck "linux binary has no .exe" slashwork-offload     x86_64-unknown-linux-gnu

# should_install: the hook re-runs at every session start, and every console on
# the machine shares ~/.slashwork/bin. A session on an older plugin must never
# pull its own older core over a newer one.
vercheck() { # vercheck <label> <yes|no> <marker on disk> <version pinned here>
    checks=$((checks + 1))
    if should_install "$3" "$4"; then got=yes; else got=no; fi
    if [ "$got" = "$2" ]; then
        printf 'PASS: %s\n' "$1"
    else
        printf 'FAIL: %s (want %s, got %s)\n' "$1" "$2" "$got"
        fails=$((fails + 1))
    fi
}

vercheck "nothing installed yet"        yes ""               offload-v0.4.0
vercheck "already at the pin"           no  offload-v0.4.0   offload-v0.4.0
vercheck "older on disk, upgrade"       yes offload-v0.3.0   offload-v0.4.0
vercheck "much older on disk, upgrade"  yes offload-v0.1.0   offload-v0.4.0
# The regression this function exists for: a stale session must not downgrade a
# newer core out from under every other console.
vercheck "newer on disk, leave it"      no  offload-v0.4.0   offload-v0.3.0
vercheck "newer on disk, ancient pin"   no  offload-v0.4.0   offload-v0.1.0
# Ordering is numeric per field, not lexical: 0.10.0 is newer than 0.9.0.
vercheck "0.10.0 beats 0.9.0"           no  offload-v0.10.0  offload-v0.9.0
vercheck "0.9.0 upgrades to 0.10.0"     yes offload-v0.9.0   offload-v0.10.0
vercheck "major beats minor"            no  offload-v1.0.0   offload-v0.99.0
# An unreadable marker means we cannot prove the binary is newer, so restore the
# pin rather than trust it.
vercheck "garbage marker restores pin"  yes "not-a-version"  offload-v0.4.0

if [ "$fails" -eq 0 ]; then
    printf '\nALL PASS (%d checks)\n' "$checks"
    exit 0
fi
printf '\n%d/%d FAILED\n' "$fails" "$checks"
exit 1
