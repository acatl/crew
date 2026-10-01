---
name: crew
description: >-
  Orchestrator ↔ worker sessions. One session (the orchestrator) spins up a fresh worker session per
  ticket or slice, briefs it, relays operator input to and from it, verifies its result, lands it when
  the operator delegates that, and cleans up. It runs a single worker or an ordered sequence of queued
  workers. Defines the contract both sides follow: the brief, the worker's four reports (ONLINE,
  NEED-INPUT, BLOCKED, DONE), the orchestrator's RELAY, START and ANSWER, the input invariant,
  parallel-safety, and who may do what. A workflow file sets how each worker works; the built-in is
  `standard`. Works in any repo; per-project answers live in docs/CREW.md, interviewed on first use.
  Triggers on "spin up a worker for", "spin up a <workflow> worker for", "spawn a worker", "start a
  worker session", "dispatch KINO-5 to a worker", "queue workers for", "run these tickets in
  sequence", "crew status", "what are my workers doing". Also loads in a worker whose first message
  starts with `<!-- crew:brief`.
argument-hint: "[<workflow>] <ticket-id>[ → <ticket-id>…] [mode]  |  status"
license: MIT
compatibility: >-
  Needs the Claude desktop app's Code tab, whose session tools (spawn_task, send_message, get_session,
  archive_session) the Claude Code CLI does not provide; bash and git; and a BSD or GNU stat(1), so
  macOS or Linux.
metadata:
  author: Acatl Pacheco
  version: "1.0.0" # x-release-please-version
---

# crew — orchestrator ↔ worker sessions

One orchestrator session. One fresh worker session per unit of work (a ticket or a slice of one). The
orchestrator writes the brief, the operator clicks the chip, the worker works its **workflow** and
reports back. This file is the contract; a workflow file says how a worker works; `docs/CREW.md`
holds the per-project answers.

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
| `ONLINE` | first action after reading the brief, unless it's a resume | own sessionId, branch, mode, and `state: ready` (with its workflow and first stage) or `state: queued` | ready → proceeds · queued → ends its turn |
| `NEED-INPUT` | **before ending any turn that waits on the operator** — a gate, a fork card, a question, a plan approval | the question verbatim, the options, and `answer: here or relay` or `answer: in this session only` | ends its turn and waits |
| `BLOCKED` | can't proceed and no answer to a question fixes it — a failure, missing setup, something the brief doesn't cover | what blocked it, where, what the fix likely needs | ends its turn and waits |
| `DONE` | a workflow stage that reports ends | first line `checkpoint <stage>` or `stop <stage>`; branch, commit sha, verify result | checkpoint → goes on · stop → stops |

Orchestrator → worker, same tool, to the worker's sessionId:

| Kind | Sent when | Body carries |
|---|---|---|
| `RELAY` | the operator answered or instructed through the orchestrator | the operator's words, verbatim, nothing added |
| `START` | a queued worker's turn has come | `base <sha>` in the first line, then the Job section its queued brief left out, written from the current landed state. It replaces the brief's Job section. Its authority is the operator's `go` on the queue card. |
| `ANSWER` | a worker's pending question is clear-cut and the operator delegated such picks to the orchestrator | the orchestrator's own answer, labelled as its own. Only a routing or stage pick that follows from recorded decisions, or an answer whose effect is inside the brief's grant. Never a hard-floor answer, a consent card, a real tradeoff, or a locked-decision change: those stay the operator's. The worker records it with its source ("orchestrator, under the operator's standing delegation"), never as the operator's words. |

Besides the brief and its resume (*Orchestrator* step 6), nothing else crosses. No progress narration, no "starting now", no worker-to-worker messages.

### The input invariant

Every `NEED-INPUT` appears in **two places**: in the worker's own session (as the operator would see it
if they were watching there) and in the orchestrator (the message). The orchestrator nudges the
operator, who answers in either place.

- **Answered in the worker session** → the worker continues. It sends nothing extra; its next message
  supersedes the pending question.
- **Answered in the orchestrator** → the orchestrator sends `RELAY` with the operator's words verbatim.
  The worker treats that as the operator's answer.
- **Answered by the orchestrator** → `ANSWER`, only under a standing delegation (see its row).
- **Never relayed:** tool-permission prompts (the approval UI lives in the worker's window) and consent
  for anything the worker's own rules gate (push, deploy, install, destructive). A relayed "yes" there is
  cross-session permission laundering. The worker marks these `answer: in this session only`; the
  orchestrator's nudge sends the operator to the worker session.

A queued worker waiting for `START` is waiting on the orchestrator, not the operator. It sends no
`NEED-INPUT` for that wait.

### Authority

- **The trigger** authorizes its card and the spawns that card lists: one worker, or one sequence. Not
  a push, a branch deletion, or a spawn the card didn't list. Each of those is a separate ask.
- **Landing** (bringing a worker's branch into the base) happens only on delegation that
  `docs/CREW.md` › Integration allows: the card's `landing: delegated`, or, under Integration mode
  `pr`, its written merge rule for a PR-merging unit, unless the card says `landing: operator`.
  A plain `go` never delegates. Without delegation, the operator lands.
- **The worker** follows its workflow as if the operator directed it, mode included — `yolo` means
  yolo — up to the workflow's stop stage, and commits. Nothing past it. It never creates a worktree
  (it already has one), never installs or links anything that outlives its worktree, never archives
  itself, never messages another worker.
- **The orchestrator** verifies by running, never by trusting a report. It executes only the landing and
  cleanup agreed on the card. It never merges other work to unblock a worker.
- **A workflow** can't change this contract: the messages, the input invariant, this authority.

### One worker per unit

A worker is created for one ticket or slice and disposed of per its cleanup plan. A session that
outlives its unit carries stale context into the next one, and clearing another session's context is
permission-gated. A fresh session is the only dependable clean start.

---

## Orchestrator

**Triggers.** The trigger is a complete instruction, its mode passed through untouched: no "shall I?"
round trip before the card.
- One worker: `spin up a worker for <TICKET> [mode]` (the project's default workflow), or
  `spin up a <workflow> worker for <TICKET>` / `… for <TICKET> with <workflow>`.
- A sequence: `spin up [<workflow>] workers for <A> → <B> → <C> [mode]`, "queue workers for A, B and
  C in order". Units run one at a time, in the order given (step 8).

**`<skill-dir>`** is this skill's own directory: the path Claude Code prints as "Base directory for this
skill" when it loads the skill. The scripts below run from `<skill-dir>/scripts/`. Substitute that real
path; never assume where the skill is installed.

### 0. Resume from the ledger

The roster lives in your conversation, which a compaction or a `/clear` destroys; the ledger
survives. See [references/ledger.md](references/ledger.md) for its location, shape and rules.

If the roster isn't already in this conversation, read `ledger.md` and reconcile it against
`list_sessions` / `get_session` before anything else. Report drift; never silently patch it. Then keep
it written: every transition below names its write.

### 1. Resolve config and workflow

Read `docs/CREW.md` at the repo root. Missing → the first-use interview in
[references/crew-md.md](references/crew-md.md). Still has `## Verbs` → its *Migration* first.
Workers never read `docs/CREW.md`; you resolve it into each brief.

The workflow: the named one, else the ✓ row of `CREW.md` › Workflows, else `standard`. A name
resolves to its Workflows row, else a built-in ([references/workflow-standard.md](references/workflow-standard.md)).
Unknown → say so on the card; no spawn. Read the file: its Parameters fill the brief (ask on the
card for a blank one); its stages say what each report means.

### 2. Read the ticket and estimate its surface

Read the ticket from the source `docs/CREW.md` names. Take its title. Estimate the **surface** — the
paths the work will likely touch — from the ticket text plus a quick search of the codebase. Paths are
repo-relative; a directory covers everything under it. An estimate is fine; say it's an estimate.

When the brief carries the spec, what you write here *is* it. Write it for a session with no memory of
this conversation, including any decision that lives only in your memory.

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

> **Spawn KINO-5 → worker** · workflow `standard` · mode `yolo`
>
> | Field | Default |
> |---|---|
> | Title | `KINO-5 — Add export command` |
> | Workflow | `standard` (plan → build → review → handoff) |
> | Scope | Whole ticket |
> | Cleanup | Archive when merged |
> | Landing | Operator decides |
> | Safety | ✓ clear — 2 workers in flight, no shared paths; main checkout on `main` |
>
> **→ You:** `go`, or override a line or a workflow parameter but `no-commit` (`workflow: pr`, `plan: skip`, `cleanup: keep`).

- **Title** default: `CREW.md` › Defaults, else `{TICKET} — {ticket title}`. It becomes the chip label
  and the session title, so lead with the ticket id — the sidebar sorts, and the roster finds it.
- **Scope**: whole ticket, or a slice described in one line.
- **Cleanup** default by scope (`CREW.md` › Defaults, else whole ticket → `archive when merged`,
  slice → `keep`). Options: `archive when verified` · `archive when merged` · `keep`.
- **Landing** defaults to `operator decides`; under Integration mode `pr`, a PR-merging unit shows
  `delegated (merge rule)`, which `landing: operator` withholds. `ff-only`: add what
  `landing: delegated` would run (`git merge --ff-only`, then Post-land); only the operator writes it.
- **Safety**: the step 3 result. On ⚠ overlap, recommend one of: wait for the overlapping worker,
  narrow this scope to avoid the shared paths, or proceed with those paths listed under `Do not touch`.

### 5. Spawn

1. `mcp__ccd_session_mgmt__get_session("self")` → your `sessionId` and `title`.
2. Fill [references/brief-template.md](references/brief-template.md), the ready variant. Every `{…}`
   gets a value or `none`; no placeholder survives.
3. `mcp__ccd_session__spawn_task` with `title` = the card's title, `tldr` = one plain sentence, `prompt`
   = the filled brief. Pass `cwd` only when the worker belongs to a different repo than yours.
4. **Write the ledger row** (status `chip`, the `task_id` in place of a session id, workflow, stage,
   surface, scope, cleanup, landing) and save the brief exactly as sent to `briefs/<row>.md`.
5. Tell the operator the chip is up and needs a click. End your turn.

`spawn_task` returns a task id, not a session id. You learn the worker's session from its `ONLINE`.

### 6. Handle messages

- **ONLINE** → `get_session(<worker sessionId>)`: confirm `parentSessionId` is yours, and record
  `worktreePath` (the worker's cwd for `overlap.sh` and verify) and `sourceBranch`. Then:
  `state: ready` → status `running`, add its roster line, subscribe to its idle notice (*Subscribing*).
  `state: queued` → status `queued`. **Don't subscribe yet:** it goes idle at once, so the notice means
  nothing. Subscribe when you send its `START`. Either way, write the session id and worktree to the row.
- **NEED-INPUT** → never send `ANSWER` or `RELAY` for `answer: in this session only`: nudge without
  "answer here", and say why. Otherwise, a standing delegation covers the question within the
  `ANSWER` row's limits → no nudge; send `ANSWER`, write it to the ledger row, and tell the operator,
  whose `RELAY` overrides it. Right before sending any `ANSWER` or `RELAY`, read the worker's tail
  (`list_events`, limit 4): answered there already → say so, send nothing. Else nudge:
  > ⏸ **KINO-5 needs you** — <question, one line>
  > <options>
  > <!-- markdownlint-disable-next-line MD051 -->
  > Answer here and I'll relay, or in [KINO-5 — Add export command](#<worker-sessionId>).

  The operator answers here → `RELAY` their words verbatim. Ledger: `owed` holds the question
  verbatim while pending, then its decision.
- **BLOCKED** → surface it the same way, with the worker's proposed fix. Decide with the operator.
- **DONE `checkpoint <stage>`** → write `stage`, do what that stage's Orchestrator line says. No
  landing, no cleanup. From an older brief, `DONE · checkpoint: <boundary>` or a plain `DONE` saying
  it will clear is a checkpoint; any other plain `DONE` is a stop.
- **DONE `stop <stage>`** → verify by running the brief's `verify` in the worker's cwd (none:
  `CREW.md` › Verify, else `docs/HARNESS.md` › Sensors, else ask). Write the verdict and sha to the
  row, against the worker's claim. On pass: land if delegated, clean up, start any next unit (steps 7, 8).
- **A worker reports it cleared (or is clearing) its own context** → status `cleared`,
  `owed: resume not sent`. Send the resume **immediately**, even when the next step is only waiting: a
  worker woken by anything else, without its brief, hedges or invents (seen repeatedly). First confirm
  the clear (`list_events`: idle, no messages; a resume sent earlier queues behind it). The resume is
  the saved brief with its marker line set to `state=resume` and any queued Job block swapped for its
  START (`briefs/<row>-start.md`) whole, then a `## Resume` section: where to pick up, the approved
  plan's path, the worker's ledger path, facts learned since the brief (an environment quirk, a
  throttle, an operator call), and any message still pending. Once it's sent: drop `resume not sent`
  from `owed`, status `running` unless `owed` still holds a question, roster start epoch reset.
- **Idle notice** → ignore it for a worker that's queued, landed or archived, or verified with nothing
  sent to it since (exits fire notices too). One busy now (`ListAgents`), yet to start on your last message, or for a turn that
  ended before you sent it (`list_events` times) is stale (*Gotchas*): see *Subscribing*. Check its
  tail on any other notice (`list_events`, limit 6), in order:
  - a final `waiting: <what>[, until <time>]` line → **waiting**: no nudge; arm or keep its wake (*Wakes*).
  - a report in its last turn → not yet here: in flight (the notice can beat it); wait, then judge it
    as here. Here: its kind's handling covers the notice. Check it didn't idle after a `checkpoint`
    with no clear: tell the operator.
  - else → it stopped without reporting: tell the operator what it's sitting on.

**Subscribing.** Subscribe at a ready `ONLINE`, after each message you send a worker, at each report
(idle by then → treat it as an idle notice), and at a stale notice, only while `ListAgents` shows it
busy: an idle one fires at once (a stale "busy", seen live, costs one such notice: accept it). For one
yet to start on your message, run a background `sleep 60` (*Monitors*); at its end, still so → tell the
operator, busy → subscribe, idle → treat it as an idle notice. Resolve its title fresh; never reuse
one. Call `get_session(<worker sessionId>)`, then
`SendMessage(to: "<title> [ref]", notify_when_idle: true)` with no message, `[ref]` from `ListAgents`.
"Not reachable" → resolve again; still so (seen after a clear) → retry when anything next wakes you (a
report, a `sleep`, the watchdog). Use the title, never the id.

**Wakes.** Keep one background `sleep` (*Monitors*) per worker whose last report or turn ends in a
`waiting: <what>[, until <time>]` line, since the watchdog can't see an idle one: to the `until` plus
10 minutes, else 30. Each report replaces it, from its own `waiting:` line or not at all; the
worker's stop ends it (step 7). Check at its end for activity since you armed it: any → an idle
notice; none → tell the operator once what it waits on, and re-arm at its next report.

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
- **Roster and watchdog** → drop the worker's line from `roster.tsv`, and stop its wake, as it stops.
  When the last one goes, stop the watchdog by the pid in `watchdog.pid`, clear its `Monitors` line,
  and delete `reported.txt` and `active.tsv`. Both serve only the sequence that just ended: nothing
  truncates them, and a later worker reusing a ticket id would be deduped or clocked against them.

Archiving detaches the worktree (the branch is kept) and hands the directory to the app's reuse pool.
It's reversible (`unarchive_session`), and the app may show its own approval card. Cleanup never
deletes a branch and never runs `git worktree remove`; the pool is the app's to reap.

### 8. Sequences and landing

**Queue card.** The pre-spawn card, with one row per unit:

> **Queue 3 workers** · in order · mode `default`
>
> | # | Unit | Title | Workflow | Scope | Landing | Cleanup |
> |---|---|---|---|---|---|---|
> | 1 | SK2b | `SK2b — short verb skills` | `standard` | whole | operator decides | archive when merged |
> | 2 | DR1 | `DR1 — restructure the driver` | `standard` | whole | operator decides | archive when merged |
> | 3 | SK3 | `SK3 — versioned install layer` | `standard` | whole | operator decides | archive when merged |
>
> `CREW.md` allows `delegated`: `git merge --ff-only`, then `cd hg && npm run build`
> Safety: ✓ clear against 0 workers outside the sequence · main checkout on `graph-port` ✓
>
> **→ You:** `go`, or override (`2 title: …`, `landing: delegated`, `1 landing: operator`).

Follow step 4 for each Landing. **Spawn every unit now**: unit 1 with a ready brief, the rest with the **queued variant** (no Job
section). Don't write later units' specs yet: earlier units will move the base under them.

**When unit N's DONE verifies:**

1. **Land.** A merged PR (Integration mode `pr`) → run Post-land, which pulls the merge into `<base>`; never
   ff-only. `ff-only`, delegated → in the main checkout, on a clean `<base>`, run
   `git merge --ff-only <worker-branch>`, then each `CREW.md` › Post-land command. If ff-only refuses
   (exit 128), the base moved under the worker: stop the sequence and tell the operator; never force,
   rebase, or make a merge commit. Not delegated → report the verdict and wait until the operator
   has landed it (`git branch --merged <base>` lists it).
2. **Clean up** unit N per its card.
3. **Start** unit N+1: send `START` ([references/brief-template.md](references/brief-template.md) ›
   START) with the new base sha and its Job section, written now from the landed state. Include what
   earlier units changed and handed on, and each finding unit N carried as a "Carried from N" line
   (also a checklist line on N+1's ticket). Save it as `briefs/<row>-start.md`. Then set it
   `running`, add its roster line, and subscribe to its idle notice.

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
  as the worker goes `running`; its no-commit clock never starts earlier. Write the ledger row and the
  roster line in the same step: a missing line is a worker nobody is watching, and nothing will tell
  you. Rewrite it write-to-temp-then-`mv`, never in place. It is re-read every pass, so an edit lands
  with no restart. The worktree path must be **byte-identical to the one the app reports** — the
  transcript directory is derived from it by substitution, so a trailing slash or a `/private/var` vs
  `/var` spelling silently yields an unwatched worker. One `--base` covers the whole roster, and it is
  used only as the baseline before a worker's first push; on a mixed-base roster, pass the base most
  of them share.
- **Stop it by the pid** in `~/.claude/crew/<slug>/watchdog.pid` once the last worker stops, and clear
  its `Monitors` line. **Never `pkill -f watchdog.sh`** — every project's watchdog is a `watchdog.sh`,
  so a name-based kill takes out every project's watchdog at once.
- **Also check on every orchestrator turn**, cheaply: `list_events` tail (limit ~40) and
  `git log -1 --format=%cr` plus `git status --porcelain | wc -l` in each running worker's
  `worktreePath`. Count review→fix iterations since its last report. The watchdog covers the stretches
  between your turns; this covers the turn you are in.
- **Surface to the operator** — don't wait for the worker to ask — when any loop-budget trigger in
  the worker's workflow shows, whether the watchdog or your own turn found it. Between your turns the
  watchdog covers a commit gap past the brief's no-commit threshold, and review iterations only
  roughly (sub-agent growth past its step, not the brief's limit); the rest are yours: a fix-created
  finding, an edge-case chase, a reimplementation of a spec. Say what it spends on, the trend, and the
  recommended stop (usually: fix what the last review found, commit, close out; or swap to a library).
  Redirecting the worker then needs the operator's words, relayed.

**Status** (`crew status`, "what are my workers doing"): one row per roster worker — ticket, title,
status (`chip` / `queued` / `running` / `waiting on you` / `blocked` / `cleared` / `done` /
`verified` / `landed`), branch, and the pending question if any. Pull live state from `list_sessions`;
don't message workers to ask.

---

## Worker

You were spawned by an orchestrator. Your brief is your first message. You remember nothing else.
A brief marked `state=resume` is a resume: you cleared earlier. Send no `ONLINE`, skip step 2 and the
*START steps* (a START in it is your job), and continue at step 3 where `## Resume` says.

1. **ONLINE.** `mcp__ccd_session_mgmt__get_session("self")` → your sessionId. Send `ONLINE` to the
   orchestrator's sessionId with `state: ready` if your brief has a Job section, or `state: queued` if
   it says the job is deferred. If the send isn't `delivered` or `queued`: `list_sessions`, find exactly
   one session whose title matches the brief's orchestrator title, ignoring a leading `🌳 `, and send to
   that. Zero or several matches, or still failing → tell the operator in this session that you can't
   reach the orchestrator, and wait. Don't start the work; nobody would hear about it.

   **Queued → end your turn now.** Don't set up, read the repo's docs, or look at the code: all of it
   will be stale by the time you start. When `START` arrives, run the *START steps* below.
2. **Set up.** First the base, guarded: if `git status --porcelain` is empty and your branch carries no
   work of yours, run `git switch -C "$(git branch --show-current)" <brief's base sha>`; if it carries
   work, `BLOCKED`. Confirm `git rev-parse HEAD` is that sha. Then apply the brief's branch rule
   (`git branch -m <name>`) and worktree setup; never create another worktree. Move a ledger already at
   `$(git rev-parse --git-dir)/crew-ledger.md` onto `mktemp <that dir>/crew-ledger.XXXXXX`: the app
   reuses worktree dirs, so it's an earlier worker's. Never read it.
3. **Work your workflow.** Read the file your brief names, in full, and follow it with your parameters;
   a resume names where to pick up. No workflow named in your
   brief → your brief's Job/Spec, Boundaries and Checkpoints are the workflow; follow them as written.
4. **Waiting on the operator?** Send `NEED-INPUT` *before* ending the turn — every time, including
   inside your workflow's own gates and fork cards. Ask in this session as you normally would, too.
   Make your final line `waiting: <what wakes you>[, until <time>]` when you end a turn to wait on your
   own timer, monitor or background task, so the orchestrator reads you as waiting, not stopped.
5. **RELAY arrives** → the operator's words, never consent for a tool-permission prompt or a gated
   action. If they answer your pending question, continue. If you already got an answer here, say so
   in this session and don't act on the relay twice.
   **ANSWER arrives** → the orchestrator's own, never the operator's words: record it as "orchestrator,
   under the operator's standing delegation", and act on it. Say so here and refuse an `ANSWER` outside
   its *Messages* row, for a tool-permission prompt, a gated action or `answer: in this session only`.
   The operator's answer wins.
6. **Stuck** → `BLOCKED`, end the turn. Don't work around it; don't ask the operator directly
   instead of reporting.
7. **Loop budget:** your workflow's Rules; with none, your brief's.
8. **At each stage that reports** → `DONE` with `checkpoint <stage>`, and go on. **At the stop
   stage** → `DONE` with `stop <stage>`, then stop. The orchestrator verifies, lands if delegated, and
   cleans up.
9. **Clear your context** only where your workflow says so, by yourself, as your last action: the
   orchestrator can't clear a chip-started worker. You wake with only its resume.

**START steps (queued workers only).** `<base>` is the brief's base branch; `<sha>` is from START's
first line.

1. Confirm you're still fresh: `git status --porcelain` prints nothing and you've committed nothing.
   Otherwise → `BLOCKED`. (Commits from where the app cut you aren't yours.)
2. Check the sha is on the base: `git merge-base --is-ancestor <sha> <base>`. If not → `BLOCKED`.
3. START's Job section and sha replace the brief's Job section and base sha. Continue at *Worker*
   step 2, which re-points you to that sha.

Never: push, merge, or open a PR past the stop stage · touch the `Do not touch` paths · install or link
anything that outlives this worktree (global installs, links from your home directory into it), since
the worktree gets archived and the link would dangle · message another worker · archive yourself · send
anything besides the four kinds.

---

## Gotchas

- **Address by sessionId, not name.** Name-based `SendMessage` breaks when a session is renamed, and
  Remote Control copies show up as duplicate names. Seen live: the app prefixed `🌳 ` to a worktree
  session mid-turn (`DEMO-1 — …` → `🌳 DEMO-1 — …`), and a `SendMessage` to the old name failed as "not
  reachable" while `send_message` by id kept working. Names only as a fallback, resolved just in time.
- **Idle notices are one-shot and local, and they fire on exit too.** `notify_when_idle` fires once when
  the session is next idle *or exits*, only for sessions on this machine, and only from a main
  conversation, and at once on a session that's idle already. Seen live (crew LIVE1, 2026-09-28; hg
  PR #63, 2026-09-30): a worker parked on its own timer drew a notice per re-subscribe all wait, and
  was reported stopped. Across permission modes the notice is only logged, not delivered, unless you
  spawned that session; crew workers always qualify.
- **Subscribe by title; an id is refused.** Verified 2026-10-01: `SendMessage(to: "local_…",
  notify_when_idle: true)` returns "Nothing was subscribed: notify_when_idle is only supported for
  Claude sessions on this machine…". Seen live in hg (2026-09-30): right after a clear, the by-title
  subscribe was "not reachable" three times while `get_session` showed that title.
- **The idle notice can beat the report, or trail a resume.** Seen live twice out of two: a worker's
  `NEED-INPUT` (later `DONE`) queued behind the orchestrator's turn, its notice first. Seen live (crew
  FIX2, 2026-10-01): a notice for the clearing turn came after the resume had started it. Check first.
- **Never assume which commit the app cut a worker from.** In hg (2026-09-22) five spawns out of five
  were cut from the default branch `main` while the main checkout sat on `graph-port`; `get_session`
  reported `sourceBranch: main` each time. Another repo was seen cutting from the checkout's branch.
  The brief states the base as a sha and the worker re-points itself (*Worker* step 2). Queued workers
  start stale too (seen live in hg, after an earlier unit landed): START re-points them.
- **A message drains after the worker has moved — write re-points GUARDED, never unconditional.** Seen
  live in hg: a START's `git switch -C <branch> <sha>`, harmless when written, drained after the worker
  had re-pointed itself and committed a round, and would have discarded two commits; the worker refused
  it. Phrase it as a check ("if `git log <base>..HEAD` is empty, `switch -C`; else
  `merge --ff-only <base>`"), and never pair it with a freshness gate that reports `BLOCKED` on the
  worker's own finished work.
- **Worker sessions don't share your memory.** A worktree session gets its own project folder under
  `~/.claude/projects/`, with no `memory/` in it (verified), so it most likely can't see memory the
  orchestrator saved (inferred). Put every decision a unit needs in its brief or START.
- **Global installs from a worktree dangle.** Seen in hg: its skill installer, run from a worktree,
  would link the operator's home at an archived directory. Run them in the main checkout (Post-land).
- **You can't clear a worker's context for it.** `clear_session` accepts "a session this session
  started", but a chip-started worker counts as started by the *operator's click*, so it's refused.
  The worker clears itself last, and you re-send its brief. *(Reported live 2026-09-23; not reproduced.)*
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
  uncommitted `docs/CREW.md` or `.env` isn't there. The brief carries all; `.env` files go in setup.
