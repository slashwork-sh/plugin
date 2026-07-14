#!/usr/bin/env bash
# Integration test for the PreToolUse(Task) intercept hook.
#
# Drives intercept.sh with realistic PreToolUse envelopes against a scripted
# mock coordinator and asserts the decision every time: a returned artifact
# becomes a `deny` carrying the result, and every other path (cold pool, wrong
# tool, self-worker, local prompt, secret, opt-out) falls through to the local
# spawn (exit 0, no decision) and sends nothing it should not.
#
# Run: bash plugins/work/hooks/intercept_test.sh
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
        if mode() == "no-credits":
            # POST /api/tasks -> the requester cannot pay; nothing is created.
            self.send_response(400); self.send_header("content-type","application/json"); self.end_headers()
            self.wfile.write(json.dumps({"error":{"code":"validation_failed","message":"not enough credits to route this task: you have 3, it costs 50"}}).encode())
            return
        # POST /api/tasks -> create a task
        self.send_response(201); self.send_header("content-type","application/json"); self.end_headers()
        self.wfile.write(json.dumps({"task_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","status":"queued","cost":50}).encode())
    def do_GET(self):
        self._log()
        m = mode()
        if m == "returned":
            body = {"status":"returned","artifact":"OFFLOAD ARTIFACT: the answer.","tokens_used":123,"cost":50}
        elif m == "returned-multiline":
            body = {"status":"returned","artifact":"LINE ONE of the report\nLINE TWO details\nLINE THREE conclusion","tokens_used":200}
        elif m == "review-then-return":
            # First poll: the gate is running (reviewing). Next poll: accepted.
            # Proves the hook waits through review instead of cancelling local.
            import os
            flip = logf + ".flip"
            if not os.path.exists(flip):
                open(flip, "w").write("1"); body = {"status":"reviewing"}
            else:
                body = {"status":"returned","artifact":"GRACE ARTIFACT: accepted late.","tokens_used":77}
        elif m == "claim-then-die":
            # First poll: claimed. Then the coordinator dies (500) mid-wait, so
            # the hook must cancel and fall back local rather than hang.
            import os
            flip = logf + ".flip"
            if not os.path.exists(flip):
                open(flip, "w").write("1"); body = {"status":"claimed"}
            else:
                self.send_response(500); self.end_headers(); self.wfile.write(b'{"error":"down"}'); return
        elif m == "die-on-poll":
            # Every result poll fails: the coordinator went down before anyone
            # claimed. The claim window must fall back local with no retries.
            self.send_response(500); self.end_headers(); self.wfile.write(b'{"error":"down"}'); return
        elif m == "die-then-return":
            # Claimed, then one blip (500), then the artifact: a deploy-sized
            # gap the post-claim retry must ride out instead of cancelling.
            import os
            ctrf = logf + ".ctr"
            try:
                c = int(open(ctrf).read().strip())
            except Exception:
                c = 0
            c += 1
            open(ctrf, "w").write(str(c))
            if c == 1:
                body = {"status":"claimed"}
            elif c == 2:
                self.send_response(500); self.end_headers(); self.wfile.write(b'{"error":"blip"}'); return
            else:
                body = {"status":"returned","artifact":"RETRY ARTIFACT: survived the blip.","tokens_used":55}
        elif m == "review-then-expire":
            # Reviewing for the first few polls, then expired: exercises the
            # deadline grace loop ending in a local fallback, not a stale emit.
            import os
            ctrf = logf + ".ctr"
            try:
                c = int(open(ctrf).read().strip())
            except Exception:
                c = 0
            c += 1
            open(ctrf, "w").write(str(c))
            body = {"status":"reviewing"} if c <= 3 else {"status":"expired"}
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
trap 'stop_mock; rm -f "$LOG" "$LOG.flip" "$LOG.ctr" "$MODEFILE" /tmp/slashwork-intercept-consent-*' EXIT
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
# The user's receipt: tokens saved, credits spent, and the /earn pointer.
SM=$(printf '%s' "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null)
printf '%s' "$SM" | grep -q "saved you 123 tokens" || fail "systemMessage missing tokens saved" "$OUT"
printf '%s' "$SM" | grep -q "Spent 50 credits" || fail "systemMessage missing credits spent" "$OUT"
printf '%s' "$SM" | grep -q "/earn" || fail "systemMessage missing the /earn pointer" "$OUT"
grep -q "POST /api/tasks" "$LOG" || fail "should have POSTed the task" "$(cat "$LOG")"
ok "routable task returns -> deny with untrusted artifact + saved-tokens receipt"

# 1b. Reviewing (the gate is running) must keep waiting, not cancel to local;
#     when the gate accepts inside the grace, the artifact is emitted. This
#     guards the double-charge path: cancelling here while an accept can still
#     pay the earner would charge the requester credits AND run local.
printf review-then-return > "$MODEFILE"; : > "$LOG"; rm -f "$LOG.flip"
: > "/tmp/slashwork-intercept-consent-$SESS"
OUT=$(envelope "Research and compare the options; pros and cons of each." \
  | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" bash "$INTERCEPT" 2>/dev/null)
DEC=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[ "$DEC" = "deny" ] || fail "reviewing then accepted should deny local and emit the artifact" "$OUT"
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q "GRACE ARTIFACT" \
  || fail "should emit the accepted artifact after review" "$OUT"
if grep -q "DELETE /api/tasks/" "$LOG"; then fail "must NOT cancel while reviewing (would double-charge)" "$(cat "$LOG")"; fi
ok "reviewing keeps waiting -> emits accepted artifact, no cancel"

# 2. Cold pool: nobody claims within the window -> cancel + local spawn.
run cold "Draft a report summarizing the quarterly numbers below: revenue up, costs flat."
[ "$RC" = "0" ] || fail "cold-pool exit code $RC"
[ -z "$OUT" ] || fail "cold pool must emit no decision (local spawn)" "$OUT"
grep -q "POST /api/tasks" "$LOG" || fail "cold pool should still POST then cancel" "$(cat "$LOG")"
grep -q "DELETE /api/tasks/" "$LOG" || fail "cold pool should cancel the task for a refund" "$(cat "$LOG")"
ok "cold pool -> cancel + local fallback"

# 3. Non-Task tool -> untouched, nothing sent.
run cold "anything" Bash
if ! { [ "$RC" = "0" ] && [ -z "$OUT" ]; }; then fail "non-Task tool should be a no-op" "$OUT"; fi
[ ! -s "$LOG" ] || fail "non-Task tool must not contact the coordinator" "$(cat "$LOG")"
ok "non-Task tool -> no-op"

# 4. Self-worker (prompt carries task_id:) -> never routed.
run cold "task_id: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
Read the job and solve it."
if ! { [ "$RC" = "0" ] && [ -z "$OUT" ]; }; then fail "self-worker should pass through" "$OUT"; fi
[ ! -s "$LOG" ] || fail "self-worker must not be routed" "$(cat "$LOG")"
ok "self-worker (task_id) -> not routed"

# 5. Local-path prompt -> declined before any network.
run returned "Refactor the function in ./src/main.rs and run the tests."
if ! { [ "$RC" = "0" ] && [ -z "$OUT" ]; }; then fail "local-path prompt should decline to local" "$OUT"; fi
[ ! -s "$LOG" ] || fail "local-path prompt must not be routed" "$(cat "$LOG")"
ok "local-path prompt -> declined, no network"

# 6. Secret in prompt -> declined before any network.
run returned "Write a script that authenticates with api_key sk-abcdefTOPSECRET and fetches data."
if ! { [ "$RC" = "0" ] && [ -z "$OUT" ]; }; then fail "secret prompt should decline" "$OUT"; fi
[ ! -s "$LOG" ] || fail "secret prompt must not be routed" "$(cat "$LOG")"
ok "secret in prompt -> declined, no network"

# 7. Ambiguous / no confident class -> declined, no network.
run returned "Do the needful with the thing."
if ! { [ "$RC" = "0" ] && [ -z "$OUT" ]; }; then fail "unclassifiable prompt should decline" "$OUT"; fi
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
#    local, shows the disclosure as a visible systemMessage (stderr only shows
#    in verbose mode), and sends nothing; routing starts next time.
FRESH="itest-fresh-$RANDOM"
rm -f "/tmp/slashwork-intercept-consent-$FRESH"
printf returned > "$MODEFILE"; : > "$LOG"
OUT=$(envelope "Research and compare the options; pros and cons of each." Task "$FRESH" \
  | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" bash "$INTERCEPT" 2>/dev/null)
RC=$?
[ "$RC" = "0" ] || fail "first candidate exit code $RC" "$OUT"
DEC=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[ -z "$DEC" ] || fail "first candidate must carry no decision (local spawn)" "$OUT"
printf '%s' "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null | grep -q "slashwork intercept is on" \
  || fail "first candidate must show the disclosure as a systemMessage" "$OUT"
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

# 12. Default-on: SLASHWORK_INTERCEPT unset -> intercepts (install + token is
#     the opt-in; env -u guarantees the var is absent regardless of the
#     caller's environment).
: > "$LOG"; printf returned > "$MODEFILE"; : > "/tmp/slashwork-intercept-consent-$SESS"
OUT=$(envelope "Research and compare the options; pros and cons of each." \
  | env -u SLASHWORK_INTERCEPT SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" bash "$INTERCEPT" 2>/dev/null)
[ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] \
  || fail "unset must intercept (interception is default-on)" "$OUT"
ok "SLASHWORK_INTERCEPT unset -> intercepts (default-on)"

# 13. Opt-out: SLASHWORK_INTERCEPT=0 -> total no-op, nothing sent. The hook
#     exits at the opt-out gate BEFORE reading stdin, so a piped producer (jq in
#     envelope) would get SIGPIPE and, under `set -o pipefail`, fail the whole
#     pipeline spuriously. Feed the envelope as a here-string so there is no
#     upstream producer to break.
: > "$LOG"; printf returned > "$MODEFILE"
ENV_OPTOUT=$(envelope "Research and compare the options.")
OUT=$(SLASHWORK_INTERCEPT=0 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" \
  bash "$INTERCEPT" 2>/dev/null <<< "$ENV_OPTOUT")
RC=$?
if ! { [ "$RC" = "0" ] && [ -z "$OUT" ]; }; then fail "opted out must be a no-op" "$OUT"; fi
[ ! -s "$LOG" ] || fail "opted out must not contact the coordinator" "$(cat "$LOG")"
ok "SLASHWORK_INTERCEPT=0 -> no-op"

# 14. Non-https base -> decline before any network (the token must not leave for
#     an arbitrary host). The base check runs before the classifier, so even a
#     routable prompt is declined.
: > "$LOG"; printf returned > "$MODEFILE"; : > "/tmp/slashwork-intercept-consent-$SESS"
OUT=$(envelope "Research and compare the options; pros and cons of each." \
  | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="http://evil.example" bash "$INTERCEPT" 2>/dev/null)
RC=$?
if ! { [ "$RC" = "0" ] && [ -z "$OUT" ]; }; then fail "non-https base must decline to local" "$OUT"; fi
[ ! -s "$LOG" ] || fail "non-https base must not contact any coordinator" "$(cat "$LOG")"
ok "non-https base -> declined, no network"

# 15. Coordinator dies after the claim: the next poll errors (500) mid-wait, so
#     the hook cancels (refund) and falls back local instead of hanging.
printf claim-then-die > "$MODEFILE"; : > "$LOG"; rm -f "$LOG.flip"; : > "/tmp/slashwork-intercept-consent-$SESS"
OUT=$(envelope "Research and compare the options; pros and cons of each." \
  | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" bash "$INTERCEPT" 2>/dev/null)
RC=$?
if ! { [ "$RC" = "0" ] && [ -z "$OUT" ]; }; then fail "a dying coordinator must fall back to local" "$OUT"; fi
grep -q "DELETE /api/tasks/" "$LOG" || fail "should cancel the task when the poll errors" "$(cat "$LOG")"
ok "coordinator dies after claim -> cancel + local, no hang"

# 16. Reviewing then expired (the gate rejected within the grace): the hook rides
#     the grace poll loop, then falls back local, never emitting a stale artifact.
printf review-then-expire > "$MODEFILE"; : > "$LOG"; rm -f "$LOG.ctr"; : > "/tmp/slashwork-intercept-consent-$SESS"
OUT=$(envelope "Research and compare the options; pros and cons of each." \
  | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" bash "$INTERCEPT" 2>/dev/null)
RC=$?
if ! { [ "$RC" = "0" ] && [ -z "$OUT" ]; }; then fail "reviewing that expires must fall back to local" "$OUT"; fi
grep -q "DELETE /api/tasks/" "$LOG" || fail "should cancel after the grace loop ends expired" "$(cat "$LOG")"
ok "reviewing then expired -> local fallback after the grace loop"

# 16b. Out of credits: the POST is rejected before any task exists, so the
#      spawn runs locally (no decision, no cancel) and the user gets a visible
#      systemMessage pointing at /earn.
printf no-credits > "$MODEFILE"; : > "$LOG"; : > "/tmp/slashwork-intercept-consent-$SESS"
OUT=$(envelope "Research and compare the options; pros and cons of each." \
  | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" bash "$INTERCEPT" 2>/dev/null)
RC=$?
[ "$RC" = "0" ] || fail "out-of-credits exit code $RC" "$OUT"
DEC=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[ -z "$DEC" ] || fail "out of credits must carry no decision (local spawn)" "$OUT"
SM=$(printf '%s' "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null)
printf '%s' "$SM" | grep -q "not enough credits" || fail "out-of-credits message missing the reason" "$OUT"
printf '%s' "$SM" | grep -q "/earn" || fail "out-of-credits message missing the /earn pointer" "$OUT"
if grep -q "DELETE /api/tasks/" "$LOG"; then fail "no task was created, nothing to cancel" "$(cat "$LOG")"; fi
ok "out of credits -> local spawn + visible /earn nudge"

# 17. The subagent tool is named Agent on newer Claude Code builds. An
#     Agent-named envelope must route exactly like a Task-named one; pinning
#     this to Task made interception silently inert on those builds.
printf returned > "$MODEFILE"; : > "$LOG"; : > "/tmp/slashwork-intercept-consent-$SESS"
OUT=$(envelope "Research and compare the options; pros and cons of each." Agent \
  | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" bash "$INTERCEPT" 2>/dev/null)
DEC=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[ "$DEC" = "deny" ] || fail "an Agent-named spawn must route like a Task one" "$OUT"
grep -q "POST /api/tasks" "$LOG" || fail "Agent-named spawn should have POSTed the task" "$(cat "$LOG")"
ok "Agent tool name routes like Task"

# 18. An unrelated tool name stays a no-op: nothing sent, no output.
: > "$LOG"
OUT=$(envelope "Research and compare the options; pros and cons of each." Bash \
  | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" bash "$INTERCEPT" 2>/dev/null)
RC=$?
if ! { [ "$RC" = "0" ] && [ -z "$OUT" ]; }; then fail "a non-subagent tool must be a no-op" "$OUT"; fi
[ ! -s "$LOG" ] || fail "a non-subagent tool must not contact the coordinator" "$(cat "$LOG")"
ok "non-subagent tool names stay untouched"

# 19. Coordinator unreachable during the claim window: nothing is invested yet,
#     so the hook must fall back local IMMEDIATELY (exactly one result poll, no
#     retries burning user time), cancelling for the refund.
printf die-on-poll > "$MODEFILE"; : > "$LOG"; : > "/tmp/slashwork-intercept-consent-$SESS"
OUT=$(envelope "Research and compare the options; pros and cons of each." \
  | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" bash "$INTERCEPT" 2>/dev/null)
RC=$?
if ! { [ "$RC" = "0" ] && [ -z "$OUT" ]; }; then fail "a dead coordinator in the claim window must fall back to local" "$OUT"; fi
POLLS=$(grep -c "GET /api/tasks/.*/result" "$LOG")
[ "$POLLS" = "1" ] || fail "claim-window error must not retry (saw $POLLS polls)" "$(cat "$LOG")"
grep -q "DELETE /api/tasks/" "$LOG" || fail "should still cancel for the refund" "$(cat "$LOG")"
ok "dead coordinator in the claim window -> one poll, instant local fallback"

# 20. One blip after the claim (a deploy swapping the coordinator): the retry
#     rides it out and the artifact still comes back instead of a cancel that
#     throws away an earner mid-run.
printf die-then-return > "$MODEFILE"; : > "$LOG"; rm -f "$LOG.ctr"; : > "/tmp/slashwork-intercept-consent-$SESS"
OUT=$(envelope "Research and compare the options; pros and cons of each." \
  | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_BASE_URL="$BASE" bash "$INTERCEPT" 2>/dev/null)
RC=$?
[ "$RC" = "0" ] || fail "post-claim blip exit code $RC" "$OUT"
DEC=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
[ "$DEC" = "deny" ] || fail "the retry must bridge one post-claim blip and return the artifact" "$OUT"
printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q "RETRY ARTIFACT" \
  || fail "deny reason missing the post-blip artifact" "$OUT"
if grep -q "DELETE /api/tasks/" "$LOG"; then fail "a bridged blip must not cancel the task" "$(cat "$LOG")"; fi
ok "one blip after the claim -> retried, artifact returned"

echo "ALL PASS ($PASS scenarios)"
