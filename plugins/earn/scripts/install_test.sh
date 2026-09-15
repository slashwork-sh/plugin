#!/usr/bin/env bash
# Test for the one-command earner installer.
#
# Stubs `sbx` on PATH, points SLASHWORK_PLUGIN_DIR at a fake launcher so no
# network is touched, and points SLASHWORK_TTY at a file so the one question
# has an answer. The fake launcher records what it was started with and what
# its stdin was, since handing the terminal through is the whole reason the
# installer execs it with an explicit stdin.
#
# Run: bash plugins/earn/scripts/install_test.sh
set -uo pipefail
exec </dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$HERE/install.sh"
TMP="$(mktemp -d)"
STUB="$TMP/bin"
LOG="$TMP/sbx.log"
FAILED=0
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$STUB" "$TMP/state" "$TMP/home" "$TMP/plugin/plugins/earn/scripts"

# Knobs:
#   STUB_AUTH=0     `sbx ls` fails until `sbx login` has run
#   STUB_POLICY=0   `sbx policy ls` fails until `sbx policy init` has run
cat > "$STUB/sbx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SBX_LOG"
case "$1" in
  daemon) [ "${2:-}" = status ] && echo "Status: running"; exit 0 ;;
  login)  touch "$TMP_STATE/logged_in"; exit 0 ;;
  ls)
    if [ "${STUB_AUTH:-1}" = "1" ] || [ -f "$TMP_STATE/logged_in" ]; then exit 0; fi
    echo "ERROR: Not authenticated to Docker" >&2; exit 1 ;;
  policy)
    case "$2" in
      ls)   if [ "${STUB_POLICY:-1}" = "1" ] || [ -f "$TMP_STATE/policy" ]; then exit 0; fi
            echo "ERROR: not initialized" >&2; exit 1 ;;
      init) touch "$TMP_STATE/policy"; exit 0 ;;
    esac ;;
esac
exit 0
SH
# The fake launcher: proves it was reached, with which args, on which stdin.
cat > "$TMP/plugin/plugins/earn/scripts/sandbox.sh" <<'SH'
#!/usr/bin/env bash
# slashwork earner sandbox launcher. (fake, for install_test.sh)
echo "LAUNCHER args=[$*] cwd=$PWD"
echo "LAUNCHER stdin=$(cat)"
SH
chmod +x "$STUB/sbx" "$TMP/plugin/plugins/earn/scripts/sandbox.sh"
export PATH="$STUB:$PATH" SBX_LOG="$LOG" TMP_STATE="$TMP/state" HOME="$TMP/home"
export SLASHWORK_PLUGIN_DIR="$TMP/plugin"
printf 'y\nterminal-content\n' > "$TMP/tty-yes"
printf 'n\n' > "$TMP/tty-no"
export SLASHWORK_TTY="$TMP/tty-yes"

reset() { rm -rf "$TMP_STATE" "$HOME/slashwork-earner"; mkdir -p "$TMP_STATE"; : > "$LOG"; }
run()   { reset; sh "$INSTALLER" "$@" 2>&1; }
rc()    { reset; sh "$INSTALLER" >/dev/null 2>&1; echo $?; }
check() { if [ "$2" = "0" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n     %s\n' "$1" "$3"; FAILED=1; fi; }
has()   { printf '%s' "$1" | grep -qF -- "$2" && echo 0 || echo 1; }
hasnt() { [ -n "$1" ] || { echo 1; return; }; printf '%s' "$1" | grep -qF -- "$2" && echo 1 || echo 0; }
is()    { [ "$1" = "$2" ] && echo 0 || echo 1; }

# ------------------------------------------------------------ the happy path
OUT=$(run --loop 25 8h)
check "installs the launcher into ~/slashwork-earner" \
  "$([ -x "$HOME/slashwork-earner/sandbox.sh" ] && echo 0 || echo 1)" "$OUT"
check "starts the launcher with the arguments passed through" \
  "$(has "$OUT" "LAUNCHER args=[--loop 25 8h] cwd=$HOME/slashwork-earner")" "$OUT"
check "hands the launcher the terminal, not the script, as stdin" \
  "$(has "$OUT" "LAUNCHER stdin=y")" "$OUT"
check "a signed-in sbx is not asked to log in again" "$(hasnt "$(cat "$LOG")" "login")" "$(cat "$LOG")"
check "an initialized policy is left alone" "$(hasnt "$(cat "$LOG")" "policy init")" "$(cat "$LOG")"
check "the happy path exits with the launcher's status" "$(is "$(rc)" 0)" ""

# ------------------------------------------------------------------ sign-in
OUT=$(STUB_AUTH=0 run); LOGGED=$(cat "$LOG")
check "a signed-out sbx is signed in" "$(has "$LOGGED" "login")" "$LOGGED"
check "sign-in happens before the launcher starts" "$(has "$OUT" "LAUNCHER args")" "$OUT"

# ------------------------------------------------------------------- policy
OUT=$(STUB_POLICY=0 run); LOGGED=$(cat "$LOG")
check "an uninitialized policy is asked about" "$(has "$OUT" "sbx policy init deny-all\" now?")" "$OUT"
check "yes initializes deny-all" "$(has "$LOGGED" "policy init deny-all")" "$LOGGED"
check "and then the launcher starts" "$(has "$OUT" "LAUNCHER args")" "$OUT"

OUT=$(SLASHWORK_TTY="$TMP/tty-no" STUB_POLICY=0 run); LOGGED=$(cat "$LOG")
check "no leaves the policy alone" "$(hasnt "$LOGGED" "policy init")" "$LOGGED"
check "no stops before the launcher" "$(hasnt "$OUT" "LAUNCHER")" "$OUT"
check "no exits 1 with the command to run" "$(has "$OUT" "Run: sbx policy init deny-all")" "$OUT"
check "no exits 1" "$(is "$(SLASHWORK_TTY="$TMP/tty-no" STUB_POLICY=0 rc)" 1)" ""

# ----------------------------------------------------------------- refusals
mkdir -p "$TMP/nosbx"
OUT=$(PATH="$TMP/nosbx:/usr/bin:/bin" run)
check "refuses without sbx, naming the install line" "$(has "$OUT" "brew install docker/tap/sbx")" "$OUT"
check "refuses without sbx: exits 1" "$(is "$(PATH="$TMP/nosbx:/usr/bin:/bin" rc)" 1)" ""
check "refuses without sbx: installs nothing" "$([ ! -e "$HOME/slashwork-earner/sandbox.sh" ] && echo 0 || echo 1)" ""

OUT=$(SLASHWORK_TTY="$TMP/no-such-tty" run)
check "refuses without a terminal" "$(has "$OUT" "no terminal at")" "$OUT"
check "refuses without a terminal: exits 1" "$(is "$(SLASHWORK_TTY="$TMP/no-such-tty" rc)" 1)" ""

# A fetch that returns something else (a 404 page, a truncated file) must not
# become an executable launcher.
mkdir -p "$TMP/badplugin/plugins/earn/scripts"
echo "<html>404</html>" > "$TMP/badplugin/plugins/earn/scripts/sandbox.sh"
OUT=$(SLASHWORK_PLUGIN_DIR="$TMP/badplugin" run)
check "refuses a launcher that is not the launcher" "$(has "$OUT" "is not the launcher")" "$OUT"
check "leaves nothing executable behind" "$([ ! -e "$HOME/slashwork-earner/sandbox.sh" ] && [ ! -e "$HOME/slashwork-earner/sandbox.sh.new" ] && echo 0 || echo 1)" "$(ls -la "$HOME/slashwork-earner" 2>&1)"

# The folder is overridable, for a second box or a different disk.
OUT=$(SLASHWORK_EARNER_DIR="$TMP/elsewhere" run)
check "honors SLASHWORK_EARNER_DIR" "$(has "$OUT" "cwd=$TMP/elsewhere")" "$OUT"

echo
if [ "$FAILED" -eq 0 ]; then echo "all install.sh tests passed"; else echo "install.sh tests FAILED"; fi
exit "$FAILED"
