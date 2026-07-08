#!/usr/bin/env bash
# Integration test for the /earn background SSE listener (earn-listen.sh).
#
# Drives the listener against a scripted mock coordinator and asserts the marker
# outcome for each case: claims a task off the feed and stages the job; gives up
# at the budget with no task; reports a rejected token (via the /api/me probe,
# before any stream); keeps listening past a lost claim (409); backs off instead
# of busy-spinning when the coordinator is unreachable; and refuses a non-https
# base so the token cannot leak.
#
# Run: bash plugins/earn/hooks/earn-listen_test.sh
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LISTEN="$HOOK_DIR/earn-listen.sh"
PORT="${MOCK_PORT:-8751}"
BASE="http://127.0.0.1:$PORT"
MODEFILE="/tmp/slashwork-earnlisten-mode"
SESSION="earnlisten-test"
STATE="/tmp/slashwork-work-${SESSION}.json"
MARKER="/tmp/slashwork-earn-${SESSION}.json"
TASK_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
JOB="/tmp/slashwork-job-${SESSION}-${TASK_ID}.json"
PASS=0

fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && { echo "-- detail --"; echo "$2"; }; exit 1; }
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }

cleanup() { kill "${MOCK:-}" 2>/dev/null || true; rm -f "$STATE" "$MARKER" "$JOB" "$MODEFILE"; }
trap cleanup EXIT

# Mock coordinator. GET /api/me is the auth+reachability probe (200, or 401 in
# "dead" mode). GET /api/queue/stream emits one `task` SSE frame then holds
# briefly. POST claim returns per the mode file. "win-after-lost" flips itself
# from lost to win so the reconnect path is exercised.
start_mock() {
  python3 - "$PORT" "$MODEFILE" "$TASK_ID" <<'PY' &
import sys, json, time, http.server, socketserver
port, modef, tid = int(sys.argv[1]), sys.argv[2], sys.argv[3]
def mode():
    try: return open(modef).read().strip()
    except FileNotFoundError: return "win"
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/api/me"):
            code = 401 if mode() == "dead" else 200
            self.send_response(code); self.send_header("content-type","application/json"); self.end_headers()
            self.wfile.write(b'{}'); return
        # /api/queue/stream: announce one queued task, then hold ~1s and close.
        self.send_response(200)
        self.send_header("content-type", "text/event-stream"); self.end_headers()
        if mode() != "none":
            self.wfile.write(("event: task\r\ndata: " + json.dumps({"id": tid, "class": "prose", "cost": 30}) + "\r\n\r\n").encode())
            try: self.wfile.flush()
            except Exception: pass
        time.sleep(1.0)
    def do_POST(self):
        n = int(self.headers.get('content-length', 0)); self.rfile.read(n)
        m = mode()
        if m == "lost":
            self.send_response(409); self.end_headers(); self.wfile.write(b'{}'); return
        if m == "win-after-lost":
            open(modef, "w").write("win")   # next claim wins
            self.send_response(409); self.end_headers(); self.wfile.write(b'{}'); return
        self.send_response(200); self.send_header("content-type","application/json"); self.end_headers()
        self.wfile.write(json.dumps({"task_id": tid, "class":"prose", "prompt":"draft it", "context_bundle":"", "cost":30, "deadline":"2099-01-01T00:00:00Z"}).encode())
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
httpd = socketserver.ThreadingTCPServer(("127.0.0.1", port), H)
httpd.serve_forever()
PY
  MOCK=$!
  disown "$MOCK" 2>/dev/null || true
  sleep 0.6
}
start_mock

# state <deadline-epoch> [base]: write the session state the listener reads.
write_state() {
  jq -nc --arg base "${2:-$BASE}" --argjson deadline "$1" \
    '{base:$base, mode:"earn", gmode:"time", deadline:$deadline, done:[]}' > "$STATE"
}
run_listener() { rm -f "$MARKER" "$JOB"; SLASHWORK_TOKEN=t bash "$LISTEN" "$STATE" "$MARKER"; }

# 1. A queued task is claimed and the job staged.
printf win > "$MODEFILE"; write_state "$(( $(date +%s) + 60 ))"; run_listener
[ "$(jq -r .status "$MARKER")" = "claimed" ] || fail "expected claimed" "$(cat "$MARKER")"
[ "$(jq -r .id "$MARKER")" = "$TASK_ID" ] || fail "wrong task id" "$(cat "$MARKER")"
if ! { [ -f "$JOB" ] && [ "$(jq -r .prompt "$JOB")" = "draft it" ]; }; then fail "job not staged" "$(cat "$JOB" 2>/dev/null)"; fi
[ "$(jq -r .base "$JOB")" = "$BASE" ] || fail "job missing base"
ok "claims a queued task and stages the job"

# 2. Budget already spent -> budget_spent, no claim.
printf win > "$MODEFILE"; write_state "$(( $(date +%s) - 5 ))"; run_listener
[ "$(jq -r .status "$MARKER")" = "budget_spent" ] || fail "expected budget_spent" "$(cat "$MARKER")"
[ ! -f "$JOB" ] || fail "should not stage a job when budget spent"
ok "gives up at the budget with no task"

# 3. Dead token -> auth_failed, caught by the /api/me probe before any stream.
printf dead > "$MODEFILE"; write_state "$(( $(date +%s) + 60 ))"; run_listener
[ "$(jq -r .status "$MARKER")" = "auth_failed" ] || fail "expected auth_failed" "$(cat "$MARKER")"
ok "reports a rejected token via the probe"

# 4. Lost the first claim (409), then wins a later one: reconnect path.
printf win-after-lost > "$MODEFILE"; write_state "$(( $(date +%s) + 60 ))"; run_listener
[ "$(jq -r .status "$MARKER")" = "claimed" ] || fail "expected claim after a lost race" "$(cat "$MARKER")"
ok "keeps listening past a lost claim and wins the next"

# 5. Coordinator unreachable (closed port): must back off, not busy-spin, and
#    reach budget_spent. A ~4s budget should take at least one backoff sleep
#    (>= ~2s) rather than returning instantly after thousands of reconnects.
DEADPORT=$(( PORT + 7 ))
write_state "$(( $(date +%s) + 4 ))" "http://127.0.0.1:$DEADPORT"
rm -f "$MARKER"
t0=$(date +%s)
SLASHWORK_TOKEN=t bash "$LISTEN" "$STATE" "$MARKER" 2>/dev/null || true
elapsed=$(( $(date +%s) - t0 ))
[ "$(jq -r .status "$MARKER" 2>/dev/null)" = "budget_spent" ] || fail "unreachable server should reach budget_spent" "$(cat "$MARKER" 2>/dev/null)"
[ "$elapsed" -ge 2 ] || fail "unreachable server returned too fast ($elapsed s): backoff not applied"
ok "backs off (no busy-spin) when the coordinator is unreachable"

# 6. Non-https base is refused so the token never leaves for an arbitrary host.
printf win > "$MODEFILE"
jq -nc --arg base "http://evil.example" --argjson deadline "$(( $(date +%s) + 60 ))" \
  '{base:$base, mode:"earn", gmode:"time", deadline:$deadline, done:[]}' > "$STATE"
rm -f "$MARKER"; SLASHWORK_TOKEN=t bash "$LISTEN" "$STATE" "$MARKER"
[ "$(jq -r .status "$MARKER")" = "error" ] || fail "expected error for non-https base" "$(cat "$MARKER")"
jq -r .detail "$MARKER" | grep -qi "https" || fail "error detail should name the https requirement"
ok "refuses a non-https base"

echo "ALL PASS ($PASS scenarios)"
