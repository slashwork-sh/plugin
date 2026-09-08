#!/usr/bin/env bash
# Integration test for the earner sandbox launcher.
#
# Stubs `sbx` and `uname` on PATH and drives sandbox.sh through its modes. The
# stub models the REAL sbx contract, which is not the obvious one and is where
# the first version of this suite went wrong:
#
#   - `sbx daemon status` exits 0 whether the daemon is running or stopped, and
#     reports state on stdout. Gating a start on its exit code never starts
#     anything. The stub reproduces that, so the launcher has to read the line.
#   - `sbx policy check network` exits 0 even when it errors, so a decision has
#     to be parsed out of its output.
#   - `sbx policy ls` and `sbx ls` DO exit non-zero when unauthenticated.
#
# The stub also keeps per-sandbox policy STATE rather than only logging argv, so
# --lock and --unlock are tested by what the egress ends up being, not by which
# command was emitted. Asserting on the log alone let a --lock that removed
# nothing still report success.
#
# Every assertion that matters checks an exit status as well as a message: the
# preflight refusals are the whole point of the preflight, and with message-only
# greps, deleting `exit 1` from fail() left the suite green.
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

# Inlined rather than a cleanup() function: shellcheck versions disagree about
# whether a trap-only function is reachable (SC2317 on the CI image, SC2329
# locally), and this sidesteps the argument entirely.
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$STUB" "$WORK" "$TMP/state" "$TMP/home"

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

# Knobs, all read from the environment of the case being driven:
#   STUB_AUTH=0          `sbx ls` fails the way a signed-out CLI does (exit 1)
#   STUB_POLICY=0        `sbx policy ls` fails the way an uninitialized one does
#   STUB_DAEMON=0        the daemon reports "stopped" until `daemon start` runs
#   STUB_EXISTS=1        the named sandbox already exists
#   STUB_GLOBAL_ALLOW=1  the global policy allows the canary (i.e. not deny-all)
#   STUB_CHECK_GARBAGE=1 `policy check` emits something unparseable
#   STUB_SB_HOME=...     what the in-box $HOME probe returns (default /home/agent)
#   STUB_TOOLS=0         jq/curl are missing in the box
#   STUB_PLUGIN=1        the earn plugin is already installed in the box
#   STUB_TOKEN_IN_BOX=1  the box already holds a token
#   STUB_FAIL="a b"      subcommands to exit 1 on
#   STUB_FAIL_MATCH=s    exit 1 when the whole argv contains s
cat > "$STUB/sbx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SBX_LOG"

for f in ${STUB_FAIL:-}; do [ "$f" = "$1" ] && exit 1; done
if [ -n "${STUB_FAIL_MATCH:-}" ]; then
  case "$*" in *"$STUB_FAIL_MATCH"*) exit 1 ;; esac
fi

ALLOWED="$TMP_STATE/allowed"   # per-sandbox allow rules, one host per line
EXISTS="$TMP_STATE/exists"

case "$1" in
  version) echo "sbx version: v0.38.0 deadbeef" ;;

  # Exits 0 in BOTH states and reports on stdout. This is the real contract.
  daemon)
    case "$2" in
      status)
        if [ "${STUB_DAEMON:-1}" = "0" ] && [ ! -f "$TMP_STATE/daemon_up" ]; then
          echo "Status: stopped"
        else
          echo "Status: running"
        fi
        exit 0 ;;
      start) touch "$TMP_STATE/daemon_up"; exit 0 ;;
    esac
    exit 0 ;;

  ls)
    [ "${STUB_AUTH:-1}" = "1" ] || { echo "ERROR: Not authenticated to Docker" >&2; exit 1; }
    if [ -f "$EXISTS" ] || { [ "${STUB_EXISTS:-0}" = "1" ] && [ ! -f "$TMP_STATE/removed" ]; }; then
      echo "test-earner"
    fi
    exit 0 ;;

  policy)
    case "$2" in
      ls)
        [ "${STUB_POLICY:-1}" = "1" ] || { echo "ERROR: not initialized" >&2; exit 1; }
        exit 0 ;;
      allow)
        # sbx policy allow network --sandbox NAME "a,b,c"
        printf '%s\n' "${!#}" | tr ',' '\n' >> "$ALLOWED"
        exit 0 ;;
      rm)
        # sbx policy rm network --sandbox NAME --resource "a,b,c"
        # STUB_RM_NOOP=1 exits 0 having removed nothing, which is what happens
        # when the resource does not match a stored rule.
        [ "${STUB_RM_NOOP:-0}" = "1" ] && exit 0
        if [ -f "$ALLOWED" ]; then
          printf '%s\n' "${!#}" | tr ',' '\n' > "$TMP_STATE/drop"
          grep -vxF -f "$TMP_STATE/drop" "$ALLOWED" > "$ALLOWED.new" 2>/dev/null
          mv "$ALLOWED.new" "$ALLOWED" 2>/dev/null
        fi
        exit 0 ;;
      check)
        # sbx policy check network [--sandbox NAME] HOST --json
        # NOTE: exits 0 even on error, like the real CLI.
        if [ "${STUB_CHECK_GARBAGE:-0}" = "1" ]; then
          echo "ERROR: Not authenticated to Docker"; exit 0
        fi
        host=""
        for a in "$@"; do
          case "$a" in --*|check|network|policy|test-earner) ;; *) host="$a" ;; esac
        done
        case "$*" in
          *--sandbox*)
            if [ -f "$ALLOWED" ] && grep -qxF "$host" "$ALLOWED"; then
              echo '{"allowed":true}'
            else
              echo '{"allowed":false}'
            fi ;;
          *)
            # Global posture: the canary is allowed only when the policy is wide.
            if [ "${STUB_GLOBAL_ALLOW:-0}" = "1" ]; then
              echo '{"allowed":true}'
            else
              echo '{"allowed":false}'
            fi ;;
        esac
        exit 0 ;;
    esac
    exit 0 ;;

  create) touch "$EXISTS"; rm -f "$TMP_STATE/removed"; exit 0 ;;
  stop)   exit 0 ;;
  rm)     rm -f "$EXISTS"; touch "$TMP_STATE/removed"; exit 0 ;;
  cp)     exit 0 ;;
  run)    exit 0 ;;

  exec)
    case "$*" in
      *'printf %s "$HOME"'*) printf '%s' "${STUB_SB_HOME-/home/agent}" ;;
      *'command -v jq'*)     [ "${STUB_TOOLS:-1}" = "1" ] || exit 1 ;;
      *'plugin list'*)       [ "${STUB_PLUGIN:-0}" = "1" ] || exit 1 ;;
      *'.slashwork/token'*)  [ "${STUB_TOKEN_IN_BOX:-0}" = "1" ] || exit 1 ;;
    esac
    exit 0 ;;
esac
exit 0
SH
chmod +x "$STUB/uname" "$STUB/sbx"
export PATH="$STUB:$PATH" SBX_LOG="$LOG" TMP_STATE="$TMP/state"
# HOME decides which token branch runs. Left unstubbed, the suite took one path
# on a developer's machine and the other in CI, asserting neither.
export HOME="$TMP/home"
# A working Claude credential is a precondition for an unattended run, and the
# launcher refuses without one. Seed the preferred form so the earn cases run;
# the refusal has its own case below.
mkdir -p "$HOME/.slashwork"; printf 'sk-ant-oat01-test-token-not-real\n' > "$HOME/.slashwork/claude-token"
# Point the virtualization probe at the test's own filesystem. Reading the real
# /dev/kvm made the Linux refusal pass on a Mac and fail on every CI runner.
export SLASHWORK_KVM_DEV="$TMP/no-such-kvm"
# The stub session returns at once; without these every earn case would pay the
# launcher's real poll and grace intervals (35s) for nothing.
export SLASHWORK_LEG_POLL_SECS=0 SLASHWORK_LEG_GRACE_SECS=0

# ------------------------------------------------------------------ helpers
# Every case starts with a working Claude credential on the host, because the
# launcher refuses an unattended run without one and a case that deletes
# ~/.slashwork (the no-host-token case does) must not silently turn every later
# earn run into that refusal. NO_CLAUDE_TOKEN=1 is for the refusal case itself.
reset_state() {
  rm -rf "$TMP_STATE"; mkdir -p "$TMP_STATE"; : > "$LOG"
  if [ "${NO_CLAUDE_TOKEN:-0}" = "1" ]; then
    rm -f "$HOME/.slashwork/claude-token"
  else
    mkdir -p "$HOME/.slashwork"
    printf 'sk-ant-oat01-test-token-not-real\n' > "$HOME/.slashwork/claude-token"
  fi
}
run_case() { reset_state; ( cd "$WORK" && ./sandbox.sh "$@" 2>&1 ); }
# Same, but keeps state across calls so lock/unlock can be driven in sequence.
run_keep() { : > "$LOG"; ( cd "$WORK" && ./sandbox.sh "$@" 2>&1 ); }
rc_of()    { reset_state; ( cd "$WORK" && ./sandbox.sh "$@" >/dev/null 2>&1 ); echo $?; }

check() { # check <description> <condition-result> <detail>
  if [ "$2" = "0" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n     %s\n' "$1" "$3"; FAILED=1; fi
}
has()  { printf '%s' "$1" | grep -qF "$2" && echo 0 || echo 1; }
# Empty input must NOT satisfy a negative assertion: a case that died before
# producing output would otherwise report ok for every hasnt in the suite.
hasnt(){ [ -n "$1" ] || { echo 1; return; }; printf '%s' "$1" | grep -qF "$2" && echo 1 || echo 0; }
is()   { [ "$1" = "$2" ] && echo 0 || echo 1; }
# "nothing reached sbx" is legitimately proved by an empty log, so this one must
# NOT inherit hasnt's empty-input rule. Reads $LOG directly.
nolog(){ grep -qF "$1" "$LOG" 2>/dev/null && echo 1 || echo 0; }

# ------------------------------------------------------------------- 1: check
OUT=$(STUB_EXISTS=0 run_case --check)
check "--check reports the sandbox is not created yet" \
  "$(has "$OUT" "not created yet")" "$OUT"
check "--check reads name/memory/cpus from settings.json" \
  "$(has "$OUT" "name=test-earner memory=6g cpus=3")" "$OUT"
check "--check creates nothing" "$(nolog "create")" "$(cat "$LOG")"
check "--check exits 0" "$(is "$(STUB_EXISTS=0 rc_of --check)" 0)" ""

OUT=$(STUB_EXISTS=1 run_case --check)
check "--check reports an existing sandbox" "$(has "$OUT" "'test-earner' exists")" "$OUT"
check "--check reports the effective egress" "$(has "$OUT" "egress for 'test-earner'")" "$OUT"
check "--check names the coordinator it will allow" \
  "$(has "$OUT" "coordinator=slashwork.sh")" "$OUT"

# ------------------------------------------------------- 2: refusals up front
# Each refusal asserts the MESSAGE and the EXIT STATUS. Message-only assertions
# let `fail()` lose its exit and the launcher build a box anyway, silently.
OUT=$(STUB_OS=Linux run_case --check)
check "refuses on Linux without KVM" "$(has "$OUT" "sbx needs KVM")" "$OUT"
check "refuses on Linux without KVM: exits 1" "$(is "$(STUB_OS=Linux rc_of --check)" 1)" ""

: > "$TMP/kvm"
OUT=$(STUB_OS=Linux SLASHWORK_KVM_DEV="$TMP/kvm" run_case --check)
check "proceeds on Linux when KVM is present" "$(hasnt "$OUT" "sbx needs KVM")" "$OUT"

OUT=$(STUB_ARCH=x86_64 run_case --check)
check "refuses on macOS without Apple silicon" "$(has "$OUT" "needs Apple silicon")" "$OUT"
check "refuses on macOS without Apple silicon: exits 1" \
  "$(is "$(STUB_ARCH=x86_64 rc_of --check)" 1)" ""
STUB_ARCH=x86_64 run_case --check >/dev/null
check "a refusal stops before any policy work" "$(nolog "policy")" "$(cat "$LOG")"

OUT=$(STUB_AUTH=0 run_case --check)
check "surfaces what sbx said when ls fails" "$(has "$OUT" "Not authenticated")" "$OUT"
check "suggests login without asserting it is the cause" \
  "$(has "$OUT" "If that is an authentication error")" "$OUT"
check "a failing sbx ls exits 1" "$(is "$(STUB_AUTH=0 rc_of --check)" 1)" ""

OUT=$(STUB_POLICY=0 run_case --check)
check "refuses when the global policy is uninitialized" \
  "$(has "$OUT" "sbx policy init deny-all")" "$OUT"
check "an uninitialized policy exits 1" "$(is "$(STUB_POLICY=0 rc_of --check)" 1)" ""

# The gap that made the deny-all comment a lie: a policy that EXISTS but allows.
OUT=$(STUB_GLOBAL_ALLOW=1 run_case --check)
check "refuses when the global policy is not deny-all" \
  "$(has "$OUT" "is not deny-all")" "$OUT"
check "a permissive global policy exits 1" "$(is "$(STUB_GLOBAL_ALLOW=1 rc_of --check)" 1)" ""
STUB_GLOBAL_ALLOW=1 run_case >/dev/null
check "a permissive global policy creates nothing" "$(nolog "create --name")" "$(cat "$LOG")"

# An unreadable decision must fail closed, not be assumed to be a deny.
OUT=$(STUB_CHECK_GARBAGE=1 run_case --check)
check "fails closed when the policy decision cannot be read" \
  "$(has "$OUT" "Refusing rather than assuming")" "$OUT"
check "an unreadable decision exits 1" "$(is "$(STUB_CHECK_GARBAGE=1 rc_of --check)" 1)" ""
OUT=$(STUB_CHECK_GARBAGE=1 SLASHWORK_SKIP_POSTURE_CHECK=1 run_case --check)
check "the posture check has a documented override" "$(has "$OUT" "ready")" "$OUT"

# A stopped daemon must be started detached. Without -d, sandboxd runs attached
# and dies with the shell, taking a standing earner's sandbox down with it.
OUT=$(STUB_DAEMON=0 run_case --check); LOGGED=$(cat "$LOG")
check "starts a stopped daemon detached" "$(has "$LOGGED" "daemon start -d")" "$LOGGED"
check "reads the daemon STATE, not its exit code" "$(has "$OUT" "daemon not running")" "$OUT"
OUT=$(run_case --check); LOGGED=$(cat "$LOG")
check "does not start an already-running daemon" "$(hasnt "$LOGGED" "daemon start")" "$LOGGED"

# A PATH with the uname stub but no sbx at all. Stripping $STUB is not enough:
# a real sbx may be installed on the developer's machine.
mkdir -p "$TMP/nosbx" && cp "$STUB/uname" "$TMP/nosbx/uname"
OUT=$(PATH="$TMP/nosbx:/usr/bin:/bin" run_case --check)
check "refuses when sbx is not installed" "$(has "$OUT" "sbx not installed")" "$OUT"

# --------------------------------------------------- 3: settings validation
mk_folder() { # mk_folder <dir> <settings-json-or-empty>
  mkdir -p "$TMP/$1"; cp "$LAUNCHER" "$TMP/$1/sandbox.sh"; chmod +x "$TMP/$1/sandbox.sh"
  [ -n "${2:-}" ] && printf '%s' "$2" > "$TMP/$1/settings.json"
  :
}
run_in() { local d="$1"; shift; reset_state; ( cd "$TMP/$d" && ./sandbox.sh "$@" 2>&1 ); }
rc_in()  { local d="$1"; shift; reset_state; ( cd "$TMP/$d" && ./sandbox.sh "$@" >/dev/null 2>&1 ); echo $?; }

mk_folder nosettings ""
OUT=$(run_in nosettings --check)
check "no settings.json falls back to the built-in defaults" \
  "$(has "$OUT" "name=slashwork-earner memory=4g cpus=2")" "$OUT"

mk_folder badjson '{"sandbox":'
OUT=$(run_in badjson --check)
check "malformed settings.json falls back to the defaults" \
  "$(has "$OUT" "name=slashwork-earner memory=4g cpus=2")" "$OUT"

# Refuse, do not repair. A silently corrected name points --lock at a DIFFERENT
# sandbox than the one settings.json asks for.
mk_folder badname '{"sandbox":{"name":"bad name'"'"'; touch pwned; '"'"'"}}'
OUT=$(run_in badname --check)
check "refuses an unsafe sandbox.name" "$(has "$OUT" "is not usable")" "$OUT"
check "an unsafe sandbox.name exits 1" "$(is "$(rc_in badname --check)" 1)" ""
check "the unsafe name never reaches sbx" "$(nolog "touch pwned")" "$(cat "$LOG")"
check "nothing ran from the injected name" \
  "$(hasnt "$(ls "$TMP/badname")" "pwned")" "$(ls "$TMP/badname")"

# `tr -cd` used to pass this through, and sbx reads it as a flag, not a name.
mk_folder dashname '{"sandbox":{"name":"-f"}}'
check "refuses a name that would read as a flag" \
  "$(has "$(run_in dashname --check)" "is not usable")" ""

mk_folder badmem '{"sandbox":{"name":"ok","memory":"lots"}}'
check "refuses a non-size sandbox.memory" \
  "$(has "$(run_in badmem --check)" "is not a size")" ""

mk_folder badcpus '{"sandbox":{"name":"ok","cpus":"-1"}}'
check "refuses a non-positive sandbox.cpus" \
  "$(has "$(run_in badcpus --check)" "is not a positive integer")" ""

# The coordinator must be allowlisted or every call inside the box hangs.
mk_folder custombase '{"base_url":"https://staging.example.org:8443/api","sandbox":{"name":"test-earner"}}'
OUT=$(run_in custombase --check)
check "takes the coordinator host from base_url" \
  "$(has "$OUT" "coordinator=staging.example.org")" "$OUT"

# ------------------------------------------------------------ 4: the full run
OUT=$(STUB_EXISTS=0 run_case); LOGGED=$(cat "$LOG")
check "creates with the configured memory and cpus" \
  "$(has "$LOGGED" "create --name test-earner --memory 6g --cpus 3 claude")" "$LOGGED"
check "allows the run hosts as one policy call" \
  "$(has "$LOGGED" "policy allow network --sandbox test-earner api.anthropic.com,claude.ai,*.claude.ai,console.anthropic.com,statsig.anthropic.com,slashwork.sh")" "$LOGGED"
check "allows the setup hosts on a fresh box" \
  "$(has "$LOGGED" "policy allow network --sandbox test-earner github.com,api.github.com,*.githubusercontent.com,registry.npmjs.org")" "$LOGGED"
check "installs the plugin when absent" \
  "$(has "$LOGGED" "plugin install slashwork-earn@slashwork")" "$LOGGED"
check "writes the marker into the sandbox HOME, naming the sandbox" \
  "$(has "$LOGGED" "'test-earner' > \"/home/agent/.slashwork-sandbox\"")" "$LOGGED"
# sbx refuses ":ro" on the primary workspace, so the protection is that the
# real folder is never mounted: the box gets a private copy in a scratch dir.
check "never mounts the earner folder itself" "$(hasnt "$LOGGED" "claude $WORK")" "$LOGGED"
check "mounts a private copy under ~/.slashwork/sandbox-ws" \
  "$(has "$LOGGED" "claude $HOME/.slashwork/sandbox-ws/test-earner")" "$LOGGED"
check "the private copy carries the earner settings" \
  "$([ -f "$HOME/.slashwork/sandbox-ws/test-earner/settings.json" ] && echo 0 || echo 1)" ""
check "the private copy does not carry the launcher" \
  "$([ ! -f "$HOME/.slashwork/sandbox-ws/test-earner/sandbox.sh" ] && echo 0 || echo 1)" ""
# With a setup-token the loop starts via exec so the token can be exported into
# the session's environment rather than written anywhere the worker reads.
check "starts the earn loop at the end, token in the session env" \
  "$(has "$LOGGED" "exec -it test-earner sh -c export CLAUDE_CODE_OAUTH_TOKEN")" "$LOGGED"
check "prompts are off inside the box" "$(has "$LOGGED" "dangerously-skip-permissions")" "$LOGGED"
check "the earn goal is passed in" "$(has "$LOGGED" "/earn 30m")" "$LOGGED"
# A leg must END. The session is bounded by the goal's budget plus a grace and
# by the budget_spent marker, and the box is stopped afterwards so --loop can
# rebuild for the next leg. The stub's session returns at once; the stop must
# still follow it.
check "stops the box when the earn session ends" "$(has "$LOGGED" "stop test-earner")" "$LOGGED"
check "reports the leg ending" "$(has "$OUT" "leg ended")" "$OUT"
check "says which Claude credential it used" "$(has "$OUT" "Claude auth")" "$OUT"

OUT=$(STUB_EXISTS=1 run_case); LOGGED=$(cat "$LOG")
check "re-run does not recreate an existing sandbox" \
  "$(hasnt "$LOGGED" "create --name")" "$LOGGED"
check "re-run still attaches" "$(has "$LOGGED" "exec -it test-earner sh -c export CLAUDE_CODE_OAUTH_TOKEN")" "$LOGGED"
check "re-run still starts the loop with prompts off" "$(has "$LOGGED" "dangerously-skip-permissions")" "$LOGGED"
check "re-run does not offer the lock hint again" "$(hasnt "$OUT" "install-only egress")" "$OUT"

# The $HOME probe must be distinguishable from its fallback, or deleting the
# probe entirely passes.
OUT=$(STUB_EXISTS=1 STUB_SB_HOME='' run_case); LOGGED=$(cat "$LOG")
check "falls back to /home/user when the HOME probe returns nothing" \
  "$(has "$LOGGED" '> "/home/user/.slashwork-sandbox"')" "$LOGGED"
check "says so when it falls back" "$(has "$OUT" "could not read")" "$OUT"

OUT=$(STUB_EXISTS=1 STUB_SB_HOME='/home/x; rm -rf /' run_case)
check "rejects a garbage HOME probe result" "$(has "$OUT" "could not read")" "$OUT"

# --------------------------------------------------------------- 5: the token
rm -rf "$HOME/.slashwork"
OUT=$(STUB_EXISTS=1 run_case); LOGGED=$(cat "$LOG")
check "no host token: says so" "$(has "$OUT" "no host token")" "$OUT"
check "no host token: copies nothing" "$(hasnt "$LOGGED" ".slashwork/token test-earner")" "$LOGGED"

mkdir -p "$HOME/.slashwork"; echo tok > "$HOME/.slashwork/token"
OUT=$(STUB_EXISTS=1 STUB_TOKEN_IN_BOX=0 run_case); LOGGED=$(cat "$LOG")
check "copies the token to the sandbox HOME" \
  "$(has "$LOGGED" "cp $HOME/.slashwork/token test-earner:/home/agent/.slashwork/token")" "$LOGGED"
check "tightens the copied token to 600" "$(has "$LOGGED" "chmod 600")" "$LOGGED"
# `sbx cp` preserves host uid/gid, so a 600 file from a Mac arrives owned by
# 501:dialout in a box whose agent is `agent`, unreadable, and the failure is
# silent ("Not logged in", "no token"). The copy must hand the file to HOME's
# owner, as root.
check "hands the copied token to the box user" \
  "$(has "$LOGGED" "exec -u root test-earner sh -c chown")" "$LOGGED"

OUT=$(STUB_EXISTS=1 STUB_TOKEN_IN_BOX=1 run_case); LOGGED=$(cat "$LOG")
check "token already in the box: no second copy" "$(hasnt "$LOGGED" ".slashwork/token test-earner")" "$LOGGED"

OUT=$(STUB_EXISTS=1 STUB_TOKEN_IN_BOX=0 STUB_FAIL=cp run_case)
check "warns when the token copy fails" "$(has "$OUT" "token copy failed")" "$OUT"

# --------------------------------------------------- 6: degraded-mode warnings
OUT=$(STUB_EXISTS=0 STUB_FAIL=create run_case); LOGGED=$(cat "$LOG")
check "a failed create aborts" "$(has "$OUT" "sbx create failed")" "$OUT"
check "a failed create does not attach" "$(hasnt "$LOGGED" "run --name")" "$LOGGED"

OUT=$(STUB_EXISTS=1 STUB_FAIL_MATCH='policy allow' run_case)
check "warns when an allow rule cannot be applied" "$(has "$OUT" "could not allow")" "$OUT"

OUT=$(STUB_EXISTS=1 STUB_TOOLS=0 STUB_FAIL_MATCH='apt-get' run_case)
check "warns when jq/curl cannot be installed" "$(has "$OUT" "hooks will exit silently")" "$OUT"

OUT=$(STUB_EXISTS=1 STUB_TOOLS=0 run_case); LOGGED=$(cat "$LOG")
check "installs jq and curl as root when missing" "$(has "$LOGGED" "exec -u root")" "$LOGGED"

OUT=$(STUB_EXISTS=1 STUB_TOOLS=1 run_case); LOGGED=$(cat "$LOG")
check "does not reinstall jq/curl when present" "$(hasnt "$LOGGED" "apt-get")" "$LOGGED"

OUT=$(STUB_EXISTS=1 STUB_PLUGIN=1 run_case); LOGGED=$(cat "$LOG")
check "does not reinstall the plugin when present" "$(hasnt "$LOGGED" "plugin install")" "$LOGGED"

OUT=$(STUB_EXISTS=1 STUB_FAIL_MATCH='plugin install' run_case)
check "warns when the plugin install fails" "$(has "$OUT" "plugin install failed")" "$OUT"

OUT=$(STUB_DAEMON=0 STUB_FAIL_MATCH='daemon start' run_case --check)
check "gives up after the daemon retry budget" "$(has "$OUT" "could not start sandboxd")" "$OUT"

# ------------------------------------------------------------ 7: lock/unlock
# Driven as a sequence against the stub's policy STATE, so each assertion is
# about the resulting egress rather than about which command was emitted.
reset_state
STUB_EXISTS=0 run_keep >/dev/null
OUT=$(run_keep --lock)
check "--lock reports the lock it verified" "$(has "$OUT" "github.com is denied")" "$OUT"
check "--lock does not attach" "$(hasnt "$(cat "$LOG")" "run --name")" "$(cat "$LOG")"
OUT=$(run_keep --check)
check "--lock actually denies github afterwards" "$(has "$OUT" "github.com  denied")" "$OUT"
check "--lock keeps the run hosts" "$(has "$OUT" "api.anthropic.com  allowed")" "$OUT"

# The regression that made --lock cosmetic: a bare re-run re-applied the setup
# hosts, so an earner who locked down on Monday was reopened on Tuesday.
OUT=$(run_keep); LOGGED=$(cat "$LOG")
check "a re-run does NOT reopen the setup egress" \
  "$(hasnt "$LOGGED" "policy allow network --sandbox test-earner github.com")" "$LOGGED"
check "a re-run says it left the egress alone" "$(has "$OUT" "leaving setup egress as it is")" "$OUT"
OUT=$(run_keep --check)
check "github is still denied after a re-run" "$(has "$OUT" "github.com  denied")" "$OUT"

OUT=$(run_keep --unlock)
check "--unlock reopens the setup egress" "$(has "$OUT" "setup egress reopened")" "$OUT"
OUT=$(run_keep --check)
check "--unlock actually allows github again" "$(has "$OUT" "github.com  allowed")" "$OUT"

# A removal that exits 0 having removed nothing must NOT be reported as locked.
reset_state
STUB_EXISTS=0 run_keep >/dev/null
OUT=$(STUB_RM_NOOP=1 run_keep --lock)
check "--lock refuses to claim a lock it could not verify" \
  "$(has "$OUT" "still allowed")" "$OUT"
check "--lock exits 1 when the removal did not take" \
  "$(is "$( ( cd "$WORK" && STUB_RM_NOOP=1 ./sandbox.sh --lock >/dev/null 2>&1 ); echo $?)" 1)" ""

OUT=$(run_case --lock)
check "--lock on a box that does not exist refuses" "$(has "$OUT" "nothing to lock")" "$OUT"
check "--lock on a missing box exits 1" "$(is "$(rc_of --lock)" 1)" ""

# --------------------------------------------------------------- 8: --rebuild
reset_state
STUB_EXISTS=0 run_keep >/dev/null
OUT=$(run_keep --rebuild); LOGGED=$(cat "$LOG")
check "--rebuild removes the sandbox" "$(has "$LOGGED" "rm -f test-earner")" "$LOGGED"
check "--rebuild stops it first" "$(has "$LOGGED" "stop test-earner")" "$LOGGED"
check "--rebuild recreates it afterwards" "$(has "$LOGGED" "create --name test-earner")" "$LOGGED"
check "--rebuild removes before it creates" \
  "$([ "$(printf '%s\n' "$LOGGED" | grep -n 'rm -f test-earner' | head -1 | cut -d: -f1)" \
     -lt "$(printf '%s\n' "$LOGGED" | grep -n 'create --name' | head -1 | cut -d: -f1)" ] && echo 0 || echo 1)" "$LOGGED"
check "--rebuild attaches at the end" "$(has "$LOGGED" "exec -it test-earner sh -c export CLAUDE_CODE_OAUTH_TOKEN")" "$LOGGED"

# sbx rm refuses a running sandbox; discarding that made --rebuild a silent
# no-op that attached to the box it was asked to destroy.
OUT=$(STUB_EXISTS=1 STUB_FAIL=rm run_case --rebuild); LOGGED=$(cat "$LOG")
check "--rebuild refuses when the removal did not take" \
  "$(has "$OUT" "could not remove")" "$OUT"
check "--rebuild does not attach to the box it failed to remove" \
  "$(hasnt "$LOGGED" "run --name")" "$LOGGED"

# ------------------------------------------------------------- 9: arg parsing
OUT=$(run_case --lokc)
check "an unknown flag prints usage" "$(has "$OUT" "usage:")" "$OUT"
check "an unknown flag exits 2" "$(is "$(rc_of --lokc)" 2)" ""
check "an unknown flag touches no sandbox" "$(nolog "create")" "$(cat "$LOG")"

# --------------------------------------------- 10b: no credential, no run
# A box parked at "Not logged in" for its whole budget is the silent failure
# the launcher exists to stop, so an unattended run without a working Claude
# credential must refuse up front rather than start.
OUT=$(NO_CLAUDE_TOKEN=1 STUB_EXISTS=0 run_case --earn 8h); LOGGED=$(cat "$LOG")
check "refuses an unattended run with no Claude credential" "$(is "$(NO_CLAUDE_TOKEN=1 rc_of --earn 8h)" 1)" ""
check "the refusal names setup-token as the fix" "$(has "$OUT" "claude setup-token")" "$OUT"
check "the refusal starts no session" "$(hasnt "$LOGGED" "dangerously-skip-permissions")" "$LOGGED"
OUT=$(NO_CLAUDE_TOKEN=1 STUB_EXISTS=0 run_case --shell); LOGGED=$(cat "$LOG")
check "--shell still attaches without a credential, for /login by hand" \
  "$(has "$LOGGED" "run --name test-earner")" "$LOGGED"

# -------------------------------------------- 11: single command and legs
# ./sandbox.sh --earn GOAL is the product: one command, prompts off inside,
# goal passed through. --loop runs legs and destroys the box between them so
# nothing a task planted survives into the next leg.
OUT=$(STUB_EXISTS=0 run_case --earn 8h); LOGGED=$(cat "$LOG")
check "--earn passes its goal into the box" "$(has "$LOGGED" "/earn 8h")" "$LOGGED"
check "--earn runs with prompts off" "$(has "$LOGGED" "dangerously-skip-permissions")" "$LOGGED"
check "--earn rejects a malformed goal" "$([ "$(rc_of --earn tomorrow)" = "1" ] && echo 0 || echo 1)" ""

OUT=$(STUB_EXISTS=0 run_case --loop 2 30m); LOGGED=$(cat "$LOG")
check "--loop removes the box before each leg" \
  "$([ "$(printf '%s\n' "$LOGGED" | grep -c '^rm -f test-earner$')" -ge 2 ] && echo 0 || echo 1)" "$LOGGED"
check "--loop creates a fresh box for each leg" \
  "$([ "$(printf '%s\n' "$LOGGED" | grep -c '^create --name test-earner')" -ge 2 ] && echo 0 || echo 1)" "$LOGGED"
check "--loop reports when all legs are done" "$(has "$OUT" "all 2 legs done")" "$OUT"
check "--loop needs a leg count" "$([ "$(rc_of --loop 8h)" = "1" ] && echo 0 || echo 1)" ""

# ------------------------------------------------------- 10: the harness itself
check "hasnt fails on empty input" "$(is "$(hasnt "" anything)" 1)" ""

echo
if [ "$FAILED" -eq 0 ]; then echo "all sandbox.sh tests passed"; else echo "sandbox.sh tests FAILED"; fi
exit "$FAILED"
