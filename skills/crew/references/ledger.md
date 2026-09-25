# The ledger — orchestrator state that survives a clear or a compaction

The orchestrator's roster lives in its conversation, which a compaction or a `/clear` destroys.
Session metadata survives that, so **identity** is always recoverable (`list_sessions` +
`get_session` › `parentSessionId`). **Intent** is not: scope, stop points, what was promised, what is
owed, what has already been verified. The ledger holds only what no tool can reconstruct.

**Split of truth, the rule that keeps it from rotting:** the app is authoritative for state (running,
branch, PR, archived), the ledger is authoritative for intent. They join on `session`. Never copy into
the ledger what `list_sessions` can answer — it goes stale and then lies.

**Generic by construction:** the skill's rules read only the *spine* below. Everything else in a row is
free-form text the orchestrator writes as a situation demands, and the skill carries it without
interpreting it. Nothing here names a tool, a workflow stage, or a count. Those are project policy
(`CREW.md`) or a row's own fields.

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

It fails loudly rather than returning a partial path; a silent fallback would scatter ledgers.

```text
~/.claude/crew/<slug>/
  ledger.md            live state only — bounded by work in flight
  briefs/<row>.md      each brief exactly as sent, so a resume can re-attach it
  archive-YYYY-MM.md   evicted rows, append-only, never read in normal operation
  roster.tsv           the watchdog's input: <ticket> TAB <worktree>, one per running worker
  reported.txt         what the watchdog already reported — it outlives the one-shot process
  watchdog.pid         the running watchdog's pid; how you stop it
  watchdog.log         its stderr: where it says a worker is unwatched, or the roster vanished
```

Outside the repo on purpose: this is session state, which is machine-local, so it needs no
`.gitignore` change in every project and it survives a worktree being archived.

## Shape

```markdown
# crew ledger — <main checkout path>
updated: <iso> · orchestrator: <sessionId>

## Live

### r3 · #9 · running
- session: local_271f8174-… · brief: briefs/r3.md
- stop point: its PR merged
- owed: operator's merge go · review budget unspent
- surface: hg/src/cli.ts, docs/CREW.md
- verified: a762e48 green (2026-09-24) — tsc, 1274 tests, links, shellcheck
- counters: rounds 5 of 5 → at limit, operator decides · reviewer passes 2 of 2
- standing: bot posts on this PR come to me, not to the worker (operator, 09-24)
- worker ledger: <its git-dir>/crew-ledger.md

## Queue
1. #26 — waiting for a free slot (limit 2)
2. #31 — blocked by #24

## Monitors
- watchdog · pid 4766 · roster: #9, #26 · stop: `kill 4766`
- ci-poll · watches #9's checks · started 13:58

## Tombstones — current sequence only
- #24 · landed 07ce872 · archived
```

**Spine** (the only fields any rule reads): row id, unit, status, `session`, `brief`, `stop point`,
`owed`. Row ids are stable and never reused; the unit may change (a unit gets folded or renumbered),
which is why rows join on `session`, never on a unit or a title.

**Status** is one of: `chip` (spawned, not yet clicked — `session` holds the `task_id` instead),
`queued`, `running`, `waiting-on-operator`, `blocked`, `cleared`, `done`, `verified`, `landed`.

**Everything else is an open field.** `counters`, `standing`, `surface`, `verified` are conventions,
not schema. Invent a field when a situation needs one. Anything that must block eviction goes in
`owed` as a line — that is how open state reaches the rules without the rules knowing what it means.

**No event log in the live file.** Events append to the archive. The live file answers "where is
everything now", and rows shrink as they age: a pending question is verbatim while pending, then
collapses to the decision (`landing → delegated (operator, 09-24)`).

## Written at every transition

After the card's `go` (the row and its brief) · on `ONLINE` (session id, worktree) · on `NEED-INPUT`
(the question verbatim, into `owed`) · on the operator's answer (collapse to the decision) · on the
verify verdict (sha + result) · on landing · on cleanup · when a monitor starts or stops · when the
operator attaches a standing rule to a worker · when a worker reports it cleared its context.

Each write rewrites the file, so eviction happens as part of writing and there is no cleanup chore to
forget.

## Eviction

A row leaves `Live` when its stop point is reached **and `owed` is empty**. Not when the worker is
archived: a worker can be archived, or cleared and idle for hours, while its work is still owed.

On eviction: append the row to `archive-YYYY-MM.md`, **copying anything the orchestrator may still
need** rather than referencing it — a worker's own ledger lives under `.git/worktrees/<name>/`, which
`git worktree prune` deletes. Leave one tombstone line if the row belongs to the sequence in progress.
When a sequence completes, its tombstones collapse to a single line.

Budget: keep `Live` under about 100 lines (`CREW.md` › Ledger may set another). Over budget, evict
oldest-terminal-first, then oldest tombstones.

## Reading

**Step 0 of every orchestrator action**, not a separate command: if the roster isn't already in the
conversation, read `ledger.md` and reconcile it against `list_sessions` / `get_session`.

- A row says running, the session is archived → report the drift, don't silently patch it.
- A session whose `parentSessionId` is yours has no row → check the archive before calling it an
  orphan; an evicted row is not a lost worker.
- Anything else reads targeted: grep the unit, don't re-read the file.

`Live` comes first in the file so a partial read still gets what matters.

## The cleared-worker invariant

A worker that cleared its own context has no brief and will hedge or invent if anything wakes it — a
message, a monitor, a notification. This has happened repeatedly in practice.

- A worker that reports it cleared gets status `cleared` and `owed: resume not sent`.
- **Nothing may wake it except a resume carrying its brief** (`briefs/<row>.md`), sent at the moment
  it clears, even when the next step is only "wait".
- The row is never evicted while that resume is owed.

Note that the orchestrator generally **cannot** clear a worker for it: a chip-started worker counts as
started by the operator, so `clear_session` refuses it. The worker clears itself.
