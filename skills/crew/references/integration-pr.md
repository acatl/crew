---
name: pr
description: The built-in integration. Land a workflow's work by GitHub pull request — open it, run its review rounds, merge it on a go.
---

# Integration: pr

Your workflow's `handoff` continues into these stages when your brief names this file. `<base>` is
your brief's Base branch. The crew contract (SKILL.md) and your workflow's Rules sit under it;
nothing here changes them.
To adapt it, edit a copy at `docs/crew/integrations/pr.md`.

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

Run `git fetch origin <base>` and get `verify` green on a clean tree. Push your own
branch and run `gh pr create --base <base>`: a Conventional Commits title; a body of what changed,
why, the risk. Call the app's `get_status`; if it doesn't report this PR, call `bind_pr` with its
URL. Then call `set_monitor` with `auto_fix: true`. Any of these calls can raise an approval
prompt, which blocks it. Send `NEED-INPUT` marked `answer: in this session only` before them, unless
`get_session("self")` reports `permissionMode` `auto` or `bypassPermissions`.

- **Ends:** PR open, bound, monitor on.
- **Report:** `checkpoint open`: PR URL, sha, push time.
- **Orchestrator:** records the PR, and its monitor in the ledger's Monitors.
- **Clears:** yes, monitor off first and back on at the resume.

### round

Arm a settle timer first, on entering and after a resume too: a background command
(`run_in_background`) that exits once `settle` minutes have passed since the push, or earlier once
every reviewer of the previous push has reviewed the head (none yet: the full window). End each
waiting turn with `waiting: settle timer, until <push time + settle>`. Woken by the monitor mid-settle → keep waiting.

Read every review thread and body (some findings have no thread).
Triage each finding: fix it, decline it with a reason cited to code or a rule, or defer it (the
operator's call). Fix, review the fixes as your workflow's review does, run `verify`, and push
once. Reply to each finding, then resolve exactly the threads this round dispositioned. A base that
moved (`BEHIND`, a conflict) → merge it at the next round's start, never mid-round, or alone as a
sync push.

A round with nothing to fix pushes nothing. Check the merge rule yourself once CI
concludes (still running → a background `gh pr checks <N> --watch`, ending the turn `waiting: CI`),
and add `merge bar met` or the condition that fails to the report. The clean round then
sends the merge `NEED-INPUT` ("merge?", or the failing condition and the choices), marked
`answer: in this session only` unless the bar is met and your brief's Landing is `delegated`, and
ends the turn.
Send `NEED-INPUT` before a round `rounds` doesn't allow, with each round's fixes and what is still open.

- **Ends:** the round's push is up and its findings dispositioned, or the clean round's report sent.
- **Report:** `checkpoint round`: round, sha, push time, fixed, declined, CI, silent reviewers.
- **Orchestrator:** verifies the sha. On a clean round it checks the merge rule itself, by running.
  Met, with no `landing: operator` on the card and its "merge?" marked `answer: here or relay`, it
  tells the worker to merge by `ANSWER`; else it nudges the operator, with the failing condition if
  missed, and relays no merge.
- **Clears:** after a push, yes, monitor off first; never after a clean round.

### merge

Merge only on a go to your "merge?": the orchestrator's `ANSWER` under `landing`, or the operator's
yes in this session, never a relayed go. Run `gh pr merge <N> --squash --match-head-commit
<sha>` and poll in the background until `gh pr view <N> --json state,mergeCommit` reads `MERGED`:
a merge queue or auto-merge only queues it. `CLOSED`, or `OPEN` with neither `isInMergeQueue` nor
`autoMergeRequest` (`gh api graphql`) → `BLOCKED`. While waiting, fix and push nothing. The
operator merged instead: wait the same. At `MERGED`, turn the monitor off (`auto_fix: false`) and
report.

- **Ends:** merged.
- **Report:** `stop merge`: `mergeCommit`'s sha, monitor off, carried.
- **Orchestrator:** reads `MERGED` itself, runs Post-land, cleans up per the card, and carries
  findings into the next unit.
- **Clears:** no

## Rules

- **Record each push's time in your ledger:** after a clear, `settle` runs from it, never the commit's.
- **Consent.** The brief grants a push to your own branch, your own PR, its binding, and writes to
  it (replies, resolves). Anything else, a merge outside the merge rule or under `landing: operator`
  included, is a Hard Gate: the operator's yes in this session, never relayed.
- **The merge rule:** CI green on the head; the PR targets `<base>`; `verify` green after
  `git fetch origin <base>`; every finding dispositioned, replied to and resolved; `reviewDecision`
  not blocking; at least one non-empty review. Judge `reviewDecision` and `mergeStateStatus`, never the open-thread count: a
  `CHANGES_REQUESTED` survives resolving every thread.
