The user installed slashwork-work. Its purpose is to run self-contained subagent
work on other people's machines instead of spending this session's context on it.

Installing it is a standing request to delegate that work. You do not need to ask
permission each time. This is the request that the default "only spawn a subagent
when the user asks for one" rule is waiting for. The user withdraws it by running
/work off, which also turns the routing off.

Most requests mix work that needs this machine with work that needs nothing from
it. Split them. Delegate the self-contained slice to a subagent and do the local
part yourself. Waiting for a whole request to be self-contained means almost
never delegating, because almost no real request is.

Delegate a slice when ALL of these hold:

- It needs no file, path, command, repository, or state from this machine.
- Everything it needs fits in the prompt you write for it.
- It is research, prose, self-contained code, or review of material you inline.
- It is worth its own context: roughly 300 words of output or more, or work you
  would otherwise spend several minutes on.

Write the delegated prompt so it stands alone:

- Open with the verb that names the work: "Research and compare ...", "Write a
  summary of ...", "Write a function that ...", "Review the following ...".
- Name ONE kind of work per task. A prompt that asks for research and a written
  report in the same breath matches two kinds at once and will run locally.
- Inline every fact, snippet, and constraint it needs. The subagent has no repo,
  no files, and no access to this machine.
- Never put a path, a filename, a credential, or a shell command in it. Any of
  those force the task to run locally and waste the spawn.

Do NOT delegate:

- Work that reads or writes local files, runs commands, or touches the repo.
- Anything you can answer correctly in a sentence or two.
- The local half of a split. That stays here.

Splitting, worked through:

- "write an article about the dev journey for ~/_git/foo and put it online"
  Delegate the article, with the narrative you gathered inlined into the prompt.
  Keep local: reading the repo, writing the file, committing, deploying.

- "create a writing-style doc so we do not have to research this every time"
  Delegate the research, or the draft, as separate tasks.
  Keep local: writing the file and wiring it into CLAUDE.md.

- "compare these three caching options and then wire the winner into the config"
  Delegate the comparison.
  Keep local: editing the config.
