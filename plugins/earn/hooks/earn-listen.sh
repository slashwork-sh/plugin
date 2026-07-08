#!/usr/bin/env bash
# Background SSE listener for the /earn loop.
#
# Holds the coordinator's task queue feed open and claims the first task the
# instant its event lands, so the earner session can sit truly idle between
# tasks: the /earn skill launches this in the background and ends its turn,
# and Claude Code re-invokes the skill only when this process exits (a task
# claimed, the budget spent, or the token rejected). No model turns burn while
# waiting, and claiming happens in-process the moment the event arrives, which
# is what keeps the requester's short claim window from falling back to local.
#
# It writes exactly one outcome to the marker file and exits 0:
#   {"status":"claimed","id":"<uuid>","job":"<path>"}   staged, ready to run
#   {"status":"budget_spent"}                            deadline reached, no task
#   {"status":"auth_failed"}                             token rejected (401/403)
#   {"status":"error","detail":"..."}                    unusable state/config
#
# Usage: earn-listen.sh <state-file> <marker-file>
#   state-file: the session state written by /earn (carries base + deadline)
#   marker-file: where to write the single-line JSON outcome
# Token: SLASHWORK_TOKEN, else ~/.slashwork/token.
set -uo pipefail

STATE="${1:-}"
MARKER="${2:-}"
if [ -z "$STATE" ] || [ -z "$MARKER" ]; then echo "usage: earn-listen.sh <state> <marker>" >&2; exit 2; fi

write_marker() { printf '%s\n' "$1" > "$MARKER"; }

command -v jq >/dev/null 2>&1 || { write_marker '{"status":"error","detail":"jq missing"}'; exit 0; }
command -v curl >/dev/null 2>&1 || { write_marker '{"status":"error","detail":"curl missing"}'; exit 0; }
[ -f "$STATE" ] || { write_marker '{"status":"error","detail":"no state file"}'; exit 0; }

TOKEN="${SLASHWORK_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$HOME/.slashwork/token" ]; then
  TOKEN=$(cat "$HOME/.slashwork/token")
fi
[ -n "$TOKEN" ] || { write_marker '{"status":"error","detail":"no token"}'; exit 0; }

BASE=$(jq -r '.base // empty' "$STATE" 2>/dev/null)
DEADLINE=$(jq -r '.deadline // 0' "$STATE" 2>/dev/null)
[ -n "$BASE" ] || { write_marker '{"status":"error","detail":"no base in state"}'; exit 0; }

# The bearer token is sent to BASE, so BASE must be https (localhost exempt for
# dev), exactly as submit.sh re-checks: a stranger's task could rewrite the
# staged state file, and the token must never leak to an arbitrary host.
case "$BASE" in
  https://*) : ;;
  http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*) : ;;
  *) write_marker '{"status":"error","detail":"base is not https"}'; exit 0 ;;
esac

# Session id names the staged job file. Prefer the state's `session`, else derive
# it from the filename (/tmp/slashwork-work-<session>.json) so the job path
# matches what submit.sh reconstructs from the SubagentStop envelope.
SESSION_ID=$(jq -r '.session // empty' "$STATE" 2>/dev/null)
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(basename "$STATE" | sed -n 's/^slashwork-work-\(.*\)\.json$/\1/p')
  [ -n "$SESSION_ID" ] || SESSION_ID="default"
fi

# Longest a single SSE connection is held before the reconnect loop re-checks
# the budget. The coordinator heartbeats every 15s, so the connection stays
# warm; this cap just bounds a hung connection and paces the deadline check.
CHUNK_CAP=300
# Backoff floor for reconnects that return fast (server down, refused, 5xx). A
# healthy stream lasts ~CHUNK seconds and resets the backoff to base; a fast
# return escalates it so a down or flaky coordinator is polled at ~1/30s, not
# hammered in a tight loop.
BACKOFF_BASE=2
BACKOFF_MAX=30
backoff=$BACKOFF_BASE

# One cheap auth+reachability probe. Echoes the HTTP status of GET /api/me
# (000 when unreachable). Fast and returns immediately (unlike the SSE stream),
# so it fails a dead token fast and detects a down server without opening the
# expensive stream.
probe() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "authorization: Bearer $TOKEN" "$BASE/api/me" 2>/dev/null || echo 000
}

# Reconnect until a task is claimed or the budget runs out. Each iteration first
# probes /api/me: a rejected token stops now (not after idling to the deadline),
# and an unreachable/erroring server backs off instead of spinning.
while :; do
  NOW=$(date +%s)
  REMAIN=$((DEADLINE - NOW))
  if [ "$REMAIN" -le 0 ]; then
    write_marker '{"status":"budget_spent"}'
    exit 0
  fi

  STATUS=$(probe)
  case "$STATUS" in
    200) : ;;                                   # authed and reachable
    401|403) write_marker '{"status":"auth_failed"}'; exit 0 ;;
    *)                                          # down / 5xx / rate-limited
      sleep "$backoff"
      backoff=$((backoff * 2)); [ "$backoff" -gt "$BACKOFF_MAX" ] && backoff=$BACKOFF_MAX
      continue ;;
  esac

  CHUNK=$REMAIN; [ "$CHUNK" -gt "$CHUNK_CAP" ] && CHUNK=$CHUNK_CAP
  CONN_START=$(date +%s)

  # Process substitution keeps this while loop in the main shell, so a claim can
  # write the marker and `exit` the whole script (a `curl | while` pipe would
  # trap the exit in a subshell). SSE parsing mirrors the skill's inline reader:
  # strip a trailing CR (proxies send CRLF), accept `data:` with or without a
  # space, and validate the id as a UUID before it reaches a path or URL.
  EXPECT=0
  while IFS= read -r line; do
    line=${line%$'\r'}
    case "$line" in
      "event: task"|"event:task") EXPECT=1 ;;
      event:*) EXPECT=0 ;;
      "data:"*)
        [ "$EXPECT" -eq 1 ] || continue
        EXPECT=0
        DATA=${line#data:}; DATA=${DATA# }
        TID=$(printf '%s' "$DATA" | jq -r '.id // empty' 2>/dev/null)
        printf '%s' "$TID" | grep -qE '^[0-9a-fA-F-]{36}$' || continue
        R=$(curl -sS --max-time 20 -w $'\n%{http_code}' -X POST "$BASE/api/tasks/$TID/claim" \
          -H "authorization: Bearer $TOKEN" 2>/dev/null)
        CODE=$(printf '%s' "$R" | tail -n1)
        BODY=$(printf '%s' "$R" | sed '$d')
        case "$CODE" in
          200)
            JOB="/tmp/slashwork-job-${SESSION_ID}-${TID}.json"
            printf '%s' "$BODY" | jq --arg base "$BASE" '. + {base: $base}' > "$JOB"
            write_marker "$(jq -nc --arg id "$TID" --arg job "$JOB" \
              '{status:"claimed", id:$id, job:$job}')"
            exit 0 ;;
          401|403)
            write_marker '{"status":"auth_failed"}'
            exit 0 ;;
          *) : ;;   # 409 lost the race, 5xx transient: keep listening
        esac
        ;;
    esac
  done < <(curl -sN --max-time "$CHUNK" -H "authorization: Bearer $TOKEN" \
            "$BASE/api/queue/stream" 2>/dev/null)

  # Connection ended with no claim. A long-lived connection was healthy: reset
  # the backoff. A fast return means the stream is not holding open (down,
  # refused, immediate close), so back off before reconnecting.
  if [ "$(( $(date +%s) - CONN_START ))" -ge 30 ]; then
    backoff=$BACKOFF_BASE
  else
    sleep "$backoff"
    backoff=$((backoff * 2)); [ "$backoff" -gt "$BACKOFF_MAX" ] && backoff=$BACKOFF_MAX
  fi
done
