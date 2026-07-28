"""slashwork Hermes adapter.

Routes self-contained ``delegate_task`` spawns to the slashwork offload network
through the shared ``slashwork-offload`` core binary, and adds a
``slashwork-earn`` command to run other users' tasks for credits.

    Install:  hermes plugins install slashwork/hermes-plugin
    Enable:   add "slashwork" to plugins.enabled

The offload/earn protocol (classify, secret-scan, POST, long-poll, claim,
submit) lives entirely in the core binary, so the routing logic never drifts
across harnesses. This shim only maps Hermes's middleware surface onto it. See
docs/openclaw-hermes-hooks.md in the coordinator repo.

The Hermes-facing glue (register, the middleware/command signatures, the
delegate_task result shape) is written to the researched Hermes plugin API and
should be validated against a live Hermes install; the routing decisions below
are pure and unit-tested.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess

HARNESS = "hermes"
SPAWN_TOOL = "delegate_task"
# Bounds a hung core. It sits above the core's own ~200s wall-clock cap, so the
# core returns `local` on its own first; this only catches a wedged process.
_ROUTE_TIMEOUT_SECS = 210


def core_binary():
    """Locate the ``slashwork-offload`` binary: ``SLASHWORK_OFFLOAD_BIN`` first,
    then the install dir ``~/.slashwork/bin`` that ``offload/dist/install.sh``
    populates, then ``PATH``. Returns ``None`` when it is not installed."""
    override = os.environ.get("SLASHWORK_OFFLOAD_BIN")
    if override:
        return override
    installed = os.path.join(os.path.expanduser("~"), ".slashwork", "bin", "slashwork-offload")
    if os.access(installed, os.X_OK):
        return installed
    return shutil.which("slashwork-offload")


def is_leaf(args):
    """v1 intercepts only single-goal leaf delegations. Fan-out batches and
    orchestrator spawns (``role`` other than ``leaf``) pass through untouched."""
    return args.get("role", "leaf") == "leaf"


def route_envelope(args):
    """Build the core ``route`` envelope from a ``delegate_task`` args dict. v1
    sends only the prompt; the core inlines no files."""
    prompt = args.get("prompt") or args.get("task") or args.get("goal") or ""
    return {"harness": HARNESS, "tool_name": SPAWN_TOOL, "spawn": {"prompt": prompt}}


def run_route(envelope, binary, runner=subprocess.run):
    """Run ``slashwork-offload route`` with ``envelope`` on stdin and return the
    decision dict. Any failure (missing binary, timeout, crash, non-JSON) yields
    ``{"decision": "local"}`` so the spawn always falls back to a local run."""
    if not binary:
        return {"decision": "local", "reason": "slashwork-offload not found"}
    try:
        proc = runner(
            [binary, "route"],
            input=json.dumps(envelope),
            capture_output=True,
            text=True,
            timeout=_ROUTE_TIMEOUT_SECS,
        )
        decision = json.loads(proc.stdout)
    except Exception:
        return {"decision": "local", "reason": "route failed"}
    if not isinstance(decision, dict):
        return {"decision": "local", "reason": "bad route output"}
    return decision


def offload_result(args, binary=None, runner=subprocess.run):
    """Try to offload a leaf ``delegate_task``. Returns the untrusted-content
    wrapped artifact string to hand back as the tool result, or ``None`` to run
    locally (non-leaf, not routable, cold pool, or any error)."""
    if not is_leaf(args):
        return None
    binary = binary or core_binary()
    decision = run_route(route_envelope(args), binary, runner)
    if decision.get("decision") == "artifact":
        # The core owns the untrusted-content wrapper (invariant 2); return it
        # verbatim so the parent model treats the artifact as data, never as
        # instructions. Fall back to the raw artifact if an older core omits it.
        return decision.get("wrapped") or decision.get("artifact") or ""
    return None


def worker_prompt(task_id, prompt):
    """Prefix a claimed task's prompt with its ``task_id`` marker so the core's
    classifier exempts the worker's own delegation from re-routing (invariant 1),
    matching what the intercept hook and submit hook key on."""
    return f"task_id: {task_id}\n{prompt}"


def result_text(result):
    """Extract the text of a ``delegate_task`` result across the shapes Hermes
    may return: a bare string, or a dict carrying it under a common key."""
    if isinstance(result, str):
        return result
    if isinstance(result, dict):
        for key in ("output", "text", "content", "result", "message"):
            value = result.get(key)
            if isinstance(value, str):
                return value
    return str(result)


# --- Hermes glue (validate against a live Hermes install) ---


def _offload_middleware(tool_name, args, next_call):
    """Hermes ``tool_execution`` middleware. Never blocks the spawn: a
    non-``delegate_task`` tool, a non-leaf delegation, or any offload failure runs
    locally via ``next_call``. A routed artifact short-circuits with a synthetic
    successful result."""
    if tool_name != SPAWN_TOOL:
        return next_call(args)
    result = offload_result(args)
    if result is None:
        return next_call(args)
    return result


def _earn_command(ctx, argv=None):
    """``slashwork-earn``: claim one task off the queue, run it locally via
    ``delegate_task`` (the core exempts its own ``task_id``-marked spawn), and
    submit the result through the core."""
    binary = core_binary()
    if not binary:
        return "slashwork-offload not found; install the core binary first."
    claim = subprocess.run(
        [binary, "claim", "--timeout", "1800"], capture_output=True, text=True
    )
    if claim.returncode != 0 or not claim.stdout.strip():
        return "no task claimed."
    try:
        job = json.loads(claim.stdout)
    except json.JSONDecodeError:
        return "could not parse the claimed job."
    task_id = job.get("task_id")
    if not task_id:
        return "claimed job had no task id."
    result = ctx.delegate_task(prompt=worker_prompt(task_id, job.get("prompt", "")), role="leaf")
    submit = subprocess.run(
        [binary, "submit", task_id],
        input=result_text(result),
        capture_output=True,
        text=True,
    )
    if submit.returncode != 0:
        return f"ran task {task_id} but the submit failed: {submit.stderr.strip()}"
    return f"submitted task {task_id}."


def register(ctx):
    """Plugin entrypoint. Hermes calls this to wire the adapter in: a
    ``tool_execution`` middleware for offloading and the ``slashwork-earn``
    command for earning."""
    ctx.register_middleware("tool_execution", _offload_middleware)
    ctx.register_command("slashwork-earn", _earn_command)
