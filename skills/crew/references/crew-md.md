# docs/CREW.md — first-use interview and template

`docs/CREW.md` holds this project's answers for the `crew` orchestrator. Only the orchestrator reads it.
It's created at the first spawn. Nothing in it is required: every field has a working default.

## Interview

Detect first, then show **one** card with every detected value filled in. The operator replies `go` or
overrides lines. Ask only what detection left blank. Write the file, tell the operator it's ready to
commit, and continue the spawn. Workers don't need it committed; the brief carries everything.

| Field | Detect from | Default when nothing is found |
|---|---|---|
| Workflows | `docs/crew/workflows/*.md`; a pipeline skill that takes a ticket id (→ a one-stage workflow that runs it) | `standard`, the default. Offer to copy it to `docs/crew/workflows/<name>.md` as a start for the project's own |
| Ticket source | `docs/HARNESS.md` › Task tracker, a tracker MCP that's connected, `docs/tasks.md`, `gh` remote | the brief carries the task inline |
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

A `.env` line in worktree setup copies secrets into another directory. Propose it; never add it
without the operator's `go`. `ff-only` lets the orchestrator land work on the operator's per-card
delegation. Propose it only when the project lands by local fast-forward, not through PRs.

## Migration

A `CREW.md` that still has `## Verbs` predates workflows. Convert it on first use, before the spawn:
show the operator the diff, and write it only on their `go`.
- each verb → `docs/crew/workflows/<verb>.md`. A `command` verb becomes one stage that runs the
  command, stopping at the verb's stop point. An `inline` verb becomes a copy of `standard` plus the
  verb's rules;
- `## Counters` and `## Checkpoints` fold into those files' Parameters and Rules;
- the Verbs table becomes a Workflows table.

## Template

```markdown
# CREW.md

Bindings for the `crew` orchestrator. Only the orchestrator reads this; workers get everything in
their brief.

## Workflows
| Name | File | Default |
|---|---|---|
| standard | built-in | ✓ |

A project workflow is a self-contained file, often a copy of `standard` plus the project's own
stages. Its row names the file; ✓ marks the default.

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

## Defaults
- title: `{TICKET} — {ticket title}`
- cleanup, whole ticket: archive when merged
- cleanup, slice: keep
```
