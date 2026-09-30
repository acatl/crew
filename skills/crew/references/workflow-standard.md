---
name: standard
description: The built-in workflow. Plan, build, review in isolation, hand off committed and verified; no PR.
---

# Workflow: standard

The crew contract (SKILL.md) sits under this file; nothing here changes it. To build on it, copy it
to `docs/crew/workflows/<name>.md` and extend the copy.

## Parameters

The orchestrator resolves each into your brief; read the values there, never `CREW.md`.

| Name | Meaning | Default |
|---|---|---|
| `plan` | `required`: plan first · `skip`: start at `build` | `required` |
| `iterations` | review→fix iterations | `2` |
| `no-commit` | minutes without a commit; must equal the watchdog's | `CREW.md` › Ledger's; absent, 60 minutes |
| `clear` | `checkpoints`: clear where a stage says so · `never` | `checkpoints` |
| `verify` | what proves the work green | `CREW.md` › Verify, else `docs/HARNESS.md` › Sensors, else asked |

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

Self-review, then run `/code-review high` in a sub-agent that gets only the commit range, its own
worktree, and "list findings as text", never your reasoning. Fix and commit. Run it once more over
those fixes alone. Any other reviewer's fixes get the same look: fixes are code no one has reviewed.

- **Ends:** every valid finding fixed or declined on the merits, `verify` green, committed.
- **Report:** none, `handoff` follows.
- **Orchestrator:** nothing.
- **Clears:** no, one step from the stop.

### handoff

Update your ledger, report, and stop.

- **Ends:** reported.
- **Report:** `stop handoff`: branch, sha, verify result, fixed, declined, carried.
- **Orchestrator:** verifies by running, lands per the card and `CREW.md` › Integration, cleans up,
  and carries findings into the next unit.
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
