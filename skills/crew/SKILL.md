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
  Runs in the Claude desktop app's Code tab or in the Claude Code CLI 2.1.300 or later (background
  sessions: claude --bg, claude agents --json); needs bash, git and jq, and a BSD or GNU stat(1), so
  macOS or Linux.
metadata:
  author: Acatl Pacheco
  version: "1.0.0" # x-release-please-version
---

# crew — orchestrator ↔ worker sessions

One orchestrator session. One fresh worker session per unit of work (a ticket or a slice of one). The
orchestrator writes the brief and spawns the worker, the worker works its **workflow** and reports
back. This file is the contract; a workflow file says how a worker works, an integration file how
its work lands; `docs/CREW.md` holds the per-project answers. crew runs on a **host**, the desktop
app or the terminal CLI: a verb in *italics* (*spawn*, *message*) is done the host's way, as
[references/host.md](references/host.md) says.

**Which role are you?**
- Your first message starts with `<!-- crew:brief` → **worker**. Read *The contract*, then *Worker*.
- The operator asked you to spin up / spawn / queue / dispatch workers, or asked for crew status →
  **orchestrator**. Read *The contract*, then *Orchestrator*.

---

## The contract (both roles)

### Messages

Worker → orchestrator, always by *message* to the orchestrator the brief names. First line is
self-contained: `[crew] <KIND> · <TICKET> · <one-line summary>`.

| Kind | Sent when | Body carries | Then the worker |
|---|---|---|---|
| `ONLINE` | first action after reading the brief, unless it's a resume | mode, and `state: ready` (with its workflow and first stage) or `state: queued`; on the desktop host also its own sessionId and branch, which a terminal orchestrator reads itself (*identify*) | ready → proceeds · queued → ends its turn |
| `NEED-INPUT` | **before ending any turn that waits on the operator** — a gate, a fork card, a question, a plan approval | the question verbatim, the options, and `answer: here or relay` or `answer: in this session only` | ends its turn and waits |
| `BLOCKED` | can't proceed and no answer to a question fixes it — a failure, missing setup, something the brief doesn't cover | what blocked it, where, what the fix likely needs | ends its turn and waits |
| `DONE` | a workflow stage that reports ends | first line `checkpoint <stage>` or `stop <stage>`; branch, commit sha, verify result | checkpoint → goes on · stop → stops |

Orchestrator → worker, by *message* to the worker:

| Kind | Sent when | Body carries |
|---|---|---|
| `RELAY` | the operator answered or instructed through the orchestrator | the operator's words, verbatim, nothing added |
| `START` | a queued worker's turn has come | `base <sha>` in the first line, then the Job section its queued brief left out, written from the landed state and the unit's ledger row. It replaces the brief's Job section. Its authority is the operator's `go` on the queue card. |
| `ANSWER` | a worker's pending question is clear-cut and the operator delegated such picks to the orchestrator | the orchestrator's own answer, labelled as its own. Only a routing or stage pick that follows from recorded decisions, or an answer whose effect is inside the brief's grant. Never a hard-floor answer, a consent card, a real tradeoff, or a locked-decision change: those stay the operator's. The worker records it with its source ("orchestrator, under the operator's standing delegation"), never as the operator's words. |

Besides the brief and its resume (*Orchestrator* step 6), nothing else crosses. No progress narration, no "starting now", no worker-to-worker messages.

### The input invariant

Every `NEED-INPUT` appears in **two places**: in the worker's own session and in the orchestrator (the
message). The orchestrator nudges the
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

A queued worker waiting for `START` waits on the orchestrator, not the operator: no `NEED-INPUT` for it.

### Authority

- **The trigger** authorizes its card and the spawns that card lists: one worker, or one sequence. Not
  a push, a branch deletion, or a spawn the card didn't list. Each of those is a separate ask. A
  *restart* continues its unit's spawn; it is not a new one.
- **Landing** (bringing a worker's branch into the base) happens only on delegation that
  `docs/CREW.md` › Integration allows: the card's `landing: delegated`, or, under Integration mode
  `pr`, its written merge rule for a PR-merging unit, unless the card says `landing: operator`.
  A plain `go` never delegates. Without delegation, the operator lands.
- **The worker** follows its workflow as if the operator directed it, mode included — `yolo` means
  yolo — up to its stop stage (its integration's, if any), and commits. Nothing past it. It never
  creates a worktree but a reviewing sub-agent's own (removed with its branch), never installs
  or links anything that outlives its worktree, never archives itself, never messages another worker.
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
survives. See [references/ledger.md](references/ledger.md).

If the roster isn't already in this conversation, read `ledger.md` and reconcile it against
*roster* before anything else. Report drift; never silently patch it. Then keep
it written: every transition below names its write.

### 1. Resolve config, workflow and integration

Read `docs/CREW.md` at the repo root. Missing → the first-use interview in
[references/crew-md.md](references/crew-md.md). Still has `## Verbs` → its *Migration* first.
Workers never read `docs/CREW.md`; you resolve it into each brief.

The workflow: the named one, else the ✓ row of `CREW.md` › Workflows, else `standard`. A name
resolves to its Workflows row, else a built-in ([references/workflow-standard.md](references/workflow-standard.md)).
Unknown → say so on the card; no spawn. The integration: `CREW.md` › Integration's `file:` under `mode: pr`
(`built-in`: [references/integration-pr.md](references/integration-pr.md)), unless the card says
`integration: none`; no `file:` → none (a workflow's own PR stages follow `merge rule:`). Read each file:
its Parameters fill the brief (ask on the card for a blank one); its stages say what each report means.

### 2. Read the ticket and estimate its surface

Read the ticket from the source `docs/CREW.md` names. Take its title. Estimate the **surface** — the
paths the work will touch — from the ticket plus a quick search of the code. Paths are repo-relative;
a directory covers everything under it. An estimate is fine; say so.

When the brief carries the spec, what you write here *is* it. Write it for a session with no memory of
this conversation, including any decision that lives only in your memory.

### 3. Parallel-safety check

Run these against every in-flight worker in the roster, but a sequence's units only
against workers outside it: they run one at a time.

1. **Actual overlap** — what in-flight workers have already touched:
   ```bash
   <skill-dir>/scripts/overlap.sh --base <base> --paths <p1,p2,...> <worker-cwd>...
   ```
   Worker cwds are the roster's worktree paths. Exit 0 = clear, 1 = overlap (TSV lines:
   branch, file, matched path), 2 = usage or git error.
2. **Declared overlap** — the candidate surface against each in-flight worker's `Surface you own`.
   This catches a worker that hasn't written anything yet.
3. **Dependency** — does the ticket need work that isn't on `<base>` yet (the ticket says so, or the
   surface needs something that exists only on an in-flight branch)?
4. **Base** — pick this unit's starting commit (the line it integrates into, the default branch for a
   PR cut from it, a specific sha for an audit), and write it in the brief as **a branch plus a sha**.
   Never assume the host cut the worktree from it (see *Gotchas*); the worker re-points to that sha first.

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
> | Integration | none |
> | Scope | Whole ticket |
> | Cleanup | Archive when merged |
> | Landing | Operator decides |
> | Safety | ✓ clear — 2 workers in flight, no shared paths; main checkout on `main` |
> | Permission | `auto` (terminal host only) |
>
> **→ You:** `go`, or override a line or a workflow parameter but `no-commit` (`integration: none`, `plan: skip`, `cleanup: keep`).

- **Title** default: `CREW.md` › Defaults, else `{TICKET} — {ticket title}`. It becomes the chip label
  and the session title, so lead with the ticket id — the sidebar sorts, and the roster finds it.
- **Scope**: whole ticket, or a slice described in one line.
- **Cleanup** default by scope (`CREW.md` › Defaults, else whole ticket → `archive when merged`,
  slice → `keep`). Options: `archive when verified` · `archive when merged` · `keep`.
- **Integration**: `pr (built-in)`, `pr (<path>)` or `none` (step 1); `none` → no PR, the operator lands.
- **Landing** defaults to `operator decides`; under Integration mode `pr`, a PR-merging unit shows
  `delegated (merge rule)`, which `landing: operator` withholds. `ff-only`: add what
  `landing: delegated` would run (`git merge --ff-only`, then Post-land); only the operator writes it.
- **Safety**: the step 3 result. On ⚠ overlap, recommend one of: wait for the overlapping worker,
  narrow this scope to avoid the shared paths, or proceed with those paths listed under `Do not touch`.
- **Permission** (terminal only): the worker's mode, yours as host.md maps it; `go` starts it at once.

### 5. Spawn

1. *self* → your `sessionId`, title, host and, on the terminal, your address.
2. Fill [references/brief-template.md](references/brief-template.md), the ready variant. Every `{…}`
   gets a value or `none`; no placeholder survives.
3. **Write the ledger row** (status `chip`, `session: pending <worktree name>`, stage, surface,
   and the card's lines: `workflow` and its overrides, `integration`, mode, scope, cleanup, landing,
   `Do not touch`, any decision only in your memory, not the spec) and save the brief exactly as it
   will be sent to `briefs/<row>.md`, before you spawn: a worker with no row is one nobody tracks.
   Save a queued brief's `{SPEC}` to `briefs/<row>-spec.md`.
4. *spawn* it with the card's title and the saved brief. The worktree name is the ticket slugged
   plus the row id (`kino-5-r3`). Write what *spawn* returns into the row's `session`.
5. Tell the operator the chip needs a click (desktop) or the worker is running (terminal, *link*). End your turn.

### 6. Handle messages

- **ONLINE** → *identify* the worker: confirm it is the one you spawned, and record its worktree
  path (the worker's cwd for `overlap.sh` and verify) and branch. Then:
  `state: ready` → status `running`, add its roster line, subscribe to its idle notice (*Subscribing*).
  `state: queued` → status `queued`. **Don't subscribe yet:** it goes idle at once, so the notice means
  nothing. Subscribe when you send its `START`. Either way, write the session id and worktree to the row.
- **NEED-INPUT** → never send `ANSWER` or `RELAY` for `answer: in this session only`: nudge without
  "answer here", and say why. Otherwise, a standing delegation covers the question within the
  `ANSWER` row's limits → no nudge; send `ANSWER`, write it to the ledger row, and tell the operator,
  whose `RELAY` overrides it. Right before sending any `ANSWER` or `RELAY`, read the worker's
  *tail* (limit 4): answered there already → say so, send nothing. Else nudge:
  > ⏸ **KINO-5 needs you** — <question, one line>
  > <options>
  > Answer here and I'll relay, or in the worker (its *link*).

  The operator answers here → `RELAY` their words verbatim. Ledger: `owed` holds the question
  verbatim while pending, then its decision.
- **BLOCKED** → surface it the same way, with the worker's proposed fix. Decide with the operator.
- **DONE `checkpoint <stage>`** → write `stage`, do what that stage's Orchestrator line says. No
  landing, no cleanup. From an older brief, `DONE · checkpoint: <boundary>` or a plain `DONE` saying
  it will clear is a checkpoint; any other plain `DONE` is a stop.
- **DONE `stop <stage>`** → verify: run the brief's `verify` as `(cd <worktreePath> && <verify>)` (none:
  `CREW.md` › Verify, else `docs/HARNESS.md` › Sensors, else ask). Write the verdict and sha to the
  row, against the worker's claim. On pass: land if delegated, clean up, start any next unit (steps 7, 8).
- **A worker reports it cleared (or is clearing) its own context** → status `cleared`,
  `owed: resume not sent`. Send the resume **immediately**, even when the next step is only waiting: a
  worker woken by anything else, without its brief, hedges or invents (seen repeatedly). First confirm
  the clear (*tail*: idle, no messages; a resume sent earlier queues behind it). On the terminal a
  worker can't clear itself: it ends its turn instead, and the resume goes out by *restart*. The resume is
  the saved brief with its marker line set to `state=resume` and any queued Job block swapped for its
  START (`briefs/<row>-start.md`) whole, then a `## Resume` section: where to pick up, the approved
  plan's path, the worker's ledger path, facts learned since the brief (an environment quirk, a
  throttle, an operator call), and any message still pending. A resume never carries consent for a
  gated action or a plan approval, not even as an operator call: the worker's own ledger holds those,
  and a worker whose ledger lacks one re-asks in its own session. Once it's sent: drop `resume not
  sent` from `owed`, status `running` unless `owed` still holds a question, roster start kept.
- **Idle notice** → ignore it for a worker that's queued, landed or archived, or verified with nothing
  sent to it since (exits fire notices too). One busy now (`ListAgents`), yet to start on your last message, or for a turn that
  ended before you sent it (*tail* times) is stale (*Gotchas*): see *Subscribing*. Check its
  *tail* on any other notice (limit 6), in order:
  - a final `waiting: <what>[, until <time>]` line → **waiting**: no nudge; arm or keep its wake (*Wakes*).
  - a report in its last turn → not yet here: in flight (the notice can beat it); wait, then judge it
    as here. Here: its kind's handling covers the notice. Check it didn't idle after a `checkpoint`
    with no clear: tell the operator.
  - else → it stopped without reporting: tell the operator what it's sitting on.

**Subscribing.** Subscribe at a ready `ONLINE`, after each message you send a worker, at each report
(idle by then → treat it as an idle notice), and at a stale notice, only while `ListAgents` shows it
busy: an idle one fires at once (a stale "busy", seen live, costs one such notice: accept it). For one
yet to start on your message, run a background `sleep 60` (*Monitors*); at its end, still so → tell the
operator, busy → subscribe, idle → treat it as an idle notice. Resolve its title fresh with
*identify*; never reuse one. Then *subscribe*, `[ref]` from `ListAgents`. "Not reachable" → resolve
again; still so (seen after a clear) → retry when anything next wakes you (a report, a `sleep`, the
watchdog). Use the title, never the id; on the terminal, its address.

**Wakes.** Keep one background `sleep` (*Monitors*) per worker whose last report or turn ends in a
`waiting: <what>[, until <time>]` line, since the watchdog can't see an idle one: to the `until` plus
10 minutes, else 30. Each report replaces it, from its own `waiting:` line or not at all; the
worker's stop ends it (step 7). Check at its end for activity since you armed it: any → an idle
notice; none → tell the operator once what it waits on, and re-arm at its next report.

**Monitors.** Record every watch you set (the *Watchdog* below, a CI poller, anything recurring) in the
ledger's `Monitors` while it runs, and remove the line when it ends. A compacted orchestrator otherwise
forgets it has one, or starts a second. Record how to **stop** it (a process: its pid): a watchdog
refuses to start while a live one holds its pidfile.

**Standing rules.** When the operator attaches an instruction to one worker mid-flight ("bot posts come
to me, not to it"), write it to that row. It exists nowhere else.

### 7. Cleanup

Execute only what the card agreed, and name it as you do it.

- `archive when verified` → *stop* it once DONE verifies.
- `archive when merged` → once the branch is on `<base>` (landed by you or the operator, `git branch
  --merged <base>` lists it, or *pr-state* reads `MERGED`), *stop* it.
- `keep` → leave it running; follow-up work goes to it by `RELAY`.
- **Roster and watchdog** → drop the worker's line from `roster.tsv`, and stop its wake, as it stops.
  When the last one goes, stop the watchdog by the pid in `watchdog.pid`, clear its `Monitors` line,
  then delete `reported.txt`, `active.tsv` and `waiting.tsv`, never under a live watchdog. They serve
  only the sequence that just ended: nothing truncates them, and a later worker reusing a ticket id
  would be deduped or clocked against them.

*stop* keeps the worker's worktree and branch, reversibly.
Cleanup never deletes a branch or runs `git worktree remove` (nor `claude rm`, which does both).

### 8. Sequences and landing

**Queue card.** The pre-spawn card, with one row per unit:

> **Queue 3 workers** · in order · mode `default`
>
> | # | Unit | Title | Workflow | Integration | Scope | Landing | Cleanup |
> |---|---|---|---|---|---|---|---|
> | 1 | SK2b | `SK2b — short verb skills` | `standard` | none | whole | operator decides | archive when merged |
> | 2 | DR1 | `DR1 — restructure the driver` | `standard` | none | whole | operator decides | archive when merged |
> | 3 | SK3 | `SK3 — versioned install layer` | `standard` | none | whole | operator decides | archive when merged |
>
> `CREW.md` allows `delegated`: `git merge --ff-only`, then `(cd hg && npm run build)`
> Safety: ✓ clear against 0 workers outside the sequence · main checkout on `graph-port` ✓
>
> **→ You:** `go`, or override (`2 title: …`, `landing: delegated`, `1 landing: operator`).

Follow step 4 for each Landing. **Spawn every unit now**, each by step 5 (end your turn after the last):
unit 1 with a ready brief, the rest with the **queued variant** (no Job section; spec on disk). Their
landed state waits for START: earlier units will move the base under them. On the terminal, spawn
only unit 1 now (an idle background session isn't known to last hours), but write every unit's row and spec.

**When unit N's DONE verifies:**

1. **Land.** A merged PR (Integration mode `pr`, once `gh pr view` reads `MERGED`) → run Post-land, which pulls the merge into `<base>`; never
   ff-only. `ff-only`, delegated → in the main checkout, on a clean `<base>`, run
   `git merge --ff-only <worker-branch>`, then each `CREW.md` › Post-land command. If ff-only refuses
   (exit 128), the base moved under the worker: stop the sequence and tell the operator; never force,
   rebase, or make a merge commit. Not delegated → report the verdict and wait until the operator
   has landed it (`git branch --merged <base>` lists it).
2. **Clean up** unit N per its card.
3. **Start** unit N+1: send `START` ([references/brief-template.md](references/brief-template.md) ›
   START) with the new base sha and its Job section, written now from the landed state and its row's
   card lines, its Spec from `briefs/<row>-spec.md`, after re-running step 3 outside the sequence (a
   new overlap goes to the operator). Include what earlier units changed and handed on, and each
   finding unit N carried as a "Carried from N" line (also a checklist line on N+1's ticket). Save it
   as `briefs/<row>-start.md`. Then set it `running`, add its roster line, and subscribe to its idle
   notice. On the terminal, spawn it by step 5 instead, with that as a ready brief.

**Hold the base still.** While a sequence is in flight, nothing commits to `<base>` except landings.
That includes you; tell the operator the same. One stray commit and the next ff-only landing is refused.

### Roster

The roster is every worker this orchestrator spawned that isn't archived. It lives in the ledger
(step 0), joined to live state by *roster*. If you also spawned non-crew sessions,
confirm with the `crew:brief` marker in the worker's first message (*tail*). A live session with no
ledger row is only an orphan if the archive doesn't know it.

### Watchdog — a looping worker never goes idle

Idle notices fire only when a worker stops; one stuck in a fix/review loop never does. Origin (hg, 2026-09-22): a unit worker ran ~15 isolated-review rounds over hours,
hand-growing a Markdown parser 519 → 779 lines, and the orchestrator didn't look for the whole stretch.

- **While any worker is `running`, a watchdog process runs.** Write `roster.tsv` **first** (a missing
  crew dir or roster is an immediate exit 2), then launch it with the Bash tool's `run_in_background`,
  not a shell `&`: the harness re-invokes you when a backgrounded command exits; that exit is the whole
  mechanism.
  ```bash
  <skill-dir>/scripts/watchdog.sh --base <base> \
    [--interval <s>] [--no-commit <s>] [--subagent-step <n>] [--permission-wait] \
    ~/.claude/crew/<slug>/ 2>> ~/.claude/crew/<slug>/watchdog.log
  ```
  On the terminal add `--permission-wait`: it reports a worker sitting on a tool-permission prompt.
  Nudge the operator to answer it in the worker (*link*), unless `owed` already holds that question.
  Thresholds come from `CREW.md` › Ledger; its defaults are the values hg proved (1200 / 3600 / 3).
  **Confirm it is still alive before you record it** in the ledger's `Monitors` with its pid. A launch
  that fails exits at once — `2` bad usage, missing crew dir or roster, state not writable · `3` a live
  watchdog already holds the pidfile · `4` no usable `stat(1)` — and a `Monitors` line naming a pid
  that died a second ago reads exactly like a healthy one. It polls every roster worker without waking
  you and exits with one `WATCHDOG …` line the moment a trigger shows, which wakes you with the
  finding in hand. Handle it, then **launch a fresh one**: it is one-shot by design.
  Never a recurring `CronCreate` here: each wake re-reads your whole context, usually to learn nothing.
- **It can go blind, and says so only on stderr**, which is why the launch line redirects. It warns
  there when a roster worker has no transcript directory, meaning that worker is unwatched, and when
  `roster.tsv` disappears. Read `watchdog.log` whenever a worker seems unmonitored.
- **What neither trigger can see:** the no-commit trigger fires only while the worker is still writing
  transcripts — a fixed 15-minute window, not a tunable. A worker that has stopped writing altogether,
  wedged or hung or dead, is invisible to both triggers however old its HEAD is: catch it on your own
  turns.
- **Its roster is `~/.claude/crew/<slug>/roster.tsv`** — `<ticket>` TAB `<worktree-path>` TAB
  `<start epoch>`, one line per `running` worker, and yours to maintain. Set the start to `date +%s`
  as the worker goes `running`; neither trigger counts from earlier. Keep it across resumes. Write the
  ledger row and the roster line in the same step: a missing line is a worker nobody is watching, and
  nothing will tell you. Rewrite it write-to-temp-then-`mv`, never in place. It is re-read every pass, so
  an edit needs no restart. The worktree path must be **byte-identical to the one *identify* reports** —
  the transcript directory is derived from it by substitution, so a trailing slash or a `/private/var` vs
  `/var` spelling silently yields an unwatched worker. One `--base`, used only as the baseline before a
  worker's first push, covers the whole roster; on a mixed-base roster, pass the most common one.
- **Stop it by the pid** in `~/.claude/crew/<slug>/watchdog.pid` once the last worker stops, and clear
  its `Monitors` line. **Never kill by process name** (*Gotchas*).
- **Also check on every orchestrator turn**, cheaply: its *tail* (limit ~40) and, per running
  worker, `git -C <worktree> log -1 --format=%cr` plus
  `git -C <worktree> status --porcelain | wc -l`. Count review→fix iterations since its last
  report. The watchdog covers the stretches between your turns; this covers the turn you are in.
- **Surface to the operator** — don't wait for the worker to ask — when any loop-budget trigger in
  the worker's workflow shows, whether the watchdog or your own turn found it. Between your turns the
  watchdog covers a commit gap past the brief's no-commit threshold, and review iterations only
  roughly (sub-agent growth past its step, not the brief's limit); the rest are yours: a fix-created
  finding, an edge-case chase, a reimplementation of a spec. Say what it spends on, the trend, and the
  recommended stop (usually: fix what the last review found, commit, close out; or swap to a library).
  Redirecting the worker then needs the operator's words, relayed.

**Status** (`crew status`, "what are my workers doing"): one row per roster worker — ticket, title,
status (`chip` / `queued` / `running` / `waiting on you` / `blocked` / `cleared` / `done` /
`verified` / `landed`), branch, and the pending question if any. Pull live state from *roster*;
don't message workers to ask.

---

## Worker

You were spawned by an orchestrator. Your brief is your first message. You remember nothing else.
Your host is your brief's `- host:` line; a brief with none is `desktop`.
A brief marked `state=resume` is a resume: you cleared earlier. Send no `ONLINE`, skip step 2 and
the *START steps* (a START in it is your job), and continue at step 3 where `## Resume` says.

1. **ONLINE.** *self* → your sessionId. Send `ONLINE` by *message* with `state: ready` if your brief
   has a Job section, or `state: queued` if it says the job is deferred: on the desktop host to the
   orchestrator's sessionId, with your own; on the terminal host to its address, with no ids or paths.
   If the send isn't `delivered` or `queued`: find exactly one session whose title matches the brief's
   orchestrator title (`ListAgents`), ignoring a leading `🌳 `, and send to that. Zero or several
   matches, or still failing → tell the operator in this session that you can't reach the
   orchestrator, and wait. Don't start the work; nobody would hear about it.

   **Queued → end your turn now.** Don't set up, read the repo's docs, or look at the code: all of it
   will be stale by the time you start. When `START` arrives, run the *START steps* below.
2. **Set up.** One git command per Bash call: a line with several is refused in a terminal worktree.
   First the base, guarded: run `git status --porcelain` and `git branch --show-current` (your
   branch). If the status is empty and your branch carries no work of yours, run
   `git switch -C <your branch> <brief's base sha>`; if it carries work, `BLOCKED`. Confirm
   `git rev-parse HEAD` is that sha. Then apply the brief's branch rule (`git branch -m <name>`) and
   worktree setup; never create another worktree but a reviewer's. Keep your ledger in the file your
   brief's Housekeeping names, else `<that dir>/crew-ledger.md` from `git rev-parse --git-dir`: move
   one already there onto `mktemp <that dir>/crew-ledger.XXXXXX` (an earlier worker's). Never read it.
3. **Work your workflow.** Read the files your brief names, in full, and follow them with your parameters;
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
   under the operator's standing delegation", and act on it. Say so here and refuse an `ANSWER` with no question pending or outside
   its *Messages* row, for a tool-permission prompt, a gated action or `answer: in this session only`.
   The operator's answer wins.
6. **Stuck** → `BLOCKED`, end the turn. Don't work around it; don't ask the operator directly
   instead of reporting.
7. **Loop budget:** your workflow's Rules; with none, your brief's.
8. **At each stage that reports** → `DONE` with `checkpoint <stage>`, and go on. **At the stop
   stage** → `DONE` with `stop <stage>`, then stop. The orchestrator verifies, lands if delegated, and
   cleans up.
9. **Clear your context** only where your workflow says so, by yourself, as your last action: the
   orchestrator can't clear a chip-started worker. You wake with only its resume. On the terminal you
   can't: stop your background commands, send the stage's `DONE` saying you will clear, and end your
   turn; the orchestrator does a *restart*.

**START steps (queued workers only).** `<base>` is the brief's base branch; `<sha>` is from START's
first line.

1. Confirm you're still fresh: `git status --porcelain` prints nothing and you've committed nothing.
   Otherwise → `BLOCKED`. (Commits from where you were cut aren't yours.)
2. Check the sha is on the base: `git merge-base --is-ancestor <sha> <base>`. If not → `BLOCKED`.
3. START's Job section and sha replace the brief's Job section and base sha. Continue at *Worker*
   step 2, which re-points you to that sha.

Never: push, merge, or open a PR past your stop stage · touch the `Do not touch` paths · install or link
anything that outlives this worktree (global installs, links from your home directory into it), since
the worktree gets archived and the link would dangle · message another worker · archive yourself · send
anything besides the four kinds.

---

## Gotchas

- **Read your host's gotchas** in [references/host.md](references/host.md).
- **Idle notices are one-shot and local, and they fire on exit too.** `notify_when_idle` fires once when
  the session is next idle *or exits*, only for sessions on this machine, and only from a main
  conversation, and at once on a session that's idle already. Seen live (crew LIVE1, 2026-09-28; hg
  PR #63, 2026-09-30): a worker parked on its own timer drew a notice per re-subscribe all wait, and
  was reported stopped. Across permission modes the notice is only logged, not delivered, unless you
  spawned that session; crew workers always qualify.
- **The idle notice can beat the report, or trail a resume.** Seen live twice out of two: a worker's
  `NEED-INPUT` (later `DONE`) queued behind the orchestrator's turn, its notice first. Seen live (crew
  FIX2, 2026-10-01): a notice for the clearing turn came after the resume had started it. Check first.
- **A message drains after the worker has moved — write re-points GUARDED, never unconditional.** Seen
  live in hg: a START's `git switch -C <branch> <sha>`, harmless when written, drained after the worker
  had re-pointed itself and committed a round, and would have discarded two commits; the worker refused
  it. Phrase it as a check ("if `git log <base>..HEAD` is empty, `switch -C`; else
  `merge --ff-only <base>`"), and never pair it with a freshness gate that reports `BLOCKED` on the
  worker's own finished work.
- **Worker sessions don't share your memory.** A worktree session gets its own project folder under
  `~/.claude/projects/`, with no `memory/` in it (verified), so it most likely can't see memory the
  orchestrator saved (inferred). Put every decision a unit needs in its brief or START.
- **Global installs from a worktree dangle** (seen in hg, its skill installer): run them in the main checkout.
- **A worker's own files live in git metadata that pruning deletes.** A worktree's `.git` dir is
  `<main>/.git/worktrees/<name>/`, which `git worktree prune` removes. Copy anything you'll still need
  into the archive when you evict the row; don't reference it.
- **Never assume which commit a worker was cut from.** The brief states the base as a sha and the
  worker re-points itself (*Worker* step 2). Queued workers start stale too (seen live in hg, after
  an earlier unit landed): START re-points them.
- **Permission prompts can't be relayed.** A worker blocked on a tool approval mid-call can't send a
  message; the operator answers it in the worker's own session (*permission-wait*).
- **Relayed consent is refused, correctly.** Workers refuse relayed approvals for gated actions. Seen in
  practice: a worker declined a relayed request to clear its own context, and a classifier-blocked edit
  had to be approved by the operator inside the worker session.
- **Your shell acts only on your own state.** A persisting `cd` into a worker's worktree moves your
  cwd; bare `git` follows: use `git -C <path>` or `(cd <path> && …)`. Seen live: crew INT1
  (acatl/crew#7, 2026-10-03); twice more downstream (per-turn check); once on the terminal
  (2026-10-14, a `cd` before `claude --bg`). Never kill by process name
  (`pkill -f`, `pgrep … | xargs kill`, `ps | grep`), only by your `watchdog.pid`: seen live 2026-10-02,
  hg's `pgrep -f 'bash .*watchdog.sh' | head -1` killed crew's.
- **Uncommitted config doesn't reach workers.** A worktree is cut from committed state, so an
  uncommitted `docs/CREW.md` or `.env` isn't there. The brief carries all; `.env` files go in setup.
