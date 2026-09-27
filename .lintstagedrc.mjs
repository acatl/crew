// The pre-commit gate (.husky/pre-commit): each STAGED file through the checks that judge it in
// seconds. The full set runs before a push (scripts/verify.sh).
export default {
  '*.md': ['markdownlint-cli2 --no-globs', 'cspell --no-progress --no-summary --no-must-find-files'],
  '*.sh': ['shellcheck -x'],
};
