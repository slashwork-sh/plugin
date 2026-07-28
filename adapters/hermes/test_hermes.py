"""Unit tests for the slashwork Hermes adapter's pure routing logic.

The Hermes-facing glue (register/middleware wiring) needs a live Hermes install
to exercise; these tests cover everything decidable without one, using an
injected subprocess stub in place of the real slashwork-offload binary (the
design's "stub slashwork-offload executable" approach). Run:

    python3 -m unittest adapters/hermes/test_hermes.py
"""

import importlib.util
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


class RouteEnvelopeTests(unittest.TestCase):
    def test_tags_hermes_and_prompt(self):
        env = hermes.route_envelope({"prompt": "do it"})
        self.assertEqual(env["harness"], "hermes")
        self.assertEqual(env["tool_name"], "delegate_task")
        self.assertEqual(env["spawn"]["prompt"], "do it")

    def test_falls_back_to_task_or_goal(self):
        self.assertEqual(hermes.route_envelope({"task": "t"})["spawn"]["prompt"], "t")
        self.assertEqual(hermes.route_envelope({"goal": "g"})["spawn"]["prompt"], "g")
        self.assertEqual(hermes.route_envelope({})["spawn"]["prompt"], "")


class LeafTests(unittest.TestCase):
    def test_default_and_explicit_leaf(self):
        self.assertTrue(hermes.is_leaf({}))
        self.assertTrue(hermes.is_leaf({"role": "leaf"}))

    def test_non_leaf(self):
        self.assertFalse(hermes.is_leaf({"role": "orchestrator"}))


class RunRouteTests(unittest.TestCase):
    def test_missing_binary_is_local(self):
        self.assertEqual(hermes.run_route({}, None)["decision"], "local")

    def test_artifact_passthrough(self):
        d = hermes.run_route({}, "bin", stub_runner('{"decision":"artifact","wrapped":"W"}'))
        self.assertEqual(d["decision"], "artifact")

    def test_non_json_output_is_local(self):
        self.assertEqual(hermes.run_route({}, "bin", stub_runner("not json"))["decision"], "local")

    def test_non_dict_output_is_local(self):
        self.assertEqual(hermes.run_route({}, "bin", stub_runner("[1, 2]"))["decision"], "local")

    def test_exception_is_local(self):
        def boom(*_a, **_k):
            raise RuntimeError("crash")

        self.assertEqual(hermes.run_route({}, "bin", boom)["decision"], "local")


class OffloadResultTests(unittest.TestCase):
    def test_artifact_returns_wrapped(self):
        r = hermes.offload_result(
            {"prompt": "p"},
            binary="bin",
            runner=stub_runner('{"decision":"artifact","wrapped":"UNTRUSTED: ans"}'),
        )
        self.assertIn("UNTRUSTED", r)

    def test_artifact_without_wrapped_falls_back_to_raw(self):
        r = hermes.offload_result(
            {"prompt": "p"},
            binary="bin",
            runner=stub_runner('{"decision":"artifact","artifact":"raw"}'),
        )
        self.assertEqual(r, "raw")

    def test_local_returns_none(self):
        r = hermes.offload_result(
            {"prompt": "p"},
            binary="bin",
            runner=stub_runner('{"decision":"local","reason":"cold pool"}'),
        )
        self.assertIsNone(r)

    def test_non_leaf_returns_none_without_routing(self):
        # A non-leaf delegation never even shells out to the core.
        def must_not_run(*_a, **_k):
            raise AssertionError("non-leaf must not route")

        r = hermes.offload_result(
            {"prompt": "p", "role": "orchestrator"}, binary="bin", runner=must_not_run
        )
        self.assertIsNone(r)


class MiddlewareTests(unittest.TestCase):
    def test_passthrough_non_delegate_tool(self):
        seen = {}

        def next_call(args):
            seen["args"] = args
            return "local-result"

        out = hermes._offload_middleware("some_other_tool", {"x": 1}, next_call)
        self.assertEqual(out, "local-result")
        self.assertEqual(seen["args"], {"x": 1})

    def test_delegate_short_circuits_on_artifact(self):
        orig = hermes.offload_result
        hermes.offload_result = lambda _args: "WRAPPED"
        try:
            out = hermes._offload_middleware("delegate_task", {"prompt": "p"}, lambda _a: "LOCAL")
        finally:
            hermes.offload_result = orig
        self.assertEqual(out, "WRAPPED")

    def test_delegate_runs_local_when_not_routed(self):
        orig = hermes.offload_result
        hermes.offload_result = lambda _args: None
        try:
            out = hermes._offload_middleware("delegate_task", {"prompt": "p"}, lambda _a: "LOCAL")
        finally:
            hermes.offload_result = orig
        self.assertEqual(out, "LOCAL")


class WorkerAndResultTests(unittest.TestCase):
    def test_worker_prompt_marker(self):
        p = hermes.worker_prompt("abc-123", "solve this")
        self.assertTrue(p.startswith("task_id: abc-123\n"))
        self.assertIn("solve this", p)

    def test_result_text_shapes(self):
        self.assertEqual(hermes.result_text("hi"), "hi")
        self.assertEqual(hermes.result_text({"output": "o"}), "o")
        self.assertEqual(hermes.result_text({"text": "t"}), "t")
        self.assertEqual(hermes.result_text({"message": "m"}), "m")
        self.assertEqual(hermes.result_text(123), "123")


if __name__ == "__main__":
    unittest.main()
