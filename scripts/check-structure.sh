#!/usr/bin/env bash
# The skill's structure, by skill-validator: the Agent Skills layout, frontmatter fields, token
# counts, code fences, internal references and orphaned files. --strict makes every warning fatal.
# --allow-extra-frontmatter admits argument-hint, a Claude Code field the spec doesn't list. Links
# are lychee's (scripts/check-links.sh), so this runs `validate structure`, not `check`.
#
# ONE warning is exempt, and every run prints it: SKILL.md's body is over the spec's recommended
# token count. Splitting SKILL.md into references/ is the next PR (PR 3), which deletes this
# exemption. Until then scripts/check-budget.sh keeps SKILL.md from growing.
#
# Then every workflow file (the built-in skills/crew/references/workflow-*.md, and this repo's
# docs/crew/workflows/*.md) has the shape an orchestrator relies on to follow a workflow it has never
# seen: frontmatter name (the file's name) and description; ## Parameters, ## Stages, ## Rules in
# that order; every ### stage names its Ends, Report and Orchestrator; each Report is
# `checkpoint <that stage>`, `stop <that stage>` or none; exactly one stop.
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

# workflow files: the built-in must exist, or this pass would check nothing and pass
workflows=()
while IFS= read -r f; do workflows+=("$f"); done < <(
  { find skills/crew/references -name 'workflow-*.md' -type f
    if [ -d docs/crew/workflows ]; then find docs/crew/workflows -name '*.md' -type f; fi
  } | LC_ALL=C sort)
builtin=0
for f in ${workflows[@]+"${workflows[@]}"}; do
  case $f in skills/crew/references/workflow-*) builtin=1 ;; esac
done
if [ "$builtin" = 0 ]; then
  bad+="${bad:+$'\n'}✖ skills/crew/references: no workflow-*.md — the built-in is gone, or this check's lookup broke"
fi
for f in ${workflows[@]+"${workflows[@]}"}; do
  [ -n "$f" ] || continue
  want=$(basename "$f" .md); want=${want#workflow-}
  out=$(LC_ALL=C awk -v f="$f" -v want="$want" '
    function err(m) { printf "✖ %s:%d: %s\n", f, FNR, m }
    NR == 1 { if ($0 != "---") err("no frontmatter"); else fm = 1; next }
    fm && $0 == "---" { fm = 0; next }
    fm && /^name:/ { n = $0; sub(/^name:[[:space:]]*/, "", n); name = n }
    fm && /^description:[[:space:]]*[^[:space:]]/ { desc = 1 }
    fm { next }
    /^(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^## / { stage_end(); sec = substr($0, 4); seen[sec] = ++order; next }
    /^### / && sec == "Stages" { stage_end(); st = substr($0, 5); stages++; ends = rep = orch = 0; next }
    st != "" && /^- \*\*Ends:\*\*/ { ends = 1 }
    st != "" && /^- \*\*Orchestrator:\*\*/ { orch = 1 }
    st != "" && /^- \*\*Report:\*\*/ {
      rep = 1; r = $0; sub(/^- \*\*Report:\*\*[[:space:]]*/, "", r)
      if (index(r, "`stop " st "`") == 1) stops++
      else if (index(r, "`checkpoint " st "`") != 1 && r !~ /^none([^A-Za-z]|$)/)
        err("stage " st ": Report must be `checkpoint " st "`, `stop " st "` or none, not \"" r "\"")
    }
    function stage_end() {
      if (st == "") return
      if (!ends) err("stage " st " names no Ends")
      if (!rep) err("stage " st " names no Report")
      if (!orch) err("stage " st " names no Orchestrator response")
      st = ""
    }
    END {
      stage_end(); FNR = 1
      if (name != want) err("frontmatter name is \"" name "\", the file makes it \"" want "\"")
      if (!desc) err("frontmatter has no description")
      if (!seen["Parameters"] || !seen["Stages"] || !seen["Rules"] || !(seen["Parameters"] < seen["Stages"] && seen["Stages"] < seen["Rules"]))
        err("needs ## Parameters, ## Stages, ## Rules, in that order")
      if (!stages) err("## Stages holds no ### stage")
      if (stops != 1) err(stops + 0 " stages report stop; a workflow has exactly one")
    }' "$f")
  if [ -n "$out" ]; then bad+="${bad:+$'\n'}$out"; fi
done

if [ -n "$bad" ]; then
  printf '%s\n' "$bad" >&2
  exit 1
fi
printf '✓ skill structure is clean (%s; %d workflow files)\n' \
  "$(jq -r '[.results[] | select(.level == "pass")] | length | tostring + " checks passed"' <<< "$json")" "${#workflows[@]}"
