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
# sentence_with <text> <fixed string>... : 0 when one sentence holds every string and a refusal
sentence_with() {
  local sentences; sentences=$(tr '.' '\n' <<< "$1"); shift
  while [ $# -gt 0 ]; do sentences=$(grep -F -- "$1" <<< "$sentences" || true); shift; done
  grep -qE -- "$refusal" <<< "$sentences"
}
# section_rule <what the rule says> <strings> -- <in-fence ok>|<heading ERE>...: every section states the
# rule; one held invariant when all do. Presence, not meaning: a string check pins that the sentence is
# there, and reviewers judge what it says.
section_rule() {
  local says=$1 strings=() spec where text ok=1; shift
  while [ "$1" != -- ]; do strings+=("$1"); shift; done; shift
  for spec in "$@"; do
    where=${spec#*|}
    text=$(section "$where" "${spec%%|*}" "${mds[@]}")
    if [ -z "$text" ]; then
      reworded "$SKILL/*.md" "a section headed '$where'"; ok=0
    elif ! sentence_with "$text" "${strings[@]}"; then
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

# --- an ANSWER with no question pending is refused ----------------------------------------------------------
# An ANSWER's trigger is a pending question (its Messages row); one that arrives with none is off-contract,
# not an instruction (seen from an orchestrator in hg, 2026-10-01). The Worker section and the brief's
# fallback each say so in one sentence holding ANSWER, "question pending" and "refuse".
# shellcheck disable=SC2016  # the backticks are literal Markdown
section_rule "an ANSWER with no question pending is refused" ANSWER 'question pending' refuse -- \
  '0|^#+ Worker[[:space:]]*$' '1|^#+ If the `crew` skill is unavailable'

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
# Every Job block that names {WORKFLOW_PATH} (the ready brief's and START's) names {INTEGRATION_PATH} too, or
# a START would drop the integration its brief carried, and its placeholder row sources it from Integration.
ip_ok=1
# shellcheck disable=SC2016  # backticks here are literal Markdown in the pattern
n_wf=$(grep -cF 'Read `{WORKFLOW_PATH}` in full' "$BRIEF" || true)
# shellcheck disable=SC2016  # backticks here are literal Markdown in the pattern
n_ip=$(grep -cE '^- Integration: `[{]INTEGRATION_PATH[}]`' "$BRIEF" || true)
if [ "$n_ip" = 0 ] || [ "$n_ip" != "$n_wf" ]; then
  fail "$BRIEF: $n_wf Job block(s) name {WORKFLOW_PATH} but $n_ip carry a '- Integration: \`{INTEGRATION_PATH}\`' line"; ip_ok=0
fi
# shellcheck disable=SC2016  # backticks here are literal Markdown in the pattern
if [ -z "$(scan "$(ws '[|] `[{]INTEGRATION_PATH[}]` [|] [^|]*`[^`|]*CREW\.md` › Integration')" "$BRIEF")" ]; then
  fail "$BRIEF: no placeholder row sourcing {INTEGRATION_PATH} from \`CREW.md\` › Integration"; ip_ok=0
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
  done < <(tr '\n' ' ' < "$f" | tr -s ' ' | sed 's/[.;] /\n/g' | grep -iE 'tells? the worker to merge' || true)
done
if [ "$merge_seen" = 0 ]; then
  reworded "the workflow and integration files" "a sentence that tells the worker to merge"; merge_ok=0
fi
if [ "$merge_ok" = 1 ]; then held=$((held + 1)); fi

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
  sentences=$(tr '\n' ' ' < "$f" | tr -s ' ' | sed 's/[.;] /\n/g')
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

if [ "$fails" -gt 0 ]; then
  printf '✖ %d restated value(s) drifted; CLAUDE.md › Invariants that span files lists every copy\n' "$fails" >&2
  exit 1
fi
printf '✓ every restated value agrees (%d invariants)\n' "$held"
