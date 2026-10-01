# PR review rounds — how this repo's PRs run them

The procedure the owner of a PR on `acatl/crew` follows for **every** review round, from the
PR's opening to its merge. A crew worker's brief names this file, and the worker reads it at the
start of each round. It is adapted from `acatl/hg`'s `docs/pr-round-workflow.md` so both repos
work the same way (operator, 2026-09-25). The operator's rulings quoted below were made on
`acatl/hg` and adopted here with it.

**Each round = settle → read → triage → sweep → fix → verify → review → push → reply**,
with § 5's verify re-run after each review pass's fixes, before the push.
One push per round, and no round starts before the reviewers settle. A clean round, with nothing to
fix, stops at triage: no push.

## What is consent, and what is a gate

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

- **At PR open, bind the PR and turn on its review monitor.** Right after `gh pr create`, call
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
- **A round with nothing to fix pushes nothing.** When § Stopping's conditions look met, the worker
  reports `merge bar met` with `verify` on the head after `git fetch origin main`, CI, open threads
  and `mergeStateStatus`; otherwise a clean `checkpoint round`.
- **The worker merges only on the coordinator's go**, never on its own reading of the PR (§
  Stopping › Merging).
- **CodeRabbit reviews rounds 1–3 only; from round 4 it is paused by label.** Just BEFORE
  pushing round 3's fixes, the worker applies the `dont-review` label
  (`gh pr edit <N> --repo acatl/crew --add-label dont-review`; `.coderabbit.yaml` excludes that
  label from auto-review). No `@coderabbitai review` after that without the operator. The label
  saves the account-wide pool for the next PR.
- **Baselines are the operator's.** The checks that compare against a committed baseline (the
  word budget, the content metrics) may hold or improve. A worker never raises a budget or lowers
  a content baseline to get green, and never asks for it inside a fix loop: new debt is fixed.
  Only the operator changes a baseline to accept a regression.
- **The CodeRabbit CLI runs ONCE, before the PR opens, never during rounds** (§ 6 › The
  CodeRabbit CLI pass).
- **The round cap: rounds 1–4 are planned; round 5 runs only for a valid defect.** Before
  STARTING round 5, look at what the reviews of round 4's push hold:
  - **a valid defect on an ordinary path** → round 5 runs, pre-approved;
  - **only low findings that are not defects** → no round 5: merge-and-carry (§ 2);
  - **a finding on a rarer input than the rounds before it** → that is the edge-case chase
    (§ The loop budget): no round 5, escalate;
  - otherwise the PR is ready (§ Stopping).

  **Hard stop before STARTING round 6**, whatever the reviews hold. Send `NEED-INPUT` with what
  each round fixed and which threads are still open, then wait.

## 0. Wait for the reviewers to settle — the round has not started yet

**Being woken is the signal to start WAITING, not to start fixing.** The app's
`set_monitor auto_fix` fires on the first bot comment, and the reviewers post minutes apart.
Starting on the first one spends a push on a partial round.

**Not being woken is no signal at all.** A reviewer that never posts never fires the monitor. On
acatl/crew#4 (2026-09-30) Codex and Copilot never reviewed the round-2 push, and the PR sat idle for
12 hours. So on entering the round, after a resume too, arm a settle timer: a background command
(the Bash tool's `run_in_background`) that exits when either condition below holds. Its exit starts
the round, unless a reviewer says it is still working: then re-arm it and keep waiting. Record each
push's time in the ledger and the `DONE`; after a resume the window is measured from it.

Roster: `coderabbitai`, `copilot-pull-request-reviewer`, `chatgpt-codex-connector`. Settle
window: 20 min. From round 4 the roster is Copilot and Codex only (CodeRabbit is paused by
label). **A roster login that never posts on the opening push may not be enabled on this repo.**
Tell the coordinator rather than waiting on it every round.

**Proceed when EITHER holds:**

- every roster login has reviewed the CURRENT head, or
- 20 minutes have passed since the head was pushed, measured from the push, never from the
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
- **A reviewer saying it is still working keeps the window open past 20 minutes.**
- **CI is outside this gate.** Judge CI separately; a red check stops the round rather than
  being fixed by it.
- **An empty review is not a review.** A reviewer that pauses itself posts a zero-length review
  that looks like a real one. Detect it (`bodyText` length 0 on the current head) and tell the
  coordinator: resuming spends a slot from the account-wide pool and is the operator's call.

## 1. Read everything before touching anything

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

## 2. Triage each finding to one verdict

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

## 3. Generalize each confirmed finding to its class, then sweep

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

## 4. Fix

On the PR branch: every confirmed finding and every sweep match, each with a test that pins it
where the behavior is testable. Skill prose is pinned by the checks that read it (invariants,
section references), not by assertion in prose.

## 5. Verify

```bash
./scripts/verify.sh      # every CI check in CI's order, stopping at the first failure
```

`verify.sh` is also the pre-push hook's command. Fetch `origin/main` at the round's start. While
iterating on one failure, run that step alone; the round's check is the whole script.

## 6. `/code-review high` over the fix diff, in a sub-agent

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
- "your final message lists every finding as text".

Never your reasoning, your conclusions or your triage: a reviewer handed your conclusion returns
it confirmed. **You judge and fix what it returns**, and every valid finding is fixed, whatever
its severity. Once its findings are in, remove the worktree it changed
(`git worktree remove <its path>`).

Two passes, then no third:

1. **Pass 1: the round's fix diff.** Range: `<the pushed PR head's sha>..HEAD`. **Never merge or
   rebase `main` mid-round**; if the base must move, do it before the round's first fix.
2. **Pass 2: pass 1's fixes only.** If pass 1 fixed nothing, skip it. Fix what it raises,
   re-run § 5, and push with **no third review**: the PR's bots are the next look.

What it catches most often is a pinning test that does not pin. A test you wrote and watched
pass is the thing you are least able to review.

### The CodeRabbit CLI pass — once, before opening

The CLI (`coderabbit`, installed and signed in on this machine) runs the same reviewer locally,
on an hourly limit separate from the PR-review pool. It never posts to the PR.

- **Before opening the PR, the only time it runs.** Order:
  1. self-review of the branch → fix;
  2. `coderabbit review --agent --base main` over the whole branch → fix;
  3. `/code-review high` in a sub-agent over *all* the pre-open fixes → fix, with no further
     local review.

  Note the sha before the first self-review fix; it is the sub-agent's range base. First confirm
  the local `main` matches `origin/main`, or pass `--base-commit <origin/main's sha>`.
- **Never during rounds.**
- Triage its findings exactly like a bot's (§ 2, § 3). Never pass `--fast`. If it refuses on its
  rate limit, wait out the window (up to 20 minutes); if it still refuses, run the sub-agent
  review without it and say so in the `DONE` that reports the PR open.

### The loop budget — a review is not a loop

**At most two local review→fix iterations per round**; a third needs the operator. In a round,
the bots' reviews are the round's INPUT, and the two iterations are § 6's two passes. Before
opening, the self-review is the review, and the CLI plus `/code-review high` are the two
iterations. **Stop early and escalate** (`NEED-INPUT` in a crew worker) the moment any of these
shows:

- a finding CAUSED by the previous iteration's own fix;
- findings moving to ever-rarer inputs (an edge-case chase, not a defect hunt);
- a fix growing into a hand-built copy of a spec or format: propose the library and ask for its
  install as a Hard Gate;
- 60 minutes without a commit.

**Every valid finding is fixed, whatever its severity.** The budget caps review *iterations*,
not fixes. **At the last allowed review, a fix-created finding is fixed and the round proceeds
to its push, with no escalation.** PR review ROUNDS are a separate count, bounded only by the
round cap. Deferring a valid finding instead of fixing it is the operator's call.

## 7. One push

Every fix batched; a clean round has none. A PR gets three CodeRabbit-reviewed pushes (the opening
push, then rounds 1 and 2), drawn from an account-wide hourly pool: load each one heavily, and the
last one hardest.
Round 3's push is also where `dont-review` goes on: label first, then push. Conventional-Commit
subject, **lowercase after the type**.

## 8. Reply and resolve, one pass

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
ready. Report it and stop; the coordinator takes it from there.

### Merging — the operator's standing rule

The operator (on `acatl/hg`, 2026-09-22, adopted here 2026-09-25): *"if all sensors are green
and enough reviews [rounds] have passed you may tell the workers to merge"*, plus a standing yes
to dismissing CodeRabbit's stale `CHANGES_REQUESTED`. The coordinator checks every condition
itself, by running, never from the worker's report:

1. **Sensors green on the PR's head sha.** Every CI check concluded `SUCCESS`, and
   `./scripts/verify.sh` passes on that sha after `git fetch origin main`.
2. **Enough review rounds.** At least **two** completed rounds (the opening review and the review
   of the round-1 push). CodeRabbit has reviewed the current head, or the PR carries
   `dont-review` and CodeRabbit reviewed every push before it. No valid finding is still open.
3. **Every thread dispositioned** (fixed, declined on the merits, deferred with the operator's
   yes, or merge-and-carry), each with its reply, and resolved.

The rule is a standing delegation (`docs/CREW.md` › Integration, `mode: pr`), void on a card that
says `landing: operator`: then the coordinator reports the PR ready and the operator merges.

When all three hold and `reviewDecision` is blocked only by CodeRabbit's stale
`CHANGES_REQUESTED`, the coordinator dismisses **that review only**, with a message naming the
resolved threads and the head sha it checked. It then confirms `mergeStateStatus` is `CLEAN` and,
unless the card says `landing: operator`, tells the worker to merge. The worker runs `gh pr merge <N> --squash` with the PR's Conventional
title and reports the merge sha.

**`BEHIND` or a conflict is not a failure.** The worker merges `main` into its branch: at the
start of the next round when one is due (never mid-round), otherwise as a sync push carrying no
fixes. The conditions above are checked again on the new head.

Any condition that fails, or any other reviewer's blocking verdict, goes to the operator. It is
never a reason to dismiss more or to push again.
