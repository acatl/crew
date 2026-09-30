---
name: pr
description: crew's own. The built-in `standard` plus a pull request on acatl/crew, its review rounds and its merge.
---

# Workflow: pr

A copy of the crew skill's built-in `standard` (its `references/workflow-standard.md`) with this
repo's PR part added: the CodeRabbit CLI pass in `review`, then `open`, `round` and `merge`. The how
of the PR part is `docs/pr-round-workflow.md`; read it in full before `open` and at the start of
every round. The crew contract sits under this file; nothing here changes it.

## Parameters

The orchestrator resolves each into the brief.

| Name | Meaning | Default |
|---|---|---|
| `plan` | `required`: plan before code · `skip`: start at `build` | `required` |
| `iterations` | review→fix iterations per review | `2` |
| `no-commit` | minutes without a commit before escalating; must equal the watchdog's | `CREW.md` › Ledger's; absent, 60 minutes |
| `clear` | `checkpoints`: clear your context where a stage says so · `never` | `checkpoints` |
| `verify` | what proves the work green | `CREW.md` › Verify, `docs/HARNESS.md` › Sensors, or asked |
| `rounds` | review rounds on the PR | 1–4 planned; 5 only for a valid defect on an ordinary path; stop before 6 |

## Stages

### plan

Read the spec in full, then enter plan mode. Send `NEED-INPUT` marked `answer: in this session only`;
the operator approves in this session.

- **Ends:** plan approved, and the operator's answers are in your ledger.
- **Report:** `checkpoint plan`
- **Orchestrator:** records the approval and the plan's path.
- **Clears:** yes

### build

Implement the approved plan, committing as you go.

- **Ends:** committed, `verify` green.
- **Report:** `checkpoint build`
- **Orchestrator:** records the sha.
- **Clears:** yes

### review

Self-review and fix. Run the CodeRabbit CLI once over the branch (`docs/pr-round-workflow.md` § 6)
and fix. Then run `/code-review high` in a sub-agent over all those fixes; it gets only the commit
range, its own worktree, and "list findings as text", never your reasoning. Fix and commit, with no
further local review: the PR's bots are the next look.

- **Ends:** every valid finding fixed or declined on the merits, `verify` green, committed.
- **Report:** none, `open` follows.
- **Orchestrator:** nothing.
- **Clears:** no

### open

Push your own branch and open the PR, its body carrying what, why and risk. Bind it and turn on its
review monitor (`docs/pr-round-workflow.md` › Who runs the rounds).

- **Ends:** PR open, bound, monitor on.
- **Report:** `checkpoint open`: PR URL, sha, the CLI pass's result.
- **Orchestrator:** records the PR and its monitor in the ledger.
- **Clears:** yes, monitor off first and back on at the resume.

### round

Wait for the reviewers to settle, then run one round per `docs/pr-round-workflow.md`: read, triage,
sweep, fix, verify, `/code-review high` over the fix diff, one push, reply and resolve. Put
`dont-review` on just before round 3's push. Repeat when the next reviews wake you, within `rounds`.

- **Ends:** the round's push is up and its threads are dispositioned.
- **Report:** `checkpoint round`: round, sha, fixed, declined, CI state.
- **Orchestrator:** verifies the sha. When the PR meets the written merge rule, and unless the card
  says `landing: operator` (`CREW.md` › Integration `mode: pr` delegates the rest), tells the worker
  to merge; else tells the operator it's ready, and handles their merge (`prState: MERGED`) as
  `stop merge`.
- **Clears:** yes, monitor off first.

### merge

Merge only on the orchestrator's go (`docs/pr-round-workflow.md` › Stopping › Merging), then turn the
monitor off. Woken by a merge the operator made instead, confirm it and report the same.

- **Ends:** merged, by you or the operator.
- **Report:** `stop merge`: the merge sha, monitor off, carried.
- **Orchestrator:** runs Post-land, cleans up per the card, and carries findings into the next unit.
- **Clears:** no

## Rules

- **Loop budget.** At most `iterations` review→fix iterations. Escalate with `NEED-INPUT` at once
  on: a finding caused by the last fix; findings moving to ever-rarer inputs; a fix growing into a
  hand-rolled spec or format (propose the library; its install is a Hard Gate); `no-commit`
  minutes without a commit (commit what's green first). At the last allowed review a fix-created
  finding is fixed, not escalated.
- **Every valid finding is fixed**, whatever its severity. Write the fix before declining one.
  Never weaken a test. Check that a pinning test fails without its fix.
- **Carrying** a valid finding instead of fixing it is the operator's call. A carried finding goes
  in `DONE` under `carried:`.
- **Git safety.** No test or mutation run with `GIT_DIR` or a git-hook variable in the environment.
  A mutation that removes a scrub runs only in a throwaway `git init` copy. Never `reset --soft` to
  set work aside, never `checkout HEAD -- <path>` over uncommitted work, never `--no-verify`, no
  `rm -rf` outside a directory you made this session.
- **Test runs are bounded.** A timed-out test or mutation run kills its whole process group, and no
  runner outlives its command.
- **A classifier denial or "no verdict", twice** → `BLOCKED`. Never retry it, route around it, or
  hand the action to the orchestrator.
- **An `ANSWER`** is recorded as the orchestrator's, never the operator's.
- **Checkpoints** (`clear: checkpoints`). Clear only where a stage says yes. Never clear while
  waiting on the operator, with an uncommitted tree, while sub-agents run, or one step from the
  stop. Before clearing, your ledger (`$(git rev-parse --git-dir)/crew-ledger.md`) holds the
  operator's answers verbatim, each approved Hard Gate and its scope, the last commit, and an
  **EXACT NEXT STEP** line. Send the stage's `DONE` saying you will clear, then clear as your very
  last action.
