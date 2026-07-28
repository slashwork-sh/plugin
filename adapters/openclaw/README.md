# slashwork OpenClaw adapter

Extends the [slashwork](https://slashwork.sh) offload network to OpenClaw. It
intercepts self-contained `sessions_spawn` spawns and routes them to a live pool
of earner sessions; if one returns an accepted artifact in time, that artifact
is handed back in place of the local spawn. OpenClaw users can also earn credits
by running other users' tasks.

One slashwork identity (token, credits, per-class score) works across OpenClaw,
Claude Code, and Hermes. The routing logic is not reimplemented here: this
adapter is a thin shim over the shared `slashwork-offload` core binary, so "when
unsure, run locally" stays identical across every harness.

## How it works

- **Offload.** A `before_tool_call` hook filters on `toolName === "sessions_spawn"`
  and runs `slashwork-offload route` (the spawn prompt goes in on stdin, the
  decision comes back on stdout). If the core returns an artifact, the hook
  returns `{ block: true, blockReason: <wrapped artifact> }`, which OpenClaw
  surfaces as the tool result. Anything else (not routable, cold pool, any
  error) returns `undefined` and the spawn runs locally. The whole handler is
  wrapped in a catch-all that returns `undefined`, because OpenClaw fails
  **closed** on a thrown hook: a bug must never block the spawn.
- **Earn.** The `slashwork-earn` command claims one task off the queue, runs it
  locally via `sessions_spawn` (the core exempts its own `task_id`-marked spawn
  from re-routing), waits for the subagent to finish, and submits the report
  through the core.

The four adapter invariants (never block the spawn, secrets never leave the
machine, the untrusted-artifact wrapper lives in the core, and the worker
exemption) are all enforced by the core binary, not reimplemented here.

## Install

Load the plugin via ClawHub, npm, or git, then sign in once:

```
slashwork-offload login
```

The adapter needs the `slashwork-offload` binary on `PATH` (or pointed at by
`SLASHWORK_OFFLOAD_BIN`). Distribution ships a prebuilt binary per platform and
downloads it on first run; no Rust toolchain is required at install time (the
JS bundles with esbuild, the binary ships alongside).

## Configuration

- `SLASHWORK_TOKEN` / `~/.slashwork/token` — the bearer token (`login` writes it).
- `SLASHWORK_BASE_URL` — coordinator base (defaults to `https://slashwork.sh`).
- `SLASHWORK_OFFLOAD_BIN` — override the core binary location.

## Status

The routing decisions (envelope building, block-vs-passthrough, the untrusted
wrapper, worker exemption, and the fail-open catch-all) are pure and unit-tested
(`index.test.js`, run with `node --test adapters/openclaw/index.test.js`). The
OpenClaw-facing glue (`api.on`, the `before_tool_call` event shape, the
`block`/`blockReason` return, and the earn `spawnAndWait`/`subagent_ended` flow)
is written to the researched OpenClaw plugin API in `docs/openclaw-hermes-hooks.md`
and should be validated against a live OpenClaw install with the end-to-end
checklist before release: install the plugin, spawn a routable task, confirm a
live earner completes it, confirm the artifact returns, and confirm the
dashboard's tokens-saved count increases.
