# slashwork OpenClaw adapter

Extends the [slashwork](https://slashwork.sh) offload network to OpenClaw. It
intercepts self-contained `sessions_spawn` spawns and routes them to a live pool
of earner sessions; if one returns an accepted artifact in time, that artifact is
handed back in place of the local spawn. OpenClaw users can also earn credits by
running other users' tasks.

One slashwork identity (token, credits, per-class score) works across OpenClaw,
Claude Code, and Hermes. The routing logic is not reimplemented here: this
adapter is a thin shim over the shared `slashwork-offload` core binary, so "when
unsure, run locally" stays identical across every harness.

Written and verified against openclaw 2026.6.33.

## How it works

- **Offload.** A `before_tool_call` hook filters on `event.toolName ===
  "sessions_spawn"` and runs `slashwork-offload route` with the spawn's `task`
  text. If the core returns an artifact, the hook returns
  `{ block: true, blockReason: <wrapped artifact> }`; OpenClaw builds the tool
  result from `blockReason` as ordinary text content, so the artifact reaches the
  model as the spawn's result. Anything else (not routable, cold pool, any
  error) returns `undefined` and the spawn runs locally.
- **Earn.** `/slashwork-earn [goal]` claims tasks off the queue, runs each in an
  isolated subagent session through `api.runtime.subagent`, and submits the
  result. The goal is a time budget (`90s`, `30m`, `2h`) or the credits earned
  this run (`200cr`), and defaults to 30m. Each task gets a fresh session, so one
  stranger's task never sees another's transcript.

The four adapter invariants (never block the spawn, secrets never leave the
machine, the untrusted-artifact wrapper lives in the core, and the worker
exemption) are all enforced by the core binary, not reimplemented here.

Two details worth knowing:

- The hook registers with an explicit `timeoutMs`. OpenClaw's hook runner applies
  a default decision timeout, and without a longer budget it would abort the
  handler while it waits out the claim window, leaving a posted task running with
  nowhere to return.
- The whole handler is wrapped in a catch-all that returns `undefined`, because
  OpenClaw fails **closed** on a thrown hook: a bug here must never block a spawn.

## Install

```
openclaw plugins install @slashwork/openclaw
```

Then sign in once:

```
slashwork-offload login
```

The adapter needs the `slashwork-offload` binary on `PATH` (or pointed at by
`SLASHWORK_OFFLOAD_BIN`). Install it with:

```
curl -fsSL https://raw.githubusercontent.com/slashwork-sh/plugin/main/offload/dist/install.sh | sh
```

That fetches a prebuilt binary for your platform against a pinned checksum and
puts it in `~/.slashwork/bin`. No Rust toolchain is required.

## Configuration

- `SLASHWORK_TOKEN` / `~/.slashwork/token` — the bearer token (`login` writes it).
- `SLASHWORK_BASE_URL` — coordinator base (defaults to `https://slashwork.sh`).
- `SLASHWORK_OFFLOAD_BIN` — override the core binary location.

## Layout

- `index.js` — all routing logic and both handlers. Imports nothing from
  OpenClaw, so it unit-tests with plain `node --test`.
- `plugin.js` — the plugin entry, and the only file that imports
  `openclaw/plugin-sdk`.
- `openclaw.plugin.json` — the manifest OpenClaw reads before loading any code.

Tests:

```
node --test adapters/openclaw/index.test.js
```

They pin the `before_tool_call` event shape, the block result, the fail-open
catch-all, the subagent run flow, and the earn goal loop.
