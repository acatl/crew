# The ledger — orchestrator state that survives a clear or a compaction

The orchestrator's roster lives in its conversation, which a compaction or a `/clear` destroys.
Session state survives that, so **identity** is recoverable (*roster*). **Intent** is not: scope, stop points, what was promised, what is
owed, what has already been verified. The ledger holds only what no tool can reconstruct.

**Split of truth:** the host is authoritative for state (running,
branch, PR, stopped), the ledger is authoritative for intent. They join on `session`. Never copy into
the ledger what *roster* can answer — it goes stale and then lies.

**Generic by construction:** the skill's rules read only the *spine* below. Everything else in a row is
free-form text the orchestrator writes as a situation demands. Nothing here names a tool, a stage, or a count: those are the workflow's, the
project's (`CREW.md`), or a row's own fields.

## Where

```bash
# Resolve the ledger dir. Works from the main checkout and from any worktree — both land on the
# same directory, so a worker or a worktree-based orchestrator agrees with the main session.
crewdir() {
  local main
  main=$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || { echo "not a git repo: ${1:-.}" >&2; return 1; }
  main=${main%/.git}; main=${main%/}
  [ -n "$main" ] && [ -d "$main" ] || { echo "could not resolve main checkout" >&2; return 1; }
  printf '%s/.claude/crew/%s\n' "$HOME" "$(printf '%s' "$main" | sed 's#/#-#g')"
}
```

It fails loudly: a partial path would scatter ledgers.

```text
~/.claude/crew/<slug>/
  ledger.md            live state only, bounded by work in flight
  briefs/<row>.md      each brief (and `<row>-start.md`, its START) exactly as sent, for a resume
  briefs/<row>-spec.md a queued unit's spec, saved when it is queued: its START's Spec
  briefs/<row>-worker-ledger.md  the worker's own ledger, which its brief names
  archive-YYYY-MM.md   evicted rows, append-only, never read in normal operation
  roster.tsv           the watchdog's input: <ticket> TAB <worktree-path> TAB <start epoch>, one per running worker
  reported.txt, active.tsv  what the watchdog reported, and each worker's clock; both outlive its one-shot runs
  waiting.tsv          the permission waits the watchdog reported (--permission-wait)
  watchdog.pid         the running watchdog's pid; how you stop it
  watchdog.log         its stderr: which worker is unwatched, or that the roster vanished
```

Outside the repo on purpose: machine-local state needs no `.gitignore` change and survives a
worktree's archiving.

## Shape

```markdown
# crew ledger — <main checkout path>
updated: <iso> · orchestrator: <sessionId>

## Live

### r3 · #9 · running
- session: local_271f8174-… · brief: briefs/r3.md
- workflow: standard · integration: pr · mode: yolo · scope: whole · landing: operator · cleanup: keep
- do not touch: none · decisions: none · stage: round 3
- owed: operator's merge go · review budget unspent
- surface: hg/src/cli.ts, docs/CREW.md
- verified: a762e48 green (2026-09-24) — tsc, 1274 tests, links, shellcheck
- standing: bot posts on this PR come to me, not to the worker (operator, 09-24)

## Queue
1. #26 — waiting for a free slot (limit 2)
2. #31 — blocked by #24

## Monitors
- watchdog · pid 4766 · roster: #9, #26 · stop: `kill 4766`
- ci-poll · watches #9's checks · started 13:58

## Tombstones — current sequence only
- #24 · landed 07ce872 · archived
```

**Spine** (the only fields any rule reads): row id, unit, status, `session`, `brief`, `stage`, `owed`,
and the card's lines (`workflow` and its overrides, `integration`, mode, compact, scope, cleanup, landing,
`Do not touch`, any decision only in memory, not the spec): a queued unit's START reads them, and
takes its Spec from `briefs/<row>-spec.md`, never from memory. Row ids are stable and never reused;
the unit may change, so rows join on `session`, never on a unit or title.

**Status** is one of: `chip` (no `ONLINE` yet — `session` holds `pending <worktree name>`, then
*spawn*'s result),
`queued`, `running`, `waiting-on-operator`, `blocked`, `cleared`, `done`, `verified`, `landed`.

**Everything else is an open field.** `counters`, `standing`, `surface`, `verified` are conventions,
not schema. Invent a field when a situation needs one. Anything that must block eviction goes in
`owed` as a line — that is how open state reaches the rules without the rules knowing what it means.

**No event log in the live file.** Events append to the archive. The live file answers "where is
everything now", and rows shrink as they age: a pending question is verbatim while pending, then
collapses to the decision (`landing → delegated (operator, 09-24)`).

## Written at every transition

After the card's `go` (the row and its brief) · on a card override after it · on `ONLINE` (session id, worktree) · on `NEED-INPUT`
(the question verbatim, into `owed`) · on the operator's answer (collapse to the decision) · on the
verify verdict (sha + result) · on landing · on cleanup · when a monitor starts or stops · when the
operator attaches a standing rule to a worker · when a worker reports it cleared its context.

Each write rewrites the file, evicting as it goes.

## Eviction

A row leaves `Live` when its stop stage (its integration's, if any) is reached **and `owed` is
empty**. Not when the worker is archived: a worker can be archived, or cleared and idle for hours,
while its work is still owed.

On eviction: append the row to `archive-YYYY-MM.md`, **copying anything the orchestrator may still
need** rather than referencing it — an older brief's worker ledger, under `.git/worktrees/<name>/`,
dies with `git worktree prune`. Leave one tombstone line if the row belongs to the sequence in progress.
When a sequence completes, its tombstones collapse to a single line.

Budget: keep `Live` under about 100 lines (`CREW.md` › Ledger may set another). Over budget, evict
oldest-terminal-first, then oldest tombstones.

## Reading

**Step 0 of every orchestrator action**, not a separate command: if the roster isn't already in the
conversation, read `ledger.md` and reconcile it against *roster*.

- A row says running, the session is stopped → report the drift, don't silently patch it.
- A worker session of yours (*roster*) has no row → check the archive before calling it an orphan;
  an evicted row is not a lost worker. A `pending` row → find its worktree.
- Anything else reads targeted: grep the unit, don't re-read the file.

`Live` comes first, so a partial read gets what matters.

## The cleared-worker invariant

A worker that cleared its own context has no brief and will hedge or invent if anything wakes it — a
message, a monitor, a notification. Seen repeatedly.

- A worker that reports it cleared gets status `cleared` and `owed: resume not sent`.
- **Nothing may wake it except its resume** (SKILL.md step 6), sent at once, even when the next step
  is only "wait".
- The row is never evicted while that resume is owed.
- A resume never carries consent for a gated action or a plan approval, not even as an operator call:
  the worker's own ledger holds those, and a worker whose ledger lacks one re-asks in its own session.
  Restated in a resume, it is consent laundered across sessions (an auto-mode classifier blocked one,
  2026-10-02).

The orchestrator **never** clears a worker: the worker clears itself (desktop). A terminal worker never
clears (`clear: never`) and compacts in place; a *restart* only recovers a crashed or wedged one.
