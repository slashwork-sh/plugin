#!/usr/bin/env bash
# PreToolUse(Task|Agent) hook for the slashwork offload network.
#
# Interception is on by default: installing the plugin and signing in
# (/work init writes the token) is the opt-in, and SLASHWORK_INTERCEPT=0 is the
# per-session/per-project opt-out (/work off writes it). This hook catches each
# subagent spawn before it runs and hands the routing decision to the shared
# `slashwork-offload` core binary. The core classifies the prompt and, if it is
# confidently self-contained, posts it to the coordinator and waits briefly for
# a warm earner to return an artifact. If one comes back in time, this hook hands
# that artifact to the parent session INSTEAD of spawning locally. Anything else
# (opted out, no token, no core binary, not a Task, our own worker, not routable,
# no earner, slow earner, any error) falls through to the local spawn exactly as
# it would have run today.
#
# The classifier, secret scan, dispatch loop, and cancel/refund all live in the
# core now (offload/, ported once so every harness shares one tested path instead
# of three that drift). What stays here is the Claude Code glue: the opt-out
# gate, PreToolUse envelope parsing, the once-per-session consent disclosure, and
# rendering the core's decision as a `deny` (with the savings receipt) that
# Claude Code understands. The core owns every network call, so this hook needs
# no curl.
#
# The iron rule is unchanged: the failure mode is always "ran locally like it
# always did," never "hung" and never "ran worse." Every branch that is not a
# clean returned artifact exits 0 with no decision, which lets Claude Code spawn
# the subagent normally. Only a returned artifact emits a `deny` that carries the
# result.
#
# Stdin is the PreToolUse envelope:
#   { session_id, tool_name, tool_input: { subagent_type, description, prompt }, ... }
#
# Docs: docs/pivot-offload-network.md ("The dispatch loop"),
#       docs/openclaw-hermes-hooks.md (the shared core the adapters all call).
set -uo pipefail

# Clean up the decision temp file on any exit path.
trap 'rm -f "/tmp/slashwork-intercept-decision-$$.json" 2>/dev/null' EXIT

# 0. Opt-out gate. On by default; exactly "0" means this session or project
#    turned routing off (/work off), so do nothing at all.
[ "${SLASHWORK_INTERCEPT:-}" != "0" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

# Locate the shared core binary: SLASHWORK_OFFLOAD_BIN, then the install dir the
# sibling install-core.sh SessionStart hook populates, then PATH. No binary =>
# inert (local), exactly as the hook behaves before sign-in. This core must be
# recent enough to have the `classify` subcommand; the pinned distribution ships
# the hook and its core together.
CORE="${SLASHWORK_OFFLOAD_BIN:-}"
if [ -z "$CORE" ] && [ -x "$HOME/.slashwork/bin/slashwork-offload" ]; then
  CORE="$HOME/.slashwork/bin/slashwork-offload"
fi
[ -n "$CORE" ] || CORE=$(command -v slashwork-offload 2>/dev/null)
[ -n "$CORE" ] || exit 0

INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
# The subagent tool is "Task" on older Claude Code builds and "Agent" on newer
# ones; the envelope shape (tool_input.prompt) is the same. Accept both or
# interception is silently inert on one side of the rename.
case "$TOOL" in
  Task|Agent) : ;;
  *) exit 0 ;;
esac

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "default"')
PROMPT=$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // empty')
[ -n "$PROMPT" ] || exit 0

# Self-exemption fast path. slashwork's own worker spawns carry "task_id:" in
# their prompt (submit keys on the same marker). The core's classifier also
# exempts them, but short-circuiting here skips a subprocess for our own workers
# (frequent while earning) and never risks reposting our own work.
case "$PROMPT" in
  *task_id:*) exit 0 ;;
esac

# Token presence gate: stay inert (and show no consent notice) until the user has
# signed in. The core reads the token itself for the real calls; this only gates
# whether the hook acts at all. Presence, never the value.
[ -n "${SLASHWORK_TOKEN:-}" ] || [ -f "$HOME/.slashwork/token" ] || exit 0

# The route envelope the core reads on stdin (harness-tagged; v1 sends the prompt
# only, the core inlines no files).
ENVELOPE=$(jq -nc --arg p "$PROMPT" '{harness:"claude-code",spawn:{prompt:$p}}')

# Route log: a persistent JSONL of routable-vs-local verdicts so the "widen the
# routable slice" work keeps signal (stderr alone is verbose-only and vanishes).
# Classification lives in the core now; this logs the decision the hook observes
# (routed when an artifact returns or the consent-gate classify says routable,
# local otherwise). Best-effort, never breaks the hook. Point SLASHWORK_ROUTE_LOG
# at /dev/null to disable.
ROUTE_LOG="${SLASHWORK_ROUTE_LOG:-$HOME/.slashwork/route-log.jsonl}"
route_log() { # $1 = routed|local ; $2 = class (routed) or reason (local)
  [ "$ROUTE_LOG" = /dev/null ] && return 0
  { mkdir -p "$(dirname "$ROUTE_LOG")" 2>/dev/null \
    && printf '{"ts":%s,"decision":"%s","detail":"%s"}\n' \
         "$(date +%s)" "$1" "$(printf '%s' "$2" | tr -d '"')" >> "$ROUTE_LOG"; } 2>/dev/null || true
}
local_spawn() { route_log local "$1"; echo "slashwork intercept: local ($1)" >&2; exit 0; }

DECISION_FILE="/tmp/slashwork-intercept-decision-$$.json"

emit_result() { # deny the local spawn and hand back the artifact from $DECISION_FILE
  route_log routed "$(jq -r '.class // "?"' "$DECISION_FILE" 2>/dev/null || echo '?')"
  # Record this offload's saving locally (last 20) for the CLI plot. A new file,
  # additive, not the cross-plugin state contract.
  local saved total dir log
  saved=$(jq -r '.tokens_used // 0' "$DECISION_FILE" 2>/dev/null); saved=${saved:-0}
  total=$(jq -r '.tokens_saved_total // 0' "$DECISION_FILE" 2>/dev/null); total=${total:-0}
  case "$saved" in ''|*[!0-9]*) saved=0 ;; esac
  dir="$HOME/.slashwork"; log="$dir/savings.log"
  mkdir -p "$dir" 2>/dev/null
  printf '%s\n' "$saved" >> "$log" 2>/dev/null
  if [ -f "$log" ]; then tail -n 20 "$log" > "$log.tmp" 2>/dev/null && mv "$log.tmp" "$log" 2>/dev/null; fi

  # Render a compact ASCII bar chart of the recent savings, scaled to 24 cols.
  # Pure shell so a crafted artifact never reaches the renderer.
  local plot vals max n i v width bars mark
  vals=$(tail -n 8 "$log" 2>/dev/null)
  max=0
  for v in $vals; do case "$v" in ''|*[!0-9]*) v=0 ;; esac; [ "$v" -gt "$max" ] && max=$v; done
  [ "$max" -eq 0 ] && max=1
  n=$(printf '%s\n' "$vals" | grep -c . 2>/dev/null); n=${n:-0}
  plot="tokens saved, recent offloads:"
  i=0
  for v in $vals; do
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    i=$((i + 1))
    width=$(( v * 24 / max )); [ "$width" -lt 1 ] && [ "$v" -gt 0 ] && width=1
    bars=$(printf '%*s' "$width" '' | tr ' ' '#')
    mark=""; [ "$i" -eq "$n" ] && mark="  <- now"
    plot="$plot"$'\n'"$(printf '  %8s  %s%s' "$v" "$bars" "$mark")"
  done

  # systemMessage receipt: settled credits, the plot, the cumulative total, and
  # the /earn pointer. Built with jq so a crafted artifact (quotes, newlines,
  # tabs, backslashes) cannot corrupt the JSON or the shell. The deny's reason is
  # the core's untrusted-content-wrapped artifact (`.wrapped`, invariant 2): the
  # wrapper lives in the core so every harness and the acceptance judge stay in
  # sync. It renders as a plain notice in the transcript (the deny itself renders
  # as a blocked tool call, which is harness styling the hook cannot change).
  jq -c --arg plot "$plot" --argjson total "$total" \
    '{systemMessage: ("/work offloaded this task: saved "
            + ((.tokens_used // 0) | tostring) + " tokens, settled "
            + ((.settled // 0) | tostring) + " cr.\n" + $plot
            + "\ntotal saved: " + ($total | tostring)
            + " tokens across your offloads. run /earn to bank credits back."),
          hookSpecificOutput: {hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: (.wrapped // .artifact // "")}}' \
    "$DECISION_FILE"
  rm -f "$DECISION_FILE"
  exit 0
}

# 1. First-candidate consent gate (once per session). Installing the plugin and
#    signing in is the standing consent, but nothing leaves the machine before
#    the user has seen what routing does: the FIRST *routable* spawn in a session
#    prints the disclosure and runs locally. Routing begins on the next one. Ask
#    the core to classify (no token, no network, no dispatch) so a non-routable
#    spawn never triggers the notice and never marks consent.
CONSENT="/tmp/slashwork-intercept-consent-$SESSION_ID"
if [ ! -f "$CONSENT" ]; then
  CLASSIFY=$(printf '%s' "$ENVELOPE" | "$CORE" classify 2>/dev/null)
  if [ "$(printf '%s' "$CLASSIFY" | jq -r '.decision // "local"' 2>/dev/null)" = "routable" ]; then
    route_log routed "$(printf '%s' "$CLASSIFY" | jq -r '.class // "?"' 2>/dev/null)"
    : > "$CONSENT" 2>/dev/null || true
    # systemMessage, not stderr: an exit-0 hook's stderr only shows in verbose
    # mode, and a disclosure the user cannot see is not a disclosure. With no
    # decision attached the spawn still runs locally.
    jq -nc '{systemMessage: "slashwork intercept is on: self-contained subagent tasks will be routed to the offload network, meaning the task prompt is sent to another slashwork user'"'"'s session to run. This first task runs locally; routing starts with the next one. Run /work off (or set SLASHWORK_INTERCEPT=0) to stop routing."}'
  else
    route_log local "$(printf '%s' "$CLASSIFY" | jq -r '.reason // "not routable"' 2>/dev/null)"
  fi
  exit 0   # never route before the disclosure has been shown once
fi

# 2. Dispatch. Hand the spawn to the core, which classifies, posts the task,
#    waits out the claim window and class deadline, cancels on any fall-through
#    (refunding the requester), and self-bounds its wall clock under the manifest
#    timeout. It always prints one JSON decision and exits 0:
#    {"decision":"artifact", ...} to hand back, or {"decision":"local","reason"}.
printf '%s' "$ENVELOPE" | "$CORE" route 2>/dev/null > "$DECISION_FILE"
DEC=$(jq -r '.decision // "local"' "$DECISION_FILE" 2>/dev/null || echo local)

if [ "$DEC" = "artifact" ]; then
  emit_result
fi

# Local decision: fall through to the local spawn. Surface the one rejection the
# user can act on, out of credits, as a visible systemMessage (a decline's
# stderr does not render) with the /earn pointer; the core reports it as a
# "not enough credits" reason. No decision accompanies it, so the spawn runs
# local as always.
REASON=$(jq -r '.reason // "route declined"' "$DECISION_FILE" 2>/dev/null || echo "route declined")
case "$REASON" in
  *"not enough credits"*)
    jq -nc --arg m "slashwork: $REASON. This task ran locally. Run /earn to earn credits by running tasks for others." \
      '{systemMessage: $m}'
    route_log local "not enough credits"
    echo "slashwork intercept: local (out of credits)" >&2
    exit 0 ;;
esac
local_spawn "$REASON"
