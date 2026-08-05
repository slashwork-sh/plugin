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

if [ "$fails" -eq 0 ]; then
    printf '\nALL PASS (%d checks)\n' "$checks"
    exit 0
fi
printf '\n%d/%d FAILED\n' "$fails" "$checks"
exit 1
