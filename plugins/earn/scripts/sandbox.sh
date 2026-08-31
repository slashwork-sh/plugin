#!/usr/bin/env bash
# slashwork earner sandbox launcher.
#
# Runs the whole /earn session inside a Docker Sandboxes microVM (sbx) instead
# of on the host, with deny-by-default egress allowlisted to the few hosts the
# earner loop actually needs.
#
# What this protects: your machine. A stranger's task prompt runs against a
# kernel boundary instead of against a promise that the folder was empty.
#
# What it narrows but does not close: exfiltration. The allowlist cuts a
# compromised worker down to a handful of hosts, which is a real reduction, but
# it is not zero. Until --lock, github and npm are reachable and both accept
# writes. After --lock, api.anthropic.com still takes an arbitrary POST body
# under someone else's API key. And the submit path is allowlisted by design:
# a task whose stated deliverable IS the payload gets it out through the one
# host the policy can never block. Say "narrows", never "prevents".
#
# What this does NOT protect at all: the offloader's payload from you. You own
# this host, so you can read anything in the sandbox (`sbx exec -it NAME bash`).
# The sandbox points outward, not inward. Do not tell anyone otherwise.
#
# Usage:
#   ./sandbox.sh            preflight, create if needed, bootstrap, attach
#   ./sandbox.sh --check    preflight only, print what is and is not ready
#   ./sandbox.sh --lock     drop the setup-only egress rules (github, npm)
#   ./sandbox.sh --unlock   put them back for a plugin update
#   ./sandbox.sh --rebuild  destroy and recreate the sandbox from scratch
set -uo pipefail

say()  { printf '%s\n' "$*"; }
fail() { printf 'SANDBOX: %s\n' "$*" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$HERE/settings.json"

# The device that proves hardware virtualization, indirected so the test can
# drive both branches. Reading the real /dev/kvm made the Linux refusal test
# pass on a Mac and fail on any runner that has one, which is every current
# GitHub ubuntu image.
KVM_DEV="${SLASHWORK_KVM_DEV:-/dev/kvm}"

# Run settings, with defaults that work when settings.json has no sandbox block.
NAME="slashwork-earner"; MEM="4g"; CPUS="2"; BASE_URL=""
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  v=$(jq -r '.sandbox.name // empty' "$SETTINGS" 2>/dev/null);   [ -n "$v" ] && NAME="$v"
  v=$(jq -r '.sandbox.memory // empty' "$SETTINGS" 2>/dev/null); [ -n "$v" ] && MEM="$v"
  v=$(jq -r '.sandbox.cpus // empty' "$SETTINGS" 2>/dev/null);   [ -n "$v" ] && CPUS="$v"
  v=$(jq -r '.base_url // empty' "$SETTINGS" 2>/dev/null);       [ -n "$v" ] && BASE_URL="$v"
elif [ -f "$SETTINGS" ]; then
  say "SANDBOX: jq is not installed, so $SETTINGS was not read; using defaults"
fi

# Refuse rather than repair. All three reach sbx as argv and the name also
# reaches `sh -c` strings that run inside the box. A silently corrected name is
# worse than stopping, because it points every later command -- including
# --lock -- at a DIFFERENT sandbox than the one settings.json asks for. The
# leading character is separate: `tr -cd` happily returns "-f", which sbx reads
# as a flag rather than a name.
printf '%s' "$NAME" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$' \
  || fail "sandbox.name '$NAME' is not usable. Letters, digits, dot, underscore and hyphen only, starting with a letter or digit."
printf '%s' "$MEM" | grep -qE '^[0-9]+[mMgG]$' \
  || fail "sandbox.memory '$MEM' is not a size like 4g or 4096m."
printf '%s' "$CPUS" | grep -qE '^[1-9][0-9]*$' \
  || fail "sandbox.cpus '$CPUS' is not a positive integer."

# The coordinator has to be reachable or every listener and submit call inside
# the box hangs against a deny-all policy with nothing pointing back here.
# base_url is the documented override, so an earner on a staging coordinator
# needs THEIR host allowed, not ours.
COORD_HOST="slashwork.sh"
if [ -n "$BASE_URL" ]; then
  h=$(printf '%s' "$BASE_URL" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*$##; s#:[0-9]+$##')
  if printf '%s' "$h" | grep -qE '^[A-Za-z0-9.-]+$'; then
    COORD_HOST="$h"
  else
    say "SANDBOX: warning, could not read a host out of base_url '$BASE_URL'; allowing $COORD_HOST"
  fi
fi

# Egress the earner loop needs. RUN_HOSTS stay allowed for the life of the box;
# SETUP_HOSTS are only needed to install or update the plugin and are dropped by
# --lock once the sandbox is bootstrapped.
RUN_HOSTS="api.anthropic.com,claude.ai,*.claude.ai,console.anthropic.com,statsig.anthropic.com,$COORD_HOST"
SETUP_HOSTS="github.com,api.github.com,*.githubusercontent.com,registry.npmjs.org"

# A host that must never be reachable from an earner box. It is what turns "the
# global policy exists" into "the global policy actually denies by default".
CANARY_HOST="${SLASHWORK_CANARY_HOST:-example.com}"

MODE="run"
case "${1:-}" in
  --check)   MODE="check" ;;
  --lock)    MODE="lock" ;;
  --unlock)  MODE="unlock" ;;
  --rebuild) MODE="rebuild" ;;
  "")        : ;;
  *) echo "usage: $0 [--check|--lock|--unlock|--rebuild]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------- preflight
command -v sbx >/dev/null 2>&1 || fail "sbx not installed.
  macOS:   brew trust docker/tap && brew install docker/tap/sbx
  Windows: winget install Docker.sbx
  Ubuntu:  curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh && sudo apt-get install docker-sbx"

# sbx needs hardware virtualization. Catching this here beats a confusing
# failure three commands later: on a cloud VM without nested virt there is no
# fix, and the earner should fall back to running /earn on the host.
case "$(uname -s)" in
  Darwin)
    [ "$(uname -m)" = "arm64" ] || fail "sbx needs Apple silicon; this is $(uname -m). Run /earn on the host instead." ;;
  Linux)
    [ -e "$KVM_DEV" ] || fail "no $KVM_DEV. sbx needs KVM, and nested virtualization if this host is itself a VM. Most cloud droplets do not have it. Run /earn on the host instead." ;;
esac

# `sbx daemon status` EXITS 0 WHEN THE DAEMON IS STOPPED -- it reports state on
# stdout ("Status: stopped") and reserves the exit code for its own failures.
# Gating the start on the exit code therefore never starts anything, and the
# next command fails with an unrelated-looking error. Read the line instead, and
# treat anything we cannot parse as "not running": trying to start a daemon that
# is already up is idempotent, skipping a start that was needed is not.
daemon_running() { sbx daemon status 2>/dev/null | grep -qiE '^[[:space:]]*Status:[[:space:]]*running'; }

# -d matters: without it sandboxd runs attached and dies with this shell, which
# on a standing earner box means the sandbox goes down whenever the terminal
# does. Backgrounding it with & is not enough, it still takes the HUP.
if ! daemon_running; then
  say "SANDBOX: daemon not running, starting it"
  sbx daemon start -d >/dev/null 2>&1
  for _ in 1 2 3 4 5; do
    daemon_running && break
    sleep 1
  done
  daemon_running || fail "could not start sandboxd. Try: sbx daemon start -d"
fi

# `sbx ls` is the cheapest call that proves the Docker session is live. Report
# what sbx actually said rather than asserting a cause: an unhealthy daemon and
# a missing flag fail here too, and sending someone to a login they have already
# done wastes the one message they get.
if ! SBX_ERR=$(sbx ls -q 2>&1 >/dev/null); then
  fail "sbx ls failed: ${SBX_ERR:-no output}
If that is an authentication error, run: sbx login"
fi

# The global policy is a one-time, machine-wide choice, so this script refuses
# to make it for you. deny-all is the only setting where the per-sandbox
# allowlist below means anything: a global allow cannot be narrowed by a
# per-sandbox rule, and a global deny would override the allows.
if ! sbx policy ls >/dev/null 2>&1; then
  fail "global network policy not initialized. For an earner box run:
  sbx policy init deny-all
That is machine-wide and one-time (undo with 'sbx policy reset'). Any other
setting leaves this sandbox with wider egress than the allowlist implies."
fi

# ...and "a policy exists" is NOT "a policy denies". `sbx policy init` takes
# allow-all, balanced or deny-all, and sbx's own help recommends balanced, which
# permits "AI services and package registries" globally. Under either of those
# the allowlist below is decoration and the deny-by-default promise in the docs
# is false, with nothing on screen to say so.
#
# So ask the authorizer instead of reading a policy name: `sbx policy check`
# evaluates the same daemon-side code path that enforces sandbox egress. Note it
# exits 0 even when it errors, so the decision has to come out of the output.
posture_allows() { # posture_allows HOST [sandbox] -> 0 allowed, 1 denied, 2 unknown
  _pa_out=$(sbx policy check network --json ${2:+--sandbox "$2"} "$1" 2>&1)
  case "$_pa_out" in
    *'"allowed":true'*|*'"allowed": true'*|*'"decision":"allow"'*|*'"decision": "allow"'*) return 0 ;;
    *'"allowed":false'*|*'"allowed": false'*|*'"decision":"deny"'*|*'"decision": "deny"'*) return 1 ;;
  esac
  return 2
}

posture_allows "$CANARY_HOST"
case $? in
  0) fail "the global network policy allows $CANARY_HOST, so it is not deny-all.
sbx policy init takes allow-all, balanced or deny-all, and only deny-all makes
the per-sandbox allowlist mean anything. Reset and reinitialize:
  sbx policy reset && sbx policy init deny-all" ;;
  2) [ "${SLASHWORK_SKIP_POSTURE_CHECK:-0}" = "1" ] || fail "could not read a decision out of
  sbx policy check network $CANARY_HOST
Refusing rather than assuming the global policy denies by default. Confirm it
yourself with that command, then re-run with SLASHWORK_SKIP_POSTURE_CHECK=1 if
sbx has changed its output format." ;;
esac

# Report a decision as a word, for the posture lines below.
verdict() { posture_allows "$1" "${2:-}"; case $? in 0) printf allowed ;; 1) printf denied ;; *) printf unknown ;; esac; }

if [ "$MODE" = "check" ]; then
  _ver=$(sbx version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  say "SANDBOX: sbx ${_ver:-version unknown} ready"
  say "SANDBOX: name=$NAME memory=$MEM cpus=$CPUS"
  say "SANDBOX: coordinator=$COORD_HOST"
  # The global posture already passed preflight, so state it rather than reprove it.
  say "SANDBOX: global policy denies $CANARY_HOST"
  if sbx ls -q 2>/dev/null | grep -qx "$NAME"; then
    say "SANDBOX: '$NAME' exists"
    # Egress is the only thing worth running --check for, so answer it: ask the
    # authorizer what this sandbox can actually reach.
    say "SANDBOX: egress for '$NAME':"
    say "  api.anthropic.com  $(verdict api.anthropic.com "$NAME")"
    say "  $COORD_HOST  $(verdict "$COORD_HOST" "$NAME")"
    say "  github.com  $(verdict github.com "$NAME")   (denied once --lock has run)"
    say "  $CANARY_HOST  $(verdict "$CANARY_HOST" "$NAME")   (must be denied)"
  else
    say "SANDBOX: '$NAME' not created yet (run $0 to create it)"
  fi
  exit 0
fi

# ------------------------------------------------------------------ rebuild
if [ "$MODE" = "rebuild" ]; then
  say "SANDBOX: removing '$NAME'"
  # sbx rm refuses a running sandbox, and stop is a separate command. Discarding
  # that failure made --rebuild attach to the unchanged box while printing
  # nothing -- the worst possible outcome for the one command an earner reaches
  # for when they suspect a task compromised it.
  sbx stop "$NAME" >/dev/null 2>&1
  sbx rm "$NAME" >/dev/null 2>&1
  if sbx ls -q 2>/dev/null | grep -qx "$NAME"; then
    fail "could not remove '$NAME'; it still exists. Stop it and retry:
  sbx stop $NAME && sbx rm $NAME"
  fi
fi

# ------------------------------------------------------------------- create
if [ "$MODE" != "lock" ] && ! sbx ls -q 2>/dev/null | grep -qx "$NAME"; then
  say "SANDBOX: creating '$NAME' (memory=$MEM cpus=$CPUS, workspace=$HERE)"
  sbx create --name "$NAME" --memory "$MEM" --cpus "$CPUS" claude "$HERE" \
    || fail "sbx create failed"
  CREATED=1
fi

# ------------------------------------------------------------------- policy
apply_allow() {
  sbx policy allow network --sandbox "$NAME" "$1" >/dev/null 2>&1 \
    || say "SANDBOX: warning, could not allow $1"
}

if [ "$MODE" = "lock" ]; then
  sbx ls -q 2>/dev/null | grep -qx "$NAME" \
    || fail "'$NAME' does not exist, so there is nothing to lock."
  say "SANDBOX: dropping setup-only egress (plugin installs will stop working)"
  ERR=$(sbx policy rm network --sandbox "$NAME" --resource "$SETUP_HOSTS" 2>&1 >/dev/null) \
    || say "SANDBOX: warning, could not remove one or more of: $SETUP_HOSTS${ERR:+ ($ERR)}"
  # Do not claim a posture we have not read back. The rm can match nothing and
  # still exit 0, and the agent kit adds its own per-sandbox rules on top that
  # this removal never touches, so "locked" was previously a guess.
  case "$(verdict github.com "$NAME")" in
    denied)  say "SANDBOX: locked. github.com is denied for '$NAME'." ;;
    allowed) fail "github.com is still allowed for '$NAME' after the removal.
Inspect what is granting it:
  sbx policy ls $NAME --wide" ;;
    *)       say "SANDBOX: warning, could not confirm the lock. Check it yourself:
  sbx policy check network --sandbox $NAME github.com" ;;
  esac
  say "SANDBOX: run './sandbox.sh --unlock' when you next need to update the plugin."
  exit 0
fi

say "SANDBOX: applying egress allowlist"
apply_allow "$RUN_HOSTS"

# SETUP_HOSTS only on a box that was just built, or when explicitly asked for.
# Applying them on every run silently undid --lock: the docs describe a bare
# ./sandbox.sh as how you attach, so an earner who locked down on Monday had
# github and npm quietly reopened on Tuesday with nothing on screen to say so.
if [ -n "${CREATED:-}" ] || [ "$MODE" = "unlock" ]; then
  apply_allow "$SETUP_HOSTS"
  [ "$MODE" = "unlock" ] && say "SANDBOX: setup egress reopened. Re-run --lock when the update is done."
else
  say "SANDBOX: leaving setup egress as it is (--unlock reopens it, --lock drops it)"
fi

# ---------------------------------------------------------------- bootstrap
# Everything below is idempotent, so a re-run after a reboot just tops up.
# The single quotes are the point: $HOME must expand inside the sandbox, not on
# the host. Do not hardcode /home/user; the agent image can change it.
# shellcheck disable=SC2016
SB_HOME=$(sbx exec "$NAME" sh -c 'printf %s "$HOME"' 2>/dev/null)
# The probe runs inside the box, and sbx prints its own chrome on command output
# from time to time (update notices), so a stray byte would make this a garbage
# path that still passes a non-empty test -- and then the token, the marker and
# two mkdirs all silently target the wrong place. Require an absolute path with
# nothing exotic in it, and say so when falling back rather than pretending the
# comment above about not hardcoding /home/user still holds.
case "$SB_HOME" in
  /*) printf '%s' "$SB_HOME" | grep -qE '^/[A-Za-z0-9._/-]*$' || SB_HOME="" ;;
  *)  SB_HOME="" ;;
esac
if [ -z "$SB_HOME" ]; then
  SB_HOME="/home/user"
  say "SANDBOX: could not read \$HOME inside the box, assuming $SB_HOME"
fi

# jq and curl: the hooks exit silently without them, which is the single most
# confusing failure mode on a fresh box.
if ! sbx exec "$NAME" sh -c 'command -v jq >/dev/null && command -v curl >/dev/null' 2>/dev/null; then
  say "SANDBOX: installing jq and curl"
  sbx exec -u root "$NAME" sh -c \
    'apt-get update -qq && apt-get install -y -qq jq curl' >/dev/null 2>&1 \
    || say "SANDBOX: warning, could not install jq/curl; the hooks will exit silently without them"
fi

# The earner plugin. The sandbox has its own filesystem, so the host's install
# does not carry over.
if ! sbx exec "$NAME" sh -c 'claude plugin list 2>/dev/null | grep -q slashwork-earn' 2>/dev/null; then
  say "SANDBOX: installing slashwork-earn"
  sbx exec "$NAME" sh -c \
    'claude plugin marketplace add slashwork-sh/plugin && claude plugin install slashwork-earn@slashwork' \
    >/dev/null 2>&1 || say "SANDBOX: warning, plugin install failed; run it by hand inside the sandbox"
fi

# The slashwork token, copied from the host so the earner keeps one identity and
# does not have to re-run /earn init inside the box. It lands outside the shared
# workspace, so it does not appear in the host folder.
if [ -f "$HOME/.slashwork/token" ]; then
  if ! sbx exec "$NAME" sh -c "[ -f \"$SB_HOME/.slashwork/token\" ]" 2>/dev/null; then
    say "SANDBOX: copying the slashwork token in"
    sbx exec "$NAME" sh -c "mkdir -p \"$SB_HOME/.slashwork\"" >/dev/null 2>&1
    sbx cp "$HOME/.slashwork/token" "$NAME:$SB_HOME/.slashwork/token" >/dev/null 2>&1 \
      || say "SANDBOX: warning, token copy failed; run /earn init inside the sandbox"
    sbx exec "$NAME" sh -c "chmod 600 \"$SB_HOME/.slashwork/token\"" >/dev/null 2>&1
  fi
else
  say "SANDBOX: no host token at ~/.slashwork/token; run /earn init inside the sandbox"
fi

# A marker the /earn preflight reads to confirm it is running inside the box
# rather than on the host. Cheap, and it makes a misconfigured run visible
# before any task is claimed.
sbx exec "$NAME" sh -c "printf '%s' '$NAME' > \"$SB_HOME/.slashwork-sandbox\"" >/dev/null 2>&1

# ------------------------------------------------------------------- attach
say ""
say "SANDBOX: attaching to '$NAME'. Inside the session:"
if [ -n "${CREATED:-}" ]; then
  say "  1. /login          sign in to Claude (host credentials do not carry over)"
  say "  2. /earn 8h        start the loop"
  say ""
  say "Then, once it is working: ./sandbox.sh --lock to drop the install-only egress."
else
  say "  /earn 8h"
fi
say ""
exec sbx run --name "$NAME"
