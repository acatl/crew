# crew

A Claude Code skill for orchestrator ↔ worker sessions. One orchestrator session spins up a fresh
worker session for each ticket or slice. It briefs the worker, passes operator input back and forth,
verifies the result, lands it when the operator delegates that, and cleans up. `skills/crew/SKILL.md`
is the contract both sides follow. Per-project answers live in each repo's `docs/CREW.md`, which the
skill interviews you for on first use.

**Workflows** set how a worker works: one Markdown file of parameters, stages (each with its end, its
report and what the orchestrator does then) and rules. The skill ships `standard`: plan, build,
isolated review, hand off committed and verified. A project lists its own in `docs/CREW.md`, usually
a copy of `standard` with stages added, like this repo's `docs/crew/workflows/pr.md`. Pick one per
spawn: `spin up a pr worker for WF2`.

## Requirements

- **The Claude desktop app (Code tab).** Sessions spawn, message and archive each other through the
  app's session tools (`spawn_task`, `send_message`, `get_session`, `archive_session`), which the
  Claude Code CLI does not provide.
- **bash, git, and a BSD or GNU `stat`**, so macOS or Linux, for the watchdog and overlap scripts.

## Layout

```text
skills/crew/                the skill: this directory is what gets installed
  SKILL.md                  the contract: messages, input invariant, authority, orchestrator + worker flows
  references/               brief template, ledger format, docs/CREW.md interview, the built-in workflow
  scripts/
    watchdog.sh             background poller that wakes the orchestrator when a looping worker stalls
    overlap.sh              parallel-safety check: does a candidate surface collide with in-flight workers?
test/                       sandboxed suites for both scripts and for the repo's checks (touch nothing real)
scripts/
  link-skills.sh            symlink skills/* into ~/.claude/skills (idempotent, never clobbers)
  verify.sh                 every CI check, in CI's order; the pre-push hook runs it
  check-*.sh                the repo's checks: structure, content metrics, word budget, invariants, references
baselines/                  the word budget and content metrics the checks compare against
```

## Install

Link the working tree so the skill is live for every Claude Code session on the machine:

```bash
scripts/link-skills.sh          # creates ~/.claude/skills/crew -> <repo>/skills/crew
scripts/link-skills.sh check    # exit 0 only if every skill is linked
```

Or install it into one project only:

```bash
CLAUDE_SKILLS_DIR=/path/to/project/.claude/skills scripts/link-skills.sh
```

Either works. SKILL.md runs its scripts from the directory Claude Code reports as the skill's base
directory, wherever that is. The orchestrator's own state lives in `~/.claude/crew/` whichever way you
install.

## Development

- **Edits are live.** Whatever is checked out here is what every new session loads, including worker
  sessions. Keep this checkout on `main`.
- **To try a risky change, use a worktree.** Point the link at it, then point it back:

  ```bash
  git worktree add ../crew-try some-branch                        # from the repo root
  ln -sfn "$PWD/../crew-try/skills/crew" ~/.claude/skills/crew     # try it: new sessions load the branch
  ln -sfn "$PWD/skills/crew" ~/.claude/skills/crew                 # done: back to main
  ```

- **Before you push, run the checks:** `npm ci` once, then `./scripts/verify.sh`. The pre-push hook
  runs it too. [CONTRIBUTING.md](CONTRIBUTING.md) › Local checks lists the tools it needs.
- **After editing `watchdog.sh`, restart any running watchdog.** It is a long-lived process and bash reads
  its script from disk while running. Stop it by pid
  (`kill "$(cat ~/.claude/crew/<slug>/watchdog.pid)"`), never with `pkill` by name.

## Contributing & license

See [CONTRIBUTING.md](CONTRIBUTING.md) for commit conventions, authoring rules and local checks, and
[SECURITY.md](SECURITY.md) to report a vulnerability privately. Licensed under [MIT](LICENSE).
