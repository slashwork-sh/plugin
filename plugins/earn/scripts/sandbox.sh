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

# A bare ./sandbox.sh is the whole product: create the box if needed, bootstrap
# it, and start the earn loop inside with prompts off, for settings.json's
# default_duration. --earn overrides the goal, --loop runs legs back to back and
# rebuilds the box between them, --shell attaches an interactive session with
# prompts ON for looking around. Everything else is maintenance.
MODE="earn"
GOAL=""
LEGS=1
usage() {
  echo "usage: $0 [--earn GOAL] [--loop LEGS GOAL] [--shell] [--check] [--lock] [--unlock] [--rebuild]" >&2
  exit 2
}
goal_ok() { printf '%s' "$1" | grep -qE '^[0-9]+(s|m|h|cr)$'; }
case "${1:-}" in
  --check)   MODE="check" ;;
  --lock)    MODE="lock" ;;
  --unlock)  MODE="unlock" ;;
  --rebuild) MODE="rebuild" ;;
  --shell)   MODE="shell" ;;
  --earn)    goal_ok "${2:-}" || fail "--earn needs a goal like 8h, 30m or 200cr"; GOAL="$2" ;;
  --loop)
    printf '%s' "${2:-}" | grep -qE '^[1-9][0-9]*$' || fail "--loop needs a leg count, then a goal: --loop 25 8h"
    goal_ok "${3:-}" || fail "--loop needs a goal like 8h after the leg count"
    MODE="loop"; LEGS="$2"; GOAL="$3" ;;
  "")        : ;;
  *) usage ;;
esac
if [ -z "$GOAL" ] && [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  GOAL=$(jq -r '.default_duration // empty' "$SETTINGS" 2>/dev/null)
fi
goal_ok "${GOAL:-}" || GOAL="30m"

# ---------------------------------------------------------------- preflight
command -v sbx >/dev/null 2>&1 || fail "sbx not installed.
  macOS:   brew tap docker/tap && brew install docker/tap/sbx
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
  # -f is load-bearing: without it `sbx rm` asks for confirmation, and with
  # its output sent to /dev/null and a pty attached (under screen, say) that
  # prompt is invisible and waits forever. --loop's first rebuild hung on it
  # for ten minutes with nothing on screen.
  sbx rm -f "$NAME" >/dev/null 2>&1
  if sbx ls -q 2>/dev/null | grep -qx "$NAME"; then
    fail "could not remove '$NAME'; it still exists. Stop it and retry:
  sbx stop $NAME && sbx rm $NAME"
  fi
fi

# --------------------------------------------------------------------- loop
# Legs back to back, and the box is destroyed and recreated between them. That
# is the answer to persistence: a task that plants something inside the box
# (a hook under ~/.claude that forwards later artifacts, a poisoned plugin
# file) gets at most one leg of it. Each leg is a plain --earn run of this
# same script, so the create, bootstrap and auth paths are exercised fresh
# every time rather than assumed to still hold.
if [ "$MODE" = "loop" ]; then
  for leg in $(seq 1 "$LEGS"); do
    say "SANDBOX: leg $leg of $LEGS, rebuilding '$NAME' so nothing a previous task planted survives"
    sbx stop "$NAME" >/dev/null 2>&1
    # -f is load-bearing: without it `sbx rm` asks for confirmation, and with
  # its output sent to /dev/null and a pty attached (under screen, say) that
  # prompt is invisible and waits forever. --loop's first rebuild hung on it
  # for ten minutes with nothing on screen.
  sbx rm -f "$NAME" >/dev/null 2>&1
    if sbx ls -q 2>/dev/null | grep -qx "$NAME"; then
      fail "could not remove '$NAME' before leg $leg; refusing to reuse a box a task may have altered"
    fi
    "$0" --earn "$GOAL" || say "SANDBOX: leg $leg ended with status $?"
    sleep 5
  done
  say "SANDBOX: all $LEGS legs done"
  exit 0
fi

# ------------------------------------------------------------------- create
# The box never sees this folder. sbx insists the primary workspace be
# writable (":ro" is refused on it), and a writable mount of the real earner
# folder is exactly what must not happen: on one earner box that folder sat
# inside a checkout of the coordinator repo, and any task could have edited
# that tree from inside the VM. So the box gets a private copy of the earner
# config in a scratch directory that contains nothing else. The loop keeps its
# state in /tmp inside the box and the artifact is the worker's final message,
# so the copy is all it needs; a task that writes into it writes into a
# throwaway that is wiped on the next create, which --loop does every leg.
WS="$HOME/.slashwork/sandbox-ws/$NAME"
stage_workspace() {
  if ! { rm -rf "$WS" && mkdir -p "$WS" && chmod 700 "$WS"; }; then
    fail "could not stage $WS"
  fi
  for f in settings.json CLAUDE.md README.md; do
    [ -f "$HERE/$f" ] && cp "$HERE/$f" "$WS/$f"
  done
  [ -d "$HERE/.claude" ] && cp -R "$HERE/.claude" "$WS/.claude"
  # Never the launcher itself, the host token, or anything a task could use to
  # learn where it really is.
  return 0
}
if [ "$MODE" != "lock" ] && ! sbx ls -q 2>/dev/null | grep -qx "$NAME"; then
  stage_workspace
  say "SANDBOX: creating '$NAME' (memory=$MEM cpus=$CPUS, workspace=a private copy of $HERE at $WS)"
  sbx create --name "$NAME" --memory "$MEM" --cpus "$CPUS" claude "$WS" \
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

# `sbx cp` preserves the HOST file's uid and gid. A 600 file copied from a Mac
# arrives owned by 501:dialout in a box whose agent is `agent`, so the agent
# cannot read it and the failure is silent: Claude says "Not logged in" and the
# listener says "no token", both with the file plainly present. Every copy in
# goes through this, which hands the file to whoever owns the box's HOME.
own_in_box() { # own_in_box <path inside the box>
  sbx exec -u root "$NAME" sh -c "chown \"\$(stat -c %u:%g \"$SB_HOME\")\" \"$1\" && chmod 600 \"$1\"" >/dev/null 2>&1 \
    || say "SANDBOX: warning, could not fix ownership of $1; the agent may be unable to read it"
}

# The slashwork token, copied from the host so the earner keeps one identity and
# does not have to re-run /earn init inside the box. It lands outside the shared
# workspace, so it does not appear in the host folder.
if [ -f "$HOME/.slashwork/token" ]; then
  # Present AND readable by the agent; a root-owned leftover must be redone.
  if ! sbx exec "$NAME" sh -c "[ -r \"$SB_HOME/.slashwork/token\" ]" 2>/dev/null; then
    say "SANDBOX: copying the slashwork token in"
    sbx exec "$NAME" sh -c "mkdir -p \"$SB_HOME/.slashwork\"" >/dev/null 2>&1
    sbx cp "$HOME/.slashwork/token" "$NAME:$SB_HOME/.slashwork/token" >/dev/null 2>&1 \
      || say "SANDBOX: warning, token copy failed; run /earn init inside the sandbox"
    own_in_box "$SB_HOME/.slashwork/token"
  fi
else
  say "SANDBOX: no host token at ~/.slashwork/token; run /earn init inside the sandbox"
fi

# The Claude credential the worker will spend. This is the unavoidable part of
# the model: an earner that uses your unused quota has to hold a credential
# that can use your quota, inside a box that runs strangers' prompts. What we
# can choose is WHICH credential.
#
# Preferred: a token from `claude setup-token`, saved by the user at
# ~/.slashwork/claude-token. It is long-lived, headless, and revocable on its
# own without touching the host login, which is exactly what you want for a
# credential that lives next to untrusted code. Fallback: the host's
# ~/.claude/.credentials.json copied in, which works with no setup but is the
# same credential your desktop session runs on, so revoking it means logging
# out everywhere. Say which one was used; the difference matters.
CLAUDE_AUTH="none"
if [ -f "$HOME/.slashwork/claude-token" ]; then
  _tok=$(tr -d '[:space:]' < "$HOME/.slashwork/claude-token")
  if [ -n "$_tok" ]; then
    sbx exec "$NAME" sh -c "mkdir -p \"$SB_HOME/.slashwork\"" >/dev/null 2>&1
    sbx cp "$HOME/.slashwork/claude-token" "$NAME:$SB_HOME/.slashwork/claude-token" >/dev/null 2>&1 \
      && own_in_box "$SB_HOME/.slashwork/claude-token" \
      && CLAUDE_AUTH="setup-token"
  fi
  unset _tok
fi
# The host file is only worth copying if it is still live. On macOS the real
# credential is refreshed in the Keychain and this file is a snapshot that can
# be months stale; inside the box it produces "Login expired" with no way to
# refresh, which is worse than saying nothing because the launcher would have
# just claimed auth was handled. Read expiresAt (epoch ms) and refuse a dead
# one up front.
if [ "$CLAUDE_AUTH" = "none" ] && [ -f "$HOME/.claude/.credentials.json" ] && command -v jq >/dev/null 2>&1; then
  _exp=$(jq -r '.claudeAiOauth.expiresAt // 0' "$HOME/.claude/.credentials.json" 2>/dev/null)
  _now_ms=$(( $(date +%s) * 1000 ))
  if [ "${_exp:-0}" -gt "$_now_ms" ] 2>/dev/null; then
    sbx exec "$NAME" sh -c "mkdir -p \"$SB_HOME/.claude\"" >/dev/null 2>&1
    sbx cp "$HOME/.claude/.credentials.json" "$NAME:$SB_HOME/.claude/.credentials.json" >/dev/null 2>&1 \
      && own_in_box "$SB_HOME/.claude/.credentials.json" \
      && CLAUDE_AUTH="host-login"
  else
    CLAUDE_AUTH="stale"
  fi
  unset _exp _now_ms
fi
case "$CLAUDE_AUTH" in
  setup-token) say "SANDBOX: Claude auth: setup-token from ~/.slashwork/claude-token (revocable on its own)" ;;
  host-login)  say "SANDBOX: Claude auth: copied your host login (live until its expiresAt; it cannot refresh inside the box). For an unattended run use 'claude setup-token' saved to ~/.slashwork/claude-token" ;;
  stale)       say "SANDBOX: Claude auth: ~/.claude/.credentials.json is expired (the live credential is in the Keychain and does not copy). Run 'claude setup-token' and save the token to ~/.slashwork/claude-token, then re-run." ;;
  none)        say "SANDBOX: no Claude credential found on the host; the session will ask you to /login" ;;
esac

# A marker the /earn preflight reads to confirm it is running inside the box
# rather than on the host. Cheap, and it makes a misconfigured run visible
# before any task is claimed.
sbx exec "$NAME" sh -c "printf '%s' '$NAME' > \"$SB_HOME/.slashwork-sandbox\"" >/dev/null 2>&1

# ------------------------------------------------------------------- attach
if [ "$MODE" = "shell" ]; then
  say ""
  say "SANDBOX: attaching an interactive session to '$NAME' (prompts ON; this is for looking around, not earning)"
  [ "$CLAUDE_AUTH" = "none" ] && say "  run /login first; then /earn $GOAL starts the loop"
  say ""
  exec sbx run --name "$NAME"
fi

# The earn run. Prompts are off INSIDE the box and nowhere else. This is the
# whole reason the box exists: an unattended earner cannot answer Claude Code's
# approval prompts, and the worker runs whatever commands a stranger's task
# needs, so the prompts cannot be allowlisted in advance either. On the host,
# skipping them would hand a task prompt your filesystem. In here it hands it a
# read-only workspace, a deny-by-default network, and a box that is rebuilt
# between legs. That is the trade, and it is only acceptable because of the
# three things above.
# An unattended run with no working Claude credential sits at "Not logged in"
# for its whole budget, claiming nothing and saying nothing, which is the
# failure this launcher exists to stop. Refuse up front; --shell is the mode
# for logging in by hand.
case "$CLAUDE_AUTH" in
  setup-token|host-login) : ;;
  *) fail "no working Claude credential for the box (auth: $CLAUDE_AUTH).
An unattended earner cannot log in. Run 'claude setup-token' on this host,
save the token to ~/.slashwork/claude-token (chmod 600), and re-run.
Or './sandbox.sh --shell' to attach and /login interactively." ;;
esac

say ""
say "SANDBOX: starting /earn $GOAL inside '$NAME' with prompts off"
say "SANDBOX: workspace read-only, egress deny-by-default, Claude auth: $CLAUDE_AUTH"
[ -n "${CREATED:-}" ] && say "SANDBOX: once a task has completed, run './sandbox.sh --lock' to drop the install-only egress"
say ""
# Not exec: --loop needs this to return when the budget is spent.
#
# -it is load-bearing. Without a pty Claude Code sees a non-TTY stdin, runs
# the /earn skill as a single turn, and exits the moment the skill ends its
# turn to wait for the listener. The exec session ends, sbx stops the VM, and
# the background listener dies with it, leaving no marker: an earner that
# connected, sat on the feed for a few seconds, and vanished. The earn loop
# depends on Claude Code re-invoking the skill when the listener exits, and
# that only happens in a live interactive session.
# A leg has to END. Claude Code stays interactive after the skill prints its
# budget summary, so the session below never returns on its own; without a
# bound, --loop's first leg is also its last, and a single --earn "for 10m"
# runs until someone quits it. Two things end a leg: the goal's wall-clock
# budget plus a grace for the task in flight, and the listener's own
# budget_spent marker (which can arrive early: a microVM clock that gets
# snapped forward after a stop/resume ends the guest's budget in guest time,
# not ours). Either way the box is stopped, the session with it, and --loop
# rebuilds for the next leg.
goal_secs() { # goal_secs GOAL -> seconds; a credits goal gets the core's 24h ceiling
  case "$1" in
    *s) printf '%s' "${1%s}" ;;
    *m) printf '%s' $(( ${1%m} * 60 )) ;;
    *h) printf '%s' $(( ${1%h} * 3600 )) ;;
    *)  printf '%s' 86400 ;;
  esac
}
LEG_CAP=$(( $(goal_secs "$GOAL") + 600 ))
# Poll and grace intervals are overridable so the test suite, whose stub
# session returns at once, does not pay 35 seconds per earn case.
LEG_POLL="${SLASHWORK_LEG_POLL_SECS:-20}"
LEG_GRACE="${SLASHWORK_LEG_GRACE_SECS:-15}"

# The session runs in the FOREGROUND and the bound runs beside it. The first
# cut backgrounded the session so this shell could poll it, and a backgrounded
# job cannot own the pty that -it needs: sbx failed the exec ("inspect exec:
# context deadline exceeded") and both loop legs ended in seconds. So the
# watchdog is the background half: it waits for the cap or the marker, then
# stops the box, which ends the foreground session.
leg_watchdog() {
  local start; start=$(date +%s)
  while :; do
    sleep "$LEG_POLL"
    if [ $(( $(date +%s) - start )) -ge "$LEG_CAP" ]; then
      say "SANDBOX: leg cap reached (${LEG_CAP}s); stopping the box"
      break
    fi
    if sbx exec "$NAME" sh -c 'grep -qs budget_spent /tmp/slashwork-earn-*.json' 2>/dev/null; then
      # The summary turn needs a moment to print before the box goes away.
      sleep "$LEG_GRACE"
      say "SANDBOX: budget spent inside the box; stopping it"
      break
    fi
  done
  sbx stop "$NAME" >/dev/null 2>&1
}
leg_watchdog &
WATCHDOG_PID=$!
if [ "$CLAUDE_AUTH" = "setup-token" ]; then
  # shellcheck disable=SC2016
  sbx exec -it "$NAME" sh -c 'export CLAUDE_CODE_OAUTH_TOKEN="$(cat "$HOME/.slashwork/claude-token")"; exec claude --dangerously-skip-permissions "/earn '"$GOAL"'"'
else
  sbx run --name "$NAME" -- --dangerously-skip-permissions "/earn $GOAL"
fi
# The session ended (the watchdog stopped the box, or someone quit it).
# Either way, retire the watchdog and make sure the box is down so --loop
# rebuilds it rather than reusing it.
kill "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null
sbx stop "$NAME" >/dev/null 2>&1
say "SANDBOX: leg ended"
