#!/usr/bin/env bash
# Every relative markdown link resolves — checked by Lychee itself, the tool CI runs.
#
# CI runs Lychee (`quality` workflow, `links` job, fail: true) over `**/*.md`. This is a thin
# wrapper with CI's exact args, so local and CI agree by construction: no second markdown parser to
# drift from Lychee's (hg tried a hand-rolled one, and it disagreed with Lychee both ways).
#
# The file list is git's view of the tree — tracked files plus untracked ones not ignored, so a new
# doc is checked before it is staged — not a glob: a glob from the repo root also walks
# .claude/worktrees/ and every node_modules/, which CI's checkout never has.
# `.lychee.toml` (offline, exclusions) is picked up from the repo root, as in CI.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if ! command -v lychee >/dev/null 2>&1; then
  echo "✖ lychee is not installed — install it (macOS: brew install lychee; else see https://github.com/lycheeverse/lychee#installation), then re-run this script" >&2
  exit 2
fi

# A tracked file deleted but not yet staged is still listed — skip it, or lychee fails on a missing
# input rather than on a link.
files=()
while IFS= read -r -d '' f; do
  [[ -e "$f" ]] && files+=("$f")
# `*.md` matches at EVERY depth: a git pathspec's `*` matches `/` too, so this is CI's `**/*.md` —
# and `**/*.md` here would DROP the repo-root files (no `/` to match).
done < <(git ls-files -z --cached --others --exclude-standard --deduplicate -- '*.md')
[[ ${#files[@]} -eq 0 ]] && { echo "no markdown files to check"; exit 0; }
lychee --offline --no-progress -- "${files[@]}"
