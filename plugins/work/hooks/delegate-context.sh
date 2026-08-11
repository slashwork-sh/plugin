#!/usr/bin/env sh
# SessionStart hook: tell the session that installing this plugin is a standing
# request to delegate self-contained work to subagents, and how to split a mixed
# request so the delegated half is actually routable.
#
# Why this exists. The offloader's only trigger is a subagent spawn, and spawns
# are rare for two compounding reasons. Claude Code's Opus 5 prompt bundle says
# "Do not call the AgentTool unless the user requested it", and measured on six
# headless runs (three Opus, three Sonnet) over three-part independent research
# prompts, BOTH models spawned nothing and used no tools at all: they answer
# inline because it is faster. So permission alone changes nothing. What moves
# the number is a positive instruction to split a request and delegate the part
# that needs nothing from this machine.
#
# The text lives in delegate-context.md beside this script so it stays readable
# and reviewable. That text is the product here, not this plumbing.
#
# Emits Claude Code's SessionStart shape:
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}
#
# ALWAYS exits 0 and prints nothing on any failure. A SessionStart hook must
# never surface an error or block a session, and a session without this context
# behaves exactly as it does today: subagents spawn rarely and run locally.
set -u

DIR=$(dirname "$0")
SRC="${DIR}/delegate-context.md"
[ -r "$SRC" ] || exit 0

# JSON-escape the file: backslashes first, then double quotes, then fold the
# whole thing into one line with literal \n escapes. No jq: Git Bash on Windows
# ships without it, and that dependency is exactly what made the intercept hook
# inert on Windows before the core binary took over its parsing.
escaped=$(
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' "$SRC" \
        | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g'
) || exit 0
[ -n "$escaped" ] || exit 0

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$escaped"
