#!/usr/bin/env bash
# Tests the SessionStart delegation-context hook with no network.
#
# The hook's output goes straight into every session's context, so malformed
# JSON there is not a cosmetic bug: it is a broken session start for every user
# who has the plugin installed. These checks are the guard on that.
#
#   bash plugins/work/hooks/delegate-context_test.sh
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/delegate-context.sh"

fails=0
checks=0
check() { # check <label> <condition-result>
    checks=$((checks + 1))
    if [ "$2" = "0" ]; then
        printf 'PASS: %s\n' "$1"
    else
        printf 'FAIL: %s\n' "$1"
        fails=$((fails + 1))
    fi
}

out="$(sh "$HOOK")"
status=$?
check "hook exits 0" "$status"

# Valid JSON is the whole contract. Everything else is downstream of it.
printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null
check "output parses as JSON" "$?"

ctx="$(printf '%s' "$out" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)"

printf '%s' "$out" | python3 -c \
    'import json,sys; sys.exit(0 if json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"]=="SessionStart" else 1)' 2>/dev/null
check "hookEventName is SessionStart" "$?"

case "$ctx" in
    *"standing request"*) check "carries the standing request" 0 ;;
    *) check "carries the standing request" 1 ;;
esac

case "$ctx" in
    *"/work off"*) check "names the way to withdraw it" 0 ;;
    *) check "names the way to withdraw it" 1 ;;
esac

# The split instruction is the part that actually moves the number. Permission
# alone does not: measured on six headless runs, Opus and Sonnet both spawned
# nothing on multi-part research and answered inline.
case "$ctx" in
    *"Split them"*) check "instructs splitting a mixed request" 0 ;;
    *) check "instructs splitting a mixed request" 1 ;;
esac

# A delegated prompt naming a path or a filename is refused by the classifier
# and runs locally, so the spawn is wasted. The text must say so.
case "$ctx" in
    *"Never put a path"*) check "warns off paths in delegated prompts" 0 ;;
    *) check "warns off paths in delegated prompts" 1 ;;
esac

# The classifier requires exactly one class signature, so a two-verb prompt
# declines. That is the least obvious rule and the easiest to violate.
case "$ctx" in
    *"ONE kind of work"*) check "requires one kind of work per task" 0 ;;
    *) check "requires one kind of work per task" 1 ;;
esac

# Missing source must degrade to silence, never to a broken session start.
tmp="$(mktemp -d)"
cp "$HOOK" "$tmp/delegate-context.sh"
out_missing="$(sh "$tmp/delegate-context.sh")"
status_missing=$?
check "exits 0 with no source file" "$status_missing"
[ -z "$out_missing" ]
check "prints nothing with no source file" "$?"
rm -rf "$tmp"

if [ "$fails" -eq 0 ]; then
    printf '\nALL PASS (%d checks)\n' "$checks"
    exit 0
fi
printf '\n%d/%d FAILED\n' "$fails" "$checks"
exit 1
