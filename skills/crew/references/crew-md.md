# docs/CREW.md — first-use interview and template

`docs/CREW.md` holds this project's answers. Only the `crew` orchestrator reads it. It's created at
the first spawn. Nothing in it is required.

## Interview

Detect first, then show **one** card with every detected value filled in; the operator replies `go` or
overrides lines. Ask only what detection left blank. Write the file, say it's ready to commit, and
continue the spawn: the brief carries everything, so workers don't need it committed.

| Field | Detect from | Default when nothing is found |
|---|---|---|
| Workflows | `docs/crew/workflows/*.md`; a pipeline skill that takes a ticket id (→ a one-stage workflow that runs it) | `standard`, the default. Offer to copy it to `docs/crew/workflows/<name>.md` as a start for the project's own |
| Ticket source | `docs/HARNESS.md` › Task tracker, a tracker MCP that's connected, `docs/tasks.md`, `gh` remote | the brief carries the task inline |
| Base (usual default only: the orchestrator picks per unit) | `git symbolic-ref --short refs/remotes/origin/HEAD` less `origin/`, the main checkout's current branch | `main` |
| Verify | `docs/HARNESS.md` › Sensors, `package.json` `check`/`test`, `Makefile` `test` | ask now; `verify` needs it |
| Worktree setup | a lockfile (`package-lock.json` → `npm ci`, `pnpm-lock.yaml` → `pnpm install`, …) in the root and in any workspace package, gitignored runtime files at the root (`.env`) | `none` |
| Branch naming | — | keep the `claude/…` branch |
| Integration (how work lands) | `docs/HARNESS.md` merge mode (workers merge PRs under a written rule → `pr`); a GitHub remote with `gh` → offer `pr` | `operator`. `pr` offers `file: built-in`; to adapt it, copy the skill's `references/integration-pr.md` to `docs/crew/integrations/pr.md` and name that |
| Post-land | anything the main checkout serves from a gitignored build (a CLI or skill linked globally from here → its build command) | `none` |
| Standing boundaries | install or link commands that write outside the repo (`<tool> install`, `npm link`, home-dir symlinks) → "never run `<cmd>` from a worktree" | `none` |
| Title / cleanup defaults | — | see template |
| Ledger budget | — | live file under ~100 lines |
| Slot limit | — | none; ask before a second worker on a shared surface |
| Watchdog thresholds — cadence, no-commit, sub-agent step | how long this project's units normally run between commits, and how many sub-agents one normal review round spawns (the step is a sub-agent count, not a round count) | 20 min · 60 min · step 3 — hg's measured values and `watchdog.sh`'s own defaults; it fires when the count *exceeds* the step |

A `.env` line in worktree setup copies secrets into another directory. Propose it; never add it
without the operator's `go`. Propose `ff-only` only when the project lands by local fast-forward.

## Migration

A `CREW.md` with `## Verbs` predates workflows. Convert it on first use, before the spawn: show the
diff, write on `go`.
- each verb → `docs/crew/workflows/<verb>.md`: a `command` verb, one stage running the command to its
  stop point; an `inline` verb, `standard` plus its rules;
- each `## Counters` line → a parameter, limit and at-limit action kept (review→fix iterations →
  `iterations`). `## Checkpoints` → the stages' Clears; none → `clear: never`, as before;
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
Chosen per unit by the orchestrator, written into the brief as a branch plus a sha. Usual default
here: `main`.

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

`operator`: the operator lands every branch. `ff-only`: on a card's `landing: delegated`, the
orchestrator lands a verified branch with `git merge --ff-only <worker-branch>` in the main
checkout. Never a merge commit, never a push. `pr`: work lands by pull request, merged by the worker
on the orchestrator's go when the merge rule holds, unless the card says `landing: operator`. Add
`- file: built-in` (or a project copy, such as `docs/crew/integrations/pr.md`): a workflow's
`handoff` continues into that file's stages, and the file holds the merge rule. Without `file:`, a
workflow with its own PR stages merges under `- merge rule: <where>`. Post-land starts by pulling
`<base>`.

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
