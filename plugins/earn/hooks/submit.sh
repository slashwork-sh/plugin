#!/usr/bin/env bash
# SubagentStop hook for the slashwork plugin.
#
# Fires when a slashwork worker subagent stops. The worker's FINAL reply IS the
# artifact (it writes no file), so this hook reads that final message straight from
# the SubagentStop envelope and POSTs it to the coordinator. The token comes from
# SLASHWORK_TOKEN, or ~/.slashwork/token written by /earn init.
#
# Reading the reply instead of a file removes the one fragile step in the old
# design: weaker models reliably solved the task but did not always Write the
# artifact file, so the hook had nothing to submit. The final assistant message
# is always present, so every solved task now submits.
#
# The worker's prompt (the first user message in its transcript) names the task
# with "task_id: <id>"; the artifact goes to /api/tasks/<id>/submit with the
# worker's token usage. The coordinator base comes from the job staged for this
# (session, id) pair. A subagent whose prompt has no task_id marker (some other
# Task in the session) is ignored. Non-zero exit is advisory only; never block
# the agent loop.
#
# Stdin is the SubagentStop envelope: { session_id, last_assistant_message,
# agent_transcript_path, ... }.
set -uo pipefail

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[ -n "$SESSION_ID" ] || exit 0   # no session; not a /earn run

# Token: env first, then the file /earn init writes.
TOKEN="${SLASHWORK_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$HOME/.slashwork/token" ]; then
  TOKEN=$(cat "$HOME/.slashwork/token")
fi
[ -n "$TOKEN" ] || { echo "slashwork: no token (set SLASHWORK_TOKEN or run /earn init); not submitting" >&2; exit 0; }

AGENT_TX=$(printf '%s' "$INPUT" | jq -r '.agent_transcript_path // empty')

# The artifact is the worker's final assistant message. Prefer the full text from
# the subagent transcript (no envelope size limits); fall back to the envelope's
# last_assistant_message.
ARTIFACT=""
if [ -n "$AGENT_TX" ] && [ -f "$AGENT_TX" ]; then
  ARTIFACT=$(jq -rs '
    [ .[] | select(.type == "assistant") ] | last
    | (.message.content // []) | map(select(.type == "text") | .text) | join("")
  ' "$AGENT_TX" 2>/dev/null)
fi
if [ -z "$ARTIFACT" ] || [ "$ARTIFACT" = "null" ]; then
  ARTIFACT=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty')
fi
[ -n "$ARTIFACT" ] || { echo "slashwork: no final message to submit" >&2; exit 0; }

# Which task did this worker do? Its prompt (the first user message in its
# transcript) carries "task_id: <uuid>".
FIRST_MSG=""
if [ -n "$AGENT_TX" ] && [ -f "$AGENT_TX" ]; then
  FIRST_MSG=$(jq -rs '
    [ .[] | select(.type == "user") ] | first | .message.content
    | if type == "string" then . else (map(select(.type == "text") | .text) | join("\n")) end
  ' "$AGENT_TX" 2>/dev/null)
fi
ID=$(printf '%s' "$FIRST_MSG" | sed -n 's/.*task_id:[[:space:]]*\([0-9a-fA-F-]\{36\}\).*/\1/p' | head -n1)

# Fallback when the prompt carried no task_id: the subagent transcript was
# missing or unreadable (some harness versions do not pass agent_transcript_path,
# and the envelope's last_assistant_message alone does not name the task). In an
# /earn run the session's only subagent is the worker, and a staged job exists
# only because THIS session claimed a task, so if exactly one job is staged for
# this session it is this worker's task. Zero or several: stay safe and submit
# nothing, so a bare non-worker subagent never has its final message posted.
if [ -z "$ID" ]; then
  STAGED=()
  while IFS= read -r f; do STAGED+=("$f"); done < <(
    ls -1 "/tmp/slashwork-job-${SESSION_ID}-"*.json 2>/dev/null)
  if [ "${#STAGED[@]}" -eq 1 ]; then
    ID=$(basename "${STAGED[0]}" \
      | sed -n "s/^slashwork-job-${SESSION_ID}-\([0-9a-fA-F-]\{36\}\)\.json\$/\1/p")
    [ -n "$ID" ] && echo "slashwork: no task_id in prompt; recovered $ID from the single staged job for this session" >&2
  fi
fi
[ -n "$ID" ] || { echo "slashwork: no task id and no single staged job for this session; not submitting" >&2; exit 0; }

STAGE="/tmp/slashwork-job-${SESSION_ID}-${ID}.json"
[ -f "$STAGE" ] || { echo "slashwork: no staged job for $ID; not submitting" >&2; exit 0; }
BASE="$(jq -r '.base // empty' "$STAGE")"
[ -n "$BASE" ] || { echo "slashwork: no base for $ID; skipping" >&2; exit 0; }

# The token goes in this request, so re-validate the destination even though the
# skill validated it at stage time (a prompt-injected worker could have rewritten
# the staged file). https only (http for localhost dev), and the host must match
# the base the skill recorded in this session's state file.
case "$BASE" in
  https://*) : ;;
  http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*) : ;;
  *) echo "slashwork: refusing to submit to non-https base '$BASE'" >&2; exit 0 ;;
esac
BASE_HOST=$(printf '%s' "$BASE" | sed -n 's#^https\{0,1\}://\([^/]\{1,\}\).*#\1#p')
WORK_STATE="/tmp/slashwork-work-${SESSION_ID}.json"
if [ -f "$WORK_STATE" ]; then
  STATE_HOST=$(jq -r '.base // empty' "$WORK_STATE" \
    | sed -n 's#^https\{0,1\}://\([^/]\{1,\}\).*#\1#p')
  if [ -n "$STATE_HOST" ] && [ "$BASE_HOST" != "$STATE_HOST" ]; then
    echo "slashwork: staged base host '$BASE_HOST' does not match session base '$STATE_HOST'; not submitting" >&2
    exit 0
  fi
fi

# Build the body. The submit also reports the worker's token usage, summed from
# its transcript (input + output + cache writes). It is advisory and untrusted
# server-side; clamp to the API ceiling so an outlier transcript does not turn
# into a rejected submit.
URL="$BASE/api/tasks/$ID/submit"
TOKENS=0
if [ -n "$AGENT_TX" ] && [ -f "$AGENT_TX" ]; then
  TOKENS=$(jq -s '
    [ .[] | select(.type == "assistant") | .message.usage? // empty
      | ((.input_tokens // 0) + (.output_tokens // 0) + (.cache_creation_input_tokens // 0)) ]
    | add // 0' "$AGENT_TX" 2>/dev/null)
fi
printf '%s' "$TOKENS" | grep -qE '^[0-9]+$' || TOKENS=0
[ "$TOKENS" -gt 100000000 ] && TOKENS=100000000
BODYJSON=$(jq -nc --arg a "$ARTIFACT" --argjson t "$TOKENS" '{artifact: $a, tokens_used: $t}')

OUT="/tmp/slashwork-submit-${SESSION_ID}-${ID}.out"
CODE=$(printf '%s' "$BODYJSON" \
  | curl -sS --max-time 30 -o "$OUT" -w '%{http_code}' \
      -X POST "$URL" \
      -H "authorization: Bearer $TOKEN" \
      -H 'content-type: application/json' \
      --data-binary @- || echo "000")

echo "slashwork: submit task $ID -> HTTP $CODE" >&2
FAIL_MARKER="/tmp/slashwork-submit-fail-${SESSION_ID}.json"
if [ "$CODE" = "201" ]; then
  # 201 means the artifact was accepted for review (status 'reviewing'); the
  # acceptance gate runs async and decides accept/requeue/reject, so it is not
  # yet 'returned' to the requester. Say what actually happened.
  echo "slashwork: artifact submitted; the acceptance gate is now judging it" >&2
  rm -f "$STAGE" "$OUT" "$FAIL_MARKER"
else
  # A non-201 leaves the staged job in place and records a durable marker so the
  # loss is visible to the /earn loop instead of vanishing into this hook's
  # stderr: the worker did the work but nothing reached the requester.
  DETAIL=$(head -c 300 "$OUT" 2>/dev/null | tr -d '\000')
  jq -nc --arg id "$ID" --arg code "$CODE" --arg detail "$DETAIL" \
    '{id:$id, code:$code, detail:$detail}' > "$FAIL_MARKER" 2>/dev/null || true
  echo "slashwork: submit failed (HTTP $CODE); left a marker at $FAIL_MARKER" >&2
fi
exit 0
