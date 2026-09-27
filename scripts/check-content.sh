#!/usr/bin/env bash
# Content metrics for the skill's instructions, against baselines/content.tsv:
#   instruction_specificity = strong markers / (strong + weak markers)
#   imperative_ratio        = imperative sentences / sentences
# A metric may hold or rise; a drop fails. --update raises the baseline to today's values and never
# lowers it. Accepting a drop is a hand edit of the baseline in the diff, and only the operator
# makes it.
#
# The counts come from skill-validator, totalled over SKILL.md plus every references/*.md, never per
# file: text moves between those files (splitting SKILL.md into references/ is planned), and a total
# is what that leaves unchanged. The per-file reports are summed rather than read from
# skill-validator's own references total, which isn't additive: it counted 21 sentences where its
# per-file reports count 91.
set -euo pipefail
cd "$(dirname "$0")/.."

BASELINE=baselines/content.tsv
update=0
case "${1:-}" in
  '') ;;
  --update) update=1 ;;
  *) echo "usage: scripts/check-content.sh [--update]" >&2; exit 2 ;;
esac
for tool in skill-validator jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "✖ $tool is not installed — see CONTRIBUTING.md › Local checks, then re-run this script" >&2; exit 2
  fi
done

json=$(skill-validator analyze content --per-file -o json skills/crew)
read -r strong weak imp sent < <(jq -r '
  [.content_analysis] + [.reference_reports[].content_analysis]
  | [(map(.strong_markers) | add), (map(.weak_markers) | add),
     (map(.imperative_count) | add), (map(.sentence_count) | add)]
  | map(tostring) | join(" ")' <<< "$json")
for v in "$strong" "$weak" "$imp" "$sent"; do
  case "$v" in ''|*[!0-9]*) echo "✖ skill-validator's JSON has no marker or sentence counts — its format changed? update scripts/check-content.sh" >&2; exit 1 ;; esac
done

ratio() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%.4f", (b > 0 ? a / b : 0)}'; }
spec=$(ratio "$strong" $((strong + weak)))
impr=$(ratio "$imp" "$sent")
base_of() { if [ -f "$BASELINE" ]; then awk -F'\t' -v k="$1" '!/^#/ && $1 == k {print $2}' "$BASELINE"; fi; }
below() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a + 0 < b + 0)}'; }

fails=0 out_spec=$spec out_impr=$impr
compare() {  # compare <metric> <today> <why it would fall>
  local base; base=$(base_of "$1")
  if [ -z "$base" ]; then
    if [ "$update" = 1 ]; then echo "+ $1: $2, recorded"; return; fi
    echo "✖ $1: no baseline in $BASELINE — the operator records it with scripts/check-content.sh --update" >&2
    fails=$((fails + 1)); return
  fi
  if below "$2" "$base"; then
    echo "✖ $1 fell: $base → $2 ($3). Fix the new text; accepting a drop is the operator's edit to $BASELINE" >&2
    fails=$((fails + 1))
    if [ "$1" = instruction_specificity ]; then out_spec=$base; else out_impr=$base; fi
  elif below "$base" "$2"; then
    if [ "$update" = 1 ]; then echo "↑ $1: $base → $2, raised"
    else echo "↑ $1: $2, above its baseline of $base — lock it in with scripts/check-content.sh --update"; fi
  fi
}
compare instruction_specificity "$spec" "$strong strong markers, $weak weak"
compare imperative_ratio "$impr" "$imp imperative sentences of $sent"

if [ "$update" = 1 ]; then
  {
    echo "# Content metrics for skills/crew (SKILL.md plus references/*.md, totalled), checked by"
    echo "# scripts/check-content.sh. A metric may hold or rise; a drop fails. --update only raises;"
    echo "# accepting a drop is a hand edit of this file, and only the operator makes it."
    printf 'instruction_specificity\t%s\n' "$out_spec"
    printf 'imperative_ratio\t%s\n' "$out_impr"
  } > "$BASELINE.tmp"
  mv "$BASELINE.tmp" "$BASELINE"
fi

if [ "$fails" -gt 0 ]; then exit 1; fi
printf '✓ content metrics hold: specificity %s (%d strong, %d weak), imperative ratio %s (%d of %d)\n' \
  "$spec" "$strong" "$weak" "$impr" "$imp" "$sent"
