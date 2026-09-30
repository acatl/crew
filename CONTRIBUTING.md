# Contributing

Thanks for helping improve crew. The repo is mostly Markdown: the skill itself is instructions a
model reads, so contributing mostly means writing unambiguous prose. It also has two bash scripts with
test suites, and checks that keep the prose consistent.

## Ground rules

- **Conventional Commits** (`feat:` / `fix:` / `docs:` / `chore:` / `refactor:` / `test:` / `ci:`),
  enforced by the `commit-msg` hook. End co-authored (for example AI-assisted) commits with a
  `Co-Authored-By:` trailer. Releases are cut by release-please from these subjects.
- **Work on a branch and land through a squashed PR to `main`.**
- **Read [CLAUDE.md](CLAUDE.md) before you edit the skill.** Its *Invariants that span files* section
  lists the values that are restated in more than one file. Change one copy and you must change the
  rest; `scripts/check-invariants.sh` catches most misses.

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

Install the toolchain once per clone; it also installs the git hooks:

```bash
npm ci                     # Node >= 22.12
```

`scripts/verify.sh` needs four more tools on the PATH: `lychee`, `shellcheck`, `jq`, and
`skill-validator`. CI pins shellcheck 0.11.0, lychee 0.24.2 and skill-validator 1.6.2
(`.github/workflows/quality.yml`), and `verify.sh` notes when yours differ. On macOS:

```bash
brew install lychee shellcheck jq agent-ecosystem/tap/skill-validator
```

Elsewhere, see each tool's releases; skill-validator publishes Linux binaries with checksums.

```bash
./scripts/verify.sh        # every CI check, in CI's order, stopping at the first failure (~95 s)
npm run check              # the fast ones: markdownlint, cspell, links, shellcheck, skill checks
npm test                   # the watchdog and overlap suites; sandboxed, they touch nothing real
```

The hooks run these for you, and are never skipped: no `--no-verify`.

- `commit-msg` checks the Conventional Commit subject.
- `pre-commit` lints and spell-checks the staged files.
- `pre-push` refuses a dirty tree, or a ref that isn't the checked-out commit, and then runs
  `verify.sh`.

A word cspell flags that is spelled right goes in `project-words.txt`.

**Pair every silence with a positive control.** Every `silent` assertion in `test/watchdog.test.sh`,
and every exit-0 assertion in `test/overlap.test.sh`, needs a case on the same fixture that must fire.
Every check in `scripts/` gets a seeded drift in `test/checks.test.sh`. A blind watchdog or check is
silent too.

### The skill checks and their baselines

`npm run skill` runs skill-validator's structure check (which also checks every workflow file's
shape), then three checks that compare the skill
against itself or against a committed baseline:

- the restated values agree (`check-invariants.sh`);
- the cross-references resolve (`check-section-refs.sh`);
- the word budget and the content metrics hold (`check-budget.sh`, `check-content.sh`).

**Baselines are the operator's.** A skill file's word count may hold or fall. Instruction specificity
and the imperative ratio may hold or rise. When yours moves the wrong way, fix the text. Raising a
budget (`--update --allow-raise`) or accepting a lower metric (an edit to `baselines/content.tsv`) is
the maintainer's call, made visibly in the PR. `--update` on its own only ratchets: budgets down,
metrics up.

## Reporting bugs

Use the issue templates. For a behavior bug, include the role (orchestrator or worker), the `[crew]`
messages exchanged, and what the session did instead. Security issues go through
[SECURITY.md](SECURITY.md), not a public issue.
