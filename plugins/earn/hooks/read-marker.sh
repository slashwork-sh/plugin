#!/usr/bin/env bash
# Read the listener's outcome marker and report it as RESULT: lines.
#
# This exists as a script rather than as inline Bash in SKILL.md because of what
# the inline version did to an unattended earner. Claude Code's Bash safety
# check reads `jq --arg id "$ID" '.done += [$id]'` as brace-wrapped expansion
# obfuscation and asks the user to confirm it. On an attended run you click
# through; on an unattended `/earn` nobody answers, so the session blocks here
# forever with a task already claimed, and every claimed task expires without a
# submission. That is a dialog box the earner cannot see, and it is the whole
# reason a headless earner never returned an artifact.
#
# A single argv-only invocation of a plugin-shipped script trips nothing, which
# is also why `earn-listen.sh` and `submit.sh` are files. Keep it that way: any
# quoting-heavy jq belongs in here, never in the skill.
#
# Usage: read-marker.sh [state-file marker-file]
#
# With no arguments it derives both paths from the session id in its own
# environment, and that is how the skill must call it. The reason is the same
# safety check that put this logic in a script: a command containing ANY shell
# variable is flagged "Contains expansion" and prompts, no matter what
# permission mode the session runs in (bypassPermissions does not silence it;
# the prompt itself suggests auto mode). Claude Code substitutes
# ${CLAUDE_PLUGIN_ROOT} before the shell ever sees it, so a bare invocation of
# this script expands to a literal path and carries no variable at all. Passing
# "$SESSION_ID"-derived arguments reintroduces the prompt and hangs an
# unattended earner on its first task.
#
# The two-argument form stays for the tests, which need to point at scratch
# files.
# Always exits 0 (except on a usage error); the caller branches on RESULT:.
set -uo pipefail

if [ "$#" -eq 2 ]; then
  STATE="$1"
  MARKER="$2"
elif [ "$#" -eq 0 ]; then
  SESSION_ID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-default}}"
  STATE="/tmp/slashwork-work-$SESSION_ID.json"
  MARKER="/tmp/slashwork-earn-$SESSION_ID.json"
else
  echo "usage: read-marker.sh [state marker]" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "RESULT: error"; echo "DETAIL=jq missing"; exit 0; }
[ -f "$MARKER" ] || { echo "RESULT: no_marker"; exit 0; }

STATUS=$(jq -r '.status // "error"' "$MARKER" 2>/dev/null)
case "$STATUS" in
  claimed)
    ID=$(jq -r '.id' "$MARKER" 2>/dev/null)
    JOB=$(jq -r '.job' "$MARKER" 2>/dev/null)
    # Record the task as seen before the worker runs, so a crash mid-task does
    # not leave the loop able to claim the same id again.
    if [ -f "$STATE" ]; then
      tmp=$(mktemp) || tmp=""
      if [ -n "$tmp" ] && jq --arg id "$ID" '.done += [$id]' "$STATE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$STATE"
      else
        [ -n "$tmp" ] && rm -f "$tmp"
      fi
    fi
    echo "RESULT: claimed"
    echo "ID=$ID"
    echo "JOB=$JOB"
    echo "CLASS=$(jq -r '.class // "?"' "$JOB" 2>/dev/null)"
    echo "TASK_DEADLINE=$(jq -r '.deadline // ""' "$JOB" 2>/dev/null)"
    echo "MODEL=$(jq -r '.model // ""' "$STATE" 2>/dev/null)"
    ;;
  budget_spent)
    echo "RESULT: budget_spent"
    echo "DONE=$(jq '.done | length' "$STATE" 2>/dev/null || echo 0)"
    ;;
  auth_failed)
    echo "RESULT: auth_failed"
    ;;
  *)
    echo "RESULT: error"
    echo "DETAIL=$(jq -r '.detail // "unknown"' "$MARKER" 2>/dev/null)"
    ;;
esac
exit 0
