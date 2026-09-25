#!/usr/bin/env bash
# The skill's structure, by skill-validator: the Agent Skills layout, frontmatter fields, token
# counts, code fences, internal references and orphaned files. --strict makes every warning fatal.
# --allow-extra-frontmatter admits argument-hint, a Claude Code field the spec doesn't list. Links
# are lychee's (scripts/check-links.sh), so this runs `validate structure`, not `check`.
#
# ONE warning is exempt, and every run prints it: SKILL.md's body is over the spec's recommended
# token count. Splitting SKILL.md into references/ is the next PR (PR 3), which deletes this
# exemption. Until then scripts/check-budget.sh keeps SKILL.md from growing.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=v1.6.2   # what CI installs (.github/workflows/quality.yml)
for tool in skill-validator jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "✖ $tool is not installed — see CONTRIBUTING.md › Local checks, then re-run this script" >&2; exit 2
  fi
done
have=$(skill-validator --version 2>/dev/null | awk '{print $NF}')
if [ "$have" != "$VERSION" ]; then
  echo "note: skill-validator $have here, CI runs $VERSION; results may differ" >&2
fi

# --strict exits 1 on any warning; the verdict comes from the JSON, which it prints either way
json=$(skill-validator validate structure --strict --allow-extra-frontmatter -o json skills/crew || true)
if ! jq -e '.results | type == "array"' >/dev/null 2>&1 <<< "$json"; then
  echo "✖ skill-validator produced no result list:" >&2; printf '%s\n' "$json" >&2; exit 1
fi

exempt='.level == "warning" and .category == "Tokens" and .file == "SKILL.md" and (.message | test("^SKILL\\.md body is [0-9,]+ tokens"))'
jq -r ".results[] | select($exempt) | \"known: \(.message) (PR 3 removes this exemption)\"" <<< "$json"
bad=$(jq -r ".results[] | select((.level == \"error\" or .level == \"warning\") and ($exempt | not))
             | \"✖ \(.file // \"skills/crew\"): \(.level): \(.message)\"" <<< "$json")
if [ -n "$bad" ]; then
  printf '%s\n' "$bad" >&2
  exit 1
fi
printf '✓ skill structure is clean (%s)\n' "$(jq -r '[.results[] | select(.level == "pass")] | length | tostring + " checks passed"' <<< "$json")"
