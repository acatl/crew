# CREW.md

Bindings for the `crew` orchestrator when crew itself is developed with crew. Only the
orchestrator reads this; workers get everything in their brief. Adapted from `acatl/hg`'s
`docs/CREW.md` so both repos run their workers the same way (operator, 2026-09-25).

**This file holds the project's facts, not the situation.** Which branch a unit starts from,
what it may push, and when it stops are decided per unit by the orchestrator and written into
that unit's brief.

## Verbs

| Verb | Kind | Command | Stop point |
|------|------|---------|------------|
| unit | inline | The unit spec carried inline in the brief, run under the protocol the brief names (for a PR: `docs/pr-round-workflow.md`) | Whatever the brief states. Default when it is silent: committed on the worker's branch, verified, never pushed |

## Ticket source

The brief carries the spec inline, derived by the orchestrator from the operator's request and
from any GitHub issue on `acatl/crew` it names. A worktree session doesn't see the
orchestrator's memory, so the brief carries every decision the unit needs.

## Base

**Chosen per unit, never fixed here.** The orchestrator picks the commit the unit must start
from and writes it into the brief as **a ref plus a sha**. The worker's first setup step
re-points it there, guarded (crew skill › *Worker* step 2), and confirms `git rev-parse HEAD`.

## Verify

Run in the worker's worktree after DONE, on a clean tree after `git fetch origin main`:

- `./scripts/verify.sh`: every CI check, in CI's order.

## Worktree setup

- The guarded self re-point to the brief's sha, first.
- `npm ci`, once `package-lock.json` exists on the base.

## Branch naming

Keep the app's `claude/…` branch unless the brief names one (a PR worker's branch is named by
its PR).

## Integration

- **Pull request**, always. The brief grants a push to the worker's OWN branch, opening its own
  PR, and binding that PR in the app with its review monitor on (Standing boundaries), nothing
  else. The worker merges only on the orchestrator's go, given under the operator's standing merge
  rule (`docs/pr-round-workflow.md` › Stopping › Merging); otherwise
  the operator merges. That go is the written rule being applied, not consent relayed from
  another session, so the worker acts on it.
- **A PR worker's round `DONE` is a checkpoint** (its first line says `checkpoint`): verify it and
  write the verdict, but don't land, clean up, or `START` the next unit; that waits for the merge
  `DONE`. On the first one, add the worker's PR review monitor to the ledger's Monitors (stop: the
  worker turns `auto_fix` off after merging); drop the line at cleanup.
- **One PR in flight here at a time.** The CodeRabbit review pool is account-wide (about 5
  reviews an hour, shared with `acatl/hg` and `acatl/kino`), so a worker opens its PR only
  when the orchestrator says a slot is free.

## Post-land

After every merge to `main`, in the main checkout: confirm the tree is clean, then
`git pull --ff-only`, then `npm ci`. **The main checkout is the live skill**:
`~/.claude/skills/crew` links to its `skills/crew/`, so the pull is what makes a merge reach
every new session. The orchestrator runs it. Pulling and installing from the committed
lockfile write only inside the repo.

## Standing boundaries

Copied into every brief:

- **Plan before changing anything.** The worker enters plan mode first. Before waiting on
  approval it sends `NEED-INPUT` marked `answer: in this session only`. The operator approves
  the plan in the worker's own session; the orchestrator only nudges with a link.
- **Never run `scripts/link-skills.sh`, or repoint `~/.claude/skills/crew`, from a worktree.**
  Either would make every session on the machine load the worktree's unlanded skill.
- **Push and PR only as the brief grants:** never `main`, never another worker's branch.
- **At PR open, bind the PR and turn on its review monitor**, as `docs/pr-round-workflow.md` › Who
  runs the rounds says, which also covers its approval prompt, clearing, and turning it off.
- **Hard Gates need the operator's yes in the worker's own session:** adding, removing or
  changing a dependency, CI and shared config, anything written outside the repo. Installing
  from the committed lockfile (`npm ci`) is not a gate.
- **Never `--no-verify`.**
- **The loop budget** (crew skill › *Worker* step 7; `docs/pr-round-workflow.md` › The loop
  budget).

## Defaults

- title: `{UNIT} — {one-line goal}`
- cleanup, whole unit: archive once its PR has merged
- cleanup, slice or a unit with a planned follow-up: keep

## Counters

- review rounds: 1–4 planned; round 5 runs only for a valid defect on an ordinary path; the
  worker stops before round 6 and the operator decides (`docs/pr-round-workflow.md` › Who runs
  the rounds)
- local review→fix iterations per round: 2

## Ledger

- budget: live file under ~100 lines
- watchdog: check every 20 min · warn at 60 min with no commit · warn once sub-agents since the
  last push pass 3, then again on each further +3
