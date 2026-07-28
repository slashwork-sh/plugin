# slashwork-offload distribution

How the prebuilt `slashwork-offload` core binary reaches a user's machine, so a
harness shim never needs a Rust toolchain to route a spawn.

## What lives here

- `install.sh` fetches the pinned binary into `~/.slashwork/bin/slashwork-offload`.
  It verifies a SHA256 checksum, is idempotent (a version marker at
  `~/.slashwork/bin/.version` short-circuits a repeat run), and fails to a clean
  "no binary" state on any error so the offloader just falls back to a local
  spawn. Safe to call from a shim's session-start hook on every start.
- `install_test.sh` exercises the pure platform-detection logic (`resolve_target`)
  with fixed `(os, arch)` pairs, no network. CI runs it in the `offload` job.

## Publishing a release

The binaries come from `.github/workflows/release.yml`, which builds
`slashwork-offload` for four targets and uploads each as
`slashwork-offload-<target>.tar.gz` plus a `.sha256`:

| Platform            | Target triple               |
| ------------------- | --------------------------- |
| Linux x86_64        | `x86_64-unknown-linux-gnu`  |
| Linux arm64         | `aarch64-unknown-linux-gnu` |
| macOS Intel         | `x86_64-apple-darwin`       |
| macOS Apple Silicon | `aarch64-apple-darwin`      |

Cut a release by pushing a tag that matches `offload-v*`:

```sh
git tag offload-v0.1.0
git push origin offload-v0.1.0
```

The workflow attaches the eight assets to the GitHub release for that tag.

## Version pinning

`install.sh` pins `VERSION="offload-v0.1.0"`. The installer only ever fetches
that exact tag, so a shim ships against a known-good core. To roll the pinned
version forward: cut the new release tag, bump `VERSION` in `install.sh`, and
land both together. The next session-start install swaps the binary in place
(the marker no longer matches, so the idempotent guard re-fetches).

Until the first `offload-v0.1.0` tag is pushed, the download 404s and the
installer exits non-zero; the shims resolve no binary and route every spawn
locally, exactly as they do before a user signs in.

## How the shims find the binary

Both adapter resolvers check, in order: `SLASHWORK_OFFLOAD_BIN` (explicit
override), then `~/.slashwork/bin/slashwork-offload` (what `install.sh` writes),
then `PATH`. See `adapters/hermes/__init__.py` `core_binary()` and
`adapters/openclaw/index.js` `coreBinary()`.
