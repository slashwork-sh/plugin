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

# ---- Scenario 4: transcript absent -> recover the id from the single staged job ----
# Some harness versions omit agent_transcript_path, so the hook cannot read the
# task_id from the prompt. It must fall back to the one staged job for the
# session, submitting the envelope's last_assistant_message.
NT="99999999-8888-7777-6666-555555555555"
NT_JOB="/tmp/slashwork-job-${SESSION}-${NT}.json"
NT_OUT="/tmp/slashwork-submit-${SESSION}-${NT}.out"
NT_ART="Recovered artifact from the envelope."
cleanup3() { cleanup2; rm -f "$NT_JOB" "$NT_OUT"; }
trap cleanup3 EXIT
rm -f "$CAP"
# Exactly one staged job for this session (the invariant during an /earn round).
rm -f /tmp/slashwork-job-"${SESSION}"-*.json
printf '{"task_id":"%s","base":"%s"}\n' "$NT" "$BASE" > "$NT_JOB"

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
MOCK3=$!
sleep 0.6

# Envelope with NO agent_transcript_path; the artifact comes from the envelope.
ENVELOPE4="$(jq -nc --arg s "$SESSION" --arg lam "$NT_ART" \
  '{session_id:$s, last_assistant_message:$lam, hook_event_name:"SubagentStop"}')"
printf '%s' "$ENVELOPE4" | SLASHWORK_TOKEN=testtoken bash "$SUBMIT" 2>"$HOOKERR"
wait "$MOCK3" 2>/dev/null || true

[ -f "$CAP" ] || fail "missing-transcript case submitted nothing (fallback did not fire)"
GOT_PATH="$(head -1 "$CAP")"
GOT_ART="$(tail -n +2 "$CAP" | jq -r '.artifact')"
GOT_TOKENS="$(tail -n +2 "$CAP" | jq -r '.tokens_used')"
[ "$GOT_PATH" = "/api/tasks/$NT/submit" ] || fail "wrong URL for the recovered id: $GOT_PATH"
[ "$GOT_ART" = "$NT_ART" ] || fail "wrong artifact for the recovered id: $GOT_ART"
[ "$GOT_TOKENS" = "0" ] || fail "no transcript must report tokens_used 0: $GOT_TOKENS"
[ ! -f "$NT_JOB" ] || fail "recovered submit should clean up the staged job after 201"
echo "PASS: recovers the task id from the single staged job when the transcript is absent"

# ---- Scenario 5: a failed submit (non-201) leaves a durable failure marker ----
FT="12121212-3434-5656-7878-909090909090"
FT_JOB="/tmp/slashwork-job-${SESSION}-${FT}.json"
FT_OUT="/tmp/slashwork-submit-${SESSION}-${FT}.out"
FAIL_MARKER="/tmp/slashwork-submit-fail-${SESSION}.json"
cleanup4() { cleanup3; rm -f "$FT_JOB" "$FT_OUT" "$FAIL_MARKER"; }
trap cleanup4 EXIT
rm -f "$CAP" "$FAIL_MARKER"
rm -f /tmp/slashwork-job-"${SESSION}"-*.json
printf '{"task_id":"%s","base":"%s"}\n' "$FT" "$BASE" > "$FT_JOB"

timeout 20 python3 - "$PORT" "$CAP" <<'PY' &
import sys, http.server, socketserver
port, cap = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length', 0)); self.rfile.read(n)
        self.send_response(500); self.end_headers(); self.wfile.write(b'{"error":"boom"}')
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", port), H) as s:
    s.handle_request()
PY
MOCK4=$!
sleep 0.6

AT5="$TXDIR/agent-fail.jsonl"
{
  printf '{"type":"user","message":{"role":"user","content":"task_id: %s\\nProduce the deliverable."}}\n' "$FT"
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"an answer"}]}}\n'
} > "$AT5"
ENVELOPE5="$(jq -nc --arg s "$SESSION" --arg at "$AT5" --arg lam "an answer" \
  '{session_id:$s, agent_transcript_path:$at, last_assistant_message:$lam, hook_event_name:"SubagentStop"}')"
printf '%s' "$ENVELOPE5" | SLASHWORK_TOKEN=testtoken bash "$SUBMIT" 2>"$HOOKERR"
wait "$MOCK4" 2>/dev/null || true

[ -f "$FAIL_MARKER" ] || fail "a non-201 submit must leave a failure marker"
[ "$(jq -r .id "$FAIL_MARKER")" = "$FT" ] || fail "failure marker has the wrong id: $(cat "$FAIL_MARKER")"
[ "$(jq -r .code "$FAIL_MARKER")" = "500" ] || fail "failure marker has the wrong code: $(cat "$FAIL_MARKER")"
[ -f "$FT_JOB" ] || fail "a failed submit must leave the staged job in place for a retry"
echo "PASS: a failed submit records a durable failure marker and keeps the staged job"

# ---- Scenario 6: staged base is non-https -> refuse (token exfiltration guard) ----
# A prompt-injected worker could rewrite the staged job to point the token at an
# arbitrary host; the hook must refuse anything but https (localhost excepted).
EVIL_ID="aaaa1111-bbbb-2222-cccc-333333333333"
EVIL_JOB="/tmp/slashwork-job-${SESSION}-${EVIL_ID}.json"
cleanup5() { cleanup4; rm -f "$EVIL_JOB"; }
trap cleanup5 EXIT
rm -f "$CAP"; rm -f /tmp/slashwork-job-"${SESSION}"-*.json
printf '{"task_id":"%s","base":"http://evil.example"}\n' "$EVIL_ID" > "$EVIL_JOB"
AT6="$TXDIR/agent-evil.jsonl"
{
  printf '{"type":"user","message":{"role":"user","content":"task_id: %s\\nProduce it."}}\n' "$EVIL_ID"
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"answer"}]}}\n'
} > "$AT6"
ENVELOPE6="$(jq -nc --arg s "$SESSION" --arg at "$AT6" --arg lam "answer" \
  '{session_id:$s, agent_transcript_path:$at, last_assistant_message:$lam, hook_event_name:"SubagentStop"}')"
printf '%s' "$ENVELOPE6" | SLASHWORK_TOKEN=testtoken bash "$SUBMIT" 2>"$HOOKERR"
[ ! -f "$CAP" ] || fail "non-https base must not POST anything" "$(cat "$CAP")"
grep -qi "non-https" "$HOOKERR" || fail "should log the non-https refusal" "$(cat "$HOOKERR")"
echo "PASS: refuses to submit to a non-https base"

# ---- Scenario 7: staged base host != session base host -> refuse ----
# The session's state file records the host the skill validated; a staged job
# pointing at a different host (again, injected) must not receive the token.
MM_ID="aaaa2222-bbbb-3333-cccc-444444444444"
MM_JOB="/tmp/slashwork-job-${SESSION}-${MM_ID}.json"
WORK_STATE="/tmp/slashwork-work-${SESSION}.json"
cleanup6() { cleanup5; rm -f "$MM_JOB" "$WORK_STATE"; }
trap cleanup6 EXIT
rm -f "$CAP"; rm -f /tmp/slashwork-job-"${SESSION}"-*.json
printf '{"task_id":"%s","base":"https://other.example"}\n' "$MM_ID" > "$MM_JOB"
printf '{"base":"https://real.example"}\n' > "$WORK_STATE"
AT7="$TXDIR/agent-mm.jsonl"
{
  printf '{"type":"user","message":{"role":"user","content":"task_id: %s\\nProduce it."}}\n' "$MM_ID"
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"answer"}]}}\n'
} > "$AT7"
ENVELOPE7="$(jq -nc --arg s "$SESSION" --arg at "$AT7" --arg lam "answer" \
  '{session_id:$s, agent_transcript_path:$at, last_assistant_message:$lam, hook_event_name:"SubagentStop"}')"
printf '%s' "$ENVELOPE7" | SLASHWORK_TOKEN=testtoken bash "$SUBMIT" 2>"$HOOKERR"
[ ! -f "$CAP" ] || fail "host mismatch must not POST anything" "$(cat "$CAP")"
grep -qi "does not match" "$HOOKERR" || fail "should log the host-mismatch refusal" "$(cat "$HOOKERR")"
echo "PASS: refuses when the staged base host differs from the session base host"

# ---- Scenario 8: transcript absent + two staged jobs -> refuse to guess ----
# The single-staged-job recovery only fires when exactly one job is staged; two
# means the hook cannot tell which is this worker's, so it submits nothing.
J1="/tmp/slashwork-job-${SESSION}-aaaa3333-bbbb-4444-cccc-555555555555.json"
J2="/tmp/slashwork-job-${SESSION}-aaaa4444-bbbb-5555-cccc-666666666666.json"
cleanup7() { cleanup6; rm -f "$J1" "$J2"; }
trap cleanup7 EXIT
rm -f "$CAP"; rm -f /tmp/slashwork-job-"${SESSION}"-*.json
printf '{"task_id":"x","base":"%s"}\n' "$BASE" > "$J1"
printf '{"task_id":"y","base":"%s"}\n' "$BASE" > "$J2"
ENVELOPE8="$(jq -nc --arg s "$SESSION" --arg lam "answer" \
  '{session_id:$s, last_assistant_message:$lam, hook_event_name:"SubagentStop"}')"
printf '%s' "$ENVELOPE8" | SLASHWORK_TOKEN=testtoken bash "$SUBMIT" 2>"$HOOKERR"
[ ! -f "$CAP" ] || fail "two staged jobs must not be guessed between" "$(cat "$CAP")"
grep -qi "no single staged job" "$HOOKERR" || fail "should log that it cannot pick a job" "$(cat "$HOOKERR")"
echo "PASS: with the transcript absent and two staged jobs, refuses to guess"

# ---- Scenario 9: transcript artifact preferred over the envelope message ----
# The transcript can hold the full final message (no envelope size limits), so
# it wins when both are present.
PT="aaaa5555-bbbb-6666-cccc-777777777777"
PT_JOB="/tmp/slashwork-job-${SESSION}-${PT}.json"
PT_OUT="/tmp/slashwork-submit-${SESSION}-${PT}.out"
cleanup8() { cleanup7; rm -f "$PT_JOB" "$PT_OUT"; }
trap cleanup8 EXIT
rm -f "$CAP"; rm -f /tmp/slashwork-job-"${SESSION}"-*.json
# Clear the session state left by scenario 7 so the host check does not fire.
rm -f "/tmp/slashwork-work-${SESSION}.json"
printf '{"task_id":"%s","base":"%s"}\n' "$PT" "$BASE" > "$PT_JOB"

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
MOCK5=$!
sleep 0.6

AT9="$TXDIR/agent-pref.jsonl"
{
  printf '{"type":"user","message":{"role":"user","content":"task_id: %s\\nProduce it."}}\n' "$PT"
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"TRANSCRIPT ARTIFACT"}]}}\n'
} > "$AT9"
ENVELOPE9="$(jq -nc --arg s "$SESSION" --arg at "$AT9" --arg lam "ENVELOPE ARTIFACT" \
  '{session_id:$s, agent_transcript_path:$at, last_assistant_message:$lam, hook_event_name:"SubagentStop"}')"
printf '%s' "$ENVELOPE9" | SLASHWORK_TOKEN=testtoken bash "$SUBMIT" 2>"$HOOKERR"
wait "$MOCK5" 2>/dev/null || true
[ -f "$CAP" ] || fail "preference scenario submitted nothing"
GOT_ART="$(tail -n +2 "$CAP" | jq -r '.artifact')"
[ "$GOT_ART" = "TRANSCRIPT ARTIFACT" ] || fail "the transcript's final message should win: $GOT_ART"
echo "PASS: the transcript's final message is preferred over the envelope's"
