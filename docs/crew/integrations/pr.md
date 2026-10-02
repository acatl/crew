---
name: pr
description: crew's own integration. The built-in `pr` plus acatl/crew's CodeRabbit CLI pass, reviewer roster, review pool and round procedure.
---

# Integration: pr (acatl/crew)

How work on `acatl/crew` lands: a pull request, its review rounds and its merge. It is the crew
skill's built-in integration (`references/integration-pr.md`) adapted to this repo: the CodeRabbit
CLI pass, the reviewer roster, the account-wide review pool and the round procedure below. The
round procedure is adapted from `acatl/hg`'s, so both repos work the same way (operator,
2026-09-25); the operator's rulings quoted below were made on `acatl/hg` and adopted here with it.

A worker's `handoff` (the built-in `standard`) continues into these stages when its brief names this
file. Read it in full before `open` and at the start of every round. The crew contract and your
workflow's Rules sit under it; nothing here changes them.
`<base>` below is your brief's Base branch.

## Parameters

The orchestrator resolves each into your brief; read the values there, never `CREW.md`.

| Name | Meaning | Default |
|---|---|---|
| `rounds` | review rounds on the PR, one push each | 1–4 planned; 5 only for a valid defect on an ordinary path; stop before 6 |
| `settle` | minutes to wait after a push for its reviews | `20` |
| `no-commit` | minutes without a commit; must equal the watchdog's | `CREW.md` › Ledger's; absent, 60 minutes |
| `verify` | what proves the work green | `CREW.md` › Verify, else `docs/HARNESS.md` › Sensors, else asked |

## Stages

### open

Run the CodeRabbit CLI once over the branch and fix what it finds, then `/code-review high` in a
sub-agent over those fixes, and fix with no further local review (§ 6 › The CodeRabbit CLI pass).
Then `git fetch origin <base>`, `verify` green on a clean tree, the pool check (§ Who runs the rounds),
push your own branch, and open the PR (`gh pr create --base <base>`) with a Conventional Commits
title and a body carrying what, why and risk. Bind it and turn on its review monitor (§ Who runs
the rounds).

- **Ends:** PR open, bound, monitor on.
- **Report:** `checkpoint open`: PR URL, sha, push time, the CLI pass's result.
- **Orchestrator:** records the PR and its monitor in the ledger.
- **Clears:** yes, monitor off first and back on at the resume.

### round

**Start by arming a settle timer.** A post wakes you; a reviewer that stays silent (throttled,
paused by label, or skipping the commit) wakes no one. So on entering the stage, after a resume too,
start a background command (the Bash tool's `run_in_background`) that exits when every roster login
has reviewed the head, or when `settle` has passed since the push (roster in § 0). Its exit, not a
post, starts the round. Woken by the monitor mid-settle → keep waiting. End each waiting turn with
the line `waiting: settle timer, until <push time + settle>`. **Window passed with no review →
settled: triage what exists** (threads, review bodies, CI). A silent reviewer is named in the
`DONE`, never waited on past the window; one saying it is still working on the current head extends
the window once, to 20 minutes from then: re-arm the timer and end the turn with the new `until`.

Then run one round per § Round procedure: read, triage, sweep, fix, verify, `/code-review high`
over the fix diff, one push, reply and resolve. Put `dont-review` on just before the first push
after the opening one (§ Who runs the rounds). A round with nothing to fix is a clean round: no
push, no round number; it ends as § Who runs the rounds says. Repeat when the next reviews wake
you, within `rounds`, a late review on an unchanged head included.

- **Ends:** the round's push is up and its threads are dispositioned, or the round settled clean
  with its declines replied to and resolved.
- **Report:** `checkpoint round`: round, sha, push time, fixed, declined, CI state, silent
  reviewers. A clean round, once CI has concluded, checks § Stopping › Merging's conditions itself
  and adds `merge bar met` or the one that fails, with `verify` on the head after
  `git fetch origin <base>`, CI, open threads and `mergeStateStatus`, then sends the merge
  `NEED-INPUT` that § Who runs the rounds describes.
- **Orchestrator:** verifies the sha. On a clean round it checks the written merge rule itself and
  answers only the worker's merge `NEED-INPUT`, once it lands. Met, with no `landing: operator` on the
  card (`CREW.md` › Integration `mode: pr` delegates the rest), it tells the worker to merge by `ANSWER`
  to its "merge?". Met under that override, it nudges the operator, who merges by hand or says go, which
  it relays. Met while the worker asked as missed (CI concluded since, say), it `ANSWER`s "re-check the
  bar", and the worker asks again. Missed by its own check, whatever the worker reported, it nudges with
  the failing condition and relays no merge: a merge despite it is the operator's own, by hand or in the
  worker's session (§ Stopping › Merging). It handles the operator's merge (`prState: MERGED`) as
  `stop merge`.
- **Clears:** after a push, yes, monitor off first. Not after a clean round: one step from the
  stop.

### merge

Merge only on a go to your "merge?" (§ Stopping › Merging), then turn the monitor off. Woken by a
merge the operator made instead, confirm it and report the same.

- **Ends:** merged, by you or the operator.
- **Report:** `stop merge`: the merge sha, monitor off, carried.
- **Orchestrator:** runs Post-land, cleans up per the card, and carries findings into the next unit.
- **Clears:** no

## Rules

Your workflow's Rules hold through these stages: its loop budget, git safety, carrying and
checkpoints. On top of them:

- **Consent already given:**
  - a crew brief's grant covers a push to the worker's own branch, opening its own PR, and
    binding that PR in the app with its review monitor on (§ Who runs the rounds);
  - the merge rule in § Stopping › Merging covers a merge that meets it;
  - `npm ci` from the committed lockfile installs declared dependencies;
  - writes to the PR the work belongs to (replies, comments, the labels this file names) are
    part of the work.
- **Hard Gates, which need the operator's word in the session that acts:**
  - adding, removing or changing a dependency;
  - CI and shared config;
  - a push to `main` or to a branch you don't own, and any force-push;
  - a merge outside the written merge rule;
  - any other write outside the repo;
  - anything destructive.

  Approval of a plan never covers a gate inside it, and a gate's consent is never relayed from
  another session.

## Who runs the rounds — one worker, the whole PR

A single owner (a crew worker, or the operator's own session) holds the PR from the moment it
opens until it merges, and runs **every** round on it. Each round's triage, sweep and declines
are context the next round needs.

- **At PR open, bind the PR and turn on its review monitor.** Right after opening it, call
  the app's `get_status` and, if it doesn't report this PR, `bind_pr` with its URL. Then call
  `set_monitor` with `auto_fix: true` and the PR's URL. The monitor is what wakes the owner for
  each round (§ 0); without it, a worker that reported `DONE` sleeps through the reviews.
  - Any of these calls can raise an approval prompt, which blocks the call, so nothing can be sent
    from inside it. Unless `get_session("self")` reports `permissionMode` `auto` or
    `bypassPermissions`, send `NEED-INPUT` marked `answer: in this session only` BEFORE the calls.
  - Before clearing your own context, turn the monitor off (`auto_fix: false`): a cleared worker
    woken by anything but the resume carrying its brief hedges or invents. Turn it back on when
    the resume arrives and the PR is still open.
  - After `gh pr merge`, turn it off, and say so in the merge `DONE`.
- **After each round's push** the worker reports `DONE`, with `checkpoint` in its first line, to
  the coordinator: round number, commit sha, push time, what was fixed and what was declined, CI
  state, silent reviewers. That is a checkpoint, not an exit: when the next reviews land, the same
  worker runs the next round from § 0.
- **A round with nothing to fix pushes nothing**, but still replies to and resolves what it
  declined (§ 8). Once CI has concluded (still running → a background `gh pr checks <N> --watch`,
  ending the turn `waiting: CI`), the worker checks § Stopping › Merging's three conditions
  itself and reports a clean `checkpoint round`: `merge bar met` when all three hold, else the one
  that fails (a clean opening round has no round-1 push). Either way it adds `verify` on the head
  after `git fetch origin <base>`, CI, open threads and `mergeStateStatus`. It then waits on the merge,
  so it sends `NEED-INPUT` marked `answer: here or relay` and ends the turn (crew's Worker step 4):
  bar met → "merge?"; bar missed → the condition and the choices, another review or a merge anyway,
  which is a Hard Gate only this session approves.
  A review that lands later on the same head starts the next round: § 0's window has long passed.
- **The worker merges only on the coordinator's go**, never on its own reading of the PR (§
  Stopping › Merging): the coordinator's `ANSWER` to that "merge?" under the merge rule (a card's
  `landing: operator` withholds it), the operator's go relayed to it, or the operator's yes in this
  session to a merge outside the rule.
- **CodeRabbit reviews the opening push only** (operator, 2026-10-02, from 2026-10-03). Just
  BEFORE the first push after the opening one (round 1's fixes, or a sync push), the worker applies
  the `dont-review` label (`gh pr edit <N> --repo acatl/crew --add-label dont-review`;
  `.coderabbit.yaml` excludes that label from auto-review). No `@coderabbitai review` after that
  without the operator. The label saves the account-wide pool for the next PR. **Until 2026-10-03
  CodeRabbit's PR reviews are paused** (operator, 2026-09-30): a PR opens with `dont-review` already
  on, and the merge bar has no CodeRabbit line.
- **The pool check: before any push CodeRabbit will review, read the pool.** CodeRabbit's PR
  reviews come from one account-wide hourly pool (about 5 an hour) shared by `acatl/hg`,
  `acatl/crew` and `acatl/kino`. For each of those repos, read the newest `coderabbitai` review:

  ```bash
  gh api graphql -f query='{repository(owner:"acatl",name:"<repo>"){pullRequests(last:20,orderBy:{field:UPDATED_AT,direction:ASC}){nodes{reviews(last:20){nodes{author{login} submittedAt}}}}}}'
  ```

  Keep the newest `coderabbitai` `submittedAt` across the three. Under 60 minutes old → hold the
  push, spend the wait on local work, then push.
- **Baselines are the operator's.** The checks that compare against a committed baseline (the
  word budget, the content metrics) may hold or improve. A worker never raises a budget or lowers
  a content baseline to get green, and never asks for it inside a fix loop: new debt is fixed.
  Only the operator changes a baseline to accept a regression.
- **The CodeRabbit CLI runs ONCE, at the start of `open`, never during rounds** (§ 6 › The
  CodeRabbit CLI pass).
- **The round cap: rounds 1–4 are planned; round 5 runs only for a valid defect.** Before
  STARTING round 5, look at what the reviews of round 4's push hold:
  - **a valid defect on an ordinary path** → round 5 runs, pre-approved;
  - **only low findings that are not defects** → no round 5: merge-and-carry (§ 2);
  - **a finding on a rarer input than the rounds before it** → that is the edge-case chase
    (§ 6 › The loop budget): no round 5, escalate;
  - otherwise the PR is ready (§ Stopping).

  **Hard stop before STARTING round 6**, whatever the reviews hold. Send `NEED-INPUT` with what
  each round fixed and which threads are still open, then wait.

  These numbers are `rounds`' default. A brief that sets `rounds` otherwise replaces them: send
  the same `NEED-INPUT` before any round it doesn't allow.

## Round procedure

**Each round = settle → read → triage → sweep → fix → verify → review → push → reply**,
with § 5's verify re-run after each review pass's fixes, before the push.
One push per round, and no round starts before the reviewers settle. A clean round, with nothing to
fix, stops at triage: no push and no round number, so round N is always the one making the PR's
N-th push after the opening one.

### 0. Wait for the reviewers to settle — the round has not started yet

**Being woken is the signal to start WAITING, not to start fixing.** The app's
`set_monitor auto_fix` fires on the first bot comment, and the reviewers post minutes apart.
Starting on the first one spends a push on a partial round.

**Not being woken is no signal at all.** A reviewer that never posts never fires the monitor. On
acatl/crew#4 (2026-09-30) Codex and Copilot never reviewed the round-2 push, and the PR sat idle for
12 hours. So on entering the round, after a resume too, arm a settle timer: a background command
(the Bash tool's `run_in_background`) that exits when either condition below holds. Its exit starts
the round, unless a reviewer says it is still working on the current head: then re-arm it once, to
20 minutes from then. Record each push's time in the ledger and the `DONE`; after a resume the
window is measured from it.

Roster: `coderabbitai` (the opening push only), `copilot-pull-request-reviewer`,
`chatgpt-codex-connector`. Settle window: `settle`, 20 minutes. **A roster login that never posts
on the opening push may not be enabled on this repo.** Tell the coordinator rather than waiting on
it every round.

**Proceed when EITHER holds:**

- every roster login has reviewed the CURRENT head (with every login dropped as silent or paused,
  this never holds: wait out the window), or
- `settle` has passed since the head was pushed, measured from the push, never from the
  commit timestamp.

```bash
gh api graphql -f query='{repository(owner:"acatl",name:"crew"){pullRequest(number:N){
  headRefOid
  reviews(last:50){nodes{author{login} commit{oid} state submittedAt bodyText}}}}}'
```

Compare each roster login's latest review `commit.oid` against `headRefOid`.

- **A missing reviewer is normal, not an alarm.** The roster only ever lets a round start
  early; the window is the real bound.
- **Window passed with no review → settled.** Triage what exists (threads, review bodies, CI) and
  name the silent reviewers in the `DONE`; never wait on one past the window.
- **A reviewer saying it is still working on the current head keeps the window open 20 more
  minutes, once.** A stale or repeated "still working" never holds the round past that.
- **CI is outside this gate.** Judge CI separately; a red check stops the round rather than
  being fixed by it.
- **An empty review is not a review.** A reviewer that pauses itself posts a zero-length review
  that looks like a real one. Detect it (`bodyText` length 0 on the current head) and tell the
  coordinator: resuming spends a slot from the account-wide pool and is the operator's call.

### 1. Read everything before touching anything

Every thread in full, including collapsed `<details>` bodies. Bots put proposed diffs there,
and sometimes concede the finding themselves.

```bash
gh api graphql --paginate -f query='query($endCursor:String){repository(owner:"acatl",name:"crew"){
  pullRequest(number:N){reviewThreads(first:100, after:$endCursor){
  pageInfo{hasNextPage endCursor}
  nodes{id path line isResolved
  comments(first:100){totalCount nodes{author{login} body}}}}}}}'
```

**Threads are not all the findings.** Copilot files some findings in the review BODY with no
thread attached. Read the review bodies too:

```bash
gh api --paginate repos/acatl/crew/pulls/N/reviews --jq '.[] | select(.body != "") | "\(.user.login)\n\(.body)"'
```

A finding with no thread still needs a disposition; its reply goes on the PR as one comment.

### 2. Triage each finding to one verdict

| Verdict | Requires |
| --- | --- |
| Fix | a real defect |
| Fix differently | the diagnosis is right, the proposed fix is not |
| Decline | a technical reason, cited to code or to a rule |
| Defer | **the operator's call only**: confirmed and real, but deliberately not fixed now. Needs the operator's yes, a stated reason the DELAY is safe, and a durable record WRITTEN FIRST. One exception is pre-approved: merge-and-carry, below |

**A deferral's reason must be a property of the code, not of the budget.** "It would cost
another round" is the motive for asking, never the justification.

**The record comes first.** It is a checklist line on the open `acatl/crew` issue that touches
the same surface, or on the backlog umbrella issue (ask the coordinator for its number). Write it
with the diagnosis, the reviewer's severity, the thread link and the reason the delay is safe.
Only then reply and resolve.

**Merge-and-carry, the one pre-approved deferral.** A low-severity finding that is not a defect
(a name, a comment, a simplification), raised on a PR that is otherwise ready, does not buy
another round. Record it as above, reply linking the record, resolve, and the PR merges. A
defect is never carried this way.

**Attempt every finding before declining it.** A decline is defensible only once the fix was
implemented and refused, by a red test that encodes the opposite intent or by the code.

**A bot that re-raises cannot see your reasoning.** On the second raise, stop restating the
argument: write the pinning test and cite it. Argument loses to artifact.

**Never weaken a test to make a fix pass.**

### 3. Generalize each confirmed finding to its class, then sweep

- **Name the class as a pattern, not an instance.**
- **Grep the whole tree**, not just this PR's files. In this repo that includes every restated
  value in CLAUDE.md › *Invariants that span files*: a finding on one copy is a finding on all
  of them.
- Fix every instance in this PR, and name the ones outside the PR's diff in the reply and the
  commit body.
- **Judge every match**; a same-shape site that is correct for its own reason is left alone and
  noted.
- **Bound it to the pattern.** If the sweep becomes a refactor, stop and report.
- A class with no other instances still gets one line: "swept, no others".

### 4. Fix

On the PR branch: every confirmed finding and every sweep match, each with a test that pins it
where the behavior is testable. Skill prose is pinned by the checks that read it (invariants,
section references), not by assertion in prose.

### 5. Verify

```bash
./scripts/verify.sh      # every CI check in CI's order, stopping at the first failure
```

`verify.sh` is also the pre-push hook's command. Fetch `origin/<base>` at the round's start. While
iterating on one failure, run that step alone; the round's check is the whole script.

### 6. `/code-review high` over the fix diff, in a sub-agent

The round's local reviewer is the `/code-review` skill at `high`, run INSIDE a sub-agent (the
Agent tool) that gets only the scope, so the reviewer stays apart from the doer.

**Commit what it reviews, and give it its own worktree** (the Agent tool's
`isolation: "worktree"`, over a commit RANGE). A reviewer sharing your worktree can lose your
uncommitted fixes.

**The sub-agent's brief is the scope and the level, nothing else:**

- the commit range, and "first `git checkout --detach <the range's tip>`";
- "run `npm ci` before any check";
- "run `/code-review high` on exactly that range; to test whether a pin pins, restore the
  pre-fix file (`git checkout <range base> -- <file>`) and run the test";
- "your final message lists every finding as text";
- "as your very last step, remove your own worktree (`git worktree remove --force <its path>`)".

Never your reasoning, your conclusions or your triage: a reviewer handed your conclusion returns
it confirmed. **You judge and fix what it returns**, and every valid finding is fixed, whatever
its severity. Once its findings are in, remove only a worktree it left behind
(`git worktree remove <its path>`); one you can't remove goes in the next `DONE` by path.

Two passes, then no third:

1. **Pass 1: the round's fix diff.** Range: `<the pushed PR head's sha>..HEAD`. **Never merge or
   rebase `<base>` mid-round**; if the base must move, do it before the round's first fix.
2. **Pass 2: pass 1's fixes only.** If pass 1 fixed nothing, skip it. Fix what it raises,
   re-run § 5, and push with **no third review**: the PR's bots are the next look.

What it catches most often is a pinning test that does not pin. A test you wrote and watched
pass is the thing you are least able to review.

#### The CodeRabbit CLI pass — once, at the start of `open`

The CLI (`coderabbit`, installed and signed in on this machine) runs the same reviewer locally,
on an hourly limit separate from the PR-review pool. It never posts to the PR.

- **At the start of `open`, before the push, the only time it runs.** Your workflow's review has
  already run. Order:
  1. `coderabbit review --agent --base <base>` over the whole branch → fix;
  2. `/code-review high` in a sub-agent over the CLI's fixes → fix, with no further local review.

  Note the sha before the first CLI fix; it is the sub-agent's range base. First confirm the local
  `<base>` matches `origin/<base>`, or pass `--base-commit` with `origin/<base>`'s sha.
- **Never during rounds.**
- Triage its findings exactly like a bot's (§ 2, § 3). Never pass `--fast`. If it refuses on its
  rate limit, wait out the window (up to 20 minutes); if it still refuses, open without it and say
  so in the `DONE` that reports the PR open.

#### The loop budget — a review is not a loop

**At most two local review→fix iterations per round**; a third needs the operator. In a round,
the bots' reviews are the round's INPUT, and the two iterations are § 6's two passes. At `open`,
the CLI and `/code-review high` are the two iterations. **Stop early and escalate** (`NEED-INPUT`
in a crew worker) the moment any of these shows:

- a finding CAUSED by the previous iteration's own fix;
- findings moving to ever-rarer inputs (an edge-case chase, not a defect hunt);
- a fix growing into a hand-built copy of a spec or format: propose the library and ask for its
  install as a Hard Gate;
- `no-commit` minutes without a commit.

**Every valid finding is fixed, whatever its severity.** The budget caps review *iterations*,
not fixes. **At the last allowed review, a fix-created finding is fixed and the round proceeds
to its push, with no escalation.** PR review ROUNDS are a separate count, bounded only by the
round cap. Deferring a valid finding instead of fixing it is the operator's call.

### 7. One push

Every fix batched; a clean round has none. CodeRabbit reviews only the opening push, drawn from an
account-wide hourly pool: load it heavily, and run the pool check before it. The first push after it
is where `dont-review` goes on: label first, then push. Conventional-Commit subject, **lowercase
after the type**.

### 8. Reply and resolve, one pass

About 2 s apart, under GitHub's bulk-write limit. Every reply says fixed-and-how,
declined-and-why or deferred-and-where, with the actual argument.

**Resolve from THIS round's triage list, never "every thread that is currently open".** Build
the list of ids you dispositioned, resolve exactly those, then re-measure the open count before
reporting.

## Escalation — what a worker never decides alone

- **A finding that would change the contract** in `skills/crew/SKILL.md`, meaning the message
  kinds, the input invariant or the authority rules → the operator.
- **A finding that contradicts a documented invariant** (CLAUDE.md › *Invariants that span
  files*) → the operator, unless the fix updates every copy.

In both cases the worker still writes the reply, and adds a pinning check when the case is
untested.

## Stopping

**Threads-clear and CI-green are NOT mergeable.** A `CHANGES_REQUESTED` verdict survives
resolving every thread; only a new review from the same reviewer clears it. Judge on
`reviewDecision` and `mergeStateStatus`, never on the open-thread count.

```bash
gh api graphql -f query='{repository(owner:"acatl",name:"crew"){pullRequest(number:N){
  reviewDecision mergeable mergeStateStatus}}}'
```

Reviewers spent, threads dispositioned, CI green, and `reviewDecision` not blocking → the PR is
ready. Report it and wait (§ Who runs the rounds); the coordinator takes it from there.

### Merging — the operator's standing rule

The operator (on `acatl/hg`, 2026-09-22, adopted here 2026-09-25): *"if all sensors are green
and enough reviews [rounds] have passed you may tell the workers to merge"*, plus a standing yes
to dismissing CodeRabbit's stale `CHANGES_REQUESTED`. The coordinator checks every condition
itself, by running, never from the worker's report:

1. **Sensors green on the PR's head sha, against `<base>`.** The PR's `baseRefName` is `<base>`,
   every CI check concluded `SUCCESS`, and
   `./scripts/verify.sh` passes on that sha after `git fetch origin <base>`.
2. **Enough review rounds.** At least **two** completed rounds (the opening review and the review
   of the round-1 push). CodeRabbit reviewed the opening push (a non-empty review), unless the PR
   opened during the pause (§ Who runs the rounds). No valid finding is still open.
3. **Every thread dispositioned** (fixed, declined on the merits, deferred with the operator's
   yes, or merge-and-carry), each with its reply, and resolved.

The rule is a standing delegation (`docs/CREW.md` › Integration, `mode: pr`), void on a card that
says `landing: operator`: then the coordinator reports the PR ready and the operator merges.

When all three hold and `reviewDecision` is blocked only by CodeRabbit's stale
`CHANGES_REQUESTED`, the coordinator dismisses **that review only**, with a message naming the
resolved threads and the head sha it checked. It then confirms `mergeStateStatus` is `CLEAN` and,
unless the card says `landing: operator`, tells the worker to merge. The worker runs
`gh pr merge <N> --squash --match-head-commit <sha>` with the PR's Conventional title and reports
the merge sha.

**`BEHIND` or a conflict is not a failure.** The worker merges `<base>` into its branch: at the
start of the next round when one is due (never mid-round), otherwise as a sync push carrying no
fixes. The conditions above are checked again on the new head.

Any condition that fails, or any other reviewer's blocking verdict, goes to the operator. It is
never a reason to dismiss more or to push again. A merge despite it is the operator's own: by hand,
or in the worker's session as a Hard Gate, never relayed.
