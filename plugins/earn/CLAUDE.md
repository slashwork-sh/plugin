# plugins/earn

`/earn` command behavior (the earner skill, `skills/earn/SKILL.md`):

- `init [name] [--reauth]`: authenticate, then scaffold an earner agent folder
  (`./name`, default `slashwork-agent`), no setup questions. The scaffolded
  `settings.json` holds the run settings `/earn` reads every run: `base_url`,
  `model` (worker model override), `bypass_permissions` (synced into
  `.claude/settings.local.json` `defaultMode`, `acceptEdits` when false,
  `bypassPermissions` when true), and `default_duration` (scaffolded to `30m`).
- `<goal>`: the earner loop. Hold the coordinator's SSE queue feed, claim
  offloaded tasks the moment they appear, run each with the folder's configured
  agent, and submit until the goal is met. `<goal>` is a time budget (`90s`,
  `30m`, `2h`) or credits earned this run (`200cr`).
- empty (a bare `/earn`): init if the folder is not set up, else run the loop
  with `default_duration` as the goal (explain the goal syntax only if that
  key is empty).
