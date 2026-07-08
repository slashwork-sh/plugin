#!/usr/bin/env bash
# Integration test for the SubagentStop submit hook.
#
# Stands up a one-shot mock coordinator on localhost, feeds submit.sh a realistic
# SubagentStop envelope (with the subagent's final reply and its transcript path),
# and asserts the hook POSTs that reply as the artifact to the right URL. Three
# scenarios: a task whose transcript carries no usage fields (tokens_used falls
# back to 0), a task with usage turns (tokens_used summed from the transcript),
# and a subagent with no task_id marker (ignored, nothing sent). No file is
# written by any worker: the point is that the hook submits the worker's final
# message, not a file it had to write.
#
# Run: bash plugins/earn/hooks/submit_test.sh
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBMIT="$HOOK_DIR/submit.sh"
PORT="${MOCK_PORT:-8731}"
BASE="http://127.0.0.1:$PORT"
CAP="/tmp/slashwork-submittest-capture.txt"
HOOKERR="/tmp/slashwork-submittest-hookerr.txt"
SESSION="submittest-session"
ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
DELIVERABLE="SELECT status, COUNT(*) FROM orders GROUP BY status;"
JOB="/tmp/slashwork-job-${SESSION}-${ID}.json"
OUT="/tmp/slashwork-submit-${SESSION}-${ID}.out"

cleanup() { rm -f "$JOB" "$OUT" "$CAP" "$HOOKERR"; [ -n "${TXDIR:-}" ] && rm -rf "$TXDIR"; }
trap cleanup EXIT
rm -f "$CAP"

# 1. One-shot mock coordinator: capture the POST path + body, return 201, exit.
timeout 20 python3 - "$PORT" "$CAP" <<'PY' &
import sys, http.server, socketserver
port, cap = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length', 0))
        body = self.rfile.read(n).decode()
        open(cap, 'w').write(self.path + "\n" + body)
        self.send_response(201); self.end_headers(); self.wfile.write(b'{"ok":true}')
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", port), H) as s:
    s.handle_request()
PY
MOCK=$!
sleep 0.6

# 2. Stage the job (only thing on disk; carries base). No artifact file is created.
printf '{"task_id":"%s","base":"%s"}\n' "$ID" "$BASE" > "$JOB"

# 3. Fake subagent transcript: first user message carries task_id, final
#    assistant message is the deliverable (with an earlier thinking turn for
#    realism). No usage fields anywhere, so tokens_used must fall back to 0.
TXDIR="$(mktemp -d)"
AT="$TXDIR/agent-test.jsonl"
{
  printf '{"type":"user","message":{"role":"user","content":"task_id: %s\\njob_file: %s\\nProduce the deliverable; your final message is the artifact."}}\n' "$ID" "$JOB"
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"working"}]}}\n'
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$DELIVERABLE"
} > "$AT"

# 4. The SubagentStop envelope Claude Code passes on stdin.
ENVELOPE="$(jq -nc \
  --arg s "$SESSION" --arg at "$AT" --arg lam "$DELIVERABLE" \
  '{session_id:$s, agent_transcript_path:$at, last_assistant_message:$lam, hook_event_name:"SubagentStop"}')"

# 5. Fire the hook. Token via env (the hook also accepts ~/.slashwork/token).
printf '%s' "$ENVELOPE" | SLASHWORK_TOKEN=testtoken bash "$SUBMIT" 2>"$HOOKERR"
wait "$MOCK" 2>/dev/null || true

# 6. Assertions.
fail() { echo "FAIL: $1"; echo "--- hook stderr ---"; cat "$HOOKERR" 2>/dev/null; exit 1; }
[ -f "$CAP" ] || fail "coordinator received no POST (hook submitted nothing)"
GOT_PATH="$(head -1 "$CAP")"
GOT_ART="$(tail -n +2 "$CAP" | jq -r '.artifact')"
GOT_TOKENS="$(tail -n +2 "$CAP" | jq -r '.tokens_used')"
[ "$GOT_PATH" = "/api/tasks/$ID/submit" ] || fail "wrong URL path: $GOT_PATH"
[ "$GOT_ART" = "$DELIVERABLE" ] || fail "wrong artifact body: $GOT_ART"
[ "$GOT_TOKENS" = "0" ] || fail "no-usage transcript must report tokens_used 0: $GOT_TOKENS"
[ ! -f "$JOB" ] || fail "staged job not cleaned up after 201"
echo "PASS: hook submitted the worker's final reply to $GOT_PATH (tokens_used 0)"

# ---- Scenario 2: token usage summed from the transcript ----

TASK_ID="11111111-2222-3333-4444-555555555555"
TASK_ART="The finished offloaded report."
TASK_JOB="/tmp/slashwork-job-${SESSION}-${TASK_ID}.json"
TASK_OUT="/tmp/slashwork-submit-${SESSION}-${TASK_ID}.out"
cleanup2() { cleanup; rm -f "$TASK_JOB" "$TASK_OUT"; }
trap cleanup2 EXIT
rm -f "$CAP"

timeout 20 python3 - "$PORT" "$CAP" <<'PY' &
import sys, http.server, socketserver
port, cap = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length', 0))
        body = self.rfile.read(n).decode()
        open(cap, 'w').write(self.path + "\n" + body)
        self.send_response(201); self.end_headers(); self.wfile.write(b'{"ok":true}')
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", port), H) as s:
    s.handle_request()
PY
MOCK2=$!
sleep 0.6

printf '{"task_id":"%s","base":"%s"}\n' "$TASK_ID" "$BASE" > "$TASK_JOB"

# Task worker transcript: task_id marker, two assistant turns carrying usage
# (1000+200+50, then 300+400) so the hook should report tokens_used = 1950.
AT2="$TXDIR/agent-task.jsonl"
{
  printf '{"type":"user","message":{"role":"user","content":"task_id: %s\\njob_file: %s\\nProduce the deliverable; your final message is the artifact."}}\n' "$TASK_ID" "$TASK_JOB"
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"working"}],"usage":{"input_tokens":1000,"output_tokens":200,"cache_creation_input_tokens":50}}}\n'
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}],"usage":{"input_tokens":300,"output_tokens":400}}}\n' "$TASK_ART"
} > "$AT2"

ENVELOPE2="$(jq -nc \
  --arg s "$SESSION" --arg at "$AT2" --arg lam "$TASK_ART" \
  '{session_id:$s, agent_transcript_path:$at, last_assistant_message:$lam, hook_event_name:"SubagentStop"}')"

printf '%s' "$ENVELOPE2" | SLASHWORK_TOKEN=testtoken bash "$SUBMIT" 2>"$HOOKERR"
wait "$MOCK2" 2>/dev/null || true

[ -f "$CAP" ] || fail "coordinator received no POST for the task"
GOT_PATH="$(head -1 "$CAP")"
GOT_ART="$(tail -n +2 "$CAP" | jq -r '.artifact')"
GOT_TOKENS="$(tail -n +2 "$CAP" | jq -r '.tokens_used')"
[ "$GOT_PATH" = "/api/tasks/$TASK_ID/submit" ] || fail "wrong task URL path: $GOT_PATH"
[ "$GOT_ART" = "$TASK_ART" ] || fail "wrong task artifact body: $GOT_ART"
[ "$GOT_TOKENS" = "1950" ] || fail "wrong tokens_used (want 1950): $GOT_TOKENS"
[ ! -f "$TASK_JOB" ] || fail "staged task job not cleaned up after 201"
echo "PASS: hook submitted the task artifact with tokens_used to $GOT_PATH"

# ---- Scenario 3: no task_id marker -> ignored, nothing sent ----

rm -f "$CAP"
AT3="$TXDIR/agent-other.jsonl"
{
  printf '{"type":"user","message":{"role":"user","content":"Summarize the design doc pasted below."}}\n'
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"A summary."}]}}\n'
} > "$AT3"

ENVELOPE3="$(jq -nc \
  --arg s "$SESSION" --arg at "$AT3" \
  '{session_id:$s, agent_transcript_path:$at, last_assistant_message:"A summary.", hook_event_name:"SubagentStop"}')"

printf '%s' "$ENVELOPE3" | SLASHWORK_TOKEN=testtoken bash "$SUBMIT" 2>"$HOOKERR"
RC=$?
[ "$RC" = "0" ] || fail "non-slashwork subagent must exit 0 (got $RC)"
[ ! -f "$CAP" ] || fail "non-slashwork subagent must not POST anything: $(cat "$CAP")"
echo "PASS: subagent without a task_id marker is ignored"
