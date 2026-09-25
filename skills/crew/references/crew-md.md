# docs/CREW.md — first-use interview and template

`docs/CREW.md` holds this project's answers for the `crew` orchestrator. Only the orchestrator reads it.
It's lazy: the file is created at the first spawn, and a row is added the first time a new verb is used.
Only the verb's command is required. Everything else has a working default.

## Interview

Detect first, then show **one** card with every detected value filled in. The operator replies `go` or
overrides lines. Ask only what detection left blank. Write the file, tell the operator it's ready to
commit, and continue the spawn. Workers don't need it committed; the brief carries everything.

| Field | Detect from | Default when nothing is found |
|---|---|---|
| Verb kind + command | `command`: installed skills that take a ticket id (e.g. `/hg-build <id> [yolo]` → `/hg-build {ticket} {mode}`), `package.json` scripts, `Makefile`. `inline`: the project's units are specs, not tracker tickets (a plan doc that names units, no command that takes an id) | **ask** — the one required answer |
| Stop point | the command's own documented end (e.g. "verified, not shipped") | "the command's natural end" |
| Ticket source | `docs/HARNESS.md` › Task tracker, a tracker MCP that's connected, `docs/tasks.md`, `gh` remote. `inline` verbs: the spec in the brief | the brief carries the task inline |
| Base (usual default only: the orchestrator picks per unit) | `git symbolic-ref --short refs/remotes/origin/HEAD`, the main checkout's current branch | `main` |
| Verify | `docs/HARNESS.md` › Sensors, `package.json` `check`/`test`, `Makefile` `test` | ask at the first DONE |
| Worktree setup | a lockfile (`package-lock.json` → `npm ci`, `pnpm-lock.yaml` → `pnpm install`, …) in the root and in any workspace package, gitignored runtime files at the root (`.env`) | `none` |
| Branch naming | — | keep the `claude/…` branch |
| Integration mode | `docs/HARNESS.md` merge mode (single-merge via PR → `operator`) | `operator` |
| Post-land | anything the main checkout serves from a gitignored build (a CLI or skill linked globally from here → its build command) | `none` |
| Standing boundaries | install or link commands that write outside the repo (`<tool> install`, `npm link`, home-dir symlinks) → "never run `<cmd>` from a worktree" | `none` |
| Title / cleanup defaults | — | see template |
| Ledger budget | — | live file under ~100 lines |
| Slot limit | — | none; ask before a second concurrent worker on a shared surface |
| Watchdog thresholds — cadence, no-commit, sub-agent step | how long this project's units normally run between commits, and how many sub-agents one normal review round spawns (the step is a sub-agent count, not a round count) | 20 min · 60 min · step 3 — hg's measured values and `watchdog.sh`'s own defaults; it fires when the count *exceeds* the step |
| Counters | budgets this project already runs on (review rounds, iteration caps, vendor limits) | none |

A `.env` line in worktree setup copies secrets into another directory. Propose it; never add it
without the operator's `go`. `ff-only` lets the orchestrator land work on the operator's per-card
delegation. Propose it only when the project lands by local fast-forward, not through PRs.

## Template

```markdown
# CREW.md

Bindings for the `crew` orchestrator. Only the orchestrator reads this; workers get everything in
their brief.

## Verbs
| Verb | Kind | Command | Stop point |
|---|---|---|---|
| build | command | `/hg-build {ticket} {mode}` | verified, not shipped |

`command`: the worker runs the Command with `{ticket}` and `{mode}` substituted; `{mode}` is the
operator's mode token (`yolo`, `gated`, …), or empty when none was given.
`inline`: the spec travels in the brief (or in `START` for a queued worker); the Command column names
the rules the worker carries it out under.

## Ticket source
Kino task — read it with the Kino MCP `get_task`.

## Base
Chosen per unit by the orchestrator and written into the brief as a ref plus a sha. The usual
default here: `main`.

Never assume which commit the app cut a worker's worktree from (observed: the default branch, or the
main checkout's branch, depending on the setup). The worker re-points itself to the brief's sha
first.

## Verify
Run in the worker's worktree after DONE:
- `npm run check`

## Worktree setup
- `npm ci`

## Branch naming
keep

## Integration
- mode: operator

`operator`: the operator lands every branch. `ff-only`: when the operator writes `landing: delegated`
on a card, the orchestrator lands each verified branch with `git merge --ff-only <worker-branch>` in
the main checkout. Never a merge commit, never a push.

## Post-land
Run in the main checkout after each landing:
- none

## Standing boundaries
Copied into every brief:
- none

## Ledger
- budget: live file under ~100 lines
- slot limit: 2 concurrent workers
- watchdog: check every 20 min · warn at 60 min with no commit · warn once sub-agents since the last
  push pass 3, then again on each further +3 (one review round here spawns 2, so 3 is ~1.5 rounds)

## Counters
Budgets the orchestrator tracks per worker and must not lose across a compaction. The names, limits and
what happens at the limit are this project's; the skill carries them and warns, and knows nothing about
what they mean.
- review rounds: limit 5 → worker stops before round 5, operator decides

## Defaults
- title: `{TICKET} — {ticket title}`
- cleanup, whole ticket: archive when merged
- cleanup, slice: keep
```
