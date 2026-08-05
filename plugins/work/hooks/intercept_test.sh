#!/usr/bin/env bash
# Integration test for the PreToolUse(Task|Agent) intercept shim.
#
# The shim is thin now: honour the opt-out, locate the core binary, hand it
# stdin, pass its stdout through. Envelope parsing, the consent gate,
# classification, dispatch, and decision shaping all live in the core
# (`slashwork-offload hook`, offload/src/hook.rs), unit-tested there and driven
# end to end by offload/tests/hook_cli.rs and the coordinator repo's
# tests/e2e_offload_test.sh.
#
# So this covers exactly what stays in shell: the opt-out gate, the core
# discovery order (including the Windows .exe), that the core is invoked with
# the `hook` subcommand, that stdin reaches it and its stdout comes back, and
# that a missing or broken core falls through cleanly instead of erroring.
#
# It drives the shim against a FAKE core, so it needs no coordinator and no Rust
# build.
#
# Run: bash plugins/work/hooks/intercept_test.sh
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
INTERCEPT="$HOOK_DIR/intercept.sh"
PASS=0

fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && { echo "--- detail ---"; echo "$2"; }; exit 1; }
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# A sandbox HOME so core discovery never finds a dev's real install.
SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/.slashwork/bin"

ENVELOPE='{"session_id":"s1","tool_name":"Task","tool_input":{"prompt":"research X"}}'

# A fake core: record argv and stdin, then echo a canned line, so we can prove
# the shim passed both through and returned the core's stdout verbatim.
make_core() { # make_core <path>
    cat > "$1" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_CORE_ARGV"
cat > "$FAKE_CORE_STDIN"
printf '{"systemMessage":"from the core"}\n'
exit 0
FAKE
    chmod +x "$1"
}
export FAKE_CORE_ARGV="$SANDBOX/argv"
export FAKE_CORE_STDIN="$SANDBOX/stdin"
reset() { : > "$FAKE_CORE_ARGV"; : > "$FAKE_CORE_STDIN"; }

# 1. Default-on: no SLASHWORK_INTERCEPT, core present at the install path. The
#    shim calls it with `hook`, feeds it stdin, and returns its stdout.
CORE="$SANDBOX/.slashwork/bin/slashwork-offload"
make_core "$CORE"
reset
OUT=$(printf '%s' "$ENVELOPE" | env -u SLASHWORK_INTERCEPT -u SLASHWORK_OFFLOAD_BIN "$INTERCEPT" 2>/dev/null)
[ "$(cat "$FAKE_CORE_ARGV")" = "hook" ] || fail "expected the hook subcommand" "$(cat "$FAKE_CORE_ARGV")"
[ "$(cat "$FAKE_CORE_STDIN")" = "$ENVELOPE" ] || fail "envelope did not reach the core" "$(cat "$FAKE_CORE_STDIN")"
[ "$OUT" = '{"systemMessage":"from the core"}' ] || fail "core stdout not passed through" "$OUT"
ok "default-on -> core invoked with 'hook', stdin in, stdout out"

# 2. Opt-out: SLASHWORK_INTERCEPT=0 is a total no-op and the core is untouched.
reset
OUT=$(printf '%s' "$ENVELOPE" | SLASHWORK_INTERCEPT=0 "$INTERCEPT" 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] || fail "opt-out must exit 0" "rc=$rc"
[ -z "$OUT" ] || fail "opt-out must emit nothing" "$OUT"
[ ! -s "$FAKE_CORE_ARGV" ] || fail "opt-out must not call the core" "$(cat "$FAKE_CORE_ARGV")"
ok "SLASHWORK_INTERCEPT=0 -> no-op, core untouched"

# 3. SLASHWORK_OFFLOAD_BIN wins over the install path.
OVERRIDE="$SANDBOX/override-core"
cat > "$OVERRIDE" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
printf '{"systemMessage":"from the override"}\n'
FAKE
chmod +x "$OVERRIDE"
OUT=$(printf '%s' "$ENVELOPE" | SLASHWORK_OFFLOAD_BIN="$OVERRIDE" "$INTERCEPT" 2>/dev/null)
[ "$OUT" = '{"systemMessage":"from the override"}' ] || fail "SLASHWORK_OFFLOAD_BIN ignored" "$OUT"
ok "SLASHWORK_OFFLOAD_BIN overrides the install path"

# 4. Windows: only slashwork-offload.exe exists in the install dir, and the shim
#    still finds it. Without the .exe candidate the offloader stays inert on
#    every Windows machine, which is the bug this path exists to fix.
rm -f "$CORE"
make_core "$SANDBOX/.slashwork/bin/slashwork-offload.exe"
reset
OUT=$(printf '%s' "$ENVELOPE" | env -u SLASHWORK_OFFLOAD_BIN "$INTERCEPT" 2>/dev/null)
[ "$(cat "$FAKE_CORE_ARGV")" = "hook" ] || fail "did not find the .exe core" "$(cat "$FAKE_CORE_ARGV")"
[ "$OUT" = '{"systemMessage":"from the core"}' ] || fail ".exe core stdout not passed through" "$OUT"
ok "windows .exe core is discovered"
rm -f "$SANDBOX/.slashwork/bin/slashwork-offload.exe"

# 5. No core anywhere (not installed yet, or an unsupported platform) -> silent
#    exit 0, so Claude Code spawns the subagent normally. PATH is narrowed to the
#    system directories, which have sh (the shim's interpreter) but no
#    slashwork-offload, rather than emptied, which would break the shebang and
#    test nothing.
OUT=$(printf '%s' "$ENVELOPE" | env -u SLASHWORK_OFFLOAD_BIN PATH=/usr/bin:/bin "$INTERCEPT" 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] || fail "missing core must exit 0" "rc=$rc"
[ -z "$OUT" ] || fail "missing core must emit nothing" "$OUT"
ok "no core -> silent local fall-through"

# 6. A core that exits non-zero must still leave the hook at exit 0. A non-zero
#    hook surfaces an error in the session; the contract is always a clean fall
#    through to the local spawn.
BROKEN="$SANDBOX/broken-core"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 3\n' > "$BROKEN"
chmod +x "$BROKEN"
printf '%s' "$ENVELOPE" | SLASHWORK_OFFLOAD_BIN="$BROKEN" "$INTERCEPT" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "a failing core must still exit 0" "rc=$rc"
ok "core exits non-zero -> hook still exits 0"

# 7. A core path that is not runnable at all -> exit 0, no shell error.
printf '%s' "$ENVELOPE" | SLASHWORK_OFFLOAD_BIN="$SANDBOX/does-not-exist" "$INTERCEPT" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "an unrunnable core must exit 0" "rc=$rc"
ok "unrunnable core -> hook still exits 0"

# 8. The shim must not depend on jq. Git Bash ships none, and reintroducing the
#    dependency would silently disable routing on every Windows machine. Comment
#    lines are stripped first: the header explains the jq history on purpose.
if grep -vE '^[[:space:]]*#' "$INTERCEPT" | grep -qE '(^|[^[:alnum:]_])jq([^[:alnum:]_]|$)'; then
    fail "intercept.sh must not use jq (Git Bash has none)"
fi
ok "shim has no jq dependency"

printf '\nALL PASS (%d checks)\n' "$PASS"
