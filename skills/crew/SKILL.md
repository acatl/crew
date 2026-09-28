---
name: crew
description: >-
  Orchestrator ↔ worker sessions. One session (the orchestrator) spins up a fresh worker session per
  ticket or slice, briefs it, relays operator input to and from it, verifies its result, lands it when
  the operator delegates that, and cleans up. It runs a single worker or an ordered sequence of queued
  workers. Defines the contract both sides follow: the brief, the worker's four reports (ONLINE,
  NEED-INPUT, BLOCKED, DONE), the orchestrator's RELAY and START, the input invariant, parallel-safety,
  and who may do what. Works in any repo; per-project answers live in docs/CREW.md, interviewed on first
  use. Triggers on "spin up a worker for", "spawn a worker", "start a worker session", "dispatch KINO-5
  to a worker", "queue workers for", "run these tickets in sequence", "crew status", "what are my
  workers doing". Also loads in a worker whose first message starts with `<!-- crew:brief`.
argument-hint: "<verb> <ticket-id>[ → <ticket-id>…] [mode]  |  status"
license: MIT
compatibility: >-
  Needs the Claude desktop app's Code tab, whose session tools (spawn_task, send_message, get_session,
  archive_session) the Claude Code CLI does not provide; bash and git; and a BSD or GNU stat(1), so
  macOS or Linux.
metadata:
  author: Acatl Pacheco
  version: "0.0.0" # x-release-please-version
---

# crew — orchestrator ↔ worker sessions

One orchestrator session. One fresh worker session per unit of work (a ticket or a slice of one). The
orchestrator writes the brief, the operator clicks the chip, the worker does the work and reports back.
This file is the contract; `docs/CREW.md` holds the per-project answers.

**Which role are you?**
- Your first message starts with `<!-- crew:brief` → **worker**. Read *The contract*, then *Worker*.
- The operator asked you to spin up / spawn / queue / dispatch workers, or asked for crew status →
  **orchestrator**. Read *The contract*, then *Orchestrator*.

---

## The contract (both roles)

### Messages

Worker → orchestrator, always with `mcp__ccd_session_mgmt__send_message` to the orchestrator's
**sessionId**. First line is self-contained: `[crew] <KIND> · <TICKET> · <one-line summary>`.

| Kind | Sent when | Body carries | Then the worker |
|---|---|---|---|
| `ONLINE` | first action after reading the brief | own sessionId, branch, mode, and `state: ready` (with the command about to run) or `state: queued` | ready → proceeds · queued → ends its turn |
| `NEED-INPUT` | **before ending any turn that waits on the operator** — a gate, a fork card, a question, a plan approval | the question verbatim, the options, and `answer: here or relay` or `answer: in this session only` | ends its turn and waits |
| `BLOCKED` | can't proceed and no answer to a question fixes it — a failure, missing setup, something the brief doesn't cover | what blocked it, where, what the fix likely needs | ends its turn and waits |
| `DONE` | stop point reached | branch, commit sha, the command's own verify result, the stop point reached | stops |

Orchestrator → worker, same tool, to the worker's sessionId:

| Kind | Sent when | Body carries |
|---|---|---|
| `RELAY` | the operator answered or instructed through the orchestrator | the operator's words, verbatim, nothing added |
| `START` | a queued worker's turn has come | `base <sha>` in the first line, then the Job section its queued brief left out, written from the current landed state. It replaces the brief's Job section. Its authority is the operator's `go` on the queue card. |

Nothing else crosses. No progress narration, no "starting now", no worker-to-worker messages.

### The input invariant

Every `NEED-INPUT` appears in **two places**: in the worker's own session (as the operator would see it
if they were watching there) and in the orchestrator (the message). The orchestrator nudges the
operator, who answers in either place.

- **Answered in the worker session** → the worker continues. It sends nothing extra; its next message
  supersedes the pending question.
- **Answered in the orchestrator** → the orchestrator sends `RELAY` with the operator's words verbatim.
  The worker treats that as the operator's answer.
- **Never relayed:** tool-permission prompts (the approval UI lives in the worker's window) and consent
  for anything the worker's own rules gate (push, deploy, install, destructive). A relayed "yes" there is
  cross-session permission laundering. The worker marks these `answer: in this session only`; the
  orchestrator's nudge sends the operator to the worker session.

A queued worker waiting for `START` is waiting on the orchestrator, not the operator. It sends no
`NEED-INPUT` for that wait.

### Authority

- **The trigger** authorizes its card and the spawns that card lists: one worker, or one sequence. Not
  a push, a branch deletion, or a spawn the card didn't list. Each of those is a separate ask.
- **Landing** (bringing a worker's branch into the base) happens only when the operator delegates it on
  the card (`landing: delegated`) *and* `docs/CREW.md` › Integration allows it. A plain `go` never
  delegates landing. Without delegation, the operator lands.
- **The worker** runs its command exactly as if the operator typed it, mode included — `yolo` means
  yolo — up to the stop point, and commits. Nothing past the stop point. It never creates a worktree
  (it already has one), never installs or links anything that outlives its worktree, never archives
  itself, never messages another worker.
- **The orchestrator** verifies by running, never by trusting a report. It executes only the landing and
  cleanup agreed on the card. It never merges other work to unblock a worker.

### One worker per unit

A worker is created for one ticket or slice and disposed of per its cleanup plan. A session that
outlives its unit carries stale context into the next one, and clearing another session's context is
permission-gated. A fresh session is the only dependable clean start.

---

## Orchestrator

**Triggers.** The trigger is a complete instruction: no "shall I?" round trip before the card.
- One worker: `spin up a worker for <verb> <TICKET> [mode]`, e.g. `spin up a worker for building
  KINO-5`, `spawn a worker for KINO-5 yolo`.
- A sequence: `spin up workers for <A> → <B> → <C> [mode]`, "queue workers for A, B and C in order".
  Units run one at a time, in the order given (step 8).

The verb defaults to `build`. The mode is passed through untouched; no mode means the command's own
default.

**`<skill-dir>`** is this skill's own directory: the path Claude Code prints as "Base directory for this
skill" when it loads the skill. The scripts below run from `<skill-dir>/scripts/`. Substitute that real
path: the skill is installed per user or per project, so never assume either one.

### 0. Resume from the ledger

The roster lives in your conversation, which a compaction or a `/clear` destroys. The ledger is the
part that survives — see [references/ledger.md](references/ledger.md) for its location, shape and
rules.

If the roster isn't already in this conversation, read `ledger.md` and reconcile it against
`list_sessions` / `get_session` before anything else. Report drift; never silently patch it. Then keep
it written: every transition below names its write.

### 1. Resolve config

Read `docs/CREW.md` at the repo root. Missing, or no row for this verb → run the first-use interview in
[references/crew-md.md](references/crew-md.md), write or extend the file, then continue. Workers never
read `docs/CREW.md`; the orchestrator resolves it into each brief.

### 2. Read the ticket and estimate its surface

Read the ticket from the source `docs/CREW.md` names. Take its title. Estimate the **surface** — the
paths the work will likely touch — from the ticket text plus a quick search of the codebase. Paths are
repo-relative; a directory covers everything under it. An estimate is fine; say it's an estimate.

For an `inline` verb, what you write here *is* the spec the worker gets. Write it for a session with no
memory of this conversation, including any decision that lives only in your memory: worker sessions
don't see it.

### 3. Parallel-safety check

Run these against every in-flight worker in the roster (see *Roster*). Units of one sequence run one at
a time, so check them against workers outside the sequence, not against each other.

1. **Actual overlap** — what in-flight workers have already touched:
   ```bash
   <skill-dir>/scripts/overlap.sh --base <base> --paths <p1,p2,...> <worker-cwd>...
   ```
   Worker cwds are the roster's `worktreePath`s. Exit 0 = clear, 1 = overlap (TSV lines:
   branch, file, matched path), 2 = usage or git error.
2. **Declared overlap** — the candidate surface against each in-flight worker's `Surface you own`.
   This catches a worker that hasn't written anything yet.
3. **Dependency** — does the ticket need work that isn't on `<base>` yet (the ticket says so, or the
   surface needs something that exists only on an in-flight branch)?
4. **Base** — pick the commit this unit must start from, for this situation (the line it integrates
   into, the default branch for a PR cut from it, a specific sha for an audit), and write it into the
   brief as **a ref plus a sha**. Never assume the app cut the worktree from it (see *Gotchas*); the
   worker re-points itself to that sha as its first setup step.

Result: `✓ clear` · `⚠ overlap` (which worker, which paths) · `⚠ main checkout on <branch>, not <base>` ·
`⛔ blocked on unmerged <X>`. On ⛔, don't show the card and don't spawn: say what the ticket waits on
and stop. Never merge anything to clear the path.

### 4. Pre-spawn card — always

Every field has a default; `go` accepts them all. Render it as live Markdown:

> **Spawn KINO-5 → worker** · `/hg-build KINO-5 yolo`
>
> | Field | Default |
> |---|---|
> | Title | `KINO-5 — Add export command` |
> | Scope | Whole ticket, stop at: verified, not shipped |
> | Cleanup | Archive when merged |
> | Landing | Operator decides |
> | Safety | ✓ clear — 2 workers in flight, no shared paths; main checkout on `main` |
>
> **→ You:** `go`, or override a line (`title: …`, `scope: slice — only the parser`, `cleanup: keep`).

- **Title** default: `CREW.md` › Defaults, else `{TICKET} — {ticket title}`. It becomes the chip label
  and the session title, so lead with the ticket id — the sidebar sorts, and the roster finds it.
- **Scope**: whole ticket, or a slice described in one line with its own stop point.
- **Cleanup** default by scope (`CREW.md` › Defaults, else whole ticket → `archive when merged`,
  slice → `keep`). Options: `archive when verified` · `archive when merged` · `keep`.
- **Landing** is always `operator decides` by default. When `CREW.md` › Integration mode is `ff-only`,
  add what `landing: delegated` would run (`git merge --ff-only`, then Post-land). It becomes delegated
  only when the operator writes that override.
- **Safety**: the step 3 result. On ⚠ overlap, recommend one of: wait for the overlapping worker,
  narrow this scope to avoid the shared paths, or proceed with those paths listed under `Do not touch`.

### 5. Spawn

1. `mcp__ccd_session_mgmt__get_session("self")` → your `sessionId` and `title`.
2. Fill [references/brief-template.md](references/brief-template.md), the ready variant. Every `{…}`
   gets a value or `none`; no placeholder survives.
3. `mcp__ccd_session__spawn_task` with `title` = the card's title, `tldr` = one plain sentence, `prompt`
   = the filled brief. Pass `cwd` only when the worker belongs to a different repo than yours.
4. **Write the ledger row** (status `chip`, the `task_id` in place of a session id, stop point,
   surface, scope, cleanup, landing) and save the brief exactly as sent to `briefs/<row>.md`.
5. Tell the operator the chip is up and needs a click. End your turn.

`spawn_task` returns a task id, not a session id. You learn the worker's session from its `ONLINE`.

### 6. Handle messages

- **ONLINE** → `get_session(<worker sessionId>)`: confirm `parentSessionId` is yours, and record
  `worktreePath` (the worker's cwd for `overlap.sh` and verify) and `sourceBranch`. Then:
  `state: ready` → status `running`, add its roster line (see *Watchdog*), subscribe to its idle
  notice (see *Subscribing*).
  `state: queued` → status `queued`. **Don't subscribe yet:** it goes idle at once, so the notice would
  mean nothing. Subscribe when you send its `START`. Either way, write the session id and worktree to
  the row.
- **NEED-INPUT** → nudge the operator right away:
  > ⏸ **KINO-5 needs you** — <question, one line>
  > <options>
  > <!-- markdownlint-disable-next-line MD051 -->
  > Answer here and I'll relay, or in [KINO-5 — Add export command](#<worker-sessionId>).

  If the worker marked it `answer: in this session only`, drop "answer here" and say why.
  When the operator answers here: first read the worker's tail (`list_events`, limit 4). If it has
  already been answered there, say so and don't relay. Otherwise send `RELAY` with their words verbatim.
  Ledger: the question goes into `owed` verbatim while it's pending, and collapses to the decision once
  answered.
- **BLOCKED** → surface it the same way, with the worker's proposed fix. Decide with the operator.
- **DONE** → verify by running, in the worker's cwd: `CREW.md` › Verify, else `docs/HARNESS.md` ›
  Sensors, else ask. Report the verdict against the worker's claim, and write it to the row with the
  sha it ran on. On pass: land if delegated (step 8), clean up per the card (step 7), and in a sequence
  start the next unit (step 8).
- **A worker reports it cleared its own context** → status `cleared`, `owed: resume not sent`. Send the
  resume carrying its brief (`briefs/<row>.md`) **immediately**, even when the next step is only
  waiting. Nothing else may wake it: a bare message, a monitor or a notification reaches a worker with
  no brief, which then hedges or invents. This has bitten repeatedly in practice.
- **Idle notice** → a notice for a worker that's queued, landed, or archived: ignore it (archiving
  counts as an exit, and exits fire notices too). If the worker sent a message since the last notice,
  ignore the notice. Otherwise read its tail (`list_events`, limit 6). A `send_message` call in its last
  turn means the report is in flight (the idle notice can arrive before the message does), so wait for
  it. No such call means it stopped without reporting: tell the operator what it's sitting on.
  Re-subscribe after every idle notice while the worker is in flight.

**Subscribing.** Resolve the worker's name fresh every time; never reuse one. Call `get_session(<worker
sessionId>)` for its current title, find the `ListAgents` row with that title, then call
`SendMessage(to: "<title> [ref]", notify_when_idle: true)` with no message. If it says the agent isn't
reachable, the title changed between those calls. Resolve again once.

**Monitors.** Record every watch you set (the *Watchdog* below, a CI poller, anything recurring) in the
ledger's `Monitors` while it runs, and remove the line when it ends. A compacted orchestrator otherwise
forgets it has one, or starts a second. Record what it takes to **stop** it — for a process, its pid.
You can't kill what you can't name, and a watchdog refuses to start while a live one holds its pidfile.

**Standing rules.** When the operator attaches an instruction to one worker mid-flight ("bot posts come
to me, not to it"), write it to that row. It exists nowhere else.

### 7. Cleanup

Execute only what the card agreed, and name it as you do it.

- `archive when verified` → `mcp__ccd_session_mgmt__archive_session` once DONE verifies.
- `archive when merged` → once the branch is on `<base>` (landed by you or the operator, `git branch
  --merged <base>` lists it, or `list_sessions` shows `prState: MERGED`), archive.
- `keep` → leave it running; follow-up work goes to it by `RELAY`.
- **Roster and watchdog** → drop the worker's line from `roster.tsv` as it stops. When the last one
  goes, stop the watchdog by the pid in `watchdog.pid`, clear its `Monitors` line, and delete
  `reported.txt` and `active.tsv`. Both serve only the sequence that just ended: nothing truncates
  them, and a later worker reusing a ticket id would be deduped or clocked against them.

Archiving detaches the worktree (the branch is released and kept, so it can be merged or checked out
elsewhere) and hands the directory to the app's reuse pool. It's reversible (`unarchive_session`). The
app may show its own approval card; that's expected. Cleanup never deletes a branch and never runs
`git worktree remove`; the pool is the app's to reap.

### 8. Sequences and landing

**Queue card.** The pre-spawn card, with one row per unit:

> **Queue 3 workers** · in order · mode `default`
>
> | # | Unit | Title | Scope | Cleanup |
> |---|---|---|---|---|
> | 1 | SK2b | `SK2b — short verb skills` | whole | archive when merged |
> | 2 | DR1 | `DR1 — restructure the driver` | whole | archive when merged |
> | 3 | SK3 | `SK3 — versioned install layer` | whole | archive when merged |
>
> Landing: **operator decides** · `CREW.md` allows `delegated`: `git merge --ff-only`, then
> `cd hg && npm run build`
> Safety: ✓ clear against 0 workers outside the sequence · main checkout on `graph-port` ✓
>
> **→ You:** `go`, or override (`2 title: …`, `landing: delegated`).

**Spawn every unit now** so its chip is ready: unit 1 with a ready brief, the rest with the **queued
variant** (no Job section). Don't write later units' specs yet. By the time their turn comes, earlier
units will have changed the base under them, and a spec written now would be stale.

**When unit N's DONE verifies:**

1. **Land.** Delegated → in the main checkout, check the working tree is clean and on `<base>`, then run
   `git merge --ff-only <worker-branch>`, then each `CREW.md` › Post-land command. If ff-only refuses
   (`fatal: Not possible to fast-forward, aborting.`, exit 128), the base moved under the worker: stop
   the sequence and tell the operator. Never force, rebase, or
   make a merge commit to get past it. Not delegated → report the verdict and wait until the operator
   has landed it (`git branch --merged <base>` lists it).
2. **Clean up** unit N per its card.
3. **Start** unit N+1: send `START` ([references/brief-template.md](references/brief-template.md) ›
   START) with the new base sha and its Job section, written now from the landed state. Include what
   earlier units changed and anything they handed on. Then add its roster line and subscribe to its
   idle notice.

**Hold the base still.** While a sequence is in flight, nothing commits to `<base>` except landings.
That includes you; tell the operator the same. One stray commit and the next ff-only landing is refused.

### Roster

The roster is every worker this orchestrator spawned that isn't archived. It lives in the ledger
(step 0), joined to live state from the app: `list_sessions`, then `get_session` on each candidate,
keeping those whose `parentSessionId` is your sessionId (`list_sessions` rows don't carry it). If you
also spawned non-crew chips, confirm with the `crew:brief` marker in the worker's first message
(`list_events`). A live session with no ledger row is only an orphan if the archive doesn't know it.

### Watchdog — a looping worker never goes idle

Idle notices only fire when a worker stops. A worker stuck in a fix/review loop never stops, so no
notice ever arrives. Origin (hg, 2026-09-22): a unit worker ran ~15 isolated-review rounds over hours,
hand-growing a Markdown parser 519 → 779 lines, and the orchestrator didn't look for the whole stretch.

- **While any worker is `running`, a watchdog process runs.** Write `roster.tsv` **first** — a missing
  crew dir or roster is an immediate exit 2 — then launch it with the Bash tool's `run_in_background`,
  not a shell `&`: the harness re-invokes you when a backgrounded command exits, and that exit is the
  entire mechanism.
  ```bash
  <skill-dir>/scripts/watchdog.sh --base <base> \
    [--interval <s>] [--no-commit <s>] [--subagent-step <n>] \
    ~/.claude/crew/<slug>/ 2>> ~/.claude/crew/<slug>/watchdog.log
  ```
  Thresholds come from `CREW.md` › Ledger; its defaults are the values hg proved (1200 / 3600 / 3).
  **Confirm it is still alive before you record it** in the ledger's `Monitors` with its pid. A launch
  that fails exits at once — `2` bad usage, missing crew dir or roster, state not writable · `3` a live
  watchdog already holds the pidfile · `4` no usable `stat(1)` — and a `Monitors` line naming a pid
  that died a second ago reads exactly like a healthy one.
  It polls every roster worker without waking you, stays silent, and exits with one `WATCHDOG …` line
  the moment a trigger shows — which wakes you with the finding already in hand. Handle it, then
  **launch a fresh one**: it is one-shot by design. Don't use a recurring `CronCreate` here. It would
  wake you every cadence to usually learn nothing, and every wake re-reads your whole context.
- **It can go blind, and says so only on stderr** — which is why the launch line redirects. It warns
  there when a roster worker has no transcript directory, meaning that worker is unwatched, and when
  `roster.tsv` disappears. Read `watchdog.log` whenever a worker seems unmonitored.
- **What neither trigger can see:** the no-commit trigger fires only while the worker is still writing
  transcripts — a fixed 15-minute window, not a tunable. A worker that has stopped writing altogether,
  wedged or hung or dead, is invisible to both triggers however old its HEAD is. That case is yours to
  catch on your own turns.
- **Its roster is `~/.claude/crew/<slug>/roster.tsv`** — `<ticket>` TAB `<worktree-path>` TAB
  `<start epoch>`, one line per `running` worker, and yours to maintain. Set the start to `date +%s`
  as the worker goes `running`: its no-commit clock never starts earlier, so a clock an earlier worker
  left for the same ticket and worktree can't fire minutes in. Write the ledger row and the roster
  line in the same step:
  a missing line is a worker nobody is watching, and nothing will tell you. Rewrite it
  write-to-temp-then-`mv`, never in place. It is re-read every pass, so an edit lands with no restart.
  The worktree path must be **byte-identical to the one the app reports** — the transcript directory
  is derived from it by substitution, so a trailing slash or a `/private/var` vs `/var` spelling
  silently yields an unwatched worker. One `--base` covers the whole roster, and it is used only as
  the baseline before a worker's first push; on a mixed-base roster, pass the base most of them share.
- **Stop it by the pid** in `~/.claude/crew/<slug>/watchdog.pid` once the last worker stops, and clear
  its `Monitors` line. **Never `pkill -f watchdog.sh`** — every project's watchdog is a `watchdog.sh`,
  so a name-based kill takes out every project's watchdog at once.
- **Also check on every orchestrator turn**, cheaply: `list_events` tail (limit ~40) and
  `git log -1 --format=%cr` plus `git status --porcelain | wc -l` in each running worker's
  `worktreePath`. Count review→fix iterations since its last report. The watchdog covers the stretches
  between your turns; this covers the turn you are in.
- **Surface to the operator** — don't wait for the worker to ask — when any *Worker* step 7 (loop
  budget) trigger shows, whether the watchdog or your own turn found it. Between your turns the
  watchdog covers a commit gap past the brief's no-commit threshold, and review iterations only
  roughly (sub-agent growth past its step, not the brief's limit); the rest are yours: a fix-created
  finding, an edge-case chase, a reimplementation of a spec. Say what it spends on, the trend, and the
  recommended stop (usually: fix what the last review found, commit, close out; or swap to a library).
  Redirecting the worker then needs the operator's words, relayed.

**Status** (`crew status`, "what are my workers doing"): one row per roster worker — ticket, title,
status (`chip` / `queued` / `running` / `waiting on you` / `blocked` / `cleared` / `done` /
`verified` / `landed`),
branch, and the pending question if any. Pull live state from `list_sessions`; don't message workers to
ask.

---

## Worker

You were spawned by an orchestrator. Your brief is your first message. You remember nothing else.

1. **ONLINE.** `mcp__ccd_session_mgmt__get_session("self")` → your sessionId. Send `ONLINE` to the
   orchestrator's sessionId with `state: ready` if your brief has a Job section, or `state: queued` if
   it says the job is deferred. If the send isn't `delivered` or `queued`: `list_sessions`, find exactly
   one session whose title matches the brief's orchestrator title, ignoring a leading `🌳 `, and send to
   that. Zero or several matches, or still failing → tell the operator in this session that you can't
   reach the orchestrator, and wait. Don't start the work; nobody would hear about it.

   **Queued → end your turn now.** Don't set up, read the repo's docs, or look at the code: all of it
   will be stale by the time you start. When `START` arrives, run the *START steps* below, then
   continue at step 2.
2. **Set up.** First the base, guarded: if `git status --porcelain` is empty and your branch carries no
   work of yours, run `git switch -C "$(git branch --show-current)" <brief's base sha>`; if it carries
   work, `BLOCKED`. Confirm `git rev-parse HEAD` is that sha. Then apply the brief's branch rule
   (`git branch -m <name>`) and worktree setup. You're already in a fresh worktree on a `claude/…`
   branch; never create another one.
3. **Run the command** exactly as the brief gives it, mode included, as if the operator typed it.
4. **Waiting on the operator?** Send `NEED-INPUT` *before* ending the turn — every time, including
   inside the command's own gates and fork cards. Ask in this session as you normally would, too.
5. **RELAY arrives** → the operator's words. If they answer your pending question, continue. If you
   already got an answer here, say so in this session and don't act on the relay twice.
6. **Stuck** → `BLOCKED`, end the turn. Don't work around it; don't ask the operator directly
   instead of reporting.
7. **Loop budget — a fix/review cycle is bounded, never open-ended.** The limit is the one your brief
   states; absent one, **two** review→fix iterations per unit or PR round: the review,
   the fix, one re-review of the fix delta. Going past it needs the operator: `NEED-INPUT` with the
   per-iteration finding counts. Stop and send `NEED-INPUT` *at once*, before the budget, on any of:
   - a finding caused by the previous iteration's own fix (fixes are seeding findings);
   - findings moving to ever-rarer inputs round over round (an edge-case chase, not a defect hunt);
   - the fix is growing a reimplementation of a spec or format (Markdown, YAML, URLs, dates, shell
     quoting) → propose the well-tested library instead; its install is a Hard Gate to ask for, never
     a reason to hand-roll;
   - going your brief's no-commit threshold (absent, 60 minutes) without a commit — commit what's
     green, then judge whether to go on.
   The budget caps review iterations, never fixes: every VALID finding is fixed and pinned whatever
   its severity (a finding wrong on the merits is declined with its reason), including the last
   allowed review's, in that same pass and without re-reviewing that fix. **At the last allowed
   review, a fix-created finding is fixed and the work proceeds, with no escalation.** That trigger
   exists to stop another local iteration, and none follows; the next independent look is the PR's
   bots or the orchestrator's verify. The edge-case chase, the hand-rolled spec and the 60-minute
   triggers still escalate at any point. Recording a valid finding instead of fixing it is the
   operator's call, not the worker's. A PR's review ROUNDS (bot review → fix → push) are a
   separate count, capped only by the brief's round cap.
8. **Stop point** → `DONE`, then stop. The orchestrator verifies, lands if delegated, and cleans up.
9. **If this project checkpoints by clearing your own context** — the orchestrator can't do it for you,
   since a chip-started worker refuses its `clear_session` — keep your own running notes (convention:
   `$(git rev-parse --git-dir)/crew-ledger.md`), updated before every `DONE`. Send `DONE` saying you are
   about to clear, then clear as your very last action. You wake with nothing, so anything not in that
   file or in the orchestrator's resume is gone. Never clear while one step from finishing.

**START steps (queued workers only).** `<base>` is the brief's base branch; `<sha>` is from START's
first line.

1. Confirm you're still fresh: `git status --porcelain` and `git log --oneline <base>..HEAD` both print
   nothing. Otherwise → `BLOCKED`.
2. Re-point your branch to the current base: `git switch -C "$(git branch --show-current)" <base>`.
   Nothing is lost; step 1 proved the branch has no work on it.
3. Check the sha is in your history: `git merge-base --is-ancestor <sha> HEAD`. If not → `BLOCKED`.
4. START's Job section replaces your brief's. Continue at step 2 above.

Never: push, merge, or open a PR past the stop point · touch the `Do not touch` paths · install or link
anything that outlives this worktree (global installs, links from your home directory into it), since
the worktree gets archived and the link would dangle · message another worker · archive yourself · send
anything besides the four kinds.

---

## Gotchas

- **Address by sessionId, not name.** Name-based `SendMessage` breaks when a session is renamed, and
  Remote Control copies show up as duplicate names. `send_message` by id doesn't. Keep the title as a
  fallback only.
- **`spawn_task` hands back a task id**, and the session exists only after the operator clicks. That's
  why `ONLINE` exists: it's the first moment the orchestrator can learn the worker's id and subscribe.
- **Idle notices are one-shot and local, and they fire on exit too.** `notify_when_idle` fires once
  when the session is next idle *or exits*, only for sessions on this machine, and only from a main
  conversation. Re-subscribe after each one. Archiving a subscribed worker produces a notice for a
  worker that's already done. Across permission modes the notice is only logged, not delivered, unless
  you spawned that session; crew workers always qualify.
- **Titles change under you.** The app prefixes `🌳 ` to worktree sessions on its own, mid-turn. Seen
  live: the worker went from `DEMO-1 — …` to `🌳 DEMO-1 — …` and a name-based `SendMessage` with the old
  name failed as "not reachable", while `send_message` by id kept working. Ids for everything; names only
  resolved just in time.
- **The idle notice can beat the report.** Seen live twice out of two: the worker sent `NEED-INPUT` (and
  later `DONE`) and ended its turn, and the idle notice reached the orchestrator first. The report was
  queued behind the orchestrator's own turn. Check the worker's tail before calling it silent.
- **Spawned workers are traceable.** `get_session` on a worker reports `parentSessionId` (the
  orchestrator), `worktreePath` (`<repo>/.claude/worktrees/<name>`), and `sourceBranch`; the branch
  starts as `claude/<name>`. `list_sessions` omits `parentSessionId`.
- **Never assume which commit the app cut a worker from.** In hg (2026-09-22) five spawns out of five
  were cut from the default branch `main` while the main checkout sat on `graph-port`; `get_session`
  reported `sourceBranch: main` each time. Another repo was seen cutting from the checkout's branch.
  The brief states the base as a sha and the worker re-points itself (*Worker* step 2), so whichever
  the app does, the worker starts where the unit needs it.
- **Queued workers start stale.** Seen live in hg: two queued workers still sat at the sha their base
  had at spawn time, after an earlier unit had landed and moved the base on. The START re-point exists
  for this.
- **A message drains after the worker has moved — write re-points GUARDED, never unconditional.** Seen
  live in hg: a START carrying `git switch -C <branch> <sha>` sat queued behind the worker's turn, and
  by the time it drained the worker had re-pointed itself (`git merge --ff-only <base>` — same
  destination, no history rewritten) and committed a whole round. The step was harmless when written
  against an empty branch and would have discarded two commits when it ran; the worker refused it and
  said so. Phrase it as a check that acts only if needed ("if `git log <base>..HEAD` is empty, re-point
  with `switch -C`; if it prints commits, you are past this step — use `merge --ff-only <base>`"), and
  never pair it with a freshness gate that reports `BLOCKED` on the worker's own finished work.
- **Worker sessions don't share your memory.** A worktree session gets its own project folder under
  `~/.claude/projects/`, with no `memory/` in it (verified), so it most likely can't see memory the
  orchestrator saved (inferred). Put every decision a unit needs in its brief or START.
- **Global installs from a worktree dangle.** Seen in hg: its skill installer, run from a worktree,
  would point the operator's home skill links at a directory that gets archived. Global installs belong
  in the main checkout, usually as a Post-land command.
- **You can't clear a worker's context for it.** `clear_session` accepts "a session this session
  started", but a chip-started worker counts as started by the *operator's click*, so it's refused.
  The worker clears itself as its last action, and you re-send its brief. *(Reported from a live run,
  2026-09-23; not reproduced here.)*
- **A worker's own files live in git metadata that pruning deletes.** A worktree's `.git` dir is
  `<main>/.git/worktrees/<name>/`, which `git worktree prune` removes. Copy anything you'll still need
  into the archive when you evict the row; don't reference it.
- **`send_message` doesn't work in unattended sessions** (scheduled-task runs, remote-dispatched
  sessions), in either direction. A worker there has no report channel. Don't spawn one there.
- **Permission prompts can't be relayed and don't make a session idle.** A worker blocked on a tool
  approval mid-call can't send a message, and no idle notice fires. The app's own attention badge on the
  worker is the only signal. *(Inferred from the tool docs; not yet observed.)*
- **Relayed consent is refused, correctly.** Workers refuse relayed approvals for gated actions. Seen in
  practice: a worker declined a relayed request to clear its own context, and a classifier-blocked edit
  had to be approved by the operator inside the worker session.
- **An archived worker's worktree stays on disk.** Seen live: after `archive_session`, `git worktree
  list` still showed it, at a detached HEAD, with the branch intact. `get_storage_usage` counts it as
  "kept ready for new sessions", the app's reuse pool, not as a leak. Pooled worktrees are not workers:
  build the roster from `parentSessionId`, never from `git worktree list`.
- **Uncommitted config doesn't reach workers.** A worktree is cut from committed state, so an
  uncommitted `docs/CREW.md` or `.env` isn't there. The brief carries everything; `.env`-style files
  belong in the worktree setup.
