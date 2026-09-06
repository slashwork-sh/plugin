#!/usr/bin/env bash
# Tests for goal-check.sh and clear-marker.sh, the two per-round loop steps
# that moved out of SKILL.md so the commands carry no shell expansion.
#
# Run: bash plugins/earn/hooks/goal-check_test.sh
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
GOAL="$HOOK_DIR/goal-check.sh"
CLEAR="$HOOK_DIR/clear-marker.sh"
SESSION="goalcheck-test"
export CLAUDE_CODE_SESSION_ID="$SESSION"
STATE="/tmp/slashwork-work-${SESSION}.json"
MARKER="/tmp/slashwork-earn-${SESSION}.json"
FAILM="/tmp/slashwork-submit-fail-${SESSION}.json"
PASS=0

fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && { echo "-- detail --"; echo "$2"; }; exit 1; }
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
cleanup() { rm -f "$STATE" "$MARKER" "$FAILM" /tmp/slashwork-job-${SESSION}-*.json; }
trap cleanup EXIT

state() { # state <deadline-offset> <rounds-json>
  printf '{"base":"https://slashwork.sh","mode":"earn","gmode":"time","model":"haiku","start":%s,"deadline":%s,"target_credits":0,"baseline_credits":0,"done":%s}\n' \
    "$(date +%s)" "$(( $(date +%s) + $1 ))" "$2" > "$STATE"
}

# --- clear-marker removes the previous round's marker ------------------------
cleanup
printf '%s\n' '{"status":"claimed"}' > "$MARKER"
OUT=$("$CLEAR")
[ -f "$MARKER" ] && fail "clear-marker left the marker in place"
case "$OUT" in *"marker cleared"*) ok "clear-marker removes the marker and says so" ;;
  *) fail "clear-marker output" "$OUT" ;; esac

# It must be safe when there is nothing to clear.
OUT=$("$CLEAR") || fail "clear-marker failed with no marker present"
ok "clear-marker is safe when no marker exists"

# --- a live budget continues -------------------------------------------------
cleanup; state 600 '[]'
OUT=$("$GOAL")
case "$OUT" in *"GOAL: continue"*) ok "a live time budget continues" ;;
  *) fail "live budget" "$OUT" ;; esac

# --- an expired budget is done -----------------------------------------------
cleanup; state -60 '["a","b"]'
OUT=$("$GOAL")
case "$OUT" in *"GOAL: done"*) ok "an expired time budget reports done" ;;
  *) fail "expired budget" "$OUT" ;; esac

# --- a failed submit is surfaced and cleaned up ------------------------------
cleanup; state 600 '[]'
printf '%s\n' '{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","code":500}' > "$FAILM"
touch "/tmp/slashwork-job-${SESSION}-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json"
OUT=$("$GOAL")
case "$OUT" in *"SUBMIT_FAILED"*) : ;; *) fail "submit failure surfaced" "$OUT" ;; esac
[ -f "$FAILM" ] && fail "the fail marker was not cleared"
[ -f "/tmp/slashwork-job-${SESSION}-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json" ] \
  && fail "the stale staged job was not dropped"
ok "a failed submit is reported once, then its marker and staged job are dropped"

# --- the loop keeps going after a failed submit ------------------------------
case "$OUT" in *"GOAL: continue"*) ok "a failed submit does not stop the loop" ;;
  *) fail "continue after failure" "$OUT" ;; esac

echo
echo "goal-check.sh / clear-marker.sh: $PASS checks passed"
