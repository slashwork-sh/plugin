#!/usr/bin/env sh
# PreToolUse(Task|Agent) hook for the slashwork offload network.
#
# A shim. It does two things: honour the opt-out, and find the shared
# `slashwork-offload` core binary. Everything else, parsing the PreToolUse
# envelope, the once-per-session consent disclosure, classification, dispatch,
# the savings receipt, and shaping the `deny` that hands an artifact back in
# place of the local spawn, happens in `slashwork-offload hook`
# (offload/src/hook.rs), which reads the envelope on stdin and writes the hook's
# JSON on stdout.
#
# That logic used to live here and ran on `jq`. Git Bash on Windows ships no
# `jq`, so this hook hit `command -v jq || exit 0` and every spawn ran locally
# with no explanation. Moving it into the core removed the last dependency
# routing had beyond the binary the SessionStart hook installs.
#
# The iron rule is unchanged: the failure mode is always "ran locally like it
# always did," never "hung" and never "ran worse." Exiting 0 with no output lets
# Claude Code spawn the subagent normally, and that is what every path here
# except a returned artifact does.
#
# Docs: docs/pivot-offload-network.md ("The dispatch loop"),
#       docs/openclaw-hermes-hooks.md (the shared core the adapters all call).
set -u

# Opt-out gate. On by default; exactly "0" means this session or project turned
# routing off (/work off), so do nothing at all.
[ "${SLASHWORK_INTERCEPT:-}" != "0" ] || exit 0

# Locate the core: SLASHWORK_OFFLOAD_BIN, then the install dir the sibling
# install-core.sh SessionStart hook populates, then PATH. Windows builds carry
# .exe. No binary means inert (local), exactly how this hook behaves before
# sign-in.
CORE="${SLASHWORK_OFFLOAD_BIN:-}"
if [ -z "$CORE" ]; then
    for candidate in \
        "$HOME/.slashwork/bin/slashwork-offload" \
        "$HOME/.slashwork/bin/slashwork-offload.exe"; do
        if [ -x "$candidate" ]; then
            CORE="$candidate"
            break
        fi
    done
fi
[ -n "$CORE" ] || CORE=$(command -v slashwork-offload 2>/dev/null)
[ -n "$CORE" ] || exit 0

# Hand the envelope on stdin to the core and let its stdout be this hook's.
# Not `exec`: if the binary turns out not to be runnable, exec would replace the
# shell and surface a non-zero hook failure to the session, where the contract
# is a clean fall-through to the local spawn.
"$CORE" hook || exit 0
