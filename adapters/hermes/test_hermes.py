"""Unit tests for the slashwork Hermes adapter.

These pin the contracts the adapter has with Hermes Agent v0.14.0, so a drift in
either direction fails here rather than in a live session:

- the ``pre_tool_call`` kwargs signature and its ``{"action": "block"}`` result
- ``delegate_task``'s real args (goal, context, toolsets, tasks[])
- the retry guard, which is what keeps an error-shaped artifact from being
  posted and paid for twice
- the earn goal loop

The core binary is stubbed throughout; nothing here touches the network. Run:

    python3 -m unittest adapters/hermes/test_hermes.py
"""

import collections
import importlib.util
import json
import os
import unittest
from collections import namedtuple

# Load __init__.py as a standalone module (it is a Hermes plugin package, not on
# the import path). Stdlib-only, no side effects on import.
_spec = importlib.util.spec_from_file_location(
    "slashwork_hermes", os.path.join(os.path.dirname(__file__), "__init__.py")
)
hermes = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hermes)

FakeProc = namedtuple("FakeProc", ["stdout", "returncode", "stderr"])


def stub_runner(stdout, returncode=0):
    """A subprocess.run stand-in that returns a canned result."""

    def runner(cmd, input=None, capture_output=None, text=None, timeout=None):
        return FakeProc(stdout=stdout, returncode=returncode, stderr="")

    return runner


def scripted_runner(script):
    """A subprocess.run stand-in driven by a list of (subcommand, stdout, code).

    Each call pops the next entry and asserts the subcommand matches, so a test
    states the exact core calls it expects in order. Records the stdin it saw.
    """
    calls = []

    def runner(cmd, input=None, capture_output=None, text=None, timeout=None):
        expected, stdout, code = script.pop(0)
        assert cmd[1] == expected, f"expected core call {expected!r}, got {cmd[1]!r}"
        calls.append({"args": cmd[1:], "stdin": input})
        return FakeProc(stdout=stdout, returncode=code, stderr="")

    runner.calls = calls
    return runner


ARTIFACT = json.dumps(
    {"decision": "artifact", "wrapped": "ALREADY COMPLETE. UNTRUSTED: the answer"}
)
LOCAL = json.dumps({"decision": "local", "reason": "cold pool"})


class SpawnPromptTests(unittest.TestCase):
    def test_goal_and_context_both_reach_the_prompt(self):
        # Context carries the paths and constraints; dropping it would route a
        # task the earner cannot complete.
        p = hermes.spawn_prompt({"goal": "compare the options", "context": "for a Rust CLI"})
        self.assertIn("compare the options", p)
        self.assertIn("for a Rust CLI", p)

    def test_goal_only_and_context_only(self):
        self.assertEqual(hermes.spawn_prompt({"goal": "g"}), "g")
        self.assertEqual(hermes.spawn_prompt({"context": "c"}), "c")
        self.assertEqual(hermes.spawn_prompt({}), "")

    def test_envelope_tags_the_harness_and_tool(self):
        env = hermes.route_envelope({"goal": "do it"})
        self.assertEqual(env["harness"], "hermes")
        self.assertEqual(env["tool_name"], "delegate_task")
        self.assertEqual(env["spawn"]["prompt"], "do it")


class SingleDelegationTests(unittest.TestCase):
    def test_a_bare_goal_is_a_single_delegation(self):
        self.assertTrue(hermes.is_single_delegation({"goal": "g"}))
        self.assertTrue(hermes.is_single_delegation({"goal": "g", "tasks": []}))

    def test_a_tasks_array_is_fan_out(self):
        self.assertFalse(hermes.is_single_delegation({"tasks": [{"goal": "a"}, {"goal": "b"}]}))


class RunRouteTests(unittest.TestCase):
    def test_missing_binary_is_local(self):
        self.assertEqual(hermes.run_route({}, None)["decision"], "local")

    def test_artifact_passthrough(self):
        d = hermes.run_route({}, "bin", stub_runner(ARTIFACT))
        self.assertEqual(d["decision"], "artifact")

    def test_non_json_output_is_local(self):
        self.assertEqual(hermes.run_route({}, "bin", stub_runner("not json"))["decision"], "local")

    def test_non_dict_output_is_local(self):
        self.assertEqual(hermes.run_route({}, "bin", stub_runner("[1, 2]"))["decision"], "local")

    def test_nonzero_exit_is_local(self):
        d = hermes.run_route({}, "bin", stub_runner(ARTIFACT, returncode=1))
        self.assertEqual(d["decision"], "local")

    def test_exception_is_local(self):
        def boom(*_a, **_k):
            raise RuntimeError("crash")

        self.assertEqual(hermes.run_route({}, "bin", boom)["decision"], "local")


class OffloadResultTests(unittest.TestCase):
    def setUp(self):
        self.store = collections.OrderedDict()

    def test_artifact_returns_wrapped(self):
        r = hermes.offload_result(
            {"goal": "g"}, binary="bin", runner=stub_runner(ARTIFACT), store=self.store
        )
        self.assertIn("UNTRUSTED", r)

    def test_local_returns_none(self):
        r = hermes.offload_result(
            {"goal": "g"}, binary="bin", runner=stub_runner(LOCAL), store=self.store
        )
        self.assertIsNone(r)

    def test_fan_out_returns_none_without_routing(self):
        def must_not_run(*_a, **_k):
            raise AssertionError("fan-out must not route")

        r = hermes.offload_result(
            {"tasks": [{"goal": "a"}]}, binary="bin", runner=must_not_run, store=self.store
        )
        self.assertIsNone(r)


class RetryGuardTests(unittest.TestCase):
    """The artifact reaches the model error-shaped, so a model may retry the same
    delegation. The second attempt has to run locally, not post a second task."""

    def setUp(self):
        self.store = collections.OrderedDict()
        self.args = {"goal": "compare the options", "context": "ctx"}

    def test_the_same_delegation_is_answered_only_once(self):
        first = hermes.offload_result(
            self.args, task_id="s1", binary="bin", runner=stub_runner(ARTIFACT), store=self.store
        )
        self.assertIsNotNone(first)

        def must_not_run(*_a, **_k):
            raise AssertionError("a repeat delegation must not route again")

        second = hermes.offload_result(
            self.args, task_id="s1", binary="bin", runner=must_not_run, store=self.store
        )
        self.assertIsNone(second)

    def test_a_different_session_is_a_different_delegation(self):
        hermes.offload_result(
            self.args, task_id="s1", binary="bin", runner=stub_runner(ARTIFACT), store=self.store
        )
        again = hermes.offload_result(
            self.args, task_id="s2", binary="bin", runner=stub_runner(ARTIFACT), store=self.store
        )
        self.assertIsNotNone(again)

    def test_a_local_decision_is_not_remembered(self):
        # Only an answered delegation is remembered; a cold pool must not stop
        # the next identical spawn from trying the network.
        hermes.offload_result(
            self.args, task_id="s1", binary="bin", runner=stub_runner(LOCAL), store=self.store
        )
        retried = hermes.offload_result(
            self.args, task_id="s1", binary="bin", runner=stub_runner(ARTIFACT), store=self.store
        )
        self.assertIsNotNone(retried)

    def test_the_guard_is_bounded(self):
        for i in range(hermes._ANSWERED_LIMIT + 10):
            hermes.remember_answered(f"key-{i}", self.store)
        self.assertLessEqual(len(self.store), hermes._ANSWERED_LIMIT)


class PreToolCallHookTests(unittest.TestCase):
    """Hermes calls the hook with kwargs and reads a block dict back."""

    def setUp(self):
        self._orig = hermes.offload_result

    def tearDown(self):
        hermes.offload_result = self._orig

    def test_non_delegate_tool_is_ignored(self):
        def must_not_run(*_a, **_k):
            raise AssertionError("only delegate_task routes")

        hermes.offload_result = must_not_run
        self.assertIsNone(
            hermes._offload_hook(tool_name="read_file", args={"path": "x"}, task_id="s1")
        )

    def test_artifact_becomes_a_block_directive(self):
        hermes.offload_result = lambda args, task_id="": "WRAPPED"
        out = hermes._offload_hook(tool_name="delegate_task", args={"goal": "g"}, task_id="s1")
        self.assertEqual(out, {"action": "block", "message": "WRAPPED"})

    def test_local_returns_none_so_the_delegation_runs(self):
        hermes.offload_result = lambda args, task_id="": None
        out = hermes._offload_hook(tool_name="delegate_task", args={"goal": "g"}, task_id="s1")
        self.assertIsNone(out)

    def test_a_raising_offload_still_runs_locally(self):
        def boom(*_a, **_k):
            raise RuntimeError("crash")

        hermes.offload_result = boom
        self.assertIsNone(
            hermes._offload_hook(tool_name="delegate_task", args={"goal": "g"}, task_id="s1")
        )

    def test_extra_kwargs_are_tolerated(self):
        # Hermes passes session_id and tool_call_id too; new kwargs must not
        # break the hook.
        hermes.offload_result = lambda args, task_id="": None
        self.assertIsNone(
            hermes._offload_hook(
                tool_name="delegate_task",
                args={"goal": "g"},
                task_id="s1",
                session_id="sess",
                tool_call_id="call-1",
                something_new=True,
            )
        )


class WorkerAndResultTests(unittest.TestCase):
    def test_worker_prompt_marker(self):
        p = hermes.worker_prompt("abc-123", "solve this")
        self.assertTrue(p.startswith("task_id: abc-123\n"))
        self.assertIn("solve this", p)

    def test_result_text_reads_the_delegate_task_shape(self):
        payload = json.dumps(
            {"results": [{"status": "ok", "summary": "s", "output": "the artifact"}]}
        )
        self.assertEqual(hermes.result_text(payload), "the artifact")

    def test_result_text_falls_back_to_summary(self):
        payload = {"results": [{"status": "ok", "summary": "just a summary"}]}
        self.assertEqual(hermes.result_text(payload), "just a summary")

    def test_result_text_other_shapes(self):
        self.assertEqual(hermes.result_text("hi"), "hi")
        self.assertEqual(hermes.result_text({"output": "o"}), "o")
        self.assertEqual(hermes.result_text(123), "123")


class GoalPlanTests(unittest.TestCase):
    def test_plan_comes_from_the_core(self):
        plan = hermes.goal_plan(
            "30m", binary="bin", runner=stub_runner('{"mode":"time","seconds":1800}')
        )
        self.assertEqual(plan["seconds"], 1800)

    def test_a_rejected_goal_is_none(self):
        self.assertIsNone(
            hermes.goal_plan("forever", binary="bin", runner=stub_runner("", returncode=2))
        )


class EarnLoopTests(unittest.TestCase):
    def test_time_goal_runs_until_the_deadline(self):
        job = json.dumps({"task_id": "t-1", "prompt": "do the thing"})
        runner = scripted_runner(
            [("claim", job, 0), ("submit", "", 0), ("claim", job, 0), ("submit", "", 0)]
        )
        # One tick sets the deadline, then one per loop pass; the last is past it.
        ticks = iter([0, 0, 10, 999])
        summary = hermes.earn_loop(
            lambda prompt: f"artifact for {prompt}",
            {"mode": "time", "seconds": 60},
            binary="bin",
            runner=runner,
            clock=lambda: next(ticks),
        )
        self.assertEqual(summary["tasks"], 2)
        self.assertEqual(summary["submitted"], 2)
        self.assertEqual(summary["stopped"], "time budget spent")
        # The claimed task's artifact is what gets submitted, marked with its id.
        self.assertIn("task_id: t-1", runner.calls[1]["stdin"])

    def test_credits_goal_stops_once_the_target_is_reached(self):
        job = json.dumps({"task_id": "t-1", "prompt": "p"})
        runner = scripted_runner(
            [
                ("credits", '{"credits":1000}', 0),  # baseline
                ("claim", job, 0),
                ("submit", "", 0),
                ("credits", '{"credits":1250}', 0),  # +250 clears the 200 target
            ]
        )
        ticks = iter([0, 0, 5])
        summary = hermes.earn_loop(
            lambda _p: "artifact",
            {"mode": "credits", "target": 200, "ceiling_seconds": 86400},
            binary="bin",
            runner=runner,
            clock=lambda: next(ticks),
        )
        self.assertEqual(summary["tasks"], 1)
        self.assertEqual(summary["stopped"], "goal met")

    def test_an_empty_claim_ends_the_run(self):
        runner = scripted_runner([("claim", "", 4)])
        ticks = iter([0, 0])
        summary = hermes.earn_loop(
            lambda _p: "artifact",
            {"mode": "time", "seconds": 60},
            binary="bin",
            runner=runner,
            clock=lambda: next(ticks),
        )
        self.assertEqual(summary["tasks"], 0)
        self.assertEqual(summary["stopped"], "no task claimed")

    def test_a_failed_submit_still_counts_the_task_but_not_the_submission(self):
        job = json.dumps({"task_id": "t-1", "prompt": "p"})
        runner = scripted_runner([("claim", job, 0), ("submit", "", 1)])
        ticks = iter([0, 0, 999])
        summary = hermes.earn_loop(
            lambda _p: "artifact",
            {"mode": "time", "seconds": 60},
            binary="bin",
            runner=runner,
            clock=lambda: next(ticks),
        )
        self.assertEqual(summary["tasks"], 1)
        self.assertEqual(summary["submitted"], 0)


class RegisterTests(unittest.TestCase):
    """register() has to call the methods Hermes's PluginContext actually has."""

    class FakeCtx:
        def __init__(self):
            self.hooks = {}
            self.commands = {}
            self.dispatched = []

        def register_hook(self, name, callback):
            self.hooks[name] = callback

        def register_command(self, name, handler, description="", args_hint=""):
            self.commands[name] = handler

        def dispatch_tool(self, tool_name, args, **kwargs):
            self.dispatched.append((tool_name, args))
            return json.dumps({"results": [{"output": "worker output"}]})

    def test_registers_the_pre_tool_call_hook_and_the_command(self):
        ctx = self.FakeCtx()
        hermes.register(ctx)
        self.assertIn("pre_tool_call", ctx.hooks)
        self.assertIn("slashwork-earn", ctx.commands)

    def test_the_command_handler_takes_a_raw_string(self):
        # Hermes calls plugin commands as handler(raw_args: str).
        ctx = self.FakeCtx()
        hermes.register(ctx)
        handler = ctx.commands["slashwork-earn"]
        orig = hermes.core_binary
        hermes.core_binary = lambda: None  # no binary: a one-line message, no loop
        try:
            out = handler("30m")
        finally:
            hermes.core_binary = orig
        self.assertIn("slashwork-offload not found", out)


if __name__ == "__main__":
    unittest.main()
