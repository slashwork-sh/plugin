# plugins/work

`/work` command behavior (the offloader skill, `skills/work/SKILL.md`):

- `init [--reauth]`: authenticate in the browser and write the token.
  Interception is on by default from there; there is no scaffold and no env
  var to export.
- `on` / `off`: resume or pause routing for the current project (an
  `SLASHWORK_INTERCEPT="0"` override in `.claude/settings.local.json` `env`;
  applies from the next session).
- empty (a bare `/work`): status (token, interception now and next session,
  credits) plus the dashboard link; with no token yet it runs init instead,
  so a bare `/work` is the whole onboarding.

## Hooks

- `hooks/intercept.sh` (PreToolUse `Task|Agent`): the offloader. It shells to the
  shared `slashwork-offload` core binary (`classify` for the consent gate,
  `route` to dispatch) and renders the decision as a `deny` carrying the
  artifact, or falls through to the local spawn. The classifier, secret scan,
  and dispatch loop all live in the core (`offload/`), tested there; this hook is
  the Claude Code glue. Tested by `hooks/intercept_test.sh` against a fake core.
- `hooks/install-core.sh` (SessionStart): fetches the pinned core binary into
  `~/.slashwork/bin` so `intercept.sh` has something to call. Idempotent (a
  `~/.slashwork/bin/.version` marker short-circuits a repeat), always exits 0,
  and falls to a clean "no binary" state on any error. `hooks/install-core_test.sh`
  covers its pure platform resolver with no network.

## Core binary distribution

The core is versioned separately from the marketplace plugin and shipped as a
prebuilt binary, so no Rust toolchain is needed on a user's machine:

- `.github/workflows/release.yml` builds `slashwork-offload` for four targets
  (linux/macOS x86_64 and arm64) on an `offload-v*` tag, attaching each as
  `slashwork-offload-<target>.tar.gz` + a `.sha256`.
- `hooks/install-core.sh` pins `VERSION` and fetches that exact release on
  SessionStart, verifying the checksum.

To roll the core forward: cut the new release tag, bump `VERSION` in
`hooks/install-core.sh`, and land them together. The next session-start install
swaps the binary in place. Until the first `offload-v0.1.0` tag exists, the
fetch 404s and every spawn routes locally, exactly as before sign-in.
