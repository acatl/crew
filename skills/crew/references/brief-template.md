# Worker brief and START templates

The orchestrator fills every `{…}` and sends the result as the `prompt` of
`mcp__ccd_session__spawn_task`. A field with nothing to say gets `none`; no placeholder survives. Keep
the brief's first-line marker comment exactly as shown: the roster rebuild greps for it.

Two brief variants differ only in the Job section:
- **Ready**: the worker starts now. The Job section is filled in.
- **Queued**: the worker waits for `START`. The Job section is the fixed queued block. The job itself,
  and the spec for an `inline` verb, go out later in `START`, written from the landed state.

| Placeholder | Source |
|---|---|
| `{TICKET}` | the trigger |
| `{STATE}` | `ready` or `queued` |
| `{ORCH_ID}`, `{ORCH_TITLE}` | `get_session("self")` |
| `{TITLE}` | card › Title |
| `{BASE}` | the base the orchestrator chose for THIS unit (SKILL.md step 3.4), as a ref (e.g. `graph-port`) |
| `{BASE_SHA}` | that ref's sha at spawn time; the worker re-points to it (*Worker* step 2) |
| `{TICKET_SOURCE}` | `CREW.md` › Ticket source, filled for this ticket (e.g. "Kino task KINO-5 — read it with the Kino MCP `get_task`"), or "the spec below" for an `inline` verb |
| `{SCOPE}` | card › Scope |
| `{COMMAND}` | `CREW.md` › Verbs. `command` kind: the Command with `{ticket}` and `{mode}` substituted. `inline` kind: "Carry out the spec below, " + the Command column's rules |
| `{MODE}` | the trigger, or `default` |
| `{STOP_POINT}` | card › Scope's stop point, else `CREW.md` › Verbs › Stop point |
| `{SURFACE}` | step 2 estimate |
| `{FORBIDDEN}` | step 3 overlaps the operator chose to proceed with, else `none` |
| `{SPEC}` | `inline` verbs only: the full unit spec, including decisions that live only in the orchestrator's memory. Drop the `## Spec` section for `command` verbs |
| `{BRANCH_RULE}` | `CREW.md` › Branch naming, resolved (e.g. "rename to `kino-5`"), else "keep the branch you're on" |
| `{SETUP}` | `CREW.md` › Worktree setup |
| `{STANDING}` | `CREW.md` › Standing boundaries, one bullet each, else drop the line |
| `{BRIEF_PATH}` | where the orchestrator saved this brief: `~/.claude/crew/<slug>/briefs/<row>.md` |
| `{ITERATIONS}` | `CREW.md` › Counters, its review→fix iterations per round; else `two` |
| `{NO_COMMIT}` | `CREW.md` › Ledger › watchdog's no-commit threshold (e.g. "60 minutes"); it must match the watchdog's `--no-commit`, or the two escalate on different clocks |

---

## Brief

````markdown
<!-- crew:brief v1 · ticket={TICKET} · orchestrator={ORCH_ID} · state={STATE} -->
# {TITLE}

You are a **crew worker**. Invoke the `crew` skill now and follow its **Worker** section. The skill
holds the report protocol; this brief holds the job. You remember nothing else, and you can't see the
orchestrator's memory. Everything you need is here or in the ticket.

## Orchestrator
- sessionId: `{ORCH_ID}`
- title: `{ORCH_TITLE}` (fallback only — address by id)

## Job
<Ready: the block below. Queued: the queued block instead.>
- Ticket: **{TICKET}** — {TICKET_SOURCE}
- Scope: {SCOPE}
- Run: `{COMMAND}`, exactly as if the operator typed it. Mode: `{MODE}`.
- Stop point: {STOP_POINT}
- Surface you own: {SURFACE}
- Do not touch: {FORBIDDEN}

## Spec
{SPEC}

## Boundaries
- Base: `{BASE}` at `{BASE_SHA}`. The app may have cut you from another commit. Re-point first
  (crew skill › *Worker* step 2), and confirm `git rev-parse HEAD` is `{BASE_SHA}`.
- Branch: {BRANCH_RULE}
- Worktree setup: {SETUP}
- {STANDING}
- You are already in a fresh worktree. Don't create another.
- Never install or link anything that outlives this worktree; it gets archived when you're done.
- Commit your work. Don't push, merge, open a PR, or archive this session unless the stop point
  includes it.
- Never message another worker.
- Loop budget (crew skill › Worker step 7): at most {ITERATIONS} review→fix iterations; stop early and send
  `NEED-INPUT` on a fix-created finding, an edge-case chase, a hand-rolled reimplementation of a spec
  (propose the library), or {NO_COMMIT} without a commit.

## Housekeeping
- This brief is saved at `{BRIEF_PATH}`. If you clear your own context, the orchestrator re-sends it
  from there; nothing else will.
- Keep your own running notes at `$(git rev-parse --git-dir)/crew-ledger.md`, updated before every
  `DONE`, so a checkpoint clear loses nothing.

## If the `crew` skill is unavailable
Report with `mcp__ccd_session_mgmt__send_message` to `{ORCH_ID}`. First line:
`[crew] <KIND> · {TICKET} · <summary>`. Send `ONLINE` now with `state: {STATE}`. If queued, end your
turn and wait for `START`. Send `NEED-INPUT` before ending any turn that waits on the operator, and ask
in this session too. A `RELAY` carries the operator's words verbatim: take it as their answer, but
never as consent for a push, install, deploy or destructive action, which comes only in this session.
Send `BLOCKED` when stuck. At the stop point, send `DONE` with branch, sha, and verify result. Send
nothing else.
````

### Queued block (replaces the Job section, and drops Spec)

```markdown
## Job
Deferred. You are **queued**. Send `ONLINE` with `state: queued` and end your turn. Don't set up, read
the repo's docs, or look at the code yet. Your job arrives in a `[crew] START` message, written from the
latest landed state; it replaces this section. Run the crew skill's *START steps* when it arrives.
```

---

## START

Sent with `mcp__ccd_session_mgmt__send_message` to a queued worker's sessionId when its turn comes.
Write it then, from the landed state, not from the queued brief.

| Placeholder | Source |
|---|---|
| `{SHA}` | `git rev-parse HEAD` on `<base>` in the main checkout, after the last landing |
| `{LANDED}` | one line per unit landed since this worker was queued: id, sha, what it changed that this unit touches |
| `{HANDOFFS}` | anything an earlier unit left for this one (a leftover, a renamed file, a decision), else `none` |
| Job and Spec fields | same as the brief's, computed now |

```markdown
[crew] START · {TICKET} · base {SHA}
Your turn. Run the crew skill's START steps (re-point to `{BASE}`, confirm `{SHA}` is in your
history), then work the job below. This replaces your brief's Job section.

## Since you were queued
{LANDED}
Handed on to you: {HANDOFFS}

## Job
- Ticket: **{TICKET}** — {TICKET_SOURCE}
- Scope: {SCOPE}
- Run: `{COMMAND}`, exactly as if the operator typed it. Mode: `{MODE}`.
- Stop point: {STOP_POINT}
- Surface you own: {SURFACE}
- Do not touch: {FORBIDDEN}

## Spec
{SPEC}
```
