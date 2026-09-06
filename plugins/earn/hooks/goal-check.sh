#!/usr/bin/env bash
# Report whether the earn goal is met, and surface a failed submit.
#
# Called bare by the skill: no arguments, no shell variables in the command.
# Claude Code prompts on any command carrying an expansion, regardless of
# permission mode, and this runs once per round on an unattended earner, so an
# inline version blocks the loop on every task. See read-marker.sh.
#
# Prints GOAL: done | GOAL: continue, plus SUBMIT_FAILED when the previous
# round's artifact POST did not land. Always exits 0.
set -uo pipefail
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-default}}"
STATE="/tmp/slashwork-work-$SESSION_ID.json"
TOKEN="${SLASHWORK_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$HOME/.slashwork/token" ]; then
  TOKEN=$(cat "$HOME/.slashwork/token")
fi

BASE=$(jq -r .base "$STATE")
GMODE=$(jq -r .gmode "$STATE")
START=$(jq -r .start "$STATE")
DEADLINE=$(jq -r .deadline "$STATE")
TARGET_CREDITS=$(jq -r .target_credits "$STATE")
BASELINE=$(jq -r .baseline_credits "$STATE")
ROUNDS=$(jq '.done | length' "$STATE")

# Surface a failed submit and clean up after it. The SubagentStop hook writes
# this marker when the artifact POST did not return 201, and it leaves the staged
# job in place. It cannot retry on its own (the worker has already stopped and its
# final message is gone), so this loop owns the cleanup: report the loss once,
# drop the stale staged job so it does not accumulate across rounds, then clear
# the marker so the loop keeps going.
FAIL_MARKER="/tmp/slashwork-submit-fail-$SESSION_ID.json"
if [ -f "$FAIL_MARKER" ]; then
  echo "SUBMIT_FAILED: $(jq -c '{id, code}' "$FAIL_MARKER" 2>/dev/null)"
  FAIL_ID=$(jq -r '.id // empty' "$FAIL_MARKER" 2>/dev/null)
  [ -n "$FAIL_ID" ] && rm -f "/tmp/slashwork-job-$SESSION_ID-$FAIL_ID.json"
  rm -f "$FAIL_MARKER"
fi

NOW=$(date +%s)
if [ "$GMODE" = "time" ]; then
  if [ "$((DEADLINE - NOW))" -le 0 ]; then
    echo "GOAL: done"; echo "earned window closed: ran $ROUNDS task(s) in $((NOW - START))s"; exit 0
  fi
  echo "GOAL: continue"; echo "tasks=$ROUNDS elapsed=$((NOW - START))s remaining=$((DEADLINE - NOW))s"
else
  CUR=$(curl -sS --max-time 20 -H "authorization: Bearer $TOKEN" "$BASE/api/me" \
    | jq -r '.credits // 0' 2>/dev/null)
  printf '%s' "$CUR" | grep -qE '^-?[0-9]+$' || CUR=$BASELINE
  GAINED=$((CUR - BASELINE))
  if [ "$GAINED" -ge "$TARGET_CREDITS" ]; then
    echo "GOAL: done"; echo "earned +$GAINED credits over $ROUNDS task(s)"; exit 0
  fi
  echo "GOAL: continue"; echo "tasks=$ROUNDS credits_gained=$GAINED/$TARGET_CREDITS"
fi
