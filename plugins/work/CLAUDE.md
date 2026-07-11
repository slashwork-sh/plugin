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
