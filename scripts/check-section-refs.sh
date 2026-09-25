#!/usr/bin/env bash
# Every prose reference the skill makes resolves. lychee checks Markdown links; these are the
# references it can't see:
#   - `CREW.md` › <Section> names a `## <Section>` heading of the docs/CREW.md template in
#     references/crew-md.md. Only the first level is checked: "Ledger › watchdog" checks "Ledger".
#   - every references/<name>.md mentioned under skills/crew exists;
#   - every <skill-dir>/scripts/<name> the skill runs exists under skills/crew/scripts/.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/scan.sh
. scripts/lib/scan.sh

SKILL=skills/crew
TEMPLATE=$SKILL/references/crew-md.md
files=()
while IFS= read -r f; do files+=("$f"); done < <(find "$SKILL" -type f \( -name '*.md' -o -name '*.sh' \) | LC_ALL=C sort)

fails=0 refs=0
fail() { fails=$((fails + 1)); printf '✖ %s\n' "$*" >&2; }
# require_some <kind> <refs before its loop>: every kind exists in the skill today, so none at all
# means the pattern broke. A check that saw nothing must not pass.
require_some() {
  if [ "$refs" = "$2" ]; then
    fail "$SKILL: found no $1 — the pattern or the skill changed; update scripts/check-section-refs.sh"
  fi
}

headings=$(awk '/^## Template/ {f = 1; next} f && /^## / {sub(/^## /, ""); print}' "$TEMPLATE")
if [ -z "$headings" ]; then
  fail "$TEMPLATE: no '## ' headings after '## Template' — reworded? update scripts/check-section-refs.sh"
  exit 1
fi

before=$refs
# `CREW.md` › <Section>: the match stops at the first character a heading can't hold, so what's left
# must be a heading, alone or followed by a space and more words ("Integration allows it").
while IFS=$'\t' read -r loc hit; do
  [ -n "$loc" ] || continue
  refs=$((refs + 1))
  name=${hit#*› }
  found=0
  while IFS= read -r h; do
    if [ "$name" = "$h" ] || [ "${name#"$h" }" != "$name" ]; then found=1; break; fi
  done <<< "$headings"
  if [ "$found" = 0 ]; then
    fail "$loc: 'CREW.md › $name' names no section of the CREW.md template in $TEMPLATE ($(tr '\n' ',' <<< "$headings" | sed 's/,$//; s/,/, /g'))"
  fi
done < <(scan 'CREW\.md`?[[:space:]]+›[[:space:]]+[A-Za-z][A-Za-z -]*' "${files[@]}")
require_some "'CREW.md › Section' references" "$before"

# references/<name>.md, backticked or bare or linked
before=$refs
while IFS=$'\t' read -r loc hit; do
  [ -n "$loc" ] || continue
  refs=$((refs + 1))
  if [ ! -f "$SKILL/$hit" ]; then fail "$loc: $hit doesn't exist under $SKILL/"; fi
done < <(scan 'references/[A-Za-z0-9._-]+\.md' "${files[@]}")
require_some "references/<name>.md mentions" "$before"

# <skill-dir>/scripts/<name>
before=$refs
while IFS=$'\t' read -r loc hit; do
  [ -n "$loc" ] || continue
  refs=$((refs + 1))
  if [ ! -f "$SKILL/${hit#<skill-dir>/}" ]; then fail "$loc: $hit doesn't exist ($SKILL/${hit#<skill-dir>/})"; fi
done < <(scan '<skill-dir>/scripts/[A-Za-z0-9._-]+' "${files[@]}")
require_some "<skill-dir>/scripts/ calls" "$before"

if [ "$fails" -gt 0 ]; then
  printf '✖ %d problem(s) across %d references\n' "$fails" "$refs" >&2
  exit 1
fi
printf '✓ all %d section, reference and script references resolve\n' "$refs"
