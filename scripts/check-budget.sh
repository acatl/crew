#!/usr/bin/env bash
# Word budget: SKILL.md and each references/*.md, per file, against baselines/budget.tsv. Every word
# is context a session loads, so a count may hold or fall, and a rise fails.
#
#   scripts/check-budget.sh                         check; exit 1 on a rise, an unbudgeted file, or a
#                                                   budgeted file that's gone
#   scripts/check-budget.sh --update                lower budgets to today's counts and drop a deleted
#                                                   file's budget; never raises
#   scripts/check-budget.sh --update --allow-raise  set budgets to today's counts, rises included
#
# --allow-raise is the operator's alone: a worker never raises a budget to get green.
#
# Words are whitespace-separated fields counted by awk in the C locale, not wc -w: BSD and GNU wc
# can disagree on non-ASCII text, and the baseline is written on macOS but checked on Linux in CI.
set -euo pipefail
cd "$(dirname "$0")/.."

BASELINE=baselines/budget.tsv
update=0 raise=0
for a in "$@"; do
  case "$a" in
    --update) update=1 ;;
    --allow-raise) raise=1 ;;
    *) echo "usage: scripts/check-budget.sh [--update [--allow-raise]]" >&2; exit 2 ;;
  esac
done
if [ "$raise" = 1 ] && [ "$update" = 0 ]; then
  echo "--allow-raise only goes with --update: scripts/check-budget.sh --update --allow-raise" >&2; exit 2
fi
if [ ! -f "$BASELINE" ] && [ "$raise" = 0 ]; then
  echo "✖ no $BASELINE — the operator creates it: scripts/check-budget.sh --update --allow-raise" >&2; exit 1
fi

words() { LC_ALL=C awk '{n += NF} END {print n + 0}' "$1"; }
budget_of() { if [ -f "$BASELINE" ]; then awk -F'\t' -v f="$1" '!/^#/ && $1 == f {print $2}' "$BASELINE"; fi; }

files=(skills/crew/SKILL.md)
while IFS= read -r f; do files+=("$f"); done < <(find skills/crew/references -name '*.md' -type f | LC_ALL=C sort)

fails=0 next=""
for f in "${files[@]}"; do
  have=$(words "$f"); budget=$(budget_of "$f")
  if [ -z "$budget" ]; then
    if [ "$raise" = 1 ]; then next+="$f"$'\t'"$have"$'\n'; echo "+ $f: $have words, budgeted"; continue; fi
    echo "✖ $f: $have words and no budget — a new file; the operator budgets it with scripts/check-budget.sh --update --allow-raise" >&2
    fails=$((fails + 1)); continue
  fi
  if [ "$have" -gt "$budget" ]; then
    if [ "$raise" = 1 ]; then next+="$f"$'\t'"$have"$'\n'; echo "↑ $f: $budget → $have words (+$((have - budget))), raised"; continue; fi
    echo "✖ $f: $have words, over its budget of $budget (+$((have - budget))) — cut words, don't raise the budget" >&2
    fails=$((fails + 1)); next+="$f"$'\t'"$budget"$'\n'; continue
  fi
  if [ "$have" -lt "$budget" ]; then
    if [ "$update" = 1 ]; then echo "↓ $f: $budget → $have words, lowered"
    else echo "↓ $f: $have words, $((budget - have)) under its budget of $budget — lock it in with scripts/check-budget.sh --update"; fi
  fi
  next+="$f"$'\t'"$(( have < budget ? have : budget ))"$'\n'
done

# budgets for files that no longer exist
if [ -f "$BASELINE" ]; then
  while IFS=$'\t' read -r f _; do
    case "$f" in ''|'#'*) continue ;; esac
    [ -f "$f" ] && continue
    # Not a pass: a budgeted file that can't be found is either deleted (say so with --update) or
    # moved out of the files this check counts, where nothing would budget it.
    if [ "$update" = 1 ]; then echo "- $f: gone, budget dropped"
    else echo "✖ $f: budgeted but gone — if it was deleted, drop its budget with scripts/check-budget.sh --update" >&2
         fails=$((fails + 1)); fi
  done < "$BASELINE"
fi

if [ "$update" = 1 ]; then
  {
    echo "# Word budgets for the skill's files, checked by scripts/check-budget.sh. A count may hold or"
    echo "# fall; a rise fails. --update lowers these; only the operator raises one (--allow-raise)."
    printf '%s' "$next"
  } > "$BASELINE.tmp"
  mv "$BASELINE.tmp" "$BASELINE"
fi

if [ "$fails" -gt 0 ]; then
  printf '✖ %d file(s) over budget, unbudgeted or gone (%s)\n' "$fails" "$BASELINE" >&2
  exit 1
fi
printf '✓ every skill file is within its word budget (%s)\n' "$BASELINE"
