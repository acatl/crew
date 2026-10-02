# CREW.md

Bindings for the `crew` orchestrator when crew itself is developed with crew. Only the
orchestrator reads this; workers get everything in their brief. Adapted from `acatl/hg`'s
`docs/CREW.md` so both repos run their workers the same way (operator, 2026-09-25).

**This file holds the project's facts, not the situation.** Which branch a unit starts from,
what it may push, and when it stops are decided per unit by the orchestrator and written into
that unit's brief.

## Workflows

| Name | File | Default |
|------|------|---------|
| standard | built-in | ✓ |

How the work lands is the integration's (below), not the workflow's.

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

- mode: pr
- file: `docs/crew/integrations/pr.md`
- **Pull request** (this repo's integration, which holds the merge rule in § Stopping › Merging).
  The brief grants a push to the worker's OWN branch, opening its own PR, and binding that PR in the
  app with its review monitor on (the integration's `open`), nothing else. The worker merges only on
  the orchestrator's go, given under the operator's standing merge rule, unless the card says
  `landing: operator`; otherwise the operator merges. That go is the written rule being applied, not
  consent relayed from another session, so the worker acts on it.
- **A card's `integration: none`** gives a unit that pushes nothing; the operator lands it.
- **A worker's PR review monitor** goes in the ledger's Monitors at its `checkpoint open`
  (stop: the worker turns `auto_fix` off after merging); drop the line at cleanup.
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

- **Never run `scripts/link-skills.sh`, or repoint `~/.claude/skills/crew`, from a worktree.**
  Either would make every session on the machine load the worktree's unlanded skill.
- **Push and PR only as the brief grants:** never `main`, never another worker's branch.
- **Hard Gates need the operator's yes in the worker's own session:** adding, removing or
  changing a dependency, CI and shared config, anything written outside the repo. Installing
  from the committed lockfile (`npm ci`) is not a gate.
- **Never `--no-verify`.**

## Defaults

- title: `{UNIT} — {one-line goal}`
- cleanup, whole unit: archive once its PR has merged
- cleanup, slice or a unit with a planned follow-up: keep

## Ledger

- budget: live file under ~100 lines
- watchdog: check every 20 min · warn at 60 min with no commit · warn once sub-agents since the
  last push pass 3, then again on each further +3
