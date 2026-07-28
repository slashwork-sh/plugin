#!/usr/bin/env bash
# Integration test for the PreToolUse(Task|Agent) intercept hook.
#
# The classifier, secret scan, and dispatch loop now live in the shared
# slashwork-offload core (unit-tested in offload/src/*.rs and end to end in
# offload/tests/classify_cli.rs). This test covers what stays in the hook: the
# opt-out gate, envelope parsing, the self-worker fast path, the token presence
# gate, the once-per-session consent disclosure, and rendering the core's
# decision as a `deny` (with the savings receipt) or a clean local fall-through.
#
# It drives the hook against a FAKE core: a stub that records each subcommand it
# is called with and echoes a canned decision from the environment. So the test
# needs no coordinator and no Rust build, and asserts exactly the bash contract:
# which subcommand ran, and what the hook emitted.
#
# Run: bash plugins/work/hooks/intercept_test.sh
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
INTERCEPT="$HOOK_DIR/intercept.sh"
TOKEN="testtoken"
SESS="itest-fixed"
PASS=0

fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && { echo "--- detail ---"; echo "$2"; }; exit 1; }
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# A sandbox HOME so the hook's ~/.slashwork writes (savings.log) and the token
# presence check never touch the real home or a dev's real token.
SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX"
export SLASHWORK_ROUTE_LOG="$SANDBOX/route-log.jsonl"
FAKE_CORE_LOG="$SANDBOX/core-calls.log"
export FAKE_CORE_LOG

# The fake core: record each subcommand to FAKE_CORE_LOG, drain the envelope on
# stdin (so the hook's pipe never breaks), and echo the canned decision for that
# subcommand from the environment. Always exits 0, like the real core.
CORE="$SANDBOX/slashwork-offload"
cat > "$CORE" <<'FAKE'
#!/usr/bin/env bash
# Emit the canned decision the test set for this subcommand. Empty (var unset)
# reads to the hook as no decision -> local, which is a valid outcome to assert.
{ printf '%s\n' "$1" >> "${FAKE_CORE_LOG:-/dev/null}"; } 2>/dev/null
cat >/dev/null
case "$1" in
  classify) printf '%s\n' "${FAKE_CLASSIFY:-}" ;;
  route)    printf '%s\n' "${FAKE_ROUTE:-}" ;;
  *)        printf '{}\n' ;;
esac
exit 0
FAKE
chmod +x "$CORE"
export SLASHWORK_OFFLOAD_BIN="$CORE"

trap 'rm -rf "$SANDBOX" /tmp/slashwork-intercept-consent-* 2>/dev/null' EXIT

# Canned decisions the fake core echoes (the JSON \n stay escaped: the hook's jq
# reads them as real newlines).
ART='{"decision":"artifact","task_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","class":"research","artifact":"OFFLOAD ARTIFACT: the answer.","wrapped":"UNTRUSTED third-party content.\n\nOFFLOAD ARTIFACT: the answer.","tokens_used":123,"settled":12,"tokens_saved_total":4560}'
ART_ML='{"decision":"artifact","task_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","class":"prose","artifact":"LINE ONE of the report\nLINE TWO details\nLINE THREE conclusion","tokens_used":200,"settled":20,"tokens_saved_total":200}'
LOCAL_COLD='{"decision":"local","reason":"no earner claimed within 5s"}'
LOCAL_CREDITS='{"decision":"local","reason":"not enough credits: you have 3, it costs 50"}'
ROUTABLE='{"decision":"routable","class":"research"}'
NOTROUTABLE='{"decision":"local","reason":"no single confident class (matched 0)"}'

# envelope <prompt> <tool_name> <session> -> a PreToolUse envelope on stdout
envelope() {
  jq -nc --arg p "$1" --arg t "${2:-Task}" --arg s "${3:-$SESS}" \
    '{session_id:$s, hook_event_name:"PreToolUse", tool_name:$t,
      tool_input:{subagent_type:"general-purpose", description:"d", prompt:$p}}'
}

consent_given() { : > "/tmp/slashwork-intercept-consent-$SESS"; }
core_called() { grep -qx "$1" "$FAKE_CORE_LOG" 2>/dev/null; }
decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }
sysmsg() { printf '%s' "$1" | jq -r '.systemMessage // empty' 2>/dev/null; }

# invoke <prompt> [tool] [session] -> sets OUT, RC. Signed in, interception on.
# The caller sets FAKE_ROUTE / FAKE_CLASSIFY (exported) first.
invoke() {
  : > "$FAKE_CORE_LOG"
  OUT=$(envelope "$1" "${2:-Task}" "${3:-$SESS}" \
    | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" bash "$INTERCEPT" 2>/dev/null)
  RC=$?
}

# 1. Routable spawn, the core returns an artifact -> deny carrying the wrapped
#    (untrusted) artifact, plus the savings receipt.
consent_given
export FAKE_ROUTE="$ART"
invoke "Research and compare the leading approaches to rate limiting; give pros and cons of each."
[ "$RC" = 0 ] || fail "artifact exit code $RC" "$OUT"
[ "$(decision "$OUT")" = "deny" ] || fail "artifact must deny the local spawn" "$OUT"
reason "$OUT" | grep -q "OFFLOAD ARTIFACT" || fail "deny reason missing the artifact" "$OUT"
reason "$OUT" | grep -qi "untrusted" || fail "deny reason must mark the artifact untrusted" "$OUT"
SM=$(sysmsg "$OUT")
printf '%s' "$SM" | grep -q "123 tokens" || fail "systemMessage missing tokens saved" "$OUT"
printf '%s' "$SM" | grep -q "12 cr" || fail "systemMessage missing settled credits" "$OUT"
printf '%s' "$SM" | grep -q "tokens saved" || fail "systemMessage missing the plot header" "$OUT"
printf '%s' "$SM" | grep -q "/earn" || fail "systemMessage missing the /earn pointer" "$OUT"
core_called route || fail "the hook should have called the core's route" "$(cat "$FAKE_CORE_LOG")"
ok "routable artifact -> deny with untrusted artifact + saved-tokens receipt"

# 2. Multi-line artifact returned whole (not truncated to line 1); with no
#    `wrapped` field the hook falls back to the raw artifact.
export FAKE_ROUTE="$ART_ML"
invoke "Draft a report summarizing the quarterly numbers; revenue up, costs flat."
R=$(reason "$OUT")
printf '%s' "$R" | grep -q "LINE ONE" || fail "multiline: line 1 missing" "$R"
printf '%s' "$R" | grep -q "LINE THREE" || fail "multiline artifact truncated (line 3 dropped)" "$R"
ok "multi-line artifact (no wrapped) returned whole via .artifact fallback"

# 3. The core returns local (cold pool, decline, any dispatch failure) -> clean
#    fall-through: no decision, no output, local spawn.
export FAKE_ROUTE="$LOCAL_COLD"
invoke "Research and compare the options; pros and cons of each."
if ! { [ "$RC" = 0 ] && [ -z "$OUT" ]; }; then fail "a local decision must fall through silently" "$OUT"; fi
core_called route || fail "should still have called route" "$(cat "$FAKE_CORE_LOG")"
ok "core returns local -> silent local fall-through"

# 4. Non-subagent tool -> no-op, the core is never called.
export FAKE_ROUTE="$ART"
invoke "anything" Bash
if ! { [ "$RC" = 0 ] && [ -z "$OUT" ]; }; then fail "non-subagent tool should be a no-op" "$OUT"; fi
[ ! -s "$FAKE_CORE_LOG" ] || fail "non-subagent tool must not call the core" "$(cat "$FAKE_CORE_LOG")"
ok "non-subagent tool -> no-op, core untouched"

# 5. Self-worker (prompt carries task_id:) -> fast-path pass-through, core never
#    called (never repost our own work, and skip the subprocess).
invoke "task_id: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
Read the job and solve it."
if ! { [ "$RC" = 0 ] && [ -z "$OUT" ]; }; then fail "self-worker should pass through" "$OUT"; fi
[ ! -s "$FAKE_CORE_LOG" ] || fail "self-worker must not call the core" "$(cat "$FAKE_CORE_LOG")"
ok "self-worker (task_id) -> pass-through, core untouched"

# 6. Empty prompt -> no-op.
invoke ""
if ! { [ "$RC" = 0 ] && [ -z "$OUT" ]; }; then fail "empty prompt should be a no-op" "$OUT"; fi
[ ! -s "$FAKE_CORE_LOG" ] || fail "empty prompt must not call the core" "$(cat "$FAKE_CORE_LOG")"
ok "empty prompt -> no-op"

# 7. Not signed in (no SLASHWORK_TOKEN and no ~/.slashwork/token in the sandbox
#    HOME) -> inert: no consent notice, core never called.
: > "$FAKE_CORE_LOG"
OUT=$(envelope "Research and compare the options; pros and cons of each." \
  | env -u SLASHWORK_TOKEN SLASHWORK_INTERCEPT=1 bash "$INTERCEPT" 2>/dev/null)
RC=$?
if ! { [ "$RC" = 0 ] && [ -z "$OUT" ]; }; then fail "no token must be inert" "$OUT"; fi
[ ! -s "$FAKE_CORE_LOG" ] || fail "no token must not call the core" "$(cat "$FAKE_CORE_LOG")"
ok "no token -> inert, core untouched"

# 8. Core binary missing/broken (bogus SLASHWORK_OFFLOAD_BIN) -> the exec fails,
#    the hook reads no decision and falls back to a local spawn. The iron rule:
#    a broken core never hangs or errors, it runs local.
consent_given
: > "$FAKE_CORE_LOG"
OUT=$(envelope "Research and compare the options; pros and cons of each." \
  | SLASHWORK_INTERCEPT=1 SLASHWORK_TOKEN="$TOKEN" SLASHWORK_OFFLOAD_BIN="/no/such/slashwork-offload" \
      bash "$INTERCEPT" 2>/dev/null)
RC=$?
if ! { [ "$RC" = 0 ] && [ -z "$OUT" ]; }; then fail "a broken core must fall back to local" "$OUT"; fi
ok "broken core binary -> local fall-through, no hang"

# 9. First-candidate consent gate: a fresh session's first ROUTABLE spawn runs
#    local, shows the disclosure as a visible systemMessage, and calls only
#    classify (never route); the next spawn routes.
FRESH="itest-fresh-$RANDOM"
rm -f "/tmp/slashwork-intercept-consent-$FRESH"
export FAKE_CLASSIFY="$ROUTABLE"
export FAKE_ROUTE="$ART"
invoke "Research and compare the options; pros and cons of each." Task "$FRESH"
[ "$RC" = 0 ] || fail "first candidate exit code $RC" "$OUT"
[ -z "$(decision "$OUT")" ] || fail "first candidate must carry no decision" "$OUT"
sysmsg "$OUT" | grep -q "slashwork intercept is on" || fail "first candidate must show the disclosure" "$OUT"
core_called classify || fail "consent gate should classify" "$(cat "$FAKE_CORE_LOG")"
core_called route && fail "consent gate must NOT dispatch the first spawn" "$(cat "$FAKE_CORE_LOG")"
# Second candidate in the same session now routes.
invoke "Research and compare the options; pros and cons of each." Task "$FRESH"
[ "$(decision "$OUT")" = "deny" ] || fail "second candidate should route" "$OUT"
core_called route || fail "second candidate should dispatch" "$(cat "$FAKE_CORE_LOG")"
ok "consent gate -> disclose+local first, route second"

# 10. Consent gate on a NON-routable first spawn: no disclosure, and consent is
#     not marked, so a later routable spawn still gets the notice. Classify runs,
#     route does not.
FRESH2="itest-fresh2-$RANDOM"
rm -f "/tmp/slashwork-intercept-consent-$FRESH2"
export FAKE_CLASSIFY="$NOTROUTABLE"
invoke "Do the needful with the thing." Task "$FRESH2"
[ -z "$OUT" ] || fail "a non-routable first spawn must be silent (no disclosure)" "$OUT"
core_called classify || fail "should classify to decide the consent notice" "$(cat "$FAKE_CORE_LOG")"
core_called route && fail "a non-routable spawn must not dispatch" "$(cat "$FAKE_CORE_LOG")"
[ ! -f "/tmp/slashwork-intercept-consent-$FRESH2" ] || fail "a non-routable spawn must not consume consent" ""
ok "non-routable first spawn -> silent, consent not consumed"

# 11. Out of credits: the core returns a local decision whose reason names it, so
#     the hook shows a visible /earn nudge and runs local (no decision).
consent_given
export FAKE_ROUTE="$LOCAL_CREDITS"
invoke "Research and compare the options; pros and cons of each."
[ "$RC" = 0 ] || fail "out-of-credits exit code $RC" "$OUT"
[ -z "$(decision "$OUT")" ] || fail "out of credits must carry no decision" "$OUT"
SM=$(sysmsg "$OUT")
printf '%s' "$SM" | grep -q "not enough credits" || fail "out-of-credits message missing the reason" "$OUT"
printf '%s' "$SM" | grep -q "/earn" || fail "out-of-credits message missing the /earn pointer" "$OUT"
ok "out of credits -> local spawn + visible /earn nudge"

# 12. Agent tool name routes like Task (newer Claude Code builds rename it).
export FAKE_ROUTE="$ART"
invoke "Research and compare the options; pros and cons of each." Agent
[ "$(decision "$OUT")" = "deny" ] || fail "an Agent-named spawn must route like a Task one" "$OUT"
core_called route || fail "Agent-named spawn should dispatch" "$(cat "$FAKE_CORE_LOG")"
ok "Agent tool name routes like Task"

# 13. Default-on: SLASHWORK_INTERCEPT unset -> intercepts (install + token is the
#     opt-in). env -u guarantees the var is absent.
export FAKE_ROUTE="$ART"
: > "$FAKE_CORE_LOG"
OUT=$(envelope "Research and compare the options; pros and cons of each." \
  | env -u SLASHWORK_INTERCEPT SLASHWORK_TOKEN="$TOKEN" bash "$INTERCEPT" 2>/dev/null)
[ "$(decision "$OUT")" = "deny" ] || fail "unset must intercept (default-on)" "$OUT"
ok "SLASHWORK_INTERCEPT unset -> intercepts (default-on)"

# 14. Opt-out: SLASHWORK_INTERCEPT=0 -> total no-op, core never called. The hook
#     exits at the opt-out gate before reading stdin, so feed the envelope as a
#     here-string (no upstream producer to SIGPIPE under pipefail).
ENV_OPTOUT=$(envelope "Research and compare the options.")
: > "$FAKE_CORE_LOG"
OUT=$(SLASHWORK_INTERCEPT=0 SLASHWORK_TOKEN="$TOKEN" bash "$INTERCEPT" 2>/dev/null <<< "$ENV_OPTOUT")
RC=$?
if ! { [ "$RC" = 0 ] && [ -z "$OUT" ]; }; then fail "opted out must be a no-op" "$OUT"; fi
[ ! -s "$FAKE_CORE_LOG" ] || fail "opted out must not call the core" "$(cat "$FAKE_CORE_LOG")"
ok "SLASHWORK_INTERCEPT=0 -> no-op"

# 15. Route log records the verdict the hook observes: routed (with the class) on
#     an artifact, local (with the reason) on a local decision.
: > "$SLASHWORK_ROUTE_LOG"
export FAKE_ROUTE="$ART"
invoke "Research and compare the leading rate limiting algorithms; give the pros and cons of each."
grep -q '"decision":"routed","detail":"research"' "$SLASHWORK_ROUTE_LOG" \
  || fail "route log missing the routed research verdict" "$(cat "$SLASHWORK_ROUTE_LOG")"
export FAKE_ROUTE="$LOCAL_COLD"
invoke "Research and compare the options; pros and cons of each."
grep -q '"decision":"local"' "$SLASHWORK_ROUTE_LOG" \
  || fail "route log missing a local verdict" "$(cat "$SLASHWORK_ROUTE_LOG")"
ok "route log records routed (class) and local (reason) verdicts"

echo "ALL PASS ($PASS scenarios)"
