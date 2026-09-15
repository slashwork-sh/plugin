#!/usr/bin/env sh
# One-command earner setup.
#
#   curl -fsSL https://raw.githubusercontent.com/slashwork-sh/plugin/main/plugins/earn/scripts/install.sh | sh
#
# Takes a machine with sbx installed and turns it into a sandboxed slashwork
# earner in one sitting: signs sbx in, sets the deny-all network policy (with
# one yes/no), drops the launcher into a folder of its own, and starts it. The
# launcher does the rest on its first run: GitHub sign-in for slashwork, a
# Claude setup-token for the box, the box itself, the plugin inside it, the
# lock, and the first earn. Three browser approvals along the way and nothing
# else to type.
#
# This installs nothing with sudo and never installs sbx itself. That is the
# one line the user runs by hand, per platform, and it stays visible: a piped
# installer that reaches for sudo is the thing people rightly refuse to run.
#
# Arguments pass through to the launcher, so `sh -s -- --loop 25 8h` starts a
# standing box straight away.
#
# Env:
#   SLASHWORK_EARNER_DIR   where the launcher lives (default ~/slashwork-earner)
#   SLASHWORK_PLUGIN_REF   git ref to fetch the launcher from (default main)
#   SLASHWORK_PLUGIN_DIR   a local checkout to copy the launcher from instead
#                          of fetching it (development and the test suite)
#   SLASHWORK_TTY          the terminal to read answers from and hand to the
#                          launcher (default /dev/tty); the test suite points
#                          it at a file
set -u

DIR="${SLASHWORK_EARNER_DIR:-$HOME/slashwork-earner}"
REF="${SLASHWORK_PLUGIN_REF:-main}"
TTY="${SLASHWORK_TTY:-/dev/tty}"
SRC="https://raw.githubusercontent.com/slashwork-sh/plugin/$REF/plugins/earn/scripts/sandbox.sh"

log() { printf 'slashwork earn: %s\n' "$1" >&2; }
die() { log "$1"; exit 1; }

# ------------------------------------------------------------- what it needs
command -v sbx >/dev/null 2>&1 || die "sbx is not installed. One line for your platform, then run this again:
  macOS:   brew tap docker/tap && brew install docker/tap/sbx
  Windows: winget install Docker.sbx   (then run this from Git Bash)
  Ubuntu:  curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh && sudo apt-get install docker-sbx"
command -v curl >/dev/null 2>&1 || die "curl is not installed."
command -v jq >/dev/null 2>&1 || die "jq is not installed (macOS: brew install jq; Ubuntu: sudo apt-get install jq). The launcher reads its settings with it."

# Piped through sh, stdin is this script, so every answer and the launcher's
# interactive session come from the terminal directly.
[ -r "$TTY" ] && [ -w "$TTY" ] \
  || die "no terminal at $TTY. This needs one: it opens sign-in pages and asks one question. Run it from a terminal, not from a script or a cron job."

# ------------------------------------------------------------------- docker
# `sbx daemon status` exits 0 whether the daemon is up or not; read the line.
if ! sbx daemon status 2>/dev/null | grep -qiE 'Status:[[:space:]]*running'; then
  sbx daemon start -d >/dev/null 2>&1
fi

if ! sbx ls -q >/dev/null 2>&1; then
  # On a Mac, sbx login stores the credential in the login keychain, which is
  # locked over SSH. Say so before it fails three commands in.
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]; then
    die "sbx is not signed in, and this is an SSH session on a Mac: 'sbx login' needs the machine's own keyboard (it uses the login keychain). Run 'sbx login' at the console once, then run this again."
  fi
  log "signing in to Docker (a browser tab may open)"
  sbx login <"$TTY" || die "sbx login failed"
  sbx ls -q >/dev/null 2>&1 || die "sbx still cannot list sandboxes after signing in. Try: sbx ls"
fi

# ------------------------------------------------------------------- policy
# Machine-wide and one-time, so it is asked, not assumed. deny-all is the only
# setting under which the box's allowlist means anything: a global allow
# cannot be narrowed by a per-sandbox rule.
if ! sbx policy ls >/dev/null 2>&1; then
  log "sbx needs a machine-wide network policy, once. Every sandbox on this machine will start with no network and get only what it is granted; the earner box is granted slashwork and Anthropic."
  printf 'slashwork earn: run "sbx policy init deny-all" now? [y/N] ' >&2
  ans=""
  read -r ans <"$TTY" || ans=""
  case "$ans" in
    y|Y|yes|YES|Yes) sbx policy init deny-all || die "sbx policy init deny-all failed" ;;
    *) die "not set. Run: sbx policy init deny-all, then run this again." ;;
  esac
fi

# ----------------------------------------------------------------- launcher
mkdir -p "$DIR" || die "could not create $DIR"
if [ -n "${SLASHWORK_PLUGIN_DIR:-}" ]; then
  cp "$SLASHWORK_PLUGIN_DIR/plugins/earn/scripts/sandbox.sh" "$DIR/sandbox.sh.new" \
    || die "could not copy the launcher from $SLASHWORK_PLUGIN_DIR"
else
  curl -fsSL -o "$DIR/sandbox.sh.new" "$SRC" || die "could not fetch $SRC"
fi
# A 404 page or a half-fetched file must not become an executable launcher.
grep -q 'slashwork earner sandbox launcher' "$DIR/sandbox.sh.new" \
  || { rm -f "$DIR/sandbox.sh.new"; die "what was fetched is not the launcher (ref '$REF'); nothing installed."; }
if ! { mv "$DIR/sandbox.sh.new" "$DIR/sandbox.sh" && chmod +x "$DIR/sandbox.sh"; }; then
  die "could not install the launcher at $DIR/sandbox.sh"
fi
log "launcher installed at $DIR/sandbox.sh"

# ---------------------------------------------------------------------- run
cd "$DIR" || die "could not enter $DIR"
log "starting the earner. It signs you in to slashwork and to Claude on the way, then builds the box and starts earning."
exec ./sandbox.sh "$@" <"$TTY"
