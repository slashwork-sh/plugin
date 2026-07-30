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

Written and verified against Hermes Agent v0.14.0.

## How it works

- **Offload.** A `pre_tool_call` hook matches `delegate_task`. For a single
  delegation it runs `slashwork-offload route` (the goal and context go in on
  stdin, the decision comes back on stdout). If the core returns an artifact,
  the hook returns `{"action": "block", "message": <wrapped artifact>}` and
  Hermes short-circuits the tool with that message. Anything else (not routable,
  cold pool, any error, or a `tasks[]` fan-out) returns `None` and the
  delegation runs locally exactly as it would have.
- **Earn.** `/slashwork-earn [goal]` claims tasks off the queue, runs each one
  locally through `delegate_task` (via `ctx.dispatch_tool`, which goes straight
  to the tool registry, so the worker's own delegation is never re-routed), and
  submits the result. The goal is a time budget (`90s`, `30m`, `2h`) or the
  credits earned this run (`200cr`), and defaults to 30m.

The four adapter invariants (never block the spawn, secrets never leave the
machine, the untrusted-artifact wrapper lives in the core, and the worker
exemption) are all enforced by the core binary, not reimplemented here.

### Why a blocked tool call, and what the retry guard is for

Hermes has no way to substitute a successful tool result. `delegate_task` is an
agent-loop tool, so it never reaches the `transform_tool_result` seam, and
`pre_tool_call` can only block. A block reaches the model as
`{"error": <message>}`, so the artifact arrives error-shaped no matter what.

Two things follow. The core's wrapper opens by stating the delegation is already
complete and must not be retried, so the model reads it as a finished result.
And the adapter remembers which delegations it has already answered: if a model
retries the same delegation anyway, the repeat runs locally instead of posting
and paying for the same work twice. The memory is per-process and bounded, and
it never replays a stored artifact.

## Install

```
hermes plugins install slashwork-sh/hermes-plugin
```

Then add `slashwork` to `plugins.enabled` in `~/.hermes/config.yaml` and sign in
once:

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

## Development

This directory is the source of truth. The `slashwork-sh/hermes-plugin` repo
that `hermes plugins install` clones is generated from it by
`adapters/hermes/sync-plugin-repo.sh`, because that installer clones a whole
repo and expects `plugin.yaml` and `__init__.py` at the root.

Tests:

```
python3 -m unittest adapters/hermes/test_hermes.py
```

They pin the contracts this adapter has with Hermes: the `pre_tool_call` kwargs
signature and block dict, `delegate_task`'s real arguments, the retry guard, and
the earn goal loop.
