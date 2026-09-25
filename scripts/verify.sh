#!/usr/bin/env bash
# Every CI check, in CI's order, stopping at the first failure: what the `quality` workflow
# (.github/workflows/quality.yml) runs, as one local command. The pre-push hook runs it
# (.husky/pre-push); run it yourself before asking for review. Add a check here and to CI, or to
# neither.
#
# It measures the WORKING TREE, which is what a push publishes only when the tree is clean. Run by
# hand, a dirty tree is named, never refused; the pre-push hook refuses one, and any pushed commit
# that is not HEAD, before calling it.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# A git hook runs with the repository's own GIT_DIR (and GIT_INDEX_FILE, …) in its environment. The
# test suites run git in throwaway repos, and each of those commands would act on THIS repository
# instead: in hg, run from pre-push, a suite committed into the pushing worktree and rewrote the
# .git/config every worktree shares. From here on, every git finds its repository from its working
# directory.
while read -r var; do unset "$var"; done < <(git rev-parse --local-env-vars)

if [[ -n "$(git status --porcelain)" ]]; then
  echo "verify: the working tree has uncommitted changes — these results are for the tree, not for HEAD" >&2
fi

step() {
  printf '\n▶ %s\n' "$*"
  "$@"
}

# job: docs
step npm run lint:md
step npm run spell
# job: links
step ./scripts/check-links.sh
# job: shellcheck
step npm run lint:sh
# job: skill
step ./scripts/check-structure.sh
step ./scripts/check-content.sh
step ./scripts/check-budget.sh
step ./scripts/check-invariants.sh
step ./scripts/check-section-refs.sh
step ./scripts/check-skill-frontmatter.sh
step ./test/checks.test.sh
# job: test
step ./test/watchdog.test.sh
step ./test/overlap.test.sh
printf '\nverify: every check passed\n'
