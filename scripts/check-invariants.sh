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
IPR=$SKILL/references/integration-pr.md
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
  out=$(scan '<ticket>[^,]*,' "${mds[@]}")   # a failing scan aborts here (set -e), never reads as "reworded"
  files=""   # one file per line, so a path with a space is still one file
  while IFS=$'\t' read -r loc got; do
    [ -n "$loc" ] || continue
    files+="${loc%:*}"$'\n'
    if [ "$(cols <<< "$got")" != "$want" ]; then
      fail "$loc: the roster columns read '$(cols <<< "$got")', but $WATCHDOG's header makes them '$want'"; roster_ok=0
    fi
  done <<< "$out"
  files=$(LC_ALL=C sort -u <<< "$files" | grep . || true)
  nfiles=$(grep -c . <<< "$files" || true)
  if [ "$nfiles" -lt "$ROSTER_COPIES" ]; then
    reworded "$SKILL/*.md" "a roster format copy ('<ticket>' … up to a comma) in $ROSTER_COPIES files, found in $nfiles:$(tr '\n' ' ' <<< "$files" | sed 's/ $//;s/^./ &/')"
    roster_ok=0
  fi
  if [ "$roster_ok" = 1 ]; then held=$((held + 1)); fi
fi

# --- ANSWER never answers an `answer: in this session only` question ---------------------------------
# That boundary is SECURITY.md's consent-laundering scope, and it fell out of the orchestrator's side
# twice under word-budget tightening. Three places must state it, each found by heading, not file: the
# Orchestrator section, the Worker section, and the brief's fallback section. "State it" means one
# sentence holding the marker, an ANSWER and a refusal (never, neither, no, not, refuse): nearness alone passed with
# the guard sentence deleted, and a sentence without the refusal could invert the rule.
# shellcheck disable=SC2016  # the backticks are literal Markdown
marker='`answer: in this session only`'
refusal='(^|[^A-Za-z])([Nn]ever|[Nn]either|[Nn]o|[Nn]ot|[Rr]efuse)([^A-Za-z]|$)'
# section <heading ERE> <in-fence ok: 0|1> <files...>: that section's text, one line. Fence-aware: a
# heading-like line inside a code fence neither starts (unless allowed) nor ends a section begun
# outside it, and a section begun inside a fence ends where that fence closes. The brief's fallback
# lives inside the template's ````markdown fence, and the template also embeds an "## Orchestrator".
section() {
  LC_ALL=C awk -v h="$1" -v ok="$2" '
    FNR == 1 {w = 0; f = 0}
    /^(```|~~~)/ {
      match($0, /^(`+|~+)/); run = substr($0, 1, RLENGTH)
      if (!f) {f = 1; frun = run}
      else if (substr(run, 1, 1) == substr(frun, 1, 1) && length(run) >= length(frun)) {
        f = 0; if (w && wf) {w = 0; next}
      }
      if (w) print; next
    }
    /^#+ / {
      n = index($0, " ") - 1
      if (w && f == wf && n <= lvl) w = 0
      if (!w && $0 ~ h && (!f || ok)) {w = 1; lvl = n; wf = f; next}
    }
    w' "${@:3}" | tr '\n' ' ' | tr -s ' '
}
# sentence_with [--any] <text> <fixed string>... : 0 when one sentence holds every string and a refusal
# (--any: no refusal needed)
sentence_with() {
  local any=0 sentences; if [ "$1" = --any ]; then any=1; shift; fi
  sentences=$(tr '.' '\n' <<< "$1"); shift
  while [ $# -gt 0 ]; do sentences=$(grep -F -- "$1" <<< "$sentences" || true); shift; done
  if [ "$any" = 1 ]; then [ -n "$sentences" ]; else grep -qE -- "$refusal" <<< "$sentences"; fi
}
# section_rule [--any] <what the rule says> <strings> -- <in-fence ok>|<heading ERE>...: every section
# states the rule; one held invariant when all do. Presence, not meaning: a string check pins that the
# sentence is there, and reviewers judge what it says. --any passes on to sentence_with.
section_rule() {
  local any=() says strings=() spec where text ok=1
  if [ "$1" = --any ]; then any=(--any); shift; fi
  says=$1; shift
  while [ "$1" != -- ]; do strings+=("$1"); shift; done; shift
  for spec in "$@"; do
    where=${spec#*|}
    text=$(section "$where" "${spec%%|*}" "${mds[@]}")
    if [ -z "$text" ]; then
      reworded "$SKILL/*.md" "a section headed '$where'"; ok=0
    elif ! sentence_with ${any[@]+"${any[@]}"} "$text" "${strings[@]}"; then
      fail "$SKILL/*.md: the section headed '$where' no longer says, in one sentence, that $says"; ok=0
    fi
  done
  if [ "$ok" = 1 ]; then held=$((held + 1)); fi
}
# shellcheck disable=SC2016  # the backticks are literal Markdown
section_rule "ANSWER never answers an $marker question" "$marker" ANSWER -- \
  '0|^#+ Orchestrator[[:space:]]*$' '0|^#+ Worker[[:space:]]*$' '1|^#+ If the `crew` skill is unavailable'

# --- a relayed answer is never consent for a tool-permission prompt or a gated action ---------------------
# The same scope. The contract's input invariant, the Worker section and the brief's fallback each say it
# in one sentence holding "consent", "tool-permission", "gate" and a refusal ("consent" keeps Worker step
# 5's ANSWER sentence, which names both but grants nothing, from standing in for the RELAY rule).
# shellcheck disable=SC2016  # the backticks are literal Markdown
section_rule "a relayed answer is never consent for a tool-permission prompt or a gated action" \
  consent tool-permission gate -- \
  '0|^#+ The contract' '0|^#+ Worker[[:space:]]*$' '1|^#+ If the `crew` skill is unavailable'

# --- a resume never carries consent ------------------------------------------------------------------------
# The orchestrator's resume for a cleared worker restates facts learned since the brief, an operator call
# among them. Restating the operator's Hard Gate yes there is the same consent laundering (an auto-mode
# classifier blocked one, 2026-10-02). The Orchestrator section and ledger.md's cleared-worker invariant each
# say so in one sentence holding "resume", "never carries consent", "gated action" and "plan approval": the
# refusal is pinned in the phrase, since the sentence's "not even" would satisfy a bare refusal match.
section_rule "a resume never carries consent for a gated action or a plan approval" \
  resume 'never carries consent' 'gated action' 'plan approval' -- \
  '0|^#+ Orchestrator[[:space:]]*$' '0|^#+ The cleared-worker invariant'

# --- an ANSWER with no question pending is refused ----------------------------------------------------------
# An ANSWER's trigger is a pending question (its Messages row); one that arrives with none is off-contract,
# not an instruction (seen from an orchestrator in hg, 2026-10-01). The Worker section and the brief's
# fallback each say so in one sentence holding ANSWER, "question pending" and "refuse".
# shellcheck disable=SC2016  # the backticks are literal Markdown
section_rule "an ANSWER with no question pending is refused" ANSWER 'question pending' refuse -- \
  '0|^#+ Worker[[:space:]]*$' '1|^#+ If the `crew` skill is unavailable'

# --- the integration's stop is the worker's stop -------------------------------------------------------------
# Under an integration, a workflow's `handoff` continues into the integration's stages, so the worker's stop
# stage is the integration's (Codex on acatl/crew#7). Read as the workflow's, the contract's Authority would
# stop a compliant worker before its PR opens, and the ledger would evict a row whose PR rounds still run. So
# SKILL.md's Authority and ledger.md's Eviction each say "stop stage" and "integration's" in one sentence.
# Presence, not meaning; no refusal to require here.
section_rule --any "the stop stage is the integration's when there is one" 'stop stage' "integration's" -- \
  '0|^#+ Authority[[:space:]]*$' '0|^#+ Eviction[[:space:]]*$'

# --- a queued unit's card lives in its ledger row -------------------------------------------------------------
# A queued brief has no Job section: START writes it later, from the card. A compaction in between destroys
# the card, so a card choice the row doesn't hold falls back to CREW.md's default, and an `integration: none`
# unit would open a PR (Codex on acatl/crew#7). Step 5's row write and ledger.md's spine each name the card's
# lines with `integration` in one sentence, step 8 spawns every unit by step 5, and step 8, the Messages
# START row and the START template write START from the row.
# shellcheck disable=SC2016  # the backticks are literal Markdown
section_rule --any "the ledger row holds the card's lines: integration, mode, Do not touch, decisions" \
  "card's lines" '`integration`' mode '`Do not touch`' 'decision only in' -- \
  '0|^#+ 5[.] Spawn' '0|^#+ Shape[[:space:]]*$'
section_rule --any "START is written from the row's card lines" 'new base sha' "row's card lines" -- \
  '0|^#+ 8[.] Sequences'
section_rule --any "every queued unit is spawned by step 5, which writes its row" 'Spawn every unit now' 'step 5' -- \
  '0|^#+ 8[.] Sequences'
section_rule --any "the contract's START row is written from the unit's ledger row" 'queued brief left out' \
  "unit's ledger row" -- '0|^#+ Messages[[:space:]]*$'
section_rule --any "START's Job fields take the card's lines from the ledger row" 'Job and Spec fields' 'ledger row' -- \
  '0|^#+ START[[:space:]]*$'

# --- a queued unit's spec lives in briefs/<row>-spec.md ------------------------------------------------------
# A queued brief drops its Spec, and the row's card lines leave the spec out, so a spec that lived only in the
# orchestrator's conversation (a ticket source of "the spec below") was gone after a compaction before START
# (Codex on acatl/crew#7). Step 5 saves it when the unit is queued; step 8, ledger.md's spine and the START
# template's placeholder table take START's Spec from that file. The strings stop short of ".md": a
# sentence ends at a period.
# shellcheck disable=SC2016  # the backticks are literal Markdown
section_rule --any "a queued brief's spec is saved to briefs/<row>-spec.md" 'queued brief' 'briefs/<row>-spec' -- \
  '0|^#+ 5[.] Spawn'
# shellcheck disable=SC2016  # the backticks are literal Markdown
section_rule --any "START takes its Spec from briefs/<row>-spec.md" 'Spec from `briefs/<row>-spec' -- \
  '0|^#+ 8[.] Sequences' '0|^#+ Shape[[:space:]]*$'
# shellcheck disable=SC2016  # the backticks are literal Markdown
section_rule --any "the START template sources {SPEC} from briefs/<row>-spec.md" '`{SPEC}`' 'briefs/<row>-spec' \
  'never from memory' -- '0|^#+ START[[:space:]]*$'
# The sentences above stop short of ".md"; the file name itself, extension included, is pinned here:
# every copy reads briefs/<row>-spec.md, the whole name up to a backtick or whitespace, where every real
# copy ends (a save and a read that disagree lose the spec: ".md.bak", ".md~" or ".md,v" is not ".md";
# a sentence's closing period is not part of the name; any other wrapper reads as part of it and fails
# closed), and each of the three files still names it.
# shellcheck disable=SC2016  # the backticks are literal Markdown delimiters
expect "the queued unit's spec file" 'briefs/<row>-spec([^`[:space:]]*[^`[:space:].])?' \
  'briefs/<row>-spec.md' \
  "SKILL.md step 5's save"
spec_ok=1
for f in "$SKILL/SKILL.md" "$SKILL/references/ledger.md" "$SKILL/references/brief-template.md"; do
  if ! grep -qF 'briefs/<row>-spec.md' "$f"; then
    fail "$f: no longer names briefs/<row>-spec.md, the file a queued unit's spec is saved to and read from"; spec_ok=0
  fi
done
if [ "$spec_ok" = 1 ]; then held=$((held + 1)); fi

# --- a resume keeps the roster start -----------------------------------------------------------------------
# Trigger 2 floors its sub-agent baseline at the roster start. A start reset at a resume after a clear would
# drop the same worker's pre-clear sub-agents since its push: three before plus three after read as three
# (acatl/crew#14). Step 6's resume sentence says the start is kept, and the Watchdog roster bullet to keep it
# across resumes.
section_rule --any "a resume keeps the roster start" 'resume' 'roster start kept' -- '0|^#+ 6[.] Handle messages'
section_rule --any "the roster start survives a resume" 'Keep it across resumes' -- '0|^#+ Watchdog'

# --- the workflow reaches a worker through its brief ------------------------------------------------------
# Workers never read CREW.md: the orchestrator resolves the workflow (CREW.md › Workflows) into the
# brief's {WORKFLOW_PATH} and {PARAMETERS}, and the worker reads the file the brief names. So no Worker
# section mentions CREW.md at all (the orchestrator's may), the brief's Job line carries {WORKFLOW_PATH}, and its
# placeholder row sources it from Workflows. In-flight workers spawned before workflows re-read the
# Worker section at every resume and their briefs name no workflow, so the Worker section keeps the
# line that makes their brief the workflow. Both contract copies give DONE its stage form.
wf_ok=1
worker=$(section '^#+ Worker[[:space:]]*$' 0 "${mds[@]}")
if [ -z "$worker" ]; then
  reworded "$SKILL/*.md" "a Worker section heading"; wf_ok=0
else
  if grep -qiF 'crew.md' <<< "$worker"; then
    fail "$SKILL/*.md: the Worker section cites CREW.md, but workers never read it; it reaches them through the brief"; wf_ok=0
  fi
  legacy='No workflow named in your brief → your brief'"'"'s Job/Spec, Boundaries and Checkpoints are the workflow; follow them as written.'
  if ! grep -qF -- "$legacy" <<< "$worker"; then
    fail "$SKILL/*.md: the Worker section lost the legacy line for briefs that name no workflow: '$legacy'"; wf_ok=0
  fi
fi
# shellcheck disable=SC2016  # backticks here are literal Markdown in the pattern
if [ -z "$(scan "$(ws 'Read `[{]WORKFLOW_PATH[}]` in full')" "$BRIEF")" ]; then
  fail "$BRIEF: the brief's Job no longer says 'Read \`{WORKFLOW_PATH}\` in full'"; wf_ok=0
fi
# shellcheck disable=SC2016  # backticks here are literal Markdown in the pattern
if [ -z "$(scan "$(ws '[|] `[{]WORKFLOW_PATH[}]` [|] [^|]*`[^`|]*CREW\.md` › Workflows')" "$BRIEF")" ]; then
  fail "$BRIEF: no placeholder row sourcing {WORKFLOW_PATH} from \`CREW.md\` › Workflows"; wf_ok=0
fi
# shellcheck disable=SC2016  # the backticks are literal Markdown
for spec in '0|^### Messages' '1|^#+ If the `crew` skill is unavailable'; do
  text=$(section "${spec#*|}" "${spec%%|*}" "${mds[@]}")
  for form in '`checkpoint <stage>`' '`stop <stage>`'; do
    if ! grep -qF -- "$form" <<< "$text"; then
      fail "$SKILL/*.md: the section headed '${spec#*|}' doesn't give DONE's $form form"; wf_ok=0
    fi
  done
done
# the orchestrator still reads an older brief's DONE: the boundary form is a checkpoint, a plain DONE a stop
orch=$(section '^#+ Orchestrator[[:space:]]*$' 0 "${mds[@]}")
# shellcheck disable=SC2016  # the backticks are literal Markdown
for form in '`DONE · checkpoint: <boundary>`' 'plain `DONE` is a stop'; do
  if ! grep -qF -- "$form" <<< "$orch"; then
    fail "$SKILL/*.md: the Orchestrator section lost its rule for an older brief's DONE: '$form'"; wf_ok=0
  fi
done
if [ "$wf_ok" = 1 ]; then held=$((held + 1)); fi

# --- the integration reaches a worker through its brief too ------------------------------------------------
# The orchestrator resolves CREW.md › Integration into the brief's {INTEGRATION_PATH}, beside the workflow.
# The ready brief's Job list names {WORKFLOW_PATH} and {INTEGRATION_PATH}, and START's Job list, which replaces
# it for a queued worker, is the same list: one that drifted would drop the integration (or the workflow, or
# `Do not touch`) its brief carried. Each list is its `## Job` section, read as section() reads one (fence-
# aware, wrapped lines joined), less its `<Ready: …>` annotation. The ready one is cut off at the queued
# block's heading; a renamed heading pulls the queued Job in, which fails as a mismatch, never passes.
ip_ok=1
job_list() { section '^## Job[[:space:]]*$' 1 "$1" | sed -E 's/<[A-Z][a-z]+: [^>]*> ?//g'; }
ready_job=$(job_list <(awk '/^### Queued block/ {exit} 1' "$BRIEF"))
start_job=$(job_list <(awk '/^## START[[:space:]]*$/ {p = 1} p' "$BRIEF"))
if [ -z "$ready_job" ]; then reworded "$BRIEF" "the ready brief's \`## Job\` section"; ip_ok=0; fi
if [ -z "$start_job" ]; then reworded "$BRIEF" "START's \`## Job\` section"; ip_ok=0; fi
if [ -n "$ready_job" ]; then
  # shellcheck disable=SC2016  # backticks here are literal Markdown in the pattern
  for want in '- Workflow: `{WORKFLOW}`. Read `{WORKFLOW_PATH}` in full' '- Integration: `{INTEGRATION_PATH}`.' \
    '- Landing: `{LANDING}`'; do
    if ! grep -qF -- "$want" <<< "$ready_job"; then
      fail "$BRIEF: the ready brief's Job list has no '$want' line"; ip_ok=0
    fi
  done
fi
if [ -n "$ready_job" ] && [ -n "$start_job" ] && [ "$ready_job" != "$start_job" ]; then
  fail "$BRIEF: START's Job list differs from the ready brief's, which it replaces"$'\n'"  brief: $ready_job"$'\n'"  START: $start_job"
  ip_ok=0
fi
# shellcheck disable=SC2016  # backticks here are literal Markdown in the pattern
if [ -z "$(scan "$(ws '[|] `[{]INTEGRATION_PATH[}]` [|] [^|]*`[^`|]*CREW\.md` › Integration')" "$BRIEF")" ]; then
  fail "$BRIEF: no placeholder row sourcing {INTEGRATION_PATH} from \`CREW.md\` › Integration"; ip_ok=0
fi
# shellcheck disable=SC2016  # backticks here are literal Markdown in the pattern
if [ -z "$(scan "$(ws '[|] `[{]LANDING[}]` [|] card › Landing[^|]*`delegated`[^|]*`operator`')" "$BRIEF")" ]; then
  fail "$BRIEF: no placeholder row resolving {LANDING} from card › Landing to \`delegated\` or \`operator\`"; ip_ok=0
fi
if [ "$ip_ok" = 1 ]; then held=$((held + 1)); fi

# --- the files that hold stages -------------------------------------------------------------------------------
# The built-in workflow and integration must exist, or the checks over them would check nothing. A project's
# own (docs/crew/workflows/, docs/crew/integrations/) may be absent: that dir is found, never globbed, so a
# deleted one reads as empty, not as a reworded file.
stage_files=()
for f in "$SKILL"/references/workflow-*.md "$SKILL"/references/integration-*.md; do
  if [ -f "$f" ]; then stage_files+=("$f"); else reworded "$f" "the built-in file"; fi
done
while IFS= read -r f; do stage_files+=("$f"); done < <(
  for d in docs/crew/workflows docs/crew/integrations; do
    if [ -d "$d" ]; then find "$d" -name '*.md' -type f; fi
  done | LC_ALL=C sort)

# sentences_of <file>: its sentences, one a line, wrapped lines joined; a sentence ends at ". " or "; "
sentences_of() { tr '\n' ' ' < "$1" | tr -s ' ' | sed 's/[.;] /\n/g'; }

# --- a merge go names its delegation -----------------------------------------------------------------------
# Landing needs delegation (the contract's Authority), and under Integration mode `pr` the written merge
# rule delegates every card that doesn't say `landing: operator`. So every sentence that tells the worker
# to merge, in a workflow or integration file, names that withholding: a merge ordered on the rule alone
# would bypass the card.
merge_ok=1 merge_seen=0
for f in ${stage_files[@]+"${stage_files[@]}"}; do
  while IFS= read -r sentence; do
    merge_seen=1
    # shellcheck disable=SC2016  # the backticks are literal Markdown
    if ! grep -qiF '`landing: operator`' <<< "$sentence"; then
      fail "$f: tells the worker to merge without naming \`landing: operator\`: '$sentence'"; merge_ok=0
    fi
  done < <(sentences_of "$f" | grep -iE 'tells? the worker to merge' || true)
done
if [ "$merge_seen" = 0 ]; then
  reworded "the workflow and integration files" "a sentence that tells the worker to merge"; merge_ok=0
fi
if [ "$merge_ok" = 1 ]; then held=$((held + 1)); fi

# --- a relayed go is never a merge go ---------------------------------------------------------------------------
# A card's `landing: operator` voids the merge rule, so a merge under it is a Hard Gate; so is a merge on a missed
# bar. Acting on a relayed go would launder consent across sessions (SECURITY.md; Codex on acatl/crew#7). The
# brief carries the card's Landing, so every workflow or integration file that asks "merge?" (any quoting):
# - refuses a relayed go in a sentence that names the "merge?" too, so a refusal elsewhere can't stand in;
# - accepts none: no clause relays a go without a refusal in it ("relays the operator's go");
# - marks the question `answer: in this session only` by the brief's Landing, in one sentence holding
#   NEED-INPUT, that marker, "Landing", "unless" and `delegated`, which leaves the orchestrator nothing to
#   relay. Presence, not meaning: the strings pin the sentence's shape, and reviewers judge its logic.
# At least one file must ask, so finding none fails.
relay_ok=1 relay_seen=0
go_refused='(^|[^A-Za-z])([Nn]ever|[Nn]either|[Nn]o|[Nn]ot|[Rr]efuse)([^A-Za-z].*)?[^A-Za-z][Gg]o([^A-Za-z]|$)'
for f in ${stage_files[@]+"${stage_files[@]}"}; do
  sentences=$(sentences_of "$f")
  grep -qiE 'merge\?' <<< "$sentences" || continue
  relay_seen=1
  if ! grep -iE 'merge\?' <<< "$sentences" | grep -F 'relayed go' | grep -qE -- "$refusal"; then
    fail "$f: asks \"merge?\" but no sentence naming it refuses a relayed go"; relay_ok=0
  fi
  # Judged per clause (split at ", ", ": " and parentheses), so a refusal in the same sentence can't cover an
  # acceptance beside it ("…, the operator's go relayed to it, …, never a relayed go"), and the refusal must
  # come before the go ("relays no go"; not "relays the operator's go and no other"). The one shape a comma
  # splits ("says go, which it relays") is matched whole. The `answer: here or relay` marker names a channel,
  # not a relay: it is dropped first.
  # shellcheck disable=SC2016  # the backticks are literal Markdown
  clauses=$(sed -E 's/, |: |[()]/\n/g' <<< "${sentences//'`answer: here or relay`'/}")
  if grep -iE '(^|[^a-z])relay(s|ed|ing)?([^a-z]|$)' <<< "$clauses" | grep -iE '(^|[^a-z])go([^a-z]|$)' \
    | grep -vqE -- "$go_refused" || grep -qiF 'says go, which it relays' <<< "$sentences"; then
    fail "$f: accepts a relayed go for the merge"; relay_ok=0
  fi
  # shellcheck disable=SC2016  # the backticks are literal Markdown
  if ! grep -F 'NEED-INPUT' <<< "$sentences" | grep -F "$marker" | grep -F 'Landing' | grep -F 'unless' \
    | grep -qF '`delegated`'; then
    fail "$f: asks \"merge?\" but doesn't mark it $marker by the brief's Landing"; relay_ok=0
  fi
done
if [ "$relay_seen" = 0 ]; then
  reworded "the workflow and integration files" "a \"merge?\" question"; relay_ok=0
fi
if [ "$relay_ok" = 1 ]; then held=$((held + 1)); fi

# --- a PR opens against the brief's base ----------------------------------------------------------------------
# Without --base, `gh pr create` (alias `gh pr new`) targets the repo's default branch or the branch's
# gh-merge-base, not the base the brief chose (SKILL.md step 3.4). The files spell the call one way,
# `gh pr create --base <base>`, prose included: one canonical form is checkable exactly, where judging gh's
# every spelling means parsing shell. Each call is matched on its own, with its own line, wrapped or not. The
# built-in must name the call itself; a project's file can't stand in for it.
pr_ok=1
pr_canon='gh pr create --base <base>'
# the call and its first two arguments, each a run of non-space; a backtick ends a code span
# shellcheck disable=SC2016  # the backticks are literal Markdown
pr_re='gh[[:space:]]+pr[[:space:]]+(create|new)([[:space:]]+[^[:space:]`]+)?([[:space:]]+[^[:space:]`]+)?'
for f in ${stage_files[@]+"${stage_files[@]}"}; do
  while IFS=$'\t' read -r at call; do
    if [ "$call" != "$pr_canon" ]; then
      fail "$at: opens a PR as '$call', not '$pr_canon': without the brief's base it opens against the default branch"
      pr_ok=0
    fi
  done < <(scan "$pr_re" "$f")
done
if [ -z "$(scan "$(ws 'gh pr create --base <base>')" "$IPR")" ]; then
  reworded "$IPR" "the call '$pr_canon'"; pr_ok=0
fi
if [ "$pr_ok" = 1 ]; then held=$((held + 1)); fi

# --- a merge is confirmed before `stop merge` -------------------------------------------------------------------
# On a base that requires a merge queue, `gh pr merge` only queues the PR (gh's own help), so a worker that reports
# `stop merge` right after it has the orchestrator run Post-land and start the next unit on a PR that may still
# fail the queue (Codex on acatl/crew#7). Every sentence in a workflow or integration file that names
# `gh pr merge` also waits for `gh pr view` to read `MERGED` and names the merge queue: judged per sentence, so a
# wait at one call site can't stand in for another. Presence, not meaning. The built-in names the call itself,
# so the check can't pass on finding none.
mq_ok=1 mq_seen=0
for f in ${stage_files[@]+"${stage_files[@]}"}; do
  while IFS= read -r sentence; do
    if [ "$f" = "$IPR" ]; then mq_seen=1; fi
    # shellcheck disable=SC2016  # the backticks are literal Markdown
    if ! grep -F 'gh pr view' <<< "$sentence" | grep -F '`MERGED`' | grep -qiF 'merge queue'; then
      fail "$f: names \`gh pr merge\` without waiting for \`gh pr view\` to read \`MERGED\` past a merge queue: '$sentence'"
      mq_ok=0
    fi
  done < <(sentences_of "$f" | grep -F 'gh pr merge' || true)
done
if [ "$mq_seen" = 0 ]; then
  reworded "$IPR" "the call 'gh pr merge'"; mq_ok=0
fi
# The orchestrator lands on its own read, not the worker's word: SKILL.md's Land holds a sentence that runs
# Post-land once `gh pr view` reads `MERGED`, which covers a workflow with its own PR stages too.
# shellcheck disable=SC2016  # the backticks are literal Markdown
if ! sentences_of "$SKILL/SKILL.md" | grep -F 'Post-land' | grep -F 'gh pr view' | grep -qF '`MERGED`'; then
  fail "$SKILL/SKILL.md: no sentence runs Post-land only once \`gh pr view\` reads \`MERGED\`"; mq_ok=0
fi
if [ "$mq_ok" = 1 ]; then held=$((held + 1)); fi

# --- the queue card shows each unit's workflow and landing ----------------------------------------------------
# Under Integration mode `pr` landing is per unit (a PR-merging unit is delegated by the merge rule), so one
# card-wide Landing line can show a delegated unit as "operator decides". The queue card's table carries both.
qhead=$(grep -E '^> \| # \| Unit \|' "$SKILL/SKILL.md" | head -n 1 || true)
if [ -z "$qhead" ]; then
  reworded "$SKILL/SKILL.md" "the queue card's '> | # | Unit |' table header"
else
  q_ok=1
  for col in Workflow Landing; do
    if ! grep -qE "\\| $col \\|" <<< "$qhead"; then
      fail "$SKILL/SKILL.md: the queue card has no per-unit $col column: '$qhead'"; q_ok=0
    fi
  done
  if [ "$q_ok" = 1 ]; then held=$((held + 1)); fi
fi

# --- a workflow's verify falls back as the orchestrator's does ------------------------------------------------
# A worker's build ends on `verify` green, and the orchestrator verifies a stop by the brief's `verify`, else
# its own chain (SKILL.md's "DONE `stop <stage>`" bullet, the source). A workflow's or integration's `verify`
# default names the same sources, or a project missing one leaves the two sides verifying different things.
# Each built-in must carry the row, so the check can't pass on finding none.
v_ok=1
# shellcheck disable=SC2016  # the backticks are literal Markdown
stop=$(section '^#+ Orchestrator[[:space:]]*$' 0 "${mds[@]}" | grep -oE '[*][*]DONE `stop <stage>`[*][*][^-]*' | head -n 1 || true)
chain=$(grep -oE '(CREW\.md|docs/HARNESS\.md)` › [A-Z][a-z]+' <<< "$stop" | LC_ALL=C sort -u || true)
if [ -z "$chain" ]; then
  reworded "$SKILL/SKILL.md" "the Orchestrator's DONE \`stop <stage>\` verify chain"; v_ok=0
fi
for f in ${stage_files[@]+"${stage_files[@]}"}; do
  # shellcheck disable=SC2016  # the backticks are literal Markdown
  row=$(grep -E '^\| `verify` \|' "$f" || true)
  if [ -z "$row" ]; then
    case $f in "$SKILL"/references/*) reworded "$f" "the \`verify\` parameter row"; v_ok=0 ;; esac
    continue
  fi
  got=$(grep -oE '(CREW\.md|docs/HARNESS\.md)` › [A-Z][a-z]+' <<< "$row" | LC_ALL=C sort -u || true)
  if [ -n "$chain" ] && [ "$got" != "$chain" ]; then
    fail "$f: the \`verify\` default falls back to '$(tr '\n' ',' <<< "$got" | sed 's/,$//')', but the orchestrator's verify falls back to '$(tr '\n' ',' <<< "$chain" | sed 's/,$//')'"; v_ok=0
  fi
done
if [ "$v_ok" = 1 ]; then held=$((held + 1)); fi

# --- a ready PR asks before it merges ----------------------------------------------------------------------
# After `merge bar met` the worker waits on the merge, so it sends NEED-INPUT (SKILL.md Worker step 4), and
# the merge go is an ANSWER to that question: no other kind can carry it. Every workflow or integration
# file that names `merge bar met` holds a sentence that sends NEED-INPUT for the merge (the worker's;
# the orchestrator's "answers only the worker's merge NEED-INPUT" doesn't count). At least one must
# name it, so the check can't pass on finding none.
ask_ok=1 ask_seen=0
for f in ${stage_files[@]+"${stage_files[@]}"}; do
  sentences=$(sentences_of "$f")
  grep -qF 'merge bar met' <<< "$sentences" || continue
  ask_seen=1
  if ! grep -F 'NEED-INPUT' <<< "$sentences" | grep -E '(^|[^a-z])sends ' | grep -qiE 'merge([^a-z]|$)'; then
    fail "$f: names \`merge bar met\` but no sentence sends the merge \`NEED-INPUT\`"; ask_ok=0
  fi
done
if [ "$ask_seen" = 0 ]; then
  reworded "the workflow and integration files" "\`merge bar met\`"; ask_ok=0
fi
if [ "$ask_ok" = 1 ]; then held=$((held + 1)); fi

# --- every brief state is handled on both sides ---------------------------------------------------------
# A brief's marker line carries `state=`, and each value means a different first move: ready starts,
# queued waits for START, resume (a re-send after a clear) skips ONLINE and the base step. The brief
# template's {STATE} row is the source. SKILL.md's Orchestrator and Worker sections each name every value
# (`state: <v>` or `state=<v>`), and the brief's fallback names every value, so a worker without the
# skill still tells a resume from a fresh start. Both ways: a state SKILL.md handles that the row doesn't
# list fails too, so a template that drops `resume` can't pass while SKILL.md still sends it.
st_ok=1
# shellcheck disable=SC2016  # the backticks are literal Markdown
states=$(grep -E '^\| `\{STATE\}` \|' "$BRIEF" | sed 's/^| `{STATE}` |//' | grep -oE '`[a-z]+`' | tr -d '`' || true)
if [ -z "$states" ]; then
  reworded "$BRIEF" "the {STATE} placeholder row"; st_ok=0
else
  for spec in '^#+ Orchestrator[[:space:]]*$' '^#+ Worker[[:space:]]*$'; do
    text=$(section "$spec" 0 "$SKILL/SKILL.md")
    for v in $states; do
      if ! grep -qE "state(: |=)$v([^a-z]|\$)" <<< "$text"; then
        fail "$SKILL/SKILL.md: the section headed '$spec' handles no brief state '$v'"; st_ok=0
      fi
    done
    while IFS= read -r v; do
      if [ -n "$v" ] && ! grep -qxF "$v" <<< "$states"; then
        fail "$SKILL/SKILL.md: the section headed '$spec' handles brief state '$v', which $BRIEF's {STATE} row doesn't list"; st_ok=0
      fi
    done < <(grep -oE 'state(: |=)[a-z]+' <<< "$text" | sed -E 's/^state(: |=)//' | LC_ALL=C sort -u || true)
  done
  # shellcheck disable=SC2016  # the backticks are literal Markdown
  text=$(section '^#+ If the `crew` skill is unavailable' 1 "$BRIEF")
  for v in $states; do
    if ! grep -qE "(^|[^a-z])$v([^a-z]|\$)" <<< "$text"; then
      fail "$BRIEF: the fallback section handles no brief state '$v'"; st_ok=0
    fi
  done
fi
if [ "$st_ok" = 1 ]; then held=$((held + 1)); fi

# --- the host layer: every verb has both hosts, and no app tool leaks past it ------------------------------
# The skill names a verb in italics (*spawn*, *identify*) and references/host.md says how each host does
# it, so the same skill runs in the desktop app and the terminal CLI. A verb row with an empty column is
# a host the skill can't run on; a verb no file cites is dead; and an app tool named outside host.md
# would run on one host only. The brief's fallback section is the one exception: a worker without the
# skill can't read host.md, so it names both hosts' send mechanisms itself.
HOST=$SKILL/references/host.md
h_ok=1
others=()
while IFS= read -r f; do others+=("$f"); done < <(printf '%s\n' "${mds[@]}" | grep -vxF "$HOST")
# shellcheck disable=SC2016  # the backticks and * are literal Markdown
verbs=$(grep -E '^\| \*[a-z-]+\* \|' "$HOST" | sed -E 's/^\| \*([a-z-]+)\* \|.*/\1/' || true)
if [ -z "$verbs" ]; then
  reworded "$HOST" "the verb table's rows ('| *verb* | desktop | terminal |')"; h_ok=0
else
  while IFS= read -r row; do
    v=$(sed -E 's/^\| \*([a-z-]+)\* \|.*/\1/' <<< "$row")
    cells=$(awk -F' \\| ' '{n = 0; for (i = 2; i <= NF; i++) if ($i ~ /[^ |]/) n++; print n}' <<< "$row")
    if [ "$cells" -lt 2 ]; then fail "$HOST: the verb *$v* doesn't say how both hosts do it"; h_ok=0; fi
  done < <(grep -E '^\| \*[a-z-]+\* \|' "$HOST")
  for v in $verbs; do
    if ! grep -qF -- "*$v*" "${others[@]}"; then
      fail "$HOST: the verb *$v* is cited nowhere else in the skill"; h_ok=0
    fi
  done
fi
app_tools='mcp__ccd_|spawn_task|get_session|list_sessions|list_events|archive_session|clear_session|send_message'
# shellcheck disable=SC2016  # the backticks are literal Markdown
fallback_cut() {  # the file's lines, numbered, less the brief's fallback section
  LC_ALL=C awk '/^## If the `crew` skill is unavailable/ {skip = 1} skip && /^````/ {skip = 0}
                !skip {print FILENAME ":" FNR ": " $0}' "$1"
}
projects=()
while IFS= read -r f; do projects+=("$f"); done < <(find docs/crew -name '*.md' -type f 2>/dev/null | LC_ALL=C sort)
for f in "${others[@]}" ${projects[@]+"${projects[@]}"}; do
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    fail "${hit%%: *}: names a host's tool outside references/host.md ($(grep -oE "$app_tools" <<< "${hit#*: }" | head -n 1)); name the verb instead"; h_ok=0
  done < <(fallback_cut "$f" | grep -E "$app_tools" || true)
done
if [ "$h_ok" = 1 ]; then held=$((held + 1)); fi

# --- the brief carries its host ----------------------------------------------------------------------------
# A worker learns its host from the brief, and a brief from before hosts names none: it is desktop. The
# brief's Orchestrator section carries `- host:`, the {HOST} row sources it from *self*, and the Worker
# section says a brief with no host line is desktop.
ho_ok=1
# shellcheck disable=SC2016  # the backticks are literal Markdown
if ! section '^## Orchestrator[[:space:]]*$' 1 "$BRIEF" | grep -qF -- '- host: `{HOST}`'; then
  fail "$BRIEF: the brief's Orchestrator section has no '- host: \`{HOST}\`' line"; ho_ok=0
fi
# shellcheck disable=SC2016  # the backticks are literal Markdown
if ! grep -qE '^\| `\{HOST\}` \| \*self\*' "$BRIEF"; then
  fail "$BRIEF: no placeholder row sourcing {HOST} from *self*"; ho_ok=0
fi
# A title can be shared by two live sessions (two orchestrators, seen live 2026-10-15); a socket can't. On
# the terminal the brief carries the orchestrator's socket address, and the fallback section sends to it.
# shellcheck disable=SC2016  # the backticks are literal Markdown
if ! section '^## Orchestrator[[:space:]]*$' 1 "$BRIEF" | grep -qF -- '- address: `{ORCH_ADDRESS}`'; then
  fail "$BRIEF: the brief's Orchestrator section has no '- address: \`{ORCH_ADDRESS}\`' line"; ho_ok=0
fi
# shellcheck disable=SC2016  # the backticks are literal Markdown
if ! grep -qE '^\| `\{ORCH_ADDRESS\}` \| \*self\*' "$BRIEF"; then
  fail "$BRIEF: no placeholder row sourcing {ORCH_ADDRESS} from *self*"; ho_ok=0
fi
# shellcheck disable=SC2016  # the backticks are literal Markdown
if ! section '^#+ If the `crew` skill is unavailable' 1 "$BRIEF" | grep -qF -- '`SendMessage` to `{ORCH_ADDRESS}`'; then
  fail "$BRIEF: the fallback section doesn't send to {ORCH_ADDRESS} on the terminal"; ho_ok=0
fi
if [ "$ho_ok" = 1 ]; then held=$((held + 1)); fi
# shellcheck disable=SC2016  # the backticks are literal Markdown
section_rule --any "a brief with no host line is desktop" 'host:' 'none is `desktop`' -- '0|^#+ Worker[[:space:]]*$'

# --- the worker's ledger is the brief's ----------------------------------------------------------------------
# A terminal worker can't write its git dir (worktree isolation, seen live 2026-10-15), so the brief names
# the ledger in the crew dir. It holds the consent a resume must never carry, so a brief that lost the line
# would leave a restarted worker with nothing. The brief's Housekeeping carries {WORKER_LEDGER}, its row
# sources it from the crew dir, and the Worker section reads its ledger from the brief.
wl_ok=1
if ! section '^## Housekeeping[[:space:]]*$' 1 "$BRIEF" | grep -qF -- '{WORKER_LEDGER}'; then
  fail "$BRIEF: the brief's Housekeeping section doesn't name {WORKER_LEDGER}"; wl_ok=0
fi
# shellcheck disable=SC2016  # the backticks are literal Markdown
if ! grep -qE '^\| `\{WORKER_LEDGER\}` \| `~/\.claude/crew/<slug>/briefs/<row>-worker-ledger\.md`' "$BRIEF"; then
  fail "$BRIEF: no placeholder row sourcing {WORKER_LEDGER} from the crew dir"; wl_ok=0
fi
if [ "$wl_ok" = 1 ]; then held=$((held + 1)); fi
section_rule --any "a worker's ledger is the one its brief names" 'ledger' "Housekeeping" -- '0|^#+ Worker[[:space:]]*$'

# --- a terminal report carries no ids or paths -------------------------------------------------------------
# Auto mode's classifier refused an ONLINE carrying a session id, a worktree path and the peer list as data
# exfiltration (seen live, 2026-10-14), so on the terminal the orchestrator reads those itself. Desktop
# ONLINE keeps the worker's sessionId: spawn_task returns only a task_id, so it is how the orchestrator
# learns the worker. Both copies of the contract say each.
# shellcheck disable=SC2016  # the backticks are literal Markdown
section_rule --any "a terminal report carries no ids or paths" 'terminal' 'no ids or paths' -- \
  '0|^#+ Worker[[:space:]]*$' '1|^#+ If the `crew` skill is unavailable'
section_rule --any "desktop ONLINE carries the worker's own sessionId" 'desktop host' 'sessionId' -- \
  '0|^#+ Messages[[:space:]]*$'

# --- the watchdog's state files are listed and cleaned up --------------------------------------------------
# Each file the watchdog keeps across runs (its dedupe and clocks) is listed in ledger.md's crew dir, and
# step 7 deletes it when the last worker goes: one left behind dedupes or clocks a later worker reusing a
# ticket id. The watchdog header is the source.
sf_ok=1
state_files=$(sed -n '/^# State, all in/,/^# Triggers/p' "$WATCHDOG" | grep -oE '^#   [a-z]+\.(txt|tsv)' | sed 's/^#   //' || true)
if [ -z "$state_files" ]; then
  reworded "$WATCHDOG" "the header's state-file list"; sf_ok=0
fi
cleanup_text=$(section '^#+ 7\. Cleanup' 0 "$SKILL/SKILL.md")
for f in $state_files; do
  [ "$f" = roster.tsv ] && continue      # the orchestrator's input, rewritten, never deleted
  if ! grep -qF -- "$f" "$LEDGER"; then fail "$LEDGER: the crew dir listing doesn't name $f, which $WATCHDOG keeps"; sf_ok=0; fi
  if ! grep -qF -- "$f" <<< "$cleanup_text"; then fail "$SKILL/SKILL.md: step 7 doesn't delete $f, which $WATCHDOG keeps"; sf_ok=0; fi
done
if [ "$sf_ok" = 1 ]; then held=$((held + 1)); fi

if [ "$fails" -gt 0 ]; then
  printf '✖ %d restated value(s) drifted; CLAUDE.md › Invariants that span files lists every copy\n' "$fails" >&2
  exit 1
fi
printf '✓ every restated value agrees (%d invariants)\n' "$held"
