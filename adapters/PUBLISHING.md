# Publishing the harness adapters

Everything here is staged and tested; these are the steps that need your
credentials. Run them in order: the core release comes first because both
adapters shell out to it and both installers pin its version.

## Status, 2026-08-04

- **Step 1, core release: DONE.** `offload-v0.2.0` is tagged and released with
  all 8 assets (4 targets, each with a `.sha256`). Verified by running the
  published installer end to end on darwin-arm64: it downloaded, matched the
  checksum, installed, and `slashwork-offload goal 30m` returned
  `{"mode":"time","seconds":1800}`. A second run correctly reported "already at
  offload-v0.2.0".
  - This needed a CI fix first (`64bf793`). `create-gh-release-action` rejects
    `offload-v0.2.0` with "invalid tag format" unless given `prefix: offload`.
    The `create-release` job was added in `da5cc1f` *after* v0.1.0 shipped, so
    the path had never run until this tag was cut.
- **Step 2, Hermes repo: DONE.** `slashwork-sh/hermes-plugin` is public, with
  `plugin.yaml` and `__init__.py` at the root and 35 passing tests. Still needs
  the on-a-real-Hermes-box verification below.
- **Step 3, npm: BLOCKED on credentials.** `npm whoami` returns `ENEEDAUTH` and
  the `@slashwork` scope does not exist yet (`npm org ls slashwork` returns 404
  "Scope not found"). `npm pack --dry-run` is clean: 5 files, 6.9 kB.
- **Step 4, ClawHub: BLOCKED on credentials.** `clawhub` is not installed.

So `openclaw plugins install @slashwork/openclaw` is the one command on
`slashwork.sh/how-to-save-tokens` that still 404s.

## 0. What is already done

- The core builds, lints clean under clippy pedantic, and passes 59 tests.
- The Hermes adapter is verified against a live Hermes Agent v0.14.0: it loads,
  the real `pre_tool_call` path returns the artifact, and the retry guard holds.
- The OpenClaw adapter is verified against a live openclaw 2026.6.33:
  `openclaw plugins install` accepts it and it loads with no doctor issues.
- `npm pack --dry-run` produces a 5-file, 6.9 kB tarball.
- `adapters/hermes/sync-plugin-repo.sh` generates the standalone Hermes repo and
  its tests pass from that tree.

## 1. Cut the core release (do this first)

Both installers pin `offload-v0.2.0`, and the adapters' earn loops call the new
`goal` and `credits` subcommands, which only exist from this release on.

```
git tag offload-v0.2.0
git push origin offload-v0.2.0
```

That fires `.github/workflows/release.yml`, which builds four targets and
attaches `slashwork-offload-<target>.tar.gz` plus a `.sha256` for each.

Until the tag exists, `plugins/work/hooks/install-core.sh` 404s on the download
and returns non-zero, which the SessionStart hook swallows. Existing Claude Code
users keep the v0.1.0 binary they already have, so the offloader keeps working;
they just do not get the new subcommands. Nothing breaks in the gap.

Verify:

```
gh release view offload-v0.2.0
curl -fsSL https://raw.githubusercontent.com/slashwork-sh/plugin/main/offload/dist/install.sh | sh
~/.slashwork/bin/slashwork-offload goal 30m     # {"mode":"time","seconds":1800}
```

## 2. Publish the Hermes plugin repo

`hermes plugins install owner/repo` clones a whole repo and expects
`plugin.yaml` and `__init__.py` at the root, so the adapter ships from its own
repo generated out of `adapters/hermes`.

```
bash adapters/hermes/sync-plugin-repo.sh          # writes ../hermes-plugin
cd ../hermes-plugin
python3 -m unittest test_hermes.py                # 35 tests
git init -b main && git add -A
git commit -m "sync from slashwork-sh/plugin"
gh repo create slashwork-sh/hermes-plugin --public --source=. --push
```

Verify on a machine with Hermes:

```
hermes plugins install slashwork-sh/hermes-plugin
# add "slashwork" to plugins.enabled in ~/.hermes/config.yaml
hermes plugins list          # slashwork, enabled, no error
```

Re-run the sync script and commit whenever `adapters/hermes` changes; the
generated repo carries a GENERATED.md saying so.

## 3. Publish the npm package

The package is `@slashwork/openclaw`, so the `@slashwork` npm scope has to exist
and your account needs publish rights on it. `npm whoami` currently returns
"need auth", so start with a login.

```
npm login
npm org create slashwork        # only if the scope does not exist yet
cd adapters/openclaw
npm pack --dry-run              # 5 files: index.js, plugin.js, openclaw.plugin.json, package.json, README.md
npm publish --access public     # scoped packages are private by default
```

Verify:

```
npm view @slashwork/openclaw version
openclaw plugins install @slashwork/openclaw
openclaw plugins doctor         # no issues
```

## 4. Publish to ClawHub

ClawHub is owner-scoped and the package scope must match the publishing owner,
so `@slashwork/openclaw` can only be published as the `@slashwork` owner. Create
that owner on ClawHub first if it does not exist.

```
npm install -g clawhub
clawhub login
cd adapters/openclaw
clawhub package publish slashwork/openclaw --dry-run
clawhub package publish slashwork/openclaw
```

New releases stay hidden from install surfaces until ClawHub's automated review
finishes, so expect a delay before `openclaw plugins search slashwork` finds it.

## 5. After all three land

- Run the end-to-end checklist per harness (install, spawn a routable task,
  confirm a live earner returns the artifact, confirm the dashboard's
  tokens-saved tile moves).
- Flip the "not released yet" block on the coordinator's how-to page
  (`coordinator/templates/how_to_save_tokens.html`) to the real install
  commands. The replacement copy is written and waiting on the
  `docs/multi-harness-live-api` branch of the coordinator repo.
