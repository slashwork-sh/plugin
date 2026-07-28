// Unit tests for the slashwork OpenClaw adapter's pure routing logic.
//
// The OpenClaw-facing glue (register/hook wiring, the earn event flow) needs a
// live OpenClaw install to exercise; these tests cover everything decidable
// without one, using an injected router in place of the real slashwork-offload
// subprocess. Run:  node --test adapters/openclaw/index.test.js

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  beforeToolCall,
  defaultRouter,
  offloadResult,
  reportText,
  routeEnvelope,
  workerPrompt,
} from "./index.js";

// A fake router that always resolves the given decision.
const router = (decision) => async () => decision;

test("routeEnvelope tags openclaw and the prompt", () => {
  const env = routeEnvelope({ prompt: "do it" });
  assert.equal(env.harness, "openclaw");
  assert.equal(env.tool_name, "sessions_spawn");
  assert.equal(env.spawn.prompt, "do it");
});

test("routeEnvelope falls back across prompt fields", () => {
  assert.equal(routeEnvelope({ task: "t" }).spawn.prompt, "t");
  assert.equal(routeEnvelope({ input: "i" }).spawn.prompt, "i");
  assert.equal(routeEnvelope({}).spawn.prompt, "");
});

test("offloadResult returns the wrapped artifact", async () => {
  const r = await offloadResult(
    { prompt: "p" },
    router({ decision: "artifact", wrapped: "UNTRUSTED: ans" }),
  );
  assert.match(r, /UNTRUSTED/);
});

test("offloadResult falls back to the raw artifact when wrapped is absent", async () => {
  const r = await offloadResult(
    { prompt: "p" },
    router({ decision: "artifact", artifact: "raw" }),
  );
  assert.equal(r, "raw");
});

test("offloadResult returns null on a local decision", async () => {
  const r = await offloadResult({ prompt: "p" }, router({ decision: "local", reason: "cold" }));
  assert.equal(r, null);
});

test("beforeToolCall passes through a non-spawn tool", async () => {
  const out = await beforeToolCall(
    { toolName: "other", args: {} },
    { router: router({ decision: "artifact", wrapped: "W" }) },
  );
  assert.equal(out, undefined);
});

test("beforeToolCall blocks with the wrapped artifact on a routed spawn", async () => {
  const out = await beforeToolCall(
    { toolName: "sessions_spawn", args: { prompt: "p" } },
    { router: router({ decision: "artifact", wrapped: "WRAPPED" }) },
  );
  assert.deepEqual(out, { block: true, blockReason: "WRAPPED" });
});

test("beforeToolCall runs local (undefined) on a local decision", async () => {
  const out = await beforeToolCall(
    { toolName: "sessions_spawn", args: { prompt: "p" } },
    { router: router({ decision: "local" }) },
  );
  assert.equal(out, undefined);
});

test("beforeToolCall fails open (undefined) when the router throws", async () => {
  const throwing = async () => {
    throw new Error("boom");
  };
  const out = await beforeToolCall(
    { toolName: "sessions_spawn", args: { prompt: "p" } },
    { router: throwing },
  );
  assert.equal(out, undefined);
});

test("workerPrompt prefixes the task_id marker", () => {
  const p = workerPrompt("abc-123", "solve this");
  assert.ok(p.startsWith("task_id: abc-123\n"));
  assert.match(p, /solve this/);
});

test("reportText handles string and object shapes", () => {
  assert.equal(reportText("hi"), "hi");
  assert.equal(reportText({ output: "o" }), "o");
  assert.equal(reportText({ text: "t" }), "t");
  assert.equal(reportText(123), "123");
});

test("defaultRouter falls back to local when the binary is missing", async () => {
  const route = defaultRouter("slashwork-offload-does-not-exist-xyz");
  const decision = await route({ harness: "openclaw", spawn: { prompt: "p" } });
  assert.equal(decision.decision, "local");
});
