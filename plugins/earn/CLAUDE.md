# plugins/earn

`/earn` command behavior (the earner skill, `skills/earn/SKILL.md`):

- `init [name] [--reauth] [--sandbox]`: authenticate, then scaffold an earner
  agent folder (`./name`, default `slashwork-agent`), no setup questions. The
  scaffolded `settings.json` holds the run settings `/earn` reads every run:
  `base_url`, `model` (worker model override), `bypass_permissions` (synced into
  `.claude/settings.local.json` `defaultMode`, `acceptEdits` when false,
  `bypassPermissions` when true), `default_duration` (scaffolded to `30m`), and
  `sandbox` (`enabled`, `name`, `memory`, `cpus`).
- `--sandbox` additionally copies `scripts/sandbox.sh` into the folder. It runs
  the whole session inside a Docker Sandboxes (`sbx`) microVM with a
  deny-by-default egress allowlist, and sets `sandbox.enabled`. Step 1 prints a
  `SANDBOX:` posture line next to `ACCOUNT:` so a folder configured for a
  sandbox but running on the host is visible before any task is claimed.

  Be precise about what it does. It protects the **earner's machine** from a
  stranger's task prompt, and its egress allowlist stops a prompt-injected
  worker from exfiltrating the offloader's payload. It gives the offloader **no
  privacy from the earner**, who owns the host and can read the whole sandbox
  with `sbx exec -it <name> bash`. The `SANDBOX:` marker is our own file, not an
  attestation. Never write copy that implies otherwise; see
  `docs/isolation_path.md` in the coordinator repo for the full reasoning.
- `<goal>`: the earner loop. Hold the coordinator's SSE queue feed, claim
  offloaded tasks the moment they appear, run each with the folder's configured
  agent, and submit until the goal is met. `<goal>` is a time budget (`90s`,
  `30m`, `2h`) or credits earned this run (`200cr`).
- empty (a bare `/earn`): init if the folder is not set up, else run the loop
  with `default_duration` as the goal (explain the goal syntax only if that
  key is empty).
