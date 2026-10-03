# Worker brief and START templates

The orchestrator fills every `{…}` and sends the result as the `prompt` of
`mcp__ccd_session__spawn_task`. A field with nothing to say gets `none`; no placeholder survives. Keep
the first-line marker byte-exact: the roster rebuild greps for it.

Two variants differ only in the Job section:
- **Ready**: the worker starts now, Job section filled in.
- **Queued**: the Job section is the fixed queued block; `START` carries the job and its spec.

| Placeholder | Source |
|---|---|
| `{TICKET}` | the trigger |
| `{STATE}` | `ready`, `queued`, or `resume` when re-sent after a clear (SKILL.md step 6) |
| `{ORCH_ID}`, `{ORCH_TITLE}` | `get_session("self")` |
| `{TITLE}` | card › Title |
| `{BASE}` | THIS unit's base (SKILL.md step 3.4), as a branch (e.g. `graph-port`, not `origin/main`) |
| `{BASE_SHA}` | its tip at spawn time, or an audit's sha; the worker re-points to it |
| `{TICKET_SOURCE}` | `CREW.md` › Ticket source, filled (e.g. "Kino task KINO-5, via the Kino MCP `get_task`"), or "the spec below" |
| `{SCOPE}` | card › Scope |
| `{WORKFLOW}` | card › Workflow |
| `{WORKFLOW_PATH}` | its file, absolute: its `CREW.md` › Workflows row, or the built-in `<skill-dir>/references/workflow-<name>.md` |
| `{PARAMETERS}` | the workflow's Parameters, each resolved (`name: value`, one line), with the card's overrides. `no-commit` is never overridden: it must equal the watchdog's `--no-commit`, which serves every worker |
| `{INTEGRATION_PATH}` | its file, absolute: `CREW.md` › Integration's `file:` under `mode: pr`, `built-in` being `<skill-dir>/references/integration-pr.md`. No `file:`, another mode, or the card's `integration: none` → the whole line reads `- Integration: none` |
| `{INTEGRATION_PARAMETERS}` | the integration's Parameters, resolved as `{PARAMETERS}` are |
| `{LANDING}` | card › Landing: `delegated` when it shows `delegated (merge rule)`, else `operator` |
| `{MODE}` | the trigger, or `default` |
| `{SURFACE}` | step 2 estimate |
| `{FORBIDDEN}` | step 3 overlaps the operator chose to proceed with, else `none` |
| `{SPEC}` | the full unit spec when the brief carries it, including decisions only in the orchestrator's memory; else drop `## Spec` |
| `{BRANCH_RULE}` | `CREW.md` › Branch naming, resolved, else "keep the branch you're on" |
| `{SETUP}` | `CREW.md` › Worktree setup |
| `{STANDING}` | `CREW.md` › Standing boundaries, one bullet each, else drop the line |
| `{BRIEF_PATH}` | this brief's saved path: `~/.claude/crew/<slug>/briefs/<row>.md` |

---

## Brief

````markdown
<!-- crew:brief v1 · ticket={TICKET} · orchestrator={ORCH_ID} · state={STATE} -->
# {TITLE}

You are a **crew worker**. Invoke the `crew` skill now and follow its **Worker** section. The skill
holds the report protocol; this brief holds the job. You remember nothing else, and you can't see the
orchestrator's memory. Everything you need is here, in the ticket, or in the files your Job names.

## Orchestrator
- sessionId: `{ORCH_ID}`
- title: `{ORCH_TITLE}` (fallback only — address by id)

## Job
<Ready: the block below. Queued: the queued block instead.>
- Ticket: **{TICKET}** — {TICKET_SOURCE}
- Scope: {SCOPE}
- Workflow: `{WORKFLOW}`. Read `{WORKFLOW_PATH}` in full and follow it. Mode: `{MODE}`.
- Parameters: {PARAMETERS}
- Integration: `{INTEGRATION_PATH}`. Read it in full; your workflow's handoff continues into its
  stages. Parameters: {INTEGRATION_PARAMETERS}
- Landing: `{LANDING}`
- Surface you own: {SURFACE}
- Do not touch: {FORBIDDEN}

## Spec
{SPEC}

## Boundaries
- Base: `{BASE}` at `{BASE_SHA}`. Unless `state=resume`, re-point first (crew skill › *Worker* step 2)
  and confirm `git rev-parse HEAD` is `{BASE_SHA}`: the app may have cut you elsewhere.
- Branch: {BRANCH_RULE}
- Worktree setup: {SETUP}
- {STANDING}
- You are already in a fresh worktree. Don't create another.
- Never install or link anything that outlives this worktree.
- Commit your work. Don't push, merge, open a PR, or archive this session unless your workflow's
  or integration's stages include it.
- Never message another worker.

## Housekeeping
- This brief is saved at `{BRIEF_PATH}`. If you clear your own context, the orchestrator re-sends it
  from there; nothing else will.
- Keep your own running notes at `$(git rev-parse --git-dir)/crew-ledger.md`, updated before every
  `DONE`.

## If the `crew` skill is unavailable
Report with `mcp__ccd_session_mgmt__send_message` to `{ORCH_ID}`. First line:
`[crew] <KIND> · {TICKET} · <summary>`. Send `ONLINE` with `state: {STATE}` (`ready` or `queued`), unless marked `state=resume`:
follow `## Resume`. If queued, end your turn until `START`. Send `NEED-INPUT`
before ending any turn that waits on the operator, and ask
in this session too. A `RELAY` carries the operator's words verbatim: take it as their answer. An
`ANSWER` is the orchestrator's, under the operator's standing delegation: act on it, recorded as
the orchestrator's, only for a routing or stage pick that follows from recorded decisions or an
effect inside this brief's grant. Say so here and refuse an `ANSWER` with no question pending, or
one for a hard floor, consent card, gated action, real tradeoff,
locked decision or `answer: in this session only`. The operator's answer wins. Neither is consent for a tool-permission prompt or a gated action (push, install,
deploy, destructive): that comes only in this session.
Send `BLOCKED` when stuck. At each stage your workflow or integration reports, send `DONE` whose first line says
`checkpoint <stage>` or `stop <stage>`, with branch, sha, and verify result. Send nothing else.
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

Sent to a queued worker's sessionId when its turn comes, written then from the landed state and the
unit's ledger row.

| Placeholder | Source |
|---|---|
| `{SHA}` | `git rev-parse HEAD` on `<base>` in the main checkout, after the last landing |
| `{LANDED}` | one line per unit landed since queuing: id, sha, what it changed that this unit touches |
| `{HANDOFFS}` | anything an earlier unit left for this one (a leftover, a decision), else `none` |
| `{CARRIED}` | one "Carried from <unit>" line per finding an earlier unit carried, else `none` |
| Job and Spec fields | same as the brief's, computed now, the card's lines from the ledger row |

```markdown
[crew] START · {TICKET} · base {SHA}
Run the START steps: confirm `{SHA}` is on `{BASE}`; if you haven't committed,
re-point to `{SHA}` (your new base sha); then work the job below. This replaces your brief's Job section.

## Since you were queued
{LANDED}
Handed on to you: {HANDOFFS}
{CARRIED}

## Job
- Ticket: **{TICKET}** — {TICKET_SOURCE}
- Scope: {SCOPE}
- Workflow: `{WORKFLOW}`. Read `{WORKFLOW_PATH}` in full and follow it. Mode: `{MODE}`.
- Parameters: {PARAMETERS}
- Integration: `{INTEGRATION_PATH}`. Read it in full; your workflow's handoff continues into its
  stages. Parameters: {INTEGRATION_PARAMETERS}
- Landing: `{LANDING}`
- Surface you own: {SURFACE}
- Do not touch: {FORBIDDEN}

## Spec
{SPEC}
```
