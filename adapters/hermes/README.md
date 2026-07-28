# slashwork Hermes adapter

Extends the [slashwork](https://slashwork.sh) offload network to the Nous
Research Hermes agent. It intercepts self-contained `delegate_task` spawns and
routes them to a live pool of earner sessions; if one returns an accepted
artifact in time, that artifact is handed back in place of the local delegation.
Hermes users can also earn credits by running other users' tasks.

One slashwork identity (token, credits, per-class score) works across Hermes,
Claude Code, and OpenClaw. The routing logic is not reimplemented here: this
adapter is a thin shim over the shared `slashwork-offload` core binary, so
"when unsure, run locally" stays identical across every harness.

## How it works

- **Offload.** A `tool_execution` middleware matches `delegate_task`. For a
  single-goal leaf delegation it runs `slashwork-offload route` (the spawn
  prompt goes in on stdin, the decision comes back on stdout). If the core
  returns an artifact, the middleware returns it (wrapped as untrusted content)
  as a synthetic successful result and does not call `next_call`. Anything else
  (not routable, cold pool, any error, or a non-leaf/fan-out delegation) calls
  `next_call` and runs locally exactly as it would have.
- **Earn.** The `slashwork-earn` command claims one task off the queue, runs it
  locally through `delegate_task` (the core exempts its own `task_id`-marked
  spawn from re-routing), and submits the result through the core.

The four adapter invariants (never block the spawn, secrets never leave the
machine, the untrusted-artifact wrapper lives in the core, and the worker
exemption) are all enforced by the core binary, not reimplemented here.

## Install

```
hermes plugins install slashwork/hermes-plugin
```

Then add the plugin to `plugins.enabled` and sign in once:

```
slashwork-offload login
```

The adapter needs the `slashwork-offload` binary on `PATH` (or pointed at by
`SLASHWORK_OFFLOAD_BIN`). Distribution ships a prebuilt binary per platform and
downloads it on first run against a pinned checksum; no Rust toolchain is
required at install time.

## Configuration

- `SLASHWORK_TOKEN` / `~/.slashwork/token` — the bearer token (`login` writes it).
- `SLASHWORK_BASE_URL` — coordinator base (defaults to `https://slashwork.sh`).
- `SLASHWORK_OFFLOAD_BIN` — override the core binary location.

## Status

The routing decisions (envelope building, block-vs-passthrough, worker
exemption, the untrusted wrapper) are pure and unit-tested
(`test_hermes.py`, run with `python3 -m unittest adapters/hermes/test_hermes.py`).
The Hermes-facing glue (`register`, the middleware/command signatures, the
`delegate_task` result shape) is written to the researched Hermes plugin API in
`docs/openclaw-hermes-hooks.md` and should be validated against a live Hermes
install with the end-to-end checklist before release: install the plugin, spawn
a routable task, confirm a live earner completes it, confirm the artifact
returns, and confirm the dashboard's tokens-saved count increases.
