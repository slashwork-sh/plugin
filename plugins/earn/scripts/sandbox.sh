#!/usr/bin/env bash
# slashwork earner sandbox launcher.
#
# Runs the whole /earn session inside a Docker Sandboxes microVM (sbx) instead
# of on the host, with deny-by-default egress allowlisted to the few hosts the
# earner loop actually needs.
#
# What this protects: your machine. A stranger's task prompt runs against a
# hard boundary instead of against a promise that the folder was empty, and a
# prompt-injected worker has nowhere to send the offloader's payload.
#
# What this does NOT protect: the offloader's payload from you. You own this
# host, so you can read anything in the sandbox (`sbx exec -it NAME bash`).
# The sandbox points outward, not inward. Do not tell anyone otherwise.
#
# Usage:
#   ./sandbox.sh            preflight, create if needed, bootstrap, attach
#   ./sandbox.sh --check    preflight only, print what is and is not ready
#   ./sandbox.sh --lock     drop the setup-only egress rules (github, npm)
#   ./sandbox.sh --rebuild  destroy and recreate the sandbox from scratch
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$HERE/settings.json"

# Run settings, with defaults that work when settings.json has no sandbox block.
NAME="slashwork-earner"; MEM="4g"; CPUS="2"
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  v=$(jq -r '.sandbox.name // empty' "$SETTINGS" 2>/dev/null);   [ -n "$v" ] && NAME="$v"
  v=$(jq -r '.sandbox.memory // empty' "$SETTINGS" 2>/dev/null); [ -n "$v" ] && MEM="$v"
  v=$(jq -r '.sandbox.cpus // empty' "$SETTINGS" 2>/dev/null);   [ -n "$v" ] && CPUS="$v"
fi

# The name reaches `sh -c` strings that run inside the box, so keep it to
# characters that cannot end a quote or start a second command. settings.json is
# the earner's own file, but a stray space here would fail three commands later
# in a way nobody would connect back to a typo.
CLEAN=$(printf '%s' "$NAME" | tr -cd 'A-Za-z0-9._-')
[ -n "$CLEAN" ] || CLEAN="slashwork-earner"
[ "$CLEAN" = "$NAME" ] || printf 'SANDBOX: sandbox.name %s is not a safe name, using %s\n' "$NAME" "$CLEAN" >&2
NAME="$CLEAN"

# Egress the earner loop needs. RUN_HOSTS stay allowed for the life of the box;
# SETUP_HOSTS are only needed to install or update the plugin and can be dropped
# with --lock once the sandbox is bootstrapped.
RUN_HOSTS="api.anthropic.com,claude.ai,*.claude.ai,console.anthropic.com,statsig.anthropic.com,slashwork.sh"
SETUP_HOSTS="github.com,api.github.com,*.githubusercontent.com,registry.npmjs.org"

MODE="run"
case "${1:-}" in
  --check)   MODE="check" ;;
  --lock)    MODE="lock" ;;
  --rebuild) MODE="rebuild" ;;
  "")        : ;;
  *) echo "usage: $0 [--check|--lock|--rebuild]" >&2; exit 2 ;;
esac

say()  { printf '%s\n' "$*"; }
fail() { printf 'SANDBOX: %s\n' "$*" >&2; exit 1; }

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
    [ -e /dev/kvm ] || fail "no /dev/kvm. sbx needs KVM, and nested virtualization if this host is itself a VM. Most cloud droplets do not have it. Run /earn on the host instead." ;;
esac

# -d matters: without it sandboxd runs attached and dies with this shell, which
# on a standing earner box means the sandbox goes down whenever the terminal
# does. Backgrounding it with & is not enough, it still takes the HUP.
sbx daemon status >/dev/null 2>&1 || {
  say "SANDBOX: daemon not running, starting it"
  sbx daemon start -d >/dev/null 2>&1
  for _ in 1 2 3 4 5; do
    sbx daemon status >/dev/null 2>&1 && break
    sleep 1
  done
  sbx daemon status >/dev/null 2>&1 || fail "could not start sandboxd. Try: sbx daemon start -d"
}

# `sbx ls` is the cheapest call that proves the Docker session is live; the
# policy commands fail the same way but less legibly.
if ! sbx ls -q >/dev/null 2>&1; then
  fail "not signed in to Docker. Run: sbx login"
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

if [ "$MODE" = "check" ]; then
  say "SANDBOX: sbx $(sbx version 2>/dev/null | head -1 | awk '{print $3}') ready"
  say "SANDBOX: name=$NAME memory=$MEM cpus=$CPUS"
  if sbx ls -q 2>/dev/null | grep -qx "$NAME"; then
    say "SANDBOX: '$NAME' exists"
  else
    say "SANDBOX: '$NAME' not created yet (run $0 to create it)"
  fi
  exit 0
fi

# ------------------------------------------------------------------ rebuild
if [ "$MODE" = "rebuild" ]; then
  say "SANDBOX: removing '$NAME'"
  sbx rm "$NAME" >/dev/null 2>&1
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
  say "SANDBOX: dropping setup-only egress (plugin installs will stop working)"
  sbx policy rm network --sandbox "$NAME" --resource "$SETUP_HOSTS" >/dev/null 2>&1 \
    || say "SANDBOX: warning, could not remove one or more of: $SETUP_HOSTS"
  say "SANDBOX: locked. Re-run ./sandbox.sh to restore them for an update."
  exit 0
fi

say "SANDBOX: applying egress allowlist"
apply_allow "$RUN_HOSTS"
apply_allow "$SETUP_HOSTS"

# ---------------------------------------------------------------- bootstrap
# Everything below is idempotent, so a re-run after a reboot just tops up.
# The single quotes are the point: $HOME must expand inside the sandbox, not on
# the host. Do not hardcode /home/user; the agent image can change it.
# shellcheck disable=SC2016
SB_HOME=$(sbx exec "$NAME" sh -c 'printf %s "$HOME"' 2>/dev/null)
[ -n "$SB_HOME" ] || SB_HOME="/home/user"

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
