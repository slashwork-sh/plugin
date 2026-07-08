#!/usr/bin/env bash
# Integration test for the PreToolUse(Task) intercept hook.
#
# Drives intercept.sh with realistic PreToolUse envelopes against a scripted
# mock coordinator and asserts the decision every time: a returned artifact
# becomes a `deny` carrying the result, and every other path (cold pool, wrong
# tool, self-worker, local prompt, secret, opt-out) falls through to the local
# spawn (exit 0, no decision) and sends nothing it should not.
#
# Run: bash plugin/hooks/intercept_test.sh
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
INTERCEPT="$HOOK_DIR/intercept.sh"
PORT="${MOCK_PORT:-8747}"
BASE="http://127.0.0.1:$PORT"
LOG="/tmp/slashwork-intercepttest-req.log"
TOKEN="testtoken"
PASS=0

fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && { echo "--- detail ---"; echo "$2"; }; exit 1; }
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# Mock coordinator. Behavior is set per-scenario by the MODE file it reads on
# each request, so one long-lived server serves every case. It appends each
# request path to $LOG so a scenario can assert "nothing was POSTed."
MODEFILE="/tmp/slashwork-intercepttest-mode"
start_mock() {
  python3 - "$PORT" "$LOG" "$MODEFILE" <<'PY' &
import sys, json, http.server, socketserver
port, logf, modef = int(sys.argv[1]), sys.argv[2], sys.argv[3]
def mode():
    try:
        return open(modef).read().strip()
    except FileNotFoundError:
        return "cold"
class H(http.server.BaseHTTPRequestHandler):
    def _log(self):
        open(logf, "a").write(self.command + " " + self.path + "\n")
    def do_POST(self):
        self._log()
        n = int(self.headers.get('content-length', 0)); self.rfile.read(n)
        # POST /api/tasks -> always create a task
        self.send_response(201); self.send_header("content-type","application/json"); self.end_headers()
        self.wfile.write(json.dumps({"task_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","status":"queued","cost":50}).encode())
    def do_GET(self):
        self._log()
        m = mode()
        if m == "returned":
            body = {"status":"returned","artifact":"OFFLOAD ARTIFACT: the answer.","tokens_used":123}
        elif m == "returned-multiline":
            body = {"status":"returned","artifact":"LINE ONE of the report\nLINE TWO details\nLINE THREE conclusion","tokens_used":200}
        elif m == "claimed":
            body = {"status":"claimed"}
        else:  # cold: nobody claims
            body = {"status":"queued"}
        self.send_response(200); self.send_header("content-type","application/json"); self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    def do_DELETE(self):
        self._log()
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"refunded":true}')
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", port), H) as s:
    s.serve_forever()
PY
  MOCK=$!
  disown "$MOCK" 2>/dev/null || true   # keep job control from printing "Terminated" at exit
  sleep 0.6
}
stop_mock() { kill "$MOCK" 2>/dev/null || true; }
trap 'stop_mock; rm -f "$LOG" "$MODEFILE" /tmp/slashwork-intercept-consent-*' EXIT
start_mock

# A fixed session id whose consent marker the routing scenarios pre-create, so
# they exercise the dispatch path rather than the once-per-session consent gate
# (which is tested on its own in the last scenario, with a fresh session).
SESS="itest-fixed"

# envelope <prompt> <tool_name> <session> -> a PreToolUse envelope on stdout
envelope() {
  jq -nc --arg p "$1" --arg t "${2:-Task}" --arg s "${3:-$SESS}" \
    '{session_id:$s, hook_event_name:"PreToolUse", tool_name:$t,
      tool_input:{subagent_type:"general-purpose", description:"d", prompt:$p}}'
}

run() { # run <mode> <prompt> [tool] ; echoes hook stdout, sets RC
  printf '%s' "$1" > "$MODEFILE"
  : > "$LOG"
  : > "/tmp/slashwork-intercept-consent-$SESS"   # consent already given this session
  OUT=$(envelope "$2" "${3:-Task}" | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" bash "$INTERCEPT" 2>/dev/null)
  RC=$?
}

# 1. Routable research task, an earner returns -> deny carrying the artifact.
run returned "Research and compare the leading approaches to rate limiting; give pros and cons of each."
[ "$RC" = "0" ] || fail "routed-return exit code $RC"
DEC=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[ "$DEC" = "deny" ] || fail "routed return should deny local spawn" "$OUT"
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q "OFFLOAD ARTIFACT" \
  || fail "deny reason missing the artifact" "$OUT"
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -qi "untrusted" \
  || fail "deny reason must mark the artifact untrusted" "$OUT"
grep -q "POST /api/tasks" "$LOG" || fail "should have POSTed the task" "$(cat "$LOG")"
ok "routable task returns -> deny with untrusted artifact"

# 2. Cold pool: nobody claims within the window -> cancel + local spawn.
run cold "Draft a report summarizing the quarterly numbers below: revenue up, costs flat."
[ "$RC" = "0" ] || fail "cold-pool exit code $RC"
[ -z "$OUT" ] || fail "cold pool must emit no decision (local spawn)" "$OUT"
grep -q "POST /api/tasks" "$LOG" || fail "cold pool should still POST then cancel" "$(cat "$LOG")"
grep -q "DELETE /api/tasks/" "$LOG" || fail "cold pool should cancel the task for a refund" "$(cat "$LOG")"
ok "cold pool -> cancel + local fallback"

# 3. Non-Task tool -> untouched, nothing sent.
run cold "anything" Bash
[ "$RC" = "0" ] && [ -z "$OUT" ] || fail "non-Task tool should be a no-op" "$OUT"
[ ! -s "$LOG" ] || fail "non-Task tool must not contact the coordinator" "$(cat "$LOG")"
ok "non-Task tool -> no-op"

# 4. Self-worker (prompt carries task_id:) -> never routed.
run cold "task_id: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
Read the job and solve it."
[ "$RC" = "0" ] && [ -z "$OUT" ] || fail "self-worker should pass through" "$OUT"
[ ! -s "$LOG" ] || fail "self-worker must not be routed" "$(cat "$LOG")"
ok "self-worker (task_id) -> not routed"

# 5. Local-path prompt -> declined before any network.
run returned "Refactor the function in ./src/main.rs and run the tests."
[ "$RC" = "0" ] && [ -z "$OUT" ] || fail "local-path prompt should decline to local" "$OUT"
[ ! -s "$LOG" ] || fail "local-path prompt must not be routed" "$(cat "$LOG")"
ok "local-path prompt -> declined, no network"

# 6. Secret in prompt -> declined before any network.
run returned "Write a script that authenticates with api_key sk-abcdefTOPSECRET and fetches data."
[ "$RC" = "0" ] && [ -z "$OUT" ] || fail "secret prompt should decline" "$OUT"
[ ! -s "$LOG" ] || fail "secret prompt must not be routed" "$(cat "$LOG")"
ok "secret in prompt -> declined, no network"

# 7. Ambiguous / no confident class -> declined, no network.
run returned "Do the needful with the thing."
[ "$RC" = "0" ] && [ -z "$OUT" ] || fail "unclassifiable prompt should decline" "$OUT"
[ ! -s "$LOG" ] || fail "unclassifiable prompt must not be routed" "$(cat "$LOG")"
ok "no confident class -> declined, no network"

# 8. Multi-line artifact is returned whole, not truncated to its first line.
printf returned-multiline > "$MODEFILE"; : > "$LOG"; : > "/tmp/slashwork-intercept-consent-$SESS"
OUT=$(envelope "Research and compare the leading approaches; give pros and cons of each." \
  | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" bash "$INTERCEPT" 2>/dev/null)
REASON=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)
printf '%s' "$REASON" | grep -q "LINE ONE"   || fail "multiline: line 1 missing" "$REASON"
printf '%s' "$REASON" | grep -q "LINE THREE" || fail "multiline artifact truncated (line 3 dropped)" "$REASON"
ok "multi-line artifact returned whole"

# 9. First-candidate consent gate: a fresh session's first routable spawn runs
#    local (shows the disclosure) and sends nothing; routing starts next time.
FRESH="itest-fresh-$RANDOM"
rm -f "/tmp/slashwork-intercept-consent-$FRESH"
printf returned > "$MODEFILE"; : > "$LOG"
OUT=$(envelope "Research and compare the options; pros and cons of each." Task "$FRESH" \
  | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" bash "$INTERCEPT" 2>/dev/null)
RC=$?
[ "$RC" = "0" ] && [ -z "$OUT" ] || fail "first candidate must run local (consent)" "$OUT"
[ ! -s "$LOG" ] || fail "first candidate must send nothing before consent shown" "$(cat "$LOG")"
# Second candidate in the same session now routes.
: > "$LOG"
OUT=$(envelope "Research and compare the options; pros and cons of each." Task "$FRESH" \
  | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" bash "$INTERCEPT" 2>/dev/null)
[ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] \
  || fail "second candidate should route" "$OUT"
ok "first-candidate consent gate -> local then route"

# 10. Broadened decline filters: extensions and absolute paths outside the old set.
for P in \
  "Summarize the findings in q3-results.csv" \
  "Review the following errors in /var/log/app.log" \
  "Implement a function matching the interface in api.h" \
  "Review the dataset in src/data.csv"; do
  run returned "$P"
  [ -z "$OUT" ] || fail "should decline local-file prompt: $P" "$OUT"
  [ ! -s "$LOG" ] || fail "should not route local-file prompt: $P" "$(cat "$LOG")"
done
ok "broadened path/extension decline (csv, /var, .h, src/)"

# 11. Broadened secret scan: key families beyond the old set.
for P in \
  "Write a function that charges a card with key sk_live_51abcdEFGHijklMNOP" \
  "Implement a script using github_pat_11ABCDEFG0abcdefghij" \
  "Write a function that calls the API with AIzaSyD-abcdefghijklmnopqrstuvwxyz012"; do
  run returned "$P"
  [ -z "$OUT" ] || fail "should decline secret-bearing prompt: $P" "$OUT"
  [ ! -s "$LOG" ] || fail "should not route secret-bearing prompt: $P" "$(cat "$LOG")"
done
ok "broadened secret scan (sk_live_, github_pat_, AIza)"

# 12. Opt-out: SLASHWORK_INTERCEPT unset -> total no-op (env -u guarantees the
#     var is absent regardless of the caller's environment).
: > "$LOG"; printf returned > "$MODEFILE"
OUT=$(envelope "Research and compare the options." \
  | env -u SLASHWORK_INTERCEPT SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" bash "$INTERCEPT" 2>/dev/null)
RC=$?
[ "$RC" = "0" ] && [ -z "$OUT" ] || fail "not opted in must be a no-op" "$OUT"
[ ! -s "$LOG" ] || fail "not opted in must not contact the coordinator" "$(cat "$LOG")"
ok "SLASHWORK_INTERCEPT unset -> no-op"

echo "ALL PASS ($PASS scenarios)"
