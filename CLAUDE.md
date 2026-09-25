# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

The source of the `crew` Claude Code skill: one orchestrator session spawns, briefs, relays for,
verifies and cleans up fresh worker sessions, one per ticket or slice. There is no build and no package
manager. The deliverable is `skills/crew/`: Markdown instructions plus two bash scripts.

**This working tree is production.** `~/.claude/skills/crew` is a symlink to `skills/crew/`, so an
edit here is live in the next session that loads the skill, including worker sessions in other repos.
Keep this checkout on `main`. To try a risky change, use a worktree and repoint the link
(`ln -sfn <worktree>/skills/crew ~/.claude/skills/crew`), then point it back.

## Commands

```bash
skills/crew/watchdog.test.sh               # watchdog test suite; prints ok/FAIL per case, then "N passed, M failed"
shellcheck skills/crew/*.sh scripts/*.sh   # lint; currently clean
scripts/link-skills.sh                     # (re)create ~/.claude/skills/crew -> skills/crew; never clobbers
scripts/link-skills.sh check               # exit 0 only if linked
```

There is no single-test runner. `watchdog.test.sh` is one sequential script whose numbered cases share
fixture state, so always run the whole thing. On failure it keeps its sandbox and prints
`sandbox kept: <path>`. It sets `HOME` to a temp directory, so it never touches real crew state.
`overlap.sh` has no tests.

## Architecture

- **`SKILL.md` is the contract, and one file serves both roles.** A session reads *The contract* and
  then either *Orchestrator* (numbered steps 0–8) or *Worker*. A worker is identified by its first
  message starting with `<!-- crew:brief`.
- **Sessions talk only through `send_message` by sessionId,** using five message kinds: worker →
  orchestrator `ONLINE`/`NEED-INPUT`/`BLOCKED`/`DONE`, orchestrator → worker `RELAY`/`START`.
  Tool-permission prompts and gated consent are never relayed.
- **`references/` holds what the orchestrator fills or persists:**
  - `brief-template.md`: the worker's first message, in a ready and a queued variant, plus `START`.
  - `crew-md.md`: the first-use interview that writes each consuming project's `docs/CREW.md`, the
    per-project config. Only the orchestrator reads it and resolves it into briefs; workers never do.
  - `ledger.md`: orchestrator state in `~/.claude/crew/<slug>/`. The app is authoritative for session
    *state*, the ledger for *intent*, and the ledger never copies what `list_sessions` can answer.
- **`watchdog.sh` is a one-shot background poller.** A worker stuck in a review loop never goes idle,
  so no idle notice ever fires. The orchestrator launches the watchdog with `run_in_background`, and its
  exit is what wakes the orchestrator: it prints one `WATCHDOG …` line on the first trigger and exits 0.
  - Input: `roster.tsv`, re-read on every pass. Dedupe state that outlives the process:
    `reported.txt`. Lock: `watchdog.pid`, matched by the crew-dir path, never the script name.
  - Worker activity is read from Claude Code's transcript dirs, `~/.claude/projects/<slug>`.
- **`overlap.sh` is the parallel-safety check** (orchestrator step 3). It lists files in-flight workers
  have touched that fall under a candidate surface.

## Invariants that span files

Changing one side without the other breaks the skill silently:

- **The stable path `~/.claude/skills/crew/…`** is how SKILL.md and every project's ledger invoke the
  scripts. Don't rename `skills/crew/` or the scripts, and don't make the scripts depend on their own
  location.
- **The message contract is duplicated.** The *If the `crew` skill is unavailable* section of
  `brief-template.md` condenses SKILL.md's message rules. Change one, change the other.
- **Watchdog defaults are 1200 s interval, 3600 s no-commit, sub-agent step 3.** They are restated in
  four places:
  - the `watchdog.sh` defaults;
  - SKILL.md's *Watchdog* section;
  - SKILL.md *Worker* step 7 ("60 minutes");
  - the `crew-md.md` interview table.

  The brief's `{NO_COMMIT}` must match what the watchdog is launched with.
- **Watchdog exit codes** (0 finding · 1 internal · 2 usage/roster/state · 3 lock held · 4 no `stat`)
  are defined in the `watchdog.sh` header. SKILL.md's *Watchdog* section restates the launch-failure
  codes 2, 3 and 4. Keep them in sync.
- **Two different slug rules, on purpose:**
  - transcript dirs (`~/.claude/projects/`) replace `/` and `.` with `-`, which mirrors Claude Code's
    own naming; `watchdog.test.sh`'s `slug()` copies it;
  - crew dirs (`~/.claude/crew/`, `crewdir()` in `ledger.md`) replace only `/`.

  Don't unify them.
- **The `<!-- crew:brief` marker** is used for role detection, in the frontmatter `description`, and
  by the roster rebuild's grep. Keep it byte-exact.

## Conventions

- **SKILL.md Gotchas carry their evidence level**: "Seen live" with where and when, *inferred*, or
  *reported, not reproduced*. New entries follow that pattern.
- **`watchdog.sh` must stay portable across BSD and GNU `stat`,** probed at startup. Only the branch
  for this machine's `stat` can be tested, so the other ships code-reviewed.
- **Tests:** every `silent` assertion in `watchdog.test.sh` must be paired with a positive control on
  the same fixture, because a blind watchdog is also silent.
- **After editing `watchdog.sh`, restart any running watchdog**, because bash reads a running script
  from disk. Stop it by its pid (`kill "$(cat ~/.claude/crew/<slug>/watchdog.pid)"`), never
  `pkill -f watchdog.sh`, which kills every project's watchdog.
