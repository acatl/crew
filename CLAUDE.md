# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

The source of the `crew` Claude Code skill: one orchestrator session spawns, briefs, relays for,
verifies and cleans up fresh worker sessions, one per ticket or slice. A **workflow** file sets how
each worker works. There is no build. The
deliverable is `skills/crew/`: Markdown instructions plus two bash scripts. The Node toolchain at the
root only lints, spell-checks and runs the git hooks.

**This working tree is production.** `~/.claude/skills/crew` is a symlink to `skills/crew/`, so an
edit here is live in the next session that loads the skill, including worker sessions in other repos.
Keep this checkout on `main`. To try a risky change, use a worktree and repoint the link
(`ln -sfn <worktree>/skills/crew ~/.claude/skills/crew`), then point it back.

## Commands

```bash
npm ci                          # the toolchain and the git hooks (husky); needs Node >= 22.12
./scripts/verify.sh             # every CI check in CI's order, stopping at the first failure (~95 s)
npm run check                   # the fast checks: markdownlint, cspell, links, shellcheck, skill checks
npm test                        # both test suites: test/watchdog.test.sh (~75 s), test/overlap.test.sh
scripts/link-skills.sh          # (re)create ~/.claude/skills/crew -> skills/crew; never clobbers
scripts/link-skills.sh check    # exit 0 only if linked
```

`verify.sh` also needs `lychee`, `shellcheck`, `jq` and `skill-validator` v1.6.2 on the PATH.

There is no single-test runner. Each suite in `test/` is one sequential script whose numbered cases
share fixture state, so always run the whole thing. On failure it keeps its sandbox and prints
`sandbox kept: <path>`. `watchdog.test.sh` sets `HOME` to a temp directory, so it never touches real
crew state.

The hooks: `commit-msg` runs commitlint (Conventional Commits); `pre-commit` runs lint-staged
(markdownlint and cspell on staged `*.md`, shellcheck on staged `*.sh`); `pre-push` refuses a dirty
tree or a pushed ref that isn't the checked-out commit, then runs `verify.sh`.

## Architecture

- **`SKILL.md` is the contract, and one file serves both roles.** A session reads *The contract* and
  then either *Orchestrator* (numbered steps 0–8) or *Worker*. A worker is identified by its first
  message starting with `<!-- crew:brief`.
- **A workflow is how a worker works:** one self-contained file of Parameters, Stages and Rules. Each
  stage names its end, its report (`checkpoint <stage>` or `stop <stage>`) and the orchestrator's
  response, which is all the orchestrator needs to follow a workflow it has never seen. The contract
  sits under every workflow. The one built-in, `standard`, is `references/workflow-standard.md`; a
  project lists its own in `docs/CREW.md` › Workflows (this repo: `docs/crew/workflows/pr.md`).
- **Sessions talk only through `send_message` by sessionId,** using seven message kinds: worker →
  orchestrator `ONLINE`/`NEED-INPUT`/`BLOCKED`/`DONE`, orchestrator → worker `RELAY`/`START`/`ANSWER`.
  Tool-permission prompts and gated consent are never relayed, and never answered by an `ANSWER`.
- **`references/` holds what the orchestrator fills or persists:**
  - `brief-template.md`: the worker's first message, in a ready and a queued variant, plus `START`.
    It names the workflow file and its resolved parameters.
  - `workflow-standard.md`: the built-in workflow. Workers read it; it's flat in `references/`
    because skill-validator warns on any other directory, or a nested one.
  - `crew-md.md`: the first-use interview that writes each consuming project's `docs/CREW.md`, the
    per-project config. Only the orchestrator reads it and resolves it into briefs; workers never do.
  - `ledger.md`: orchestrator state in `~/.claude/crew/<slug>/`. The app is authoritative for session
    *state*, the ledger for *intent*, and the ledger never copies what `list_sessions` can answer.
- **`scripts/watchdog.sh` is a one-shot background poller.** A worker stuck in a review loop never
  goes idle, so no idle notice ever fires. The orchestrator launches the watchdog with
  `run_in_background`, and its exit is what wakes the orchestrator: it prints one `WATCHDOG …` line on
  the first trigger and exits 0.
  - Input: `roster.tsv` (`<ticket>` TAB `<worktree-path>` TAB `<start epoch>`, the start optional),
    re-read on every pass. State that outlives the process: `reported.txt` (dedupe) and
    `active.tsv` (each worker's clock, keyed by ticket and worktree, pruned to the roster). Lock:
    `watchdog.pid`, matched by the crew-dir path, never the script name.
  - Worker activity is read from the modification times in Claude Code's transcript dirs,
    `~/.claude/projects/<slug>`, never their contents. The no-commit clock starts at the latest of
    HEAD's commit, the worker's roster start, and the start of its current active stretch. The
    roster start covers a stretch an earlier worker on the same ticket and worktree left in
    `active.tsv`. A stretch starts when the watchdog first sees the worker active after an idle
    pass, or after a gap in sightings longer than `--interval` + 15 min. Before exiting on a finding
    it sights the whole roster, so a prompt relaunch keeps every clock.
- **`scripts/overlap.sh` is the parallel-safety check** (orchestrator step 3). It lists files
  in-flight workers have touched that fall under a candidate surface.
- **Outside the skill:** `test/` holds the suites, so they don't ship with the skill. `scripts/` holds
  the repo's checks, `baselines/` their committed baselines, and `scripts/lib/scan.sh` the matcher the
  checks share, which reads a file with its line breaks as spaces so a wrapped copy still matches.

## Invariants that span files

Changing one side without the other breaks the skill silently. `scripts/check-invariants.sh` and
`scripts/check-section-refs.sh` enforce most of these in CI; the entries say which.

- **The base-directory rule.** SKILL.md runs its scripts as `<skill-dir>/scripts/<name>.sh`, where
  `<skill-dir>` is the "Base directory for this skill" path Claude Code prints when it loads the
  skill. That is what lets the skill install per user or per project. Don't rename
  `skills/crew/scripts/` or the scripts, never hard-code an install path in the skill, and don't make
  the scripts depend on their own location. *Checked:* every `<skill-dir>/scripts/…` the skill names
  exists.
- **The message contract is duplicated.** The *If the `crew` skill is unavailable* section of
  `brief-template.md` condenses SKILL.md's message rules. Change one, change the other. *Checked:* the
  seven kinds in SKILL.md's *Messages* tables, the fallback section, the frontmatter description
  ("four reports", "RELAY, START and ANSWER") and the *Worker* rule ("the four kinds").
- **Watchdog defaults are 1200 s interval, 3600 s no-commit, sub-agent step 3.** They are restated in
  five places, all *checked*:
  - the `watchdog.sh` defaults, the source;
  - SKILL.md's *Watchdog* section;
  - `workflow-standard.md`'s `no-commit` default ("absent, 60 minutes");
  - the `crew-md.md` interview table;
  - the `crew-md.md` template's `watchdog:` line.

  A brief's resolved `no-commit` parameter must match what the watchdog is launched with.
- **Exit codes.** `watchdog.sh`'s header defines 0 finding · 1 internal · 2 usage/roster/state · 3 lock
  held · 4 no `stat`, and SKILL.md's *Watchdog* section restates the launch-failure codes 2, 3 and 4.
  `overlap.sh`'s header defines 0 clear · 1 overlap · 2 usage or git error, and SKILL.md step 3
  restates them. *Checked*, code by code.
- **Two different slug rules, on purpose:**
  - transcript dirs (`~/.claude/projects/`) replace `/` and `.` with `-`, which mirrors Claude Code's
    own naming; `test/watchdog.test.sh`'s `slug()` copies it;
  - crew dirs (`~/.claude/crew/`, `crewdir()` in `ledger.md`) replace only `/`.

  Don't unify them. *Checked.*
- **The roster format.** `watchdog.sh`'s header defines `roster.tsv`'s columns (`<ticket>`,
  `<worktree-path>`, `<start epoch>`), and SKILL.md's *Watchdog* section and `ledger.md`'s file
  listing restate them. *Checked*, column by column, and both copies must be found (counted by file, so
  a section that moves stays checked).
- **`ANSWER` never answers an `answer: in this session only` question** (SECURITY.md's consent
  laundering). SKILL.md's *Orchestrator* and *Worker* sections and the brief's fallback section each
  say so in one sentence holding the marker, `ANSWER` and a refusal. *Checked*, by section heading,
  code-fence aware.
- **A relayed answer is never consent for a tool-permission prompt or a gated action.** SKILL.md's
  contract (the input invariant) and *Worker* sections and the brief's fallback section each say so in
  one sentence holding "consent", "tool-permission", "gate" and a refusal. *Checked*, by section heading. Both
  this and the `ANSWER` entry pin that the sentence is present, not what it means.
- **The `<!-- crew:brief` marker** is used for role detection, in the frontmatter `description`, and
  by the roster rebuild's grep. Keep it byte-exact. *Checked* against the brief template's first line.
- **`CREW.md` › Section references** in the skill name `## ` headings of the template in
  `crew-md.md`. *Checked*, as is every `references/<name>.md` the skill mentions.
- **The workflow reaches a worker through its brief.** Workers never read `CREW.md`: the
  orchestrator resolves `CREW.md` › Workflows into the brief's `{WORKFLOW_PATH}` and `{PARAMETERS}`.
  *Checked*: no Worker section cites `CREW.md` (the orchestrator's may), the brief's Job line carries
  `{WORKFLOW_PATH}`, and its placeholder row sources it from Workflows.
- **Briefs from before workflows still work.** In-flight workers re-read the Worker section at every
  resume, and their briefs name no workflow. The Worker section keeps the line that makes such a
  brief its own workflow, and the orchestrator reads the older `DONE · checkpoint: <boundary>` and
  plain `DONE`. *Checked*: the line, verbatim; both older forms in the Orchestrator section; and DONE's `checkpoint <stage>` / `stop <stage>` forms in both
  copies of the contract (SKILL.md's *Messages* and the brief's fallback).
- **A merge go names its delegation.** Landing needs delegation; Integration mode `pr` is the one
  standing delegation, withheld by a card's `landing: operator`. *Checked*: every sentence in a
  workflow file or `docs/pr-round-workflow.md` that tells the worker to merge names `landing`.
- **The queue card shows each unit's Workflow and Landing** (under Integration mode `pr` landing is
  per unit). *Checked*: SKILL.md's queue-card table header.
- **A workflow's `verify` falls back as the orchestrator's does.** The source is SKILL.md's
  ``DONE `stop <stage>` `` bullet; every workflow's `verify` default names the same sources. *Checked*,
  and the built-in must carry the row.
- **Every workflow file has the orchestrator's shape** (frontmatter `name` = file name, and
  `description`; Parameters, Stages, Rules in order; each stage's Ends, Report, Orchestrator; exactly
  one `stop`). *Checked* by `check-structure.sh`, over the built-in and `docs/crew/workflows/`.

## Conventions

- **Baselines are the operator's.** `baselines/budget.tsv` holds each skill file's word budget: a
  count may hold or fall, never rise. `baselines/content.tsv` holds instruction specificity and the
  imperative ratio, totalled over SKILL.md and `references/`: they may hold or rise, never fall. Only
  the operator raises a budget (`scripts/check-budget.sh --update --allow-raise`) or accepts a lower
  content metric (a hand edit of the baseline). A worker fixes the new text instead. `--update` alone
  only ratchets: budgets down, metrics up.
- **One exemption, until PR 3:** `scripts/check-structure.sh` lets through skill-validator's warning
  that SKILL.md's body is over the recommended token count, and prints it on every run. Splitting
  SKILL.md into `references/` removes it.
- **SKILL.md Gotchas carry their evidence level**: "Seen live" with where and when, *inferred*, or
  *reported, not reproduced*. New entries follow that pattern.
- **`watchdog.sh` must stay portable across BSD and GNU `stat`,** probed at startup.
  CI's `test` job runs the suites on macOS and Linux, which is the only place both branches run.
- **Tests pair every silence with a positive control.** Every `silent` assertion in
  `watchdog.test.sh`, every exit-0 assertion in `overlap.test.sh`, and every check in
  `checks.test.sh` is paired with a case on the same fixture that must fire, because a blind watchdog
  or check is silent too.
- **After editing `watchdog.sh`, restart any running watchdog**, because bash reads a running script
  from disk. Stop it by its pid (`kill "$(cat ~/.claude/crew/<slug>/watchdog.pid)"`), never
  `pkill -f watchdog.sh`, which kills every project's watchdog.
- **Never `--no-verify`.** The hooks run what CI runs.
