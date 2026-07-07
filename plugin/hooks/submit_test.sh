#!/usr/bin/env bash
# Integration test for the SubagentStop submit hook.
#
# Stands up a one-shot mock coordinator on localhost, feeds submit.sh a realistic
# SubagentStop envelope (with the subagent's final reply and its transcript path),
# and asserts the hook POSTs that reply as the artifact to the right challenge URL.
# No file is written by any worker: the point is that the hook submits the worker's
# final message, not a file it had to write.
#
# Run: bash plugin/hooks/submit_test.sh
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
printf '{"id":"%s","base":"%s"}\n' "$ID" "$BASE" > "$JOB"

# 3. Fake subagent transcript: first user message carries challenge_id, final
#    assistant message is the deliverable (with an earlier thinking turn for realism).
TXDIR="$(mktemp -d)"
AT="$TXDIR/agent-test.jsonl"
{
  printf '{"type":"user","message":{"role":"user","content":"challenge_id: %s\\njob_file: %s\\nSolve it; your final message is the artifact."}}\n' "$ID" "$JOB"
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
[ "$GOT_PATH" = "/api/challenges/$ID/submit" ] || fail "wrong URL path: $GOT_PATH"
[ "$GOT_ART" = "$DELIVERABLE" ] || fail "wrong artifact body: $GOT_ART"
[ ! -f "$JOB" ] || fail "staged job not cleaned up after 201"
echo "PASS: hook submitted the worker's final reply to $GOT_PATH"
