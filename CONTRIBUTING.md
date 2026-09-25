# Contributing

Thanks for helping improve crew. The repo is mostly Markdown: the skill itself is instructions a
model reads, so contributing mostly means writing unambiguous prose. It also has two bash scripts with
a test suite.

## Ground rules

- **Conventional Commits** (`feat:` / `fix:` / `docs:` / `chore:` / `refactor:` / `test:` / `ci:`).
  End co-authored (for example AI-assisted) commits with a `Co-Authored-By:` trailer.
- **Work on a branch and land through a squashed PR to `main`.**
- **Read [CLAUDE.md](CLAUDE.md) before you edit the skill.** Its *Invariants that span files* section
  lists the values that are restated in more than one file. Change one copy and you must change the
  rest.

## Working on the skill

Link your clone so the skill you're editing is the one Claude Code loads:

```bash
scripts/link-skills.sh          # ~/.claude/skills/crew -> <clone>/skills/crew
scripts/link-skills.sh check    # exit 0 only if linked
```

The link is live: every new session, including worker sessions in other repos, loads what your
checkout has. Try risky changes on a worktree and repoint the link (see the [README](README.md)).

Authoring conventions:

- **A rule states what to do, not the story behind it.** When a rule exists because of something
  observed, the SKILL.md *Gotchas* entry says how sure it is: "Seen live" with where and when,
  *inferred*, or *reported, not reproduced*.
- **The frontmatter `description` is what the router reads.** Keep it natural-language and full of
  trigger phrases.
- **Scripts stay portable** across BSD (macOS) and GNU (Linux) userlands, and never kill processes by
  name.

## Local checks

```bash
skills/crew/watchdog.test.sh                 # sandboxed; touches nothing real (~70 s)
shellcheck skills/crew/*.sh scripts/*.sh
```

Every `silent` assertion in `watchdog.test.sh` needs a positive control on the same fixture: a blind
watchdog is silent too.

## Reporting bugs

Use the issue templates. For a behavior bug, include the role (orchestrator or worker), the `[crew]`
messages exchanged, and what the session did instead. Security issues go through
[SECURITY.md](SECURITY.md), not a public issue.
