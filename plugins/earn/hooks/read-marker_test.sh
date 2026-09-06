#!/usr/bin/env bash
# Tests for read-marker.sh, the listener-outcome reader.
#
# Covers every marker status the listener can write, the missing-marker case,
# and the one behaviour the inline version was there for: recording the claimed
# id in the state file's `done` list.
#
# Run: bash plugins/earn/hooks/read-marker_test.sh
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
READ="$HOOK_DIR/read-marker.sh"
SESSION="readmarker-test"
STATE="/tmp/slashwork-work-${SESSION}.json"
MARKER="/tmp/slashwork-earn-${SESSION}.json"
JOB="/tmp/slashwork-job-${SESSION}.json"
TASK_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
PASS=0

fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && { echo "-- detail --"; echo "$2"; }; exit 1; }
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
cleanup() { rm -f "$STATE" "$MARKER" "$JOB"; }
trap cleanup EXIT

fresh_state() {
  printf '%s\n' '{"base":"https://slashwork.sh","mode":"earn","model":"haiku","done":[]}' > "$STATE"
}

# --- no marker ---------------------------------------------------------------
cleanup; fresh_state
OUT=$("$READ" "$STATE" "$MARKER")
case "$OUT" in *"RESULT: no_marker"*) ok "missing marker reports no_marker" ;;
  *) fail "missing marker" "$OUT" ;; esac

# --- claimed -----------------------------------------------------------------
cleanup; fresh_state
printf '%s\n' "{\"status\":\"claimed\",\"id\":\"$TASK_ID\",\"job\":\"$JOB\"}" > "$MARKER"
printf '%s\n' '{"class":"research","deadline":"2026-09-06T19:21:21Z","prompt":"x"}' > "$JOB"
OUT=$("$READ" "$STATE" "$MARKER")
case "$OUT" in *"RESULT: claimed"*) : ;; *) fail "claimed status" "$OUT" ;; esac
case "$OUT" in *"ID=$TASK_ID"*) : ;; *) fail "claimed reports the id" "$OUT" ;; esac
case "$OUT" in *"CLASS=research"*) : ;; *) fail "claimed reports the class" "$OUT" ;; esac
case "$OUT" in *"MODEL=haiku"*) : ;; *) fail "claimed reports the model" "$OUT" ;; esac
ok "claimed reports id, job, class, deadline and model"

# The id must land in `done`, or the loop could re-claim the same task.
DONE=$(jq -r '.done[0] // ""' "$STATE")
[ "$DONE" = "$TASK_ID" ] || fail "claimed records the id in done" "done=$DONE"
ok "claimed records the id in the state's done list"

# --- budget_spent ------------------------------------------------------------
cleanup; fresh_state
printf '%s\n' '{"status":"budget_spent"}' > "$MARKER"
OUT=$("$READ" "$STATE" "$MARKER")
case "$OUT" in *"RESULT: budget_spent"*) : ;; *) fail "budget_spent" "$OUT" ;; esac
case "$OUT" in *"DONE=0"*) ok "budget_spent reports the done count" ;;
  *) fail "budget_spent count" "$OUT" ;; esac

# --- auth_failed -------------------------------------------------------------
cleanup; fresh_state
printf '%s\n' '{"status":"auth_failed"}' > "$MARKER"
OUT=$("$READ" "$STATE" "$MARKER")
case "$OUT" in *"RESULT: auth_failed"*) ok "auth_failed is reported" ;;
  *) fail "auth_failed" "$OUT" ;; esac

# --- error with detail -------------------------------------------------------
cleanup; fresh_state
printf '%s\n' '{"status":"error","detail":"no token"}' > "$MARKER"
OUT=$("$READ" "$STATE" "$MARKER")
case "$OUT" in *"RESULT: error"*) : ;; *) fail "error status" "$OUT" ;; esac
case "$OUT" in *"DETAIL=no token"*) ok "error relays the detail" ;;
  *) fail "error detail" "$OUT" ;; esac

# --- a state file that is missing entirely must not abort --------------------
cleanup
printf '%s\n' "{\"status\":\"claimed\",\"id\":\"$TASK_ID\",\"job\":\"$JOB\"}" > "$MARKER"
printf '%s\n' '{"class":"prose","deadline":"","prompt":"x"}' > "$JOB"
OUT=$("$READ" "$STATE" "$MARKER")
case "$OUT" in *"RESULT: claimed"*) ok "a missing state file still reports the claim" ;;
  *) fail "missing state" "$OUT" ;; esac

# --- usage -------------------------------------------------------------------
# No arguments is the skill's calling convention, not an error: it derives the
# paths from the session id itself so the command carries no shell expansion.
# An odd number of arguments is still wrong.
if "$READ" /tmp/only-one >/dev/null 2>&1; then fail "one argument must be a usage error"; fi
ok "a single argument is a usage error"

echo
echo "read-marker.sh: $PASS checks passed"

# --- no-argument form derives its own paths -----------------------------------
# This is how the skill calls it, and the reason the script exists: a command
# with a shell variable in it prompts and hangs an unattended earner.
cleanup
export CLAUDE_CODE_SESSION_ID="$SESSION"
fresh_state
printf '%s\n' "{\"status\":\"claimed\",\"id\":\"$TASK_ID\",\"job\":\"$JOB\"}" > "$MARKER"
printf '%s\n' '{"class":"review","deadline":"","prompt":"x"}' > "$JOB"
OUT=$("$READ")
case "$OUT" in *"RESULT: claimed"*) : ;; *) fail "no-arg form reads the marker" "$OUT" ;; esac
case "$OUT" in *"ID=$TASK_ID"*) ok "no-arg form derives paths from the session id" ;;
  *) fail "no-arg id" "$OUT" ;; esac
unset CLAUDE_CODE_SESSION_ID

# One argument is still a usage error.
if "$READ" /tmp/only-one >/dev/null 2>&1; then fail "one argument must be a usage error"; fi
ok "one argument is a usage error"

echo "read-marker.sh: no-arg form verified"
