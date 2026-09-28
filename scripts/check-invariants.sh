#!/usr/bin/env bash
# The values the skill restates across files must agree (CLAUDE.md › Invariants that span files).
#
# Each value is read from its source of truth. Every copy is then found by pattern in any Markdown
# file under skills/crew, not in a named section, so a section that moves to another file is still
# checked. Copies are matched across line breaks.
#
# A pattern that matches nothing fails with its own message: the copy was reworded and this script
# needs updating. That is a different failure from a copy whose value drifted.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/scan.sh
. scripts/lib/scan.sh

SKILL=skills/crew
WATCHDOG=$SKILL/scripts/watchdog.sh
OVERLAP=$SKILL/scripts/overlap.sh
BRIEF=$SKILL/references/brief-template.md
LEDGER=$SKILL/references/ledger.md
WDTEST=test/watchdog.test.sh
mds=()
while IFS= read -r f; do mds+=("$f"); done < <(find "$SKILL" -name '*.md' -type f | LC_ALL=C sort)

fails=0 held=0
fail() { fails=$((fails + 1)); printf '✖ %s\n' "$*" >&2; }
reworded() { fail "$1: $2 not found — reworded? update scripts/check-invariants.sh"; }

# expect <what> <ERE> <expected> <source>: every copy of <what> under skills/crew reads <expected>,
# and there is at least one
expect() {
  local what=$1 re=$2 want=$3 src=$4 out loc got drift=0
  out=$(scan "$re" "${mds[@]}")
  if [ -z "$out" ]; then reworded "$SKILL/*.md" "$what"; return; fi
  while IFS=$'\t' read -r loc got; do
    if [ "$got" != "$want" ]; then
      fail "$loc: $what reads '$got', but $src makes it '$want'"; drift=1
    fi
  done <<< "$out"
  if [ "$drift" = 0 ]; then held=$((held + 1)); fi
}

# --- the watchdog defaults: watchdog.sh is the source ---------------------------------------------
defaults=$(grep -E '^base="" interval=[0-9]+ nocommit=[0-9]+ step=[0-9]+$' "$WATCHDOG" || true)
if [ -z "$defaults" ]; then
  reworded "$WATCHDOG" "the defaults line (base=\"\" interval=N nocommit=N step=N)"
else
  read -r iv nc st <<< "$(sed -E 's/.*interval=([0-9]+) nocommit=([0-9]+) step=([0-9]+)/\1 \2 \3/' <<< "$defaults")"
  expect "the watchdog defaults (interval / no-commit / step)" \
    "$(ws '[(][0-9]+ / [0-9]+ / [0-9]+[)]')" "($iv / $nc / $st)" "$WATCHDOG"
  if (( iv % 60 || nc % 60 )); then
    fail "$WATCHDOG: interval $iv s and no-commit $nc s must be whole minutes; the skill restates them in minutes"
  else
    expect "the no-commit default in minutes" \
      "$(ws 'absent, [0-9]+ minutes')" "absent, $((nc / 60)) minutes" "$WATCHDOG"
    expect "the interview's watchdog defaults" \
      "$(ws '[0-9]+ min · [0-9]+ min · step [0-9]+')" "$((iv / 60)) min · $((nc / 60)) min · step $st" "$WATCHDOG"
    expect "the template's watchdog line" \
      "$(ws 'check every [0-9]+ min · warn at [0-9]+ min with no commit · warn once sub-agents since the last push pass [0-9]+')" \
      "check every $((iv / 60)) min · warn at $((nc / 60)) min with no commit · warn once sub-agents since the last push pass $st" \
      "$WATCHDOG"
  fi
fi

# --- exit codes: each script's header is the source --------------------------------------------------
# The header and the skill word a code differently, so each code carries the words that must appear
# on both sides.
wd_exit=$(awk '/^# Exit:/ {f = 1} f && !/^#[[:space:]]+(Exit:[[:space:]]+)?[0-9>]/ {exit} f' "$WATCHDOG")
wd_code() {  # wd_code <code> <header words> <skill words>
  if ! grep -qE "^#[[:space:]]+(Exit:[[:space:]]+)?$1[[:space:]].*$2" <<< "$wd_exit"; then
    reworded "$WATCHDOG" "exit $1 ('$2') in the Exit header"; return
  fi
  if [ -z "$(scan "\`$1\`[[:space:]]+[^\`]*$(ws "$3")" "${mds[@]}")" ]; then
    fail "$SKILL/*.md: no launch-failure code \`$1\` reading '$3', which $WATCHDOG's Exit header defines"; return
  fi
  held=$((held + 1))
}
wd_code 2 'usage' 'usage'
wd_code 3 'already holds' 'already holds'
wd_code 4 'no usable' 'no usable'

ov_exit=$(grep -E '^# Exit:' "$OVERLAP" || true)
ov_code() {  # ov_code <code> <header words> <skill words>
  if ! grep -qE "(^|[^0-9])$1[[:space:]]+$2" <<< "$ov_exit"; then
    reworded "$OVERLAP" "exit $1 ('$2') in the Exit line"; return
  fi
  if [ -z "$(scan "(^|[^0-9])$1 = $(ws "$3")" "${mds[@]}")" ]; then
    fail "$SKILL/*.md: no '$1 = $3', but $OVERLAP exits $1 on '$2'"; return
  fi
  held=$((held + 1))
}
ov_code 0 'no overlap' 'clear'
ov_code 1 'overlap found' 'overlap'
ov_code 2 'usage or git error' 'usage or git error'

# SKILL.md's frontmatter and body, each on one line, for the checks that read them whole
flat() { tr '\n' ' ' | tr -s ' '; }
fm=$(awk 'NR == 1 && $0 == "---" {f = 1; next} f && $0 == "---" {exit} f' "$SKILL/SKILL.md" | flat)
body=$(awk 'NR == 1 && $0 == "---" {f = 1; next} f && $0 == "---" {f = 0; b = 1; next} b' "$SKILL/SKILL.md" | flat)

# --- the brief marker: the brief template's first line is the source ---------------------------------
marker=$(sed -n 's/^\(<!-- crew:[a-z]*\) .*/\1/p' "$BRIEF" | head -n 1)
if [ -z "$marker" ]; then
  reworded "$BRIEF" "the brief's '<!-- crew:…' first line"
else
  marker_ok=1
  if ! grep -qF -- "starts with \`$marker\`" <<< "$fm"; then
    fail "$SKILL/SKILL.md: the frontmatter description doesn't say a worker's first message starts with \`$marker\`, the marker $BRIEF opens the brief with"; marker_ok=0
  fi
  if ! grep -qF -- "starts with \`$marker\`" <<< "$body"; then
    fail "$SKILL/SKILL.md: the role detection doesn't say a worker's first message starts with \`$marker\`, the marker $BRIEF opens the brief with"; marker_ok=0
  fi
  # any other spelling of the marker's name, anywhere under skills/crew
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    loc=${hit%:crew:*}
    fail "$loc: '${hit#"$loc":}' is not the brief marker's name '${marker#<!-- }'"; marker_ok=0
  done < <(grep -rnoE 'crew:[a-z]+' "$SKILL" | grep -vE ":${marker#<!-- }\$" || true)
  if [ "$marker_ok" = 1 ]; then held=$((held + 1)); fi
fi

# --- the message kinds: SKILL.md's two Messages tables are the source ---------------------------------
kinds=$(LC_ALL=C awk '
  /^### Messages/ {f = 1; next}
  f && /^##/ {exit}
  f && /^Worker → orchestrator/ {d = "worker"}
  f && /^Orchestrator → worker/ {d = "orchestrator"}
  f && d != "" && /^\| `[A-Z][A-Z-]*` \|/ {k = $0; sub(/^\| `/, "", k); sub(/`.*/, "", k); print d, k}
' "$SKILL/SKILL.md")
wk=$(awk '$1 == "worker" {print $2}' <<< "$kinds" | LC_ALL=C sort)
ok=$(awk '$1 == "orchestrator" {print $2}' <<< "$kinds" | LC_ALL=C sort)
if [ -z "$wk" ] || [ -z "$ok" ]; then
  reworded "$SKILL/SKILL.md" "the worker → orchestrator and orchestrator → worker tables under '### Messages'"
else
  all=$(printf '%s\n%s\n' "$wk" "$ok" | LC_ALL=C sort)
  nwk=$(wc -l <<< "$wk" | tr -d ' ')
  word() { case $1 in 1) echo one;; 2) echo two;; 3) echo three;; 4) echo four;; 5) echo five;;
                      6) echo six;; 7) echo seven;; 8) echo eight;; 9) echo nine;; *) echo "$1";; esac; }
  oneline() { tr '\n' ' ' <<< "$1" | sed 's/ $//'; }
  kinds_ok=1

  # the brief template's fallback section names every kind, and nothing else
  fb_line=$(grep -n "^## If the \`crew\` skill is unavailable" "$BRIEF" | cut -d: -f1 || true)
  if [ -z "$fb_line" ]; then
    reworded "$BRIEF" "the '## If the \`crew\` skill is unavailable' section"; kinds_ok=0
  else
    fb=$(awk -v s="$fb_line" 'NR > s && /^````/ {exit} NR > s' "$BRIEF" \
         | grep -oE "\`[A-Z][A-Z-]+\`" | tr -d "\`" | LC_ALL=C sort -u)
    for k in $(LC_ALL=C comm -23 <(echo "$all") <(echo "$fb")); do
      fail "$BRIEF:$fb_line: the fallback section doesn't name \`$k\`, one of SKILL.md's message kinds"; kinds_ok=0
    done
    for k in $(LC_ALL=C comm -13 <(echo "$all") <(echo "$fb")); do
      fail "$BRIEF:$fb_line: the fallback section names \`$k\`, which SKILL.md's Messages tables don't define"; kinds_ok=0
    done
  fi

  # the frontmatter description: "the worker's four reports (…), the orchestrator's X, Y and Z"
  desc_w=$(sed -nE "s/.*the worker's ([a-z]+) reports \(([^)]*)\).*/\1|\2/p" <<< "$fm")
  desc_o=$(sed -nE "s/.*the orchestrator's (([A-Z-]+, )*[A-Z-]+) and ([A-Z-]+).*/\1 \3/p" <<< "$fm" | tr -d ',')
  if [ -z "$desc_w" ] || [ -z "$desc_o" ]; then
    reworded "$SKILL/SKILL.md" "the description's \"the worker's N reports (…), the orchestrator's X, Y and Z\""; kinds_ok=0
  else
    listed=$(tr -d ' ' <<< "${desc_w#*|}" | tr ',' '\n' | LC_ALL=C sort)
    if [ "${desc_w%%|*}" != "$(word "$nwk")" ] || [ "$listed" != "$wk" ]; then
      fail "$SKILL/SKILL.md: the description says the worker's ${desc_w%%|*} reports (${desc_w#*|}), but the table has $(word "$nwk"): $(oneline "$wk")"; kinds_ok=0
    fi
    if [ "$(tr ' ' '\n' <<< "$desc_o" | LC_ALL=C sort)" != "$ok" ]; then
      fail "$SKILL/SKILL.md: the description gives the orchestrator $desc_o, but the table has $(oneline "$ok")"; kinds_ok=0
    fi
  fi

  # the worker's closing rule: "send anything besides the four kinds"
  besides=$(scan "$(ws 'besides the [a-z]+ kinds')" "${mds[@]}")
  if [ -z "$besides" ]; then
    reworded "$SKILL/*.md" "the worker rule \"besides the N kinds\""; kinds_ok=0
  else
    while IFS=$'\t' read -r loc got; do
      if [ "$got" != "besides the $(word "$nwk") kinds" ]; then
        fail "$loc: '$got', but a worker sends $(word "$nwk") kinds: $(oneline "$wk")"; kinds_ok=0
      fi
    done <<< "$besides"
  fi
  if [ "$kinds_ok" = 1 ]; then held=$((held + 1)); fi
fi

# --- the loop limit reaches a worker through its brief ---------------------------------------------------
# Workers never read CREW.md. The orchestrator resolves CREW.md › Counters into the brief's
# {ITERATIONS}, and the Worker section reads the limit from the brief, so it never cites Counters
# itself. The orchestrator's sections read CREW.md, so the ban is scoped to Worker sections, found by
# heading in any skill file (PR 3 moves sections); one must exist, or the check would pass blind.
limit_ok=1
worker=$(LC_ALL=C awk 'FNR == 1 {w = 0}
  /^#+ / {n = index($0, " ") - 1; if (w && n <= lvl) w = 0
          if ($0 ~ /^#+ Worker[[:space:]]*$/) {w = 1; lvl = n; next}}
  w {printf "%s:%d\t%s\n", FILENAME, FNR, $0}' "${mds[@]}")
if [ -z "$worker" ]; then
  reworded "$SKILL/*.md" "a Worker section heading"; limit_ok=0
fi
while IFS=$'\t' read -r loc _; do
  [ -n "$loc" ] || continue
  fail "$loc: the Worker section cites CREW.md › Counters, but workers never read CREW.md; the limit reaches them as the brief's {ITERATIONS}"
  limit_ok=0
done < <(grep -E 'CREW\.md`?[[:space:]]+›[[:space:]]+Counters' <<< "$worker" || true)
if [ -z "$(scan "$(ws 'Loop budget [^:]*: at most [{]ITERATIONS[}] review→fix iterations')" "$BRIEF")" ]; then
  fail "$BRIEF: the brief's Loop budget line no longer says 'at most {ITERATIONS} review→fix iterations'"; limit_ok=0
fi
# shellcheck disable=SC2016  # backticks here are literal Markdown in the pattern
row_re='[|] `[{]ITERATIONS[}]` [|] `[^`|]*CREW\.md` › Counters'
if [ -z "$(scan "$(ws "$row_re")" "$BRIEF")" ]; then
  fail "$BRIEF: no placeholder row sourcing {ITERATIONS} from \`CREW.md\` › Counters"; limit_ok=0
fi
if [ "$limit_ok" = 1 ]; then held=$((held + 1)); fi

# --- the two slug rules, different on purpose ----------------------------------------------------------
# Transcript dirs mirror Claude Code's own naming (/ and . become -), and the test copies it. Crew
# dirs replace only /. They must not be unified.
sed_of() { grep -oE "sed '[^']*'" | head -n 1; }
t_slug=$(grep -E '^[[:space:]]*proj=' "$WATCHDOG" | sed_of || true)
test_slug=$(grep -E '^slug\(\)' "$WDTEST" | sed_of || true)
crew_slug=$(awk '/^crewdir\(\) \{/ {f = 1} f && /^\}/ {exit} f' "$LEDGER" | sed_of || true)
slug_ok=1
if [ "$t_slug" != "sed 's#[/.]#-#g'" ]; then
  fail "$WATCHDOG: the transcript-dir slug is '${t_slug:-not found}', but Claude Code names those dirs with sed 's#[/.]#-#g'"; slug_ok=0
fi
if [ "$test_slug" != "$t_slug" ]; then
  fail "$WDTEST: slug() uses '${test_slug:-not found}', but $WATCHDOG uses '$t_slug'"; slug_ok=0
fi
if [ "$crew_slug" != "sed 's#/#-#g'" ]; then
  fail "$LEDGER: crewdir() slugs with '${crew_slug:-not found}', but crew dirs replace only / (sed 's#/#-#g'); don't unify it with the transcript slug"; slug_ok=0
fi
if [ "$slug_ok" = 1 ]; then held=$((held + 1)); fi

# --- the roster format: watchdog.sh's header is the source ---------------------------------------------
# Its roster.tsv line names the columns ("<ticket> <TAB> <worktree-path> [<TAB> <start epoch>]"). A
# copy runs from `<ticket>` to the next comma and must name the same columns, in order. There are two
# copies, in two files (SKILL.md's Watchdog section and ledger.md's file listing today), counted by
# file rather than named, so a section that moves is still checked. A copy reworded out of the pattern
# drops the count, so it can't pass on the strength of the other.
ROSTER_COPIES=2
cols() { grep -oE '<[a-z][a-z -]*>' | tr '\n' ' ' | sed 's/ $//'; }
want=$(grep -E '^#[[:space:]]+roster\.tsv[[:space:]]+input:' "$WATCHDOG" | sed 's/,.*//' | cols || true)
if [ -z "$want" ]; then
  reworded "$WATCHDOG" "the header's 'roster.tsv    input:  <ticket> …' line"
else
  roster_ok=1
  out=$(scan '<ticket>[^,]*,' "${mds[@]}")
  nfiles=$(sed -n 's/:[0-9]*\t.*//p' <<< "$out" | LC_ALL=C sort -u | grep -c . || true)
  if [ "$nfiles" -lt "$ROSTER_COPIES" ]; then
    reworded "$SKILL/*.md" "a roster format copy ('<ticket>' … up to a comma) in $ROSTER_COPIES files, found in $nfiles:$(sed -n 's/:[0-9]*\t.*//p' <<< "$out" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//;s/^./ &/')"
    roster_ok=0
  fi
  while IFS=$'\t' read -r loc got; do
    [ -n "$loc" ] || continue
    if [ "$(cols <<< "$got")" != "$want" ]; then
      fail "$loc: the roster columns read '$(cols <<< "$got")', but $WATCHDOG's header makes them '$want'"; roster_ok=0
    fi
  done <<< "$out"
  if [ "$roster_ok" = 1 ]; then held=$((held + 1)); fi
fi

if [ "$fails" -gt 0 ]; then
  printf '✖ %d restated value(s) drifted; CLAUDE.md › Invariants that span files lists every copy\n' "$fails" >&2
  exit 1
fi
printf '✓ every restated value agrees (%d invariants)\n' "$held"
