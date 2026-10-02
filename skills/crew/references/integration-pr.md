---
name: pr
description: The built-in integration. Land a workflow's work by GitHub pull request — open it, run its review rounds, merge it on a go.
---

# Integration: pr

How finished work lands: a pull request, its review rounds and its merge. Your workflow's `handoff`
continues into these stages when your brief names this file. It needs `gh` and the app's PR binding,
nothing else. The crew contract (SKILL.md) and your workflow's Rules sit under it; nothing here
changes them. To adapt it (a reviewer roster, labels, a review budget), copy it to
`docs/crew/integrations/pr.md` and edit the copy.

## Parameters

The orchestrator resolves each into your brief; read the values there, never `CREW.md`.

| Name | Meaning | Default |
|---|---|---|
| `rounds` | review rounds on the PR, one push each | 1–3; stop before 4 |
| `settle` | minutes to wait after a push for its reviews | `20` |
| `no-commit` | minutes without a commit; must equal the watchdog's | `CREW.md` › Ledger's; absent, 60 minutes |
| `verify` | what proves the work green | `CREW.md` › Verify, else `docs/HARNESS.md` › Sensors, else asked |

## Stages

### open

Run `git fetch origin <base>`, then `verify` on a clean tree; fix anything red first. Push your own
branch and run `gh pr create`: a Conventional Commits title, and a body saying what changed, why,
and the risk. Call the app's `get_status`; if it doesn't report this PR, call `bind_pr` with its URL;
then call `set_monitor` with `auto_fix: true`. Each of these calls raises an approval prompt in some
permission modes, and a prompt blocks the call. Send `NEED-INPUT` marked `answer: in this session
only` before them, unless `get_session("self")` reports `permissionMode` `auto` or
`bypassPermissions`.

- **Ends:** PR open, bound, monitor on.
- **Report:** `checkpoint open`: PR URL, sha, push time.
- **Orchestrator:** records the PR, and its monitor in the ledger's Monitors.
- **Clears:** yes, monitor off first and back on at the resume.

### round

Arm a settle timer first, on entering and after a resume too: a background command (the Bash tool's
`run_in_background`) that exits once `settle` minutes have passed since the push, or earlier once
every reviewer that reviewed this PR before has reviewed the head. A silent reviewer wakes no one;
the timer does. End each waiting turn with `waiting: settle timer, until <push time + settle>`.
Woken by the monitor mid-settle → keep waiting.

Read every review thread and every review body: some reviewers file findings with no thread.
Triage each finding: fix it, decline it with a reason cited to code or a rule, or defer it, which is
the operator's call. Fix, review the fixes as your workflow's review does, run `verify`, and push
once. Reply to each finding, then resolve exactly the threads this round dispositioned. A base that
moved (`BEHIND`, a conflict) → merge it at the next round's start, never mid-round, or alone as a
sync push.

A round with nothing to fix pushes nothing. Check the merge rule (Rules) yourself once CI
concludes (still running → a background `gh pr checks <N> --watch`, ending the turn `waiting: CI`),
and add `merge bar met` or the condition that fails to the report. The clean round then
sends the merge `NEED-INPUT` ("merge?", or the failing condition and the choices) and ends the turn.
Send `NEED-INPUT` before a round `rounds` doesn't allow, with what each round fixed and what is still
open.

- **Ends:** the round's push is up and its findings dispositioned, or the clean round's report sent.
- **Report:** `checkpoint round`: round, sha, push time, fixed, declined, CI, silent reviewers.
- **Orchestrator:** verifies the sha. On a clean round it checks the merge rule itself, by running.
  Met, with no `landing: operator` on the card, it tells the worker to merge by `ANSWER` to its
  "merge?"; met under `landing: operator`, it nudges the operator; missed, it nudges with the
  failing condition and relays no merge.
- **Clears:** after a push, yes, monitor off first; never after a clean round.

### merge

Merge only on a go to your "merge?": the orchestrator's `ANSWER` under `landing`, the operator's go
relayed, or the operator's yes in this session. Run `gh pr merge <N> --squash --match-head-commit
<sha>`, then turn the monitor off (`auto_fix: false`). Woken by a merge the operator made instead,
confirm it and report the same.

- **Ends:** merged.
- **Report:** `stop merge`: merge sha, monitor off, carried.
- **Orchestrator:** runs Post-land, cleans up per the card, and carries findings into the next unit.
- **Clears:** no

## Rules

- **Your workflow's Rules hold here:** its loop budget, git safety, carrying and checkpoints.
- **Consent.** The brief grants a push to your own branch, your own PR, its binding, and writes to
  it (replies, resolves). Anything else, a merge outside the merge rule included, is a Hard Gate:
  the operator's yes in this session, never relayed.
- **The merge rule:** CI green on the head; `verify` green after `git fetch origin <base>`; every
  finding dispositioned, replied to and resolved; `reviewDecision` not blocking; at least one
  round's reviews in. Judge `reviewDecision` and `mergeStateStatus`, never the open-thread count: a
  `CHANGES_REQUESTED` survives resolving every thread.
