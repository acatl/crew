# crew

A Claude Code skill for orchestrator ↔ worker sessions. One orchestrator session spins up a fresh
worker session for each ticket or slice. It briefs the worker, passes operator input back and forth,
verifies the result, lands it when the operator delegates that, and cleans up. `skills/crew/SKILL.md`
is the contract both sides follow. Per-project answers live in each repo's `docs/CREW.md`, which the
skill interviews you for on first use.

**Workflows** set how a worker works: one Markdown file of parameters, stages (each with its end, its
report and what the orchestrator does then) and rules. The skill ships `standard`: plan, build,
isolated review, hand off committed and verified. A project lists its own in `docs/CREW.md`, usually
a copy of `standard` with stages added. Pick one per spawn: `spin up a <workflow> worker for WF2`.

**Integrations** set how the work lands, in the same shape. The skill ships `pr`: open a GitHub pull
request, run its review rounds, merge it on a go. `docs/CREW.md` › Integration names it (`mode: pr`,
`file: built-in`), and `standard`'s handoff continues into it. To adapt it, copy it into the project,
as this repo does in `docs/crew/integrations/pr.md` (CodeRabbit, its review pool, the round
procedure).

## Usage

Say it to the session you want as the orchestrator:

- `spin up a worker for <ticket>`: one worker, on the project's default workflow.
- `spin up a <workflow> worker for <ticket>`: one worker, on a named workflow.
- `spin up workers for A → B → C`, or `queue workers for A, B and C in order`: a sequence, run one
  at a time in that order.
- `crew status`: one row per worker, with any question waiting on you.

The orchestrator answers with a card listing the title, workflow, integration, scope, cleanup, landing and a
parallel-safety check. Reply `go` to accept it, or override a line. In the desktop app each worker
appears as a chip; click it to start the session. In the terminal the worker starts at once as a
background session, with no tab of its own: see [Watching a terminal worker](#watching-a-terminal-worker).

The default workflow is the ✓ row of `docs/CREW.md` › Workflows, else the built-in `standard`.

Landing follows `docs/CREW.md` › Integration's mode:

- **`operator`** (the default): you land every branch.
- **`ff-only`**: on a card's `landing: delegated`, the orchestrator fast-forwards the verified branch
  into the base and runs Post-land.
- **`pr`**: the worker opens a PR and merges it on the orchestrator's go, under the integration's
  written merge rule, unless the card says `landing: operator`. A card's `integration: none` gives a
  unit that pushes nothing; you land it.

### Watching a terminal worker

A background worker has no tab. To watch it or type into it, open another terminal and run
`claude attach <id>`; the orchestrator gives you the id when it spawns the worker and whenever it
sends you to it. Leaving the view (← to the agent view, or Ctrl+Z to your shell) leaves the worker
running.

- **Look without attaching:** `claude logs <id>` prints a running worker's recent output, and
  `claude agents` opens the agent view of every active session (`claude agents --json` prints each
  with a `status`: `busy`, `idle` or `waiting`). `waiting` means it sits on a prompt only you can
  answer, in the worker, such as a tool permission. A worker that asked you a question and ended
  its turn shows `idle`, so rely on the orchestrator's nudge, or `crew status`, to tell you which
  worker needs you.
- **Answer in the worker itself:** tool-permission prompts, anything the worker's brief gates (an
  install, shared config, a push it isn't granted), and any question it marks `answer: in this
  session only`, such as `standard`'s plan approval or a merge go you kept for yourself. The
  orchestrator never answers or relays these; it sends you to the worker.
- **A restart brings a new id.** The orchestrator may restart a crashed or wedged worker; that closes
  your attached view, and the orchestrator gives you the new id.
- **Never reopen a stopped worker,** neither with the `claude --resume …` line its exit screen prints
  nor with `claude attach <old id>`. Either revives it behind the orchestrator's back, possibly in
  the same worktree and on the same branch as its successor.

[`skills/crew/references/host.md`](skills/crew/references/host.md) holds the mechanics.

## Requirements

- **A host: the Claude desktop app (Code tab), or the Claude Code CLI 2.1.300 or later.** The app
  spawns and messages sessions through its session tools; the CLI through background sessions
  (`claude --bg`, `claude agents --json`) and `SendMessage`. `skills/crew/references/host.md` maps
  each to the other. The orchestrator's host is the workers' host.
- **bash, git, jq, and a BSD or GNU `stat`**, so macOS or Linux, for the watchdog and overlap scripts.

## Layout

```text
skills/crew/                the skill: this directory is what gets installed
  SKILL.md                  the contract: messages, input invariant, authority, orchestrator + worker flows
  references/               brief template, ledger format, docs/CREW.md interview, host verbs, the built-in workflow and integration
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
  (`kill "$(cat ~/.claude/crew/<slug>/watchdog.pid)"`), never by a process-name match (`pkill`,
  `pgrep`, `ps | grep`): every project's watchdog is a `watchdog.sh`.

## Contributing & license

See [CONTRIBUTING.md](CONTRIBUTING.md) for commit conventions, authoring rules and local checks, and
[SECURITY.md](SECURITY.md) to report a vulnerability privately. Licensed under [MIT](LICENSE).
