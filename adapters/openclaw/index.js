// slashwork OpenClaw adapter.
//
// Routes self-contained `sessions_spawn` spawns to the slashwork offload network
// through the shared `slashwork-offload` core binary, and adds a `slashwork-earn`
// command to run other users' tasks for credits.
//
//   Install:  via ClawHub, npm, or git
//   Enable:   load the plugin; sign in once with `slashwork-offload login`
//
// The offload/earn protocol (classify, secret-scan, POST, long-poll, claim,
// submit) lives entirely in the core binary, so the routing logic never drifts
// across harnesses. This shim only maps OpenClaw's hook surface onto it. See
// docs/openclaw-hermes-hooks.md in the coordinator repo.
//
// The OpenClaw-facing glue (`api.on`, the event shape, the block/blockReason
// return, the earn event flow) is written to the researched OpenClaw plugin API
// and should be validated against a live OpenClaw install; the routing decisions
// below are pure and unit-tested.

import { spawn } from "node:child_process";

export const HARNESS = "openclaw";
export const SPAWN_TOOL = "sessions_spawn";
// Bounds a hung core. It sits above the core's own ~200s wall-clock cap, so the
// core returns `local` on its own first; this only catches a wedged process.
const ROUTE_TIMEOUT_MS = 210_000;

/** Locate the `slashwork-offload` binary: `SLASHWORK_OFFLOAD_BIN`, else the bare
 * name (resolved on PATH by spawn; a miss surfaces as a spawn error -> local). */
export function coreBinary() {
  return process.env.SLASHWORK_OFFLOAD_BIN || "slashwork-offload";
}

/** Build the core `route` envelope from a `sessions_spawn` args object. v1 sends
 * only the prompt; the core inlines no files. */
export function routeEnvelope(args) {
  const a = args || {};
  const prompt = a.prompt || a.task || a.input || a.goal || "";
  return { harness: HARNESS, tool_name: SPAWN_TOOL, spawn: { prompt } };
}

/** Default router: spawn `slashwork-offload route`, write the envelope to stdin,
 * and resolve the decision dict. Every failure (missing binary, timeout, crash,
 * non-JSON) resolves to `{ decision: "local" }` so the spawn always falls back
 * to a local run. Never rejects. */
export function defaultRouter(binary) {
  return (envelope) =>
    new Promise((resolve) => {
      const local = (reason) => resolve({ decision: "local", reason });
      let child;
      try {
        child = spawn(binary, ["route"], { stdio: ["pipe", "pipe", "ignore"] });
      } catch {
        return local("spawn failed");
      }
      let out = "";
      const timer = setTimeout(() => {
        child.kill();
        local("route timeout");
      }, ROUTE_TIMEOUT_MS);
      child.stdout.on("data", (d) => {
        out += d;
      });
      child.on("error", () => {
        clearTimeout(timer);
        local("slashwork-offload not found");
      });
      child.on("close", () => {
        clearTimeout(timer);
        try {
          const decision = JSON.parse(out);
          resolve(decision && typeof decision === "object" && !Array.isArray(decision)
            ? decision
            : { decision: "local", reason: "bad route output" });
        } catch {
          local("bad route output");
        }
      });
      child.stdin.on("error", () => {}); // ignore EPIPE if the child died early
      child.stdin.write(JSON.stringify(envelope));
      child.stdin.end();
    });
}

/** Try to offload a `sessions_spawn`. Resolves to the untrusted-content wrapped
 * artifact string to hand back, or `null` to run locally (not routable, cold
 * pool, or any error). `router` is injectable for tests. */
export async function offloadResult(args, router) {
  const decision = await router(routeEnvelope(args));
  if (decision && decision.decision === "artifact") {
    // The core owns the untrusted-content wrapper (invariant 2); return it
    // verbatim so the parent model treats the artifact as data, never as
    // instructions. Fall back to the raw artifact if an older core omits it.
    return decision.wrapped || decision.artifact || "";
  }
  return null;
}

/** The `before_tool_call` handler. Never blocks the spawn on failure: OpenClaw
 * fails CLOSED on a thrown handler, so this catches everything and returns
 * `undefined` (let the spawn run locally). A routed artifact short-circuits with
 * `{ block: true, blockReason: <wrapped artifact> }`. */
export async function beforeToolCall(event, deps) {
  try {
    const toolName = event && (event.toolName || event.tool_name);
    if (toolName !== SPAWN_TOOL) return undefined;
    const args = (event && (event.args || event.input)) || {};
    const wrapped = await offloadResult(args, deps.router);
    if (wrapped == null) return undefined;
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

/** Plugin entrypoint. OpenClaw calls this to wire the adapter in: a
 * `before_tool_call` hook (offload) and the `slashwork-earn` command (earn). */
export function register(api) {
  const router = defaultRouter(coreBinary());
  api.on("before_tool_call", (event) => beforeToolCall(event, { router }));
  if (typeof api.registerCommand === "function") {
    api.registerCommand("slashwork-earn", () => earnCommand(api));
  }
}

/** `slashwork-earn`: claim one task off the queue, run it locally via
 * `sessions_spawn` (the core exempts its own `task_id`-marked spawn), wait for
 * the subagent to finish, and submit the report through the core.
 *
 * The claim/submit halves go through the core binary; the middle (launch
 * `sessions_spawn`, await `subagent_ended`, read the report) is OpenClaw glue to
 * validate against a live install. */
export async function earnCommand(api, binary = coreBinary(), runCore = defaultRunCore) {
  const claim = await runCore(binary, ["claim", "--timeout", "1800"]);
  if (claim.code !== 0 || !claim.stdout.trim()) return "no task claimed.";
  let job;
  try {
    job = JSON.parse(claim.stdout);
  } catch {
    return "could not parse the claimed job.";
  }
  const taskId = job.task_id;
  if (!taskId) return "claimed job had no task id.";
  const report = await api.spawnAndWait({
    prompt: workerPrompt(taskId, job.prompt || ""),
  });
  const submit = await runCore(binary, ["submit", taskId], reportText(report));
  return submit.code === 0
    ? `submitted task ${taskId}.`
    : `ran task ${taskId} but the submit failed.`;
}

/** Extract the report text from a spawn result across the shapes OpenClaw may
 * return. */
export function reportText(result) {
  if (typeof result === "string") return result;
  if (result && typeof result === "object") {
    for (const key of ["output", "text", "content", "result", "report"]) {
      if (typeof result[key] === "string") return result[key];
    }
  }
  return String(result);
}

/** Run the core binary with optional stdin, resolving `{ code, stdout, stderr }`.
 * Never rejects. */
export function defaultRunCore(binary, cmdArgs, stdin) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(binary, cmdArgs, { stdio: ["pipe", "pipe", "pipe"] });
    } catch {
      return resolve({ code: 1, stdout: "", stderr: "spawn failed" });
    }
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", () => resolve({ code: 1, stdout, stderr: "spawn failed" }));
    child.on("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
    child.stdin.on("error", () => {});
    if (stdin != null) child.stdin.write(stdin);
    child.stdin.end();
  });
}
