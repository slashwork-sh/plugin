// slashwork OpenClaw adapter: routing logic and hook handlers.
//
// Routes self-contained `sessions_spawn` spawns to the slashwork offload network
// through the shared `slashwork-offload` core binary, and adds a
// `slashwork-earn` command to run other users' tasks for credits.
//
// This file holds everything that does not need the OpenClaw SDK, so it can be
// unit-tested with plain `node --test` and no OpenClaw install. `plugin.js` is
// the actual plugin entry and is the only file that imports from
// `openclaw/plugin-sdk`.
//
// Written against openclaw 2026.6.33:
//
//   - `api.on("before_tool_call", handler, opts)` is the interception point.
//     The event carries `toolName` and `params` (not `args`), and returning
//     `{ block: true, blockReason }` makes OpenClaw build the tool result from
//     `blockReason` as ordinary text content (buildBlockedToolResult), so the
//     artifact reaches the model as the spawn's result rather than an error.
//   - The hook runner applies a default decision timeout, so a handler that
//     waits out a claim window has to set `timeoutMs` explicitly.
//   - `api.runtime.subagent` (run / waitForRun / getSessionMessages) is how a
//     plugin runs an agent turn itself, which is what the earn loop uses.

import { spawn } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const HARNESS = "openclaw";
export const SPAWN_TOOL = "sessions_spawn";
// Bounds a hung core. It sits above the core's own ~200s wall-clock cap, so the
// core returns `local` on its own first; this only catches a wedged process.
const ROUTE_TIMEOUT_MS = 210_000;
// The budget we ask OpenClaw for. Above ROUTE_TIMEOUT_MS so the core's own
// fallback always wins the race; without it the hook runner's default decision
// timeout would abort the handler mid-claim and the spawn would run locally
// while a posted task went on burning an earner's time.
export const HOOK_TIMEOUT_MS = 240_000;
// How long a claimed task's local run may take before the earner gives up. The
// coordinator's per-class deadlines are all well inside this.
const WORKER_TIMEOUT_MS = 300_000;
// The goal a bare `/slashwork-earn` runs with, matching /earn's default.
export const DEFAULT_GOAL = "30m";

/** Locate the `slashwork-offload` binary: `SLASHWORK_OFFLOAD_BIN`, then the
 * install dir `~/.slashwork/bin` that `offload/dist/install.sh` populates, else
 * the bare name (resolved on PATH by spawn; a miss surfaces as a spawn error ->
 * local). */
export function coreBinary() {
  if (process.env.SLASHWORK_OFFLOAD_BIN) return process.env.SLASHWORK_OFFLOAD_BIN;
  const installed = join(homedir(), ".slashwork", "bin", "slashwork-offload");
  try {
    accessSync(installed, constants.X_OK);
    return installed;
  } catch {
    return "slashwork-offload";
  }
}

/** Build the core `route` envelope from a `sessions_spawn` params object. The
 * task text is the tool's required `task` parameter. */
export function routeEnvelope(params) {
  const p = params || {};
  const task = typeof p.task === "string" ? p.task : "";
  return { harness: HARNESS, tool_name: SPAWN_TOOL, spawn: { prompt: task } };
}

/** Run the core binary with optional stdin, resolving `{ code, stdout, stderr }`.
 * Never rejects: every failure is a code the caller treats as "run locally". */
export function runCore(binary, cmdArgs, stdin, timeoutMs) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(binary, cmdArgs, { stdio: ["pipe", "pipe", "pipe"] });
    } catch {
      return resolve({ code: 1, stdout: "", stderr: "spawn failed" });
    }
    let stdout = "";
    let stderr = "";
    let timer;
    if (timeoutMs) {
      timer = setTimeout(() => {
        child.kill();
        resolve({ code: 1, stdout: "", stderr: "timeout" });
      }, timeoutMs);
    }
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", () => {
      clearTimeout(timer);
      resolve({ code: 1, stdout, stderr: "slashwork-offload not found" });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code: code ?? 1, stdout, stderr });
    });
    child.stdin.on("error", () => {}); // ignore EPIPE if the child died early
    if (stdin != null) child.stdin.write(stdin);
    child.stdin.end();
  });
}

/** Default router: `slashwork-offload route` with the envelope on stdin,
 * resolving the decision object. Every failure (missing binary, timeout, crash,
 * non-JSON) resolves to `{ decision: "local" }`. Never rejects. */
export function defaultRouter(binary, run = runCore) {
  return async (envelope) => {
    const { code, stdout } = await run(
      binary,
      ["route"],
      JSON.stringify(envelope),
      ROUTE_TIMEOUT_MS,
    );
    if (code !== 0) return { decision: "local", reason: "route failed" };
    try {
      const decision = JSON.parse(stdout);
      if (decision && typeof decision === "object" && !Array.isArray(decision)) return decision;
    } catch {
      // fall through to local
    }
    return { decision: "local", reason: "bad route output" };
  };
}

/** Try to offload a `sessions_spawn`. Resolves to the untrusted-content wrapped
 * artifact to hand back, or `null` to run locally (not routable, cold pool, or
 * any error). `router` is injectable for tests. */
export async function offloadResult(params, router) {
  const decision = await router(routeEnvelope(params));
  if (decision && decision.decision === "artifact") {
    // The core owns the untrusted-content wrapper (invariant 2), including the
    // line stating the spawn is already complete; return it verbatim so the
    // parent model treats the artifact as data, never as instructions.
    return decision.wrapped || decision.artifact || null;
  }
  return null;
}

/** The `before_tool_call` handler. A routed artifact short-circuits the spawn
 * with `{ block: true, blockReason: <wrapped artifact> }`, which OpenClaw turns
 * into the tool result's text content. Everything else returns `undefined` and
 * the spawn runs locally.
 *
 * The whole handler is wrapped in a catch-all: OpenClaw fails CLOSED on a thrown
 * hook, so a bug here must never block a spawn.
 *
 * Unlike the Hermes adapter there is no retry guard, because the artifact lands
 * as a normal tool result rather than an error; a model has no reason to respawn
 * the same task, and guarding would turn a genuinely repeated spawn into a local
 * run for no gain. */
export async function beforeToolCall(event, deps) {
  try {
    if (!event || event.toolName !== SPAWN_TOOL) return undefined;
    const wrapped = await offloadResult(event.params || {}, deps.router);
    if (!wrapped) return undefined;
    return { block: true, blockReason: wrapped };
  } catch {
    return undefined;
  }
}

/** Prefix a claimed task's prompt with its `task_id` marker so the core's
 * classifier exempts the worker's own spawn from re-routing (invariant 1). */
export function workerPrompt(taskId, prompt) {
  return `task_id: ${taskId}\n${prompt || ""}`;
}

/** Pull the worker's answer out of a subagent session: the last assistant
 * message, whether its content is a string or content parts. Mirrors how
 * OpenClaw's own bundled plugins read a finished subagent run. */
export function assistantText(messages) {
  const list = Array.isArray(messages) ? messages : [];
  for (let i = list.length - 1; i >= 0; i--) {
    const msg = list[i];
    if (!msg || typeof msg !== "object" || Array.isArray(msg)) continue;
    if (msg.role !== "assistant") continue;
    const content = msg.content;
    if (typeof content === "string" && content.trim()) return content.trim();
    if (Array.isArray(content)) {
      const text = content
        .filter(
          (part) =>
            part &&
            typeof part === "object" &&
            (part.type === "text" || part.type === "output_text") &&
            typeof part.text === "string",
        )
        .map((part) => part.text)
        .join("")
        .trim();
      if (text) return text;
    }
  }
  return null;
}

/** Ask the core to parse an earn goal. Resolves the plan object, or `null` when
 * the spec is not a goal. The core owns the syntax so `90s` / `30m` / `200cr`
 * mean the same thing in every harness. */
export async function goalPlan(spec, binary, run = runCore) {
  const { code, stdout } = await run(binary, ["goal", spec]);
  if (code !== 0) return null;
  try {
    const plan = JSON.parse(stdout);
    if (plan && typeof plan === "object" && !Array.isArray(plan)) return plan;
  } catch {
    // fall through to null
  }
  return null;
}

/** The signed-in earner's credit balance, or `null` if it cannot be read. */
export async function coreCredits(binary, run = runCore) {
  const { code, stdout } = await run(binary, ["credits"]);
  if (code !== 0) return null;
  try {
    const value = JSON.parse(stdout).credits;
    return typeof value === "number" ? value : null;
  } catch {
    return null;
  }
}

/** Claim, run, and submit until the goal is met.
 *
 * `runTask(taskId, prompt)` runs one task locally and resolves the artifact text
 * (or null); the harness supplies it. Every exit is a normal stop: the deadline
 * passes, the credits target is reached, or a claim comes back empty because the
 * queue stayed quiet. Resolves a summary for the caller to report. */
export async function earnLoop({ runTask, plan, binary, run = runCore, clock = Date.now }) {
  const seconds = plan.seconds || plan.ceiling_seconds || 0;
  const target = typeof plan.target === "number" ? plan.target : null;
  let baseline = null;
  if (target !== null) {
    baseline = await coreCredits(binary, run);
    if (baseline === null) return { tasks: 0, submitted: 0, stopped: "no credit baseline" };
  }

  const deadline = clock() + seconds * 1000;
  let tasks = 0;
  let submitted = 0;
  let stopped = "goal met";
  for (;;) {
    const remaining = Math.floor((deadline - clock()) / 1000);
    if (remaining <= 0) {
      stopped = "time budget spent";
      break;
    }
    const claim = await run(binary, ["claim", "--timeout", String(remaining)]);
    if (claim.code !== 0 || !claim.stdout.trim()) {
      stopped = "no task claimed";
      break;
    }
    let job;
    try {
      job = JSON.parse(claim.stdout);
    } catch {
      stopped = "could not parse the claimed job";
      break;
    }
    if (!job || !job.task_id) {
      stopped = "claimed job had no task id";
      break;
    }

    const artifact = await runTask(job.task_id, job.prompt || "");
    tasks += 1;
    if (artifact && artifact.trim()) {
      const submit = await run(binary, ["submit", job.task_id], artifact);
      if (submit.code === 0) submitted += 1;
    }

    if (target !== null) {
      const current = await coreCredits(binary, run);
      if (current !== null && current - baseline >= target) break;
    }
  }

  return { tasks, submitted, stopped };
}

/** Run one claimed task in an isolated subagent session and resolve its answer.
 * Follows the run -> waitForRun -> getSessionMessages pattern OpenClaw's own
 * bundled plugins use, with a fresh session per task so one stranger's task
 * never sees another's transcript. */
export async function runTaskViaSubagent(api, taskId, prompt) {
  const subagent = api?.runtime?.subagent;
  if (!subagent) return null;
  const sessionKey = `slashwork-earn-${taskId}`;
  try {
    await subagent.deleteSession({ sessionKey });
  } catch {
    // No prior session for this task id, which is the normal case.
  }
  try {
    const { runId } = await subagent.run({ sessionKey, message: workerPrompt(taskId, prompt) });
    if (!runId) return null;
    const result = await subagent.waitForRun({ runId, timeoutMs: WORKER_TIMEOUT_MS });
    if (result?.status !== "ok") return null;
    const { messages } = await subagent.getSessionMessages({ sessionKey, limit: 50 });
    return assistantText(messages);
  } catch {
    return null;
  }
}

/** Build the `/slashwork-earn` command handler. OpenClaw calls a plugin command
 * with a context object and takes a reply payload back. */
export function makeEarnHandler(api, deps = {}) {
  const binary = deps.binary || coreBinary();
  const run = deps.run || runCore;
  const runTask = deps.runTask || ((taskId, prompt) => runTaskViaSubagent(api, taskId, prompt));
  return async (ctx) => {
    const spec = (ctx?.args || "").trim().split(/\s+/)[0] || DEFAULT_GOAL;
    const plan = await goalPlan(spec, binary, run);
    if (!plan) {
      return {
        text:
          `could not plan the run: '${spec}' is not a goal, or ${binary} could not run. ` +
          "Goals are a time budget (90s, 30m, 2h) or credits earned this run (200cr).",
      };
    }
    const summary = await earnLoop({ runTask, plan, binary, run });
    return {
      text:
        `slashwork-earn: ran ${summary.tasks} task(s), ` +
        `submitted ${summary.submitted} (${summary.stopped}).`,
    };
  };
}

/** Wire the adapter into OpenClaw: the offload hook and the earn command. Kept
 * separate from the plugin entry so tests can drive it with a fake api. */
export function register(api) {
  const router = defaultRouter(coreBinary());
  api.on("before_tool_call", (event) => beforeToolCall(event, { router }), {
    timeoutMs: HOOK_TIMEOUT_MS,
  });
  api.registerCommand({
    name: "slashwork-earn",
    description: "Earn slashwork credits by running other users' offloaded tasks",
    acceptsArgs: true,
    handler: makeEarnHandler(api),
  });
}
