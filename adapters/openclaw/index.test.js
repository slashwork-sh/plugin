// Unit tests for the slashwork OpenClaw adapter.
//
// These pin the contracts the adapter has with openclaw 2026.6.33, so a drift in
// either direction fails here rather than in a live session: the
// `before_tool_call` event shape (`toolName` / `params`), the
// `{ block, blockReason }` result, the fail-open catch-all, the subagent run
// flow the earn loop uses, and the goal loop itself.
//
// Run:  node --test adapters/openclaw/index.test.js

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  assistantText,
  beforeToolCall,
  coreCredits,
  defaultRouter,
  earnLoop,
  goalPlan,
  HOOK_TIMEOUT_MS,
  makeEarnHandler,
  offloadResult,
  register,
  routeEnvelope,
  runTaskViaSubagent,
  workerPrompt,
} from "./index.js";

// A fake router that always resolves the given decision.
const router = (decision) => async () => decision;

const ARTIFACT = {
  decision: "artifact",
  task_id: "t-1",
  artifact: "the answer",
  wrapped: "ALREADY COMPLETE. UNTRUSTED: the answer",
};

/** A `runCore` stand-in driven by a script of [subcommand, {code, stdout}]. */
function scriptedRun(script) {
  const calls = [];
  const run = async (_binary, args, stdin) => {
    const [expected, result] = script.shift();
    assert.equal(args[0], expected, `expected core call ${expected}, got ${args[0]}`);
    calls.push({ args, stdin });
    return { code: result.code ?? 0, stdout: result.stdout ?? "", stderr: "" };
  };
  run.calls = calls;
  return run;
}

test("routeEnvelope reads the sessions_spawn task parameter", () => {
  const env = routeEnvelope({ task: "do it" });
  assert.equal(env.harness, "openclaw");
  assert.equal(env.tool_name, "sessions_spawn");
  assert.equal(env.spawn.prompt, "do it");
});

test("routeEnvelope tolerates a missing or non-string task", () => {
  assert.equal(routeEnvelope({}).spawn.prompt, "");
  assert.equal(routeEnvelope(undefined).spawn.prompt, "");
  assert.equal(routeEnvelope({ task: 42 }).spawn.prompt, "");
});

test("offloadResult returns the wrapped artifact", async () => {
  const out = await offloadResult({ task: "t" }, router(ARTIFACT));
  assert.match(out, /UNTRUSTED/);
});

test("offloadResult falls back to the raw artifact when wrapped is absent", async () => {
  const out = await offloadResult({ task: "t" }, router({ decision: "artifact", artifact: "raw" }));
  assert.equal(out, "raw");
});

test("offloadResult returns null on a local decision", async () => {
  const out = await offloadResult({ task: "t" }, router({ decision: "local", reason: "cold pool" }));
  assert.equal(out, null);
});

test("beforeToolCall blocks the spawn with the artifact as the block reason", async () => {
  const out = await beforeToolCall(
    { toolName: "sessions_spawn", params: { task: "t" } },
    { router: router(ARTIFACT) },
  );
  assert.equal(out.block, true);
  assert.match(out.blockReason, /UNTRUSTED/);
});

test("beforeToolCall ignores every other tool", async () => {
  const out = await beforeToolCall(
    { toolName: "exec", params: { command: "ls" } },
    {
      router: () => {
        throw new Error("only sessions_spawn routes");
      },
    },
  );
  assert.equal(out, undefined);
});

test("beforeToolCall runs locally when the network does not answer", async () => {
  const out = await beforeToolCall(
    { toolName: "sessions_spawn", params: { task: "t" } },
    { router: router({ decision: "local" }) },
  );
  assert.equal(out, undefined);
});

test("beforeToolCall never blocks a spawn when the handler throws", async () => {
  // OpenClaw fails closed on a thrown hook, so a bug here must degrade to a
  // local spawn rather than veto it.
  const out = await beforeToolCall(
    { toolName: "sessions_spawn", params: { task: "t" } },
    {
      router: () => {
        throw new Error("boom");
      },
    },
  );
  assert.equal(out, undefined);
});

test("beforeToolCall tolerates a malformed event", async () => {
  assert.equal(await beforeToolCall(undefined, { router: router(ARTIFACT) }), undefined);
  assert.equal(
    await beforeToolCall({ toolName: "sessions_spawn" }, { router: router({ decision: "local" }) }),
    undefined,
  );
});

test("defaultRouter turns a non-zero exit into a local decision", async () => {
  const route = defaultRouter("bin", async () => ({ code: 1, stdout: "", stderr: "nope" }));
  assert.equal((await route({})).decision, "local");
});

test("defaultRouter turns unparseable output into a local decision", async () => {
  const route = defaultRouter("bin", async () => ({ code: 0, stdout: "not json", stderr: "" }));
  assert.equal((await route({})).decision, "local");
});

test("defaultRouter rejects a non-object decision", async () => {
  const route = defaultRouter("bin", async () => ({ code: 0, stdout: "[1,2]", stderr: "" }));
  assert.equal((await route({})).decision, "local");
});

test("workerPrompt marks the claimed task id", () => {
  const p = workerPrompt("abc-123", "solve this");
  assert.ok(p.startsWith("task_id: abc-123\n"));
  assert.match(p, /solve this/);
});

test("assistantText reads the last assistant message", () => {
  assert.equal(
    assistantText([
      { role: "user", content: "q" },
      { role: "assistant", content: "first" },
      { role: "assistant", content: "second" },
    ]),
    "second",
  );
});

test("assistantText joins content parts", () => {
  const messages = [
    {
      role: "assistant",
      content: [
        { type: "text", text: "part one " },
        { type: "output_text", text: "part two" },
        { type: "image", url: "ignored" },
      ],
    },
  ];
  assert.equal(assistantText(messages), "part one part two");
});

test("assistantText returns null when there is nothing to submit", () => {
  assert.equal(assistantText([]), null);
  assert.equal(assistantText([{ role: "user", content: "q" }]), null);
  assert.equal(assistantText(undefined), null);
});

test("goalPlan reads the plan from the core", async () => {
  const plan = await goalPlan("30m", "bin", scriptedRun([["goal", { stdout: '{"mode":"time","seconds":1800}' }]]));
  assert.equal(plan.seconds, 1800);
});

test("goalPlan returns null for a rejected goal", async () => {
  const plan = await goalPlan("forever", "bin", scriptedRun([["goal", { code: 2 }]]));
  assert.equal(plan, null);
});

test("coreCredits reads the balance", async () => {
  const credits = await coreCredits("bin", scriptedRun([["credits", { stdout: '{"credits":1234}' }]]));
  assert.equal(credits, 1234);
});

test("earnLoop claims, runs, and submits until the deadline", async () => {
  const job = JSON.stringify({ task_id: "t-1", prompt: "do the thing" });
  const run = scriptedRun([
    ["claim", { stdout: job }],
    ["submit", {}],
    ["claim", { stdout: job }],
    ["submit", {}],
  ]);
  const ticks = [0, 0, 10_000, 999_000];
  const summary = await earnLoop({
    runTask: async (taskId) => `artifact for ${taskId}`,
    plan: { mode: "time", seconds: 60 },
    binary: "bin",
    run,
    clock: () => ticks.shift(),
  });
  assert.equal(summary.tasks, 2);
  assert.equal(summary.submitted, 2);
  assert.equal(summary.stopped, "time budget spent");
  assert.equal(run.calls[1].stdin, "artifact for t-1");
});

test("earnLoop stops once a credits target is reached", async () => {
  const job = JSON.stringify({ task_id: "t-1", prompt: "p" });
  const run = scriptedRun([
    ["credits", { stdout: '{"credits":1000}' }],
    ["claim", { stdout: job }],
    ["submit", {}],
    ["credits", { stdout: '{"credits":1250}' }],
  ]);
  const ticks = [0, 0, 5_000];
  const summary = await earnLoop({
    runTask: async () => "artifact",
    plan: { mode: "credits", target: 200, ceiling_seconds: 86_400 },
    binary: "bin",
    run,
    clock: () => ticks.shift(),
  });
  assert.equal(summary.tasks, 1);
  assert.equal(summary.stopped, "goal met");
});

test("earnLoop ends the run when nothing is claimed", async () => {
  const run = scriptedRun([["claim", { code: 4 }]]);
  const ticks = [0, 0];
  const summary = await earnLoop({
    runTask: async () => "artifact",
    plan: { mode: "time", seconds: 60 },
    binary: "bin",
    run,
    clock: () => ticks.shift(),
  });
  assert.equal(summary.tasks, 0);
  assert.equal(summary.stopped, "no task claimed");
});

test("earnLoop does not submit an empty artifact", async () => {
  // A worker run that produced nothing must not post an empty submission: the
  // task stays claimable rather than burning its one submit on nothing.
  const job = JSON.stringify({ task_id: "t-1", prompt: "p" });
  const run = scriptedRun([["claim", { stdout: job }]]);
  const ticks = [0, 0, 999_000];
  const summary = await earnLoop({
    runTask: async () => null,
    plan: { mode: "time", seconds: 60 },
    binary: "bin",
    run,
    clock: () => ticks.shift(),
  });
  assert.equal(summary.tasks, 1);
  assert.equal(summary.submitted, 0);
});

test("runTaskViaSubagent runs, waits, and reads the answer", async () => {
  const seen = {};
  const api = {
    runtime: {
      subagent: {
        deleteSession: async ({ sessionKey }) => {
          seen.deleted = sessionKey;
        },
        run: async ({ sessionKey, message }) => {
          seen.sessionKey = sessionKey;
          seen.message = message;
          return { runId: "r-1" };
        },
        waitForRun: async ({ runId }) => {
          seen.waited = runId;
          return { status: "ok" };
        },
        getSessionMessages: async () => ({
          messages: [{ role: "assistant", content: "the worker answer" }],
        }),
      },
    },
  };
  const out = await runTaskViaSubagent(api, "t-1", "do the thing");
  assert.equal(out, "the worker answer");
  assert.equal(seen.sessionKey, "slashwork-earn-t-1");
  assert.equal(seen.waited, "r-1");
  // The task id marker keeps the worker's own spawn out of the offload path.
  assert.ok(seen.message.startsWith("task_id: t-1\n"));
});

test("runTaskViaSubagent returns null when the run does not finish cleanly", async () => {
  const api = {
    runtime: {
      subagent: {
        deleteSession: async () => {},
        run: async () => ({ runId: "r-1" }),
        waitForRun: async () => ({ status: "timeout" }),
        getSessionMessages: async () => ({ messages: [] }),
      },
    },
  };
  assert.equal(await runTaskViaSubagent(api, "t-1", "p"), null);
});

test("runTaskViaSubagent returns null without a runtime", async () => {
  assert.equal(await runTaskViaSubagent({}, "t-1", "p"), null);
});

test("the earn handler reads ctx.args and reports a summary", async () => {
  const run = scriptedRun([
    ["goal", { stdout: '{"mode":"time","seconds":60}' }],
    ["claim", { code: 4 }],
  ]);
  const handler = makeEarnHandler({}, { binary: "bin", run, runTask: async () => "x" });
  const out = await handler({ args: "60s" });
  assert.match(out.text, /ran 0 task/);
});

test("the earn handler refuses a bad goal", async () => {
  const run = scriptedRun([["goal", { code: 2 }]]);
  const handler = makeEarnHandler({}, { binary: "bin", run, runTask: async () => "x" });
  const out = await handler({ args: "forever" });
  assert.match(out.text, /not a goal/);
});

test("register wires the hook with an explicit timeout and the command", () => {
  const registered = { hooks: [], commands: [] };
  const api = {
    on: (name, handler, opts) => registered.hooks.push({ name, handler, opts }),
    registerCommand: (def) => registered.commands.push(def),
  };
  register(api);

  const hook = registered.hooks.find((h) => h.name === "before_tool_call");
  assert.ok(hook, "before_tool_call must be registered");
  // Without an explicit budget the hook runner's default decision timeout would
  // abort the handler while it waits out the claim window.
  assert.equal(hook.opts.timeoutMs, HOOK_TIMEOUT_MS);
  assert.ok(HOOK_TIMEOUT_MS > 210_000, "the budget must outlast the core's own cap");

  const command = registered.commands.find((c) => c.name === "slashwork-earn");
  assert.ok(command, "slashwork-earn must be registered");
  assert.equal(command.acceptsArgs, true);
  assert.equal(typeof command.handler, "function");
});
