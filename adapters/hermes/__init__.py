"""slashwork Hermes adapter.

Routes self-contained ``delegate_task`` spawns to the slashwork offload network
through the shared ``slashwork-offload`` core binary, and adds a
``slashwork-earn`` command to run other users' tasks for credits.

    Install:  hermes plugins install slashwork-sh/hermes-plugin
    Enable:   add "slashwork" to plugins.enabled

The offload/earn protocol (classify, secret-scan, POST, long-poll, claim,
submit, goal parsing) lives entirely in the core binary, so the routing logic
never drifts across harnesses. This shim only maps Hermes's hook surface onto
it. See docs/superpowers/specs/2026-07-30-multi-harness-adapters-live-api-design.md
in the coordinator repo for what that surface actually is.

Written against Hermes Agent v0.14.0:

- ``ctx.register_hook("pre_tool_call", cb)`` is the interception point. There is
  no substitution seam for ``delegate_task``: it is an agent-loop tool, so it
  never reaches ``handle_function_call``'s ``transform_tool_result`` hook. The
  only way to hand an artifact back is to block, and a block reaches the model
  as ``{"error": <message>}``.
- Because the artifact arrives error-shaped, a model can read it as a failure
  and delegate the same work again. The retry guard below answers a given
  delegation once; a repeat runs locally instead of posting and paying twice.
- ``ctx.dispatch_tool`` is the documented way for a plugin command to run
  ``delegate_task`` itself, which is what the earn loop uses.
"""

from __future__ import annotations

import collections
import hashlib
import json
import os
import shutil
import subprocess
import time

HARNESS = "hermes"
SPAWN_TOOL = "delegate_task"
# Bounds a hung core. It sits above the core's own ~200s wall-clock cap, so the
# core returns `local` on its own first; this only catches a wedged process.
_ROUTE_TIMEOUT_SECS = 210
# How many answered delegations the retry guard remembers. Bounded so a long
# session cannot grow it without limit; oldest keys fall off first.
_ANSWERED_LIMIT = 256
_ANSWERED = collections.OrderedDict()
# The goal a bare `slashwork-earn` runs with, matching /earn's scaffolded default.
DEFAULT_GOAL = "30m"


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


# --- routing decisions (pure) ---


def is_single_delegation(args):
    """v1 intercepts one goal at a time. A ``tasks`` array is a fan-out batch and
    passes through untouched, so the parent keeps its concurrency and its
    per-task toolsets."""
    tasks = args.get("tasks")
    return not (isinstance(tasks, list) and tasks)


def spawn_prompt(args):
    """Flatten a ``delegate_task`` call into the single prompt the core
    classifies and the earner runs. Hermes splits the ask across ``goal`` and
    ``context``, and the context is where the file paths and constraints live,
    so dropping it would route a task nobody can complete."""
    goal = (args.get("goal") or "").strip()
    context = (args.get("context") or "").strip()
    if goal and context:
        return f"{goal}\n\n{context}"
    return goal or context


def route_envelope(args):
    """Build the core ``route`` envelope from a ``delegate_task`` args dict."""
    return {
        "harness": HARNESS,
        "tool_name": SPAWN_TOOL,
        "spawn": {"prompt": spawn_prompt(args)},
    }


def delegation_key(args, task_id=""):
    """Stable identity for one delegation, used by the retry guard. Keyed on the
    session/task id plus the delegation's own fields, so two different sessions
    asking the same thing are still two delegations."""
    payload = json.dumps(
        {
            "task_id": task_id or "",
            "goal": args.get("goal") or "",
            "context": args.get("context") or "",
            "toolsets": args.get("toolsets") or [],
        },
        sort_keys=True,
        ensure_ascii=False,
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def already_answered(key, store=None):
    """True when this delegation was already answered from the network. The
    caller then runs it locally: the artifact went back once, and a second
    round trip would post and pay for the same work twice."""
    store = _ANSWERED if store is None else store
    return key in store


def remember_answered(key, store=None):
    """Record an answered delegation, evicting the oldest past the cap."""
    store = _ANSWERED if store is None else store
    store[key] = True
    while len(store) > _ANSWERED_LIMIT:
        store.popitem(last=False)


# --- core binary plumbing ---


def run_core(args, binary=None, stdin=None, runner=subprocess.run, timeout=None):
    """Run the core binary. Returns ``(returncode, stdout, stderr)`` and never
    raises: every failure is a returncode the caller treats as "run locally"."""
    binary = binary or core_binary()
    if not binary:
        return (1, "", "slashwork-offload not found")
    try:
        proc = runner(
            [binary, *args],
            input=stdin,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except Exception as exc:  # missing binary, timeout, crash
        return (1, "", str(exc))
    return (proc.returncode, proc.stdout or "", proc.stderr or "")


def run_route(envelope, binary, runner=subprocess.run):
    """Run ``slashwork-offload route`` with ``envelope`` on stdin and return the
    decision dict. Any failure (missing binary, timeout, crash, non-JSON) yields
    ``{"decision": "local"}`` so the spawn always falls back to a local run."""
    if not binary:
        return {"decision": "local", "reason": "slashwork-offload not found"}
    code, stdout, _ = run_core(
        ["route"],
        binary=binary,
        stdin=json.dumps(envelope),
        runner=runner,
        timeout=_ROUTE_TIMEOUT_SECS,
    )
    if code != 0:
        return {"decision": "local", "reason": "route failed"}
    try:
        decision = json.loads(stdout)
    except Exception:
        return {"decision": "local", "reason": "bad route output"}
    if not isinstance(decision, dict):
        return {"decision": "local", "reason": "bad route output"}
    return decision


def offload_result(args, task_id="", binary=None, runner=subprocess.run, store=None):
    """Try to offload one ``delegate_task``. Returns the untrusted-content
    wrapped artifact to hand back, or ``None`` to run locally (fan-out, a repeat
    of an already-answered delegation, not routable, cold pool, or any error)."""
    if not is_single_delegation(args):
        return None
    key = delegation_key(args, task_id)
    if already_answered(key, store):
        return None
    decision = run_route(route_envelope(args), binary or core_binary(), runner)
    if decision.get("decision") != "artifact":
        return None
    # The core owns the untrusted-content wrapper (invariant 2), including the
    # line that says the delegation is already complete; return it verbatim so
    # the parent model treats the artifact as data, never as instructions.
    wrapped = decision.get("wrapped") or decision.get("artifact") or ""
    if not wrapped:
        return None
    remember_answered(key, store)
    return wrapped


def worker_prompt(task_id, prompt):
    """Prefix a claimed task's prompt with its ``task_id`` marker so the core's
    classifier exempts the worker's own delegation from re-routing (invariant 1),
    matching what the intercept hook and submit hook key on."""
    return f"task_id: {task_id}\n{prompt}"


def result_text(result):
    """Extract the artifact text from a ``delegate_task`` result. A single
    delegation returns ``{"results": [{"status", "summary", "output"}], ...}``
    as a JSON string; older shapes and bare strings are handled too."""
    if isinstance(result, str):
        try:
            parsed = json.loads(result)
        except Exception:
            return result
        return result_text(parsed)
    if isinstance(result, dict):
        results = result.get("results")
        if isinstance(results, list) and results:
            first = results[0]
            if isinstance(first, dict):
                for key in ("output", "summary", "result", "text"):
                    value = first.get(key)
                    if isinstance(value, str) and value.strip():
                        return value
        for key in ("output", "text", "content", "result", "message"):
            value = result.get(key)
            if isinstance(value, str):
                return value
    return str(result)


# --- earn loop ---


def goal_plan(spec, binary=None, runner=subprocess.run):
    """Ask the core to parse an earn goal. Returns the plan dict, or ``None``
    when the spec is not a goal. The core owns the syntax so ``90s`` / ``30m`` /
    ``200cr`` mean the same thing in every harness."""
    code, stdout, _ = run_core(["goal", spec], binary=binary, runner=runner)
    if code != 0:
        return None
    try:
        plan = json.loads(stdout)
    except Exception:
        return None
    return plan if isinstance(plan, dict) else None


def core_credits(binary=None, runner=subprocess.run):
    """The signed-in earner's credit balance, or ``None`` if it cannot be read."""
    code, stdout, _ = run_core(["credits"], binary=binary, runner=runner)
    if code != 0:
        return None
    try:
        return json.loads(stdout).get("credits")
    except Exception:
        return None


def earn_loop(run_task, plan, binary=None, runner=subprocess.run, clock=time.monotonic):
    """Claim, run, and submit until the goal is met.

    ``run_task(prompt)`` runs one task locally and returns the artifact text;
    the harness supplies it. Every exit is a normal stop: the deadline passes,
    the credits target is reached, or a claim comes back empty because the queue
    stayed quiet. Returns a summary dict for the caller to report."""
    seconds = plan.get("seconds") or plan.get("ceiling_seconds") or 0
    target = plan.get("target")
    baseline = None
    if target is not None:
        baseline = core_credits(binary, runner)
        if baseline is None:
            return {"tasks": 0, "submitted": 0, "stopped": "no credit baseline"}

    deadline = clock() + seconds
    tasks = submitted = 0
    stopped = "goal met"
    while True:
        remaining = int(deadline - clock())
        if remaining <= 0:
            stopped = "time budget spent"
            break
        code, stdout, _ = run_core(
            ["claim", "--timeout", str(remaining)], binary=binary, runner=runner
        )
        if code != 0 or not stdout.strip():
            stopped = "no task claimed"
            break
        try:
            job = json.loads(stdout)
        except Exception:
            stopped = "could not parse the claimed job"
            break
        task_id = job.get("task_id")
        if not task_id:
            stopped = "claimed job had no task id"
            break

        artifact = run_task(worker_prompt(task_id, job.get("prompt", "")))
        tasks += 1
        code, _, _ = run_core(["submit", task_id], binary=binary, stdin=artifact, runner=runner)
        if code == 0:
            submitted += 1

        if target is not None:
            current = core_credits(binary, runner)
            if current is not None and current - baseline >= target:
                break

    return {"tasks": tasks, "submitted": submitted, "stopped": stopped}


# --- Hermes glue ---


def _offload_hook(tool_name=None, args=None, task_id="", **_kwargs):
    """Hermes ``pre_tool_call`` hook. Returns a block directive carrying the
    artifact when the network answered, and ``None`` (run locally) for every
    other tool, every fan-out, every repeat, and every failure."""
    try:
        if tool_name != SPAWN_TOOL:
            return None
        wrapped = offload_result(args if isinstance(args, dict) else {}, task_id)
        if not wrapped:
            return None
        return {"action": "block", "message": wrapped}
    except Exception:
        # Hermes swallows hook exceptions, but never rely on that: a bug here
        # must degrade to a normal local delegation.
        return None


def run_earn(ctx, raw_args=""):
    """``/slashwork-earn [goal]``: claim, run, and submit other users' tasks
    until the goal is met. The goal is a time budget (``90s``, ``30m``, ``2h``)
    or the credits earned this run (``200cr``); it defaults to 30m."""
    binary = core_binary()
    if not binary:
        return "slashwork-offload not found; install the core binary first."
    words = (raw_args or "").split()
    spec = words[0] if words else DEFAULT_GOAL
    plan = goal_plan(spec, binary)
    if not plan:
        # Either the spec is not a goal or the core binary could not run; the
        # adapter cannot tell those apart from one exit code, so say both.
        return (
            f"could not plan the run: '{spec}' is not a goal, or {binary} could not run. "
            "Goals are a time budget (90s, 30m, 2h) or credits earned this run (200cr)."
        )

    def run_task(prompt):
        # dispatch_tool is the documented way for a plugin command to run a
        # tool with parent-agent context. It goes straight to the registry, so
        # the pre_tool_call hook above never sees the worker's own delegation.
        return result_text(ctx.dispatch_tool(SPAWN_TOOL, {"goal": prompt}))

    summary = earn_loop(run_task, plan, binary)
    return (
        f"slashwork-earn: ran {summary['tasks']} task(s), "
        f"submitted {summary['submitted']} ({summary['stopped']})."
    )


def make_earn_command(ctx):
    """Build the ``/slashwork-earn`` handler. Hermes calls plugin commands as
    ``handler(raw_args: str) -> str``, so the plugin context is closed over here
    rather than passed in."""

    def slashwork_earn(raw_args=""):
        return run_earn(ctx, raw_args)

    return slashwork_earn


def register(ctx):
    """Plugin entrypoint. Hermes calls this to wire the adapter in: a
    ``pre_tool_call`` hook for offloading and the ``slashwork-earn`` command."""
    ctx.register_hook("pre_tool_call", _offload_hook)
    ctx.register_command(
        "slashwork-earn",
        make_earn_command(ctx),
        description="Earn slashwork credits by running other users' offloaded tasks",
        args_hint="<90s|30m|2h|200cr>",
    )
