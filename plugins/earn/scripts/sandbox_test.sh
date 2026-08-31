#!/usr/bin/env bash
# Integration test for the earner sandbox launcher.
#
# Stubs `sbx` and `uname` on PATH and drives sandbox.sh through its modes,
# asserting on the exact command log the launcher produces. The point is that
# the launcher refuses clearly when a precondition is missing (no sbx, no
# Docker session, no global policy, wrong hardware) and, when everything is
# ready, issues the create / allowlist / bootstrap calls with the settings from
# settings.json rather than its built-in defaults.
#
# No real sandbox is created and no network is touched.
#
# Run: bash plugins/earn/scripts/sandbox_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$HERE/sandbox.sh"
TMP="$(mktemp -d)"
STUB="$TMP/bin"
LOG="$TMP/sbx.log"
WORK="$TMP/agent"
FAILED=0

# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$STUB" "$WORK"

# The launcher lives next to settings.json in a real earner folder, so copy it
# into one rather than running it from the plugin tree.
cp "$LAUNCHER" "$WORK/sandbox.sh"
chmod +x "$WORK/sandbox.sh"
cat > "$WORK/settings.json" <<'JSON'
{"base_url":"","model":"","bypass_permissions":false,"default_duration":"30m",
 "sandbox":{"enabled":true,"name":"test-earner","memory":"6g","cpus":3}}
JSON

# ---------------------------------------------------------------- the stubs
cat > "$STUB/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${STUB_OS:-Darwin}" ;;
  -m) printf '%s\n' "${STUB_ARCH:-arm64}" ;;
  *)  printf '%s\n' "${STUB_OS:-Darwin}" ;;
esac
SH

# STUB_AUTH=0 makes `sbx ls` fail the way a signed-out CLI does.
# STUB_POLICY=0 makes `sbx policy ls` fail the way an uninitialized one does.
# STUB_EXISTS=1 makes the named sandbox already exist.
cat > "$STUB/sbx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SBX_LOG"
case "$1" in
  version) echo "sbx version: v0.38.0 deadbeef" ;;
  daemon)  # STUB_DAEMON=0 models a stopped daemon: status fails until start runs.
           if [ "${STUB_DAEMON:-1}" = "0" ]; then
             case "$2" in
               status) [ -f "$TMP_STATE/daemon_up" ] || exit 1 ;;
               start)  touch "$TMP_STATE/daemon_up" ;;
             esac
           fi
           exit 0 ;;
  ls)      [ "${STUB_AUTH:-1}" = "1" ] || { echo "not authenticated" >&2; exit 1; }
           [ "${STUB_EXISTS:-0}" = "1" ] && echo "test-earner"
           exit 0 ;;
  policy)  case "$2" in
             ls) [ "${STUB_POLICY:-1}" = "1" ] || { echo "not initialized" >&2; exit 1; } ;;
           esac
           exit 0 ;;
  create)  exit 0 ;;
  cp)      exit 0 ;;
  run)     exit 0 ;;
  exec)    # $HOME probe, tool probe, plugin probe. Report tools present and the
           # plugin absent so the bootstrap path is exercised once.
           case "$*" in
             *'printf %s "$HOME"'*) printf '/home/user' ;;
             *'command -v jq'*)     exit 0 ;;
             *'plugin list'*)       exit 1 ;;
           esac
           exit 0 ;;
esac
exit 0
SH
chmod +x "$STUB/uname" "$STUB/sbx"
mkdir -p "$TMP/state"
export PATH="$STUB:$PATH" SBX_LOG="$LOG" TMP_STATE="$TMP/state"

# ------------------------------------------------------------------ helpers
run_case() { : > "$LOG"; ( cd "$WORK" && ./sandbox.sh "$@" 2>&1 ); }

check() { # check <description> <condition-result> <detail>
  if [ "$2" = "0" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n     %s\n' "$1" "$3"; FAILED=1; fi
}
has()  { printf '%s' "$1" | grep -qF "$2" && echo 0 || echo 1; }
hasnt(){ printf '%s' "$1" | grep -qF "$2" && echo 1 || echo 0; }

# ------------------------------------------------------------------- 1: check
OUT=$(STUB_EXISTS=0 run_case --check)
check "--check reports the sandbox is not created yet" \
  "$(has "$OUT" "not created yet")" "$OUT"
check "--check reads name/memory/cpus from settings.json" \
  "$(has "$OUT" "name=test-earner memory=6g cpus=3")" "$OUT"
check "--check creates nothing" "$(hasnt "$(cat "$LOG")" "create")" "$(cat "$LOG")"

OUT=$(STUB_EXISTS=1 run_case --check)
check "--check reports an existing sandbox" "$(has "$OUT" "'test-earner' exists")" "$OUT"

# ------------------------------------------------------- 2: refusals up front
OUT=$(STUB_OS=Linux run_case --check)
check "refuses on Linux without /dev/kvm" "$(has "$OUT" "no /dev/kvm")" "$OUT"

OUT=$(STUB_ARCH=x86_64 run_case --check)
check "refuses on macOS without Apple silicon" "$(has "$OUT" "needs Apple silicon")" "$OUT"

OUT=$(STUB_AUTH=0 run_case --check)
check "refuses when not signed in to Docker" "$(has "$OUT" "sbx login")" "$OUT"

# A stopped daemon must be started detached. Without -d, sandboxd runs attached
# and dies with the shell, taking a standing earner's sandbox down with it.
rm -f "$TMP/state/daemon_up"
OUT=$(STUB_DAEMON=0 run_case --check); LOGGED=$(cat "$LOG")
check "starts a stopped daemon detached" "$(has "$LOGGED" "daemon start -d")" "$LOGGED"
check "does not start an already-running daemon" \
  "$(hasnt "$(: > "$LOG"; run_case --check >/dev/null; cat "$LOG")" "daemon start")" "$(cat "$LOG")"

OUT=$(STUB_POLICY=0 run_case --check)
check "refuses when the global policy is uninitialized" \
  "$(has "$OUT" "sbx policy init deny-all")" "$OUT"

# A PATH with the uname stub but no sbx at all. Stripping $STUB is not enough:
# a real sbx may be installed on the developer's machine.
mkdir -p "$TMP/nosbx" && cp "$STUB/uname" "$TMP/nosbx/uname"
OUT=$(PATH="$TMP/nosbx:/usr/bin:/bin" run_case --check)
check "refuses when sbx is not installed" "$(has "$OUT" "sbx not installed")" "$OUT"

# ------------------------------------------------------------ 3: the full run
OUT=$(STUB_EXISTS=0 run_case); LOGGED=$(cat "$LOG")
check "creates with the configured memory and cpus" \
  "$(has "$LOGGED" "create --name test-earner --memory 6g --cpus 3 claude")" "$LOGGED"
check "allows the run hosts" \
  "$(has "$LOGGED" "policy allow network --sandbox test-earner api.anthropic.com")" "$LOGGED"
check "allows slashwork.sh" "$(has "$LOGGED" "slashwork.sh")" "$LOGGED"
check "allows the setup hosts" "$(has "$LOGGED" "github.com")" "$LOGGED"
check "installs the plugin when absent" \
  "$(has "$LOGGED" "plugin install slashwork-earn@slashwork")" "$LOGGED"
check "writes the in-sandbox marker" \
  "$(has "$LOGGED" ".slashwork-sandbox")" "$LOGGED"
check "attaches at the end" "$(has "$LOGGED" "run --name test-earner")" "$LOGGED"

# An existing sandbox must not be recreated on a re-run after a reboot.
OUT=$(STUB_EXISTS=1 run_case); LOGGED=$(cat "$LOG")
check "re-run does not recreate an existing sandbox" \
  "$(hasnt "$LOGGED" "create --name")" "$LOGGED"
check "re-run still attaches" "$(has "$LOGGED" "run --name test-earner")" "$LOGGED"

# ---------------------------------------------------------------- 4: --lock
OUT=$(STUB_EXISTS=1 run_case --lock); LOGGED=$(cat "$LOG")
check "--lock removes the setup hosts in one call" \
  "$(has "$LOGGED" "policy rm network --sandbox test-earner --resource github.com,api.github.com,*.githubusercontent.com,registry.npmjs.org")" "$LOGGED"
check "--lock keeps the run hosts" "$(hasnt "$LOGGED" "policy rm network --sandbox test-earner --resource api.anthropic.com")" "$LOGGED"
check "--lock does not attach" "$(hasnt "$LOGGED" "run --name")" "$LOGGED"

# --------------------------------------------------------------- 5: --rebuild
OUT=$(STUB_EXISTS=0 run_case --rebuild); LOGGED=$(cat "$LOG")
check "--rebuild removes before creating" "$(has "$LOGGED" "rm test-earner")" "$LOGGED"

# ------------------------------------------------- 6: an unsafe sandbox.name
# The name is interpolated into `sh -c` strings that run inside the box, so a
# name carrying a quote or a semicolon must be cut down before it gets there
# rather than reaching the sandbox as a second command.
BAD="$TMP/agent-badname"
mkdir -p "$BAD"
cp "$LAUNCHER" "$BAD/sandbox.sh"
chmod +x "$BAD/sandbox.sh"
cat > "$BAD/settings.json" <<'JSON'
{"sandbox":{"enabled":true,"name":"bad name'; touch pwned; '","memory":"4g","cpus":2}}
JSON
: > "$LOG"
OUT=$( cd "$BAD" && STUB_EXISTS=0 ./sandbox.sh --check 2>&1 )
check "warns about an unsafe sandbox.name" "$(has "$OUT" "is not a safe name")" "$OUT"
check "falls back to the sanitized name" "$(has "$OUT" "name=badnametouchpwned")" "$OUT"
check "the unsafe name never reaches sbx" "$(hasnt "$(cat "$LOG")" "touch pwned")" "$(cat "$LOG")"
check "nothing ran from the injected name" "$(hasnt "$(ls "$BAD")" "pwned")" "$(ls "$BAD")"

echo
if [ "$FAILED" -eq 0 ]; then echo "all sandbox.sh tests passed"; else echo "sandbox.sh tests FAILED"; fi
exit "$FAILED"
