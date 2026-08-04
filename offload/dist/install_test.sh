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
check "unsupported os (windows)"    "<unsupported>"           MINGW64_NT-10.0 x86_64
check "unsupported arch (riscv)"    "<unsupported>"           Linux  riscv64
check "unsupported darwin arch"     "<unsupported>"           Darwin i386

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
