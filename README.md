# crew

A Claude Code skill for orchestrator ↔ worker sessions. One orchestrator session spins up a fresh
worker session for each ticket or slice. It briefs the worker, passes operator input back and forth,
verifies the result, lands it when the operator delegates that, and cleans up. `skills/crew/SKILL.md`
is the contract both sides follow. Per-project answers live in each repo's `docs/CREW.md`, which the
skill interviews you for on first use.

## Layout

```text
skills/crew/
  SKILL.md              the contract: messages, input invariant, authority, orchestrator + worker flows
  references/           brief template, ledger format, docs/CREW.md interview
  watchdog.sh           background poller that wakes the orchestrator when a looping worker stalls
  watchdog.test.sh      sandboxed tests for watchdog.sh (touches nothing real)
  overlap.sh            parallel-safety check: does a candidate surface collide with in-flight workers?
scripts/
  link-skills.sh        symlink skills/* into ~/.claude/skills (idempotent, never clobbers)
```

## Install

Link the working tree so the skill is live for every Claude Code session on the machine:

```bash
scripts/link-skills.sh          # creates ~/.claude/skills/crew -> <repo>/skills/crew
scripts/link-skills.sh check    # exit 0 only if every skill is linked
```

Set `CLAUDE_SKILLS_DIR=/path/to/project/.claude/skills` to link into a single project instead.

Callers use the stable path `~/.claude/skills/crew/...`, both SKILL.md itself and each project's crew
ledger. That path must keep resolving, so install with a symlink, never a copy.

## Development

- **Edits are live.** Whatever is checked out here is what every new session loads, including worker
  sessions. Keep this checkout on `main`.
- **To try a risky change, use a worktree.** Point the link at it, then point it back:

  ```bash
  git worktree add ../crew-try some-branch                        # from the repo root
  ln -sfn "$PWD/../crew-try/skills/crew" ~/.claude/skills/crew     # try it: new sessions load the branch
  ln -sfn "$PWD/skills/crew" ~/.claude/skills/crew                 # done: back to main
  ```

- **After editing a script, run the tests:** `skills/crew/watchdog.test.sh`.
- **After editing `watchdog.sh`, restart any running watchdog.** It is a long-lived process and bash reads
  its script from disk while running. Stop it by pid
  (`kill "$(cat ~/.claude/crew/<slug>/watchdog.pid)"`), never with `pkill` by name.
