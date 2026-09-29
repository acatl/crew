#!/usr/bin/env bash
# shellcheck disable=SC2016  # the backticks and $ below are literal Markdown and sed, not expansions
# Tests for the skill checks in scripts/. Each case copies the repo's skill, scripts, baselines and
# the watchdog suite (the slug check reads it) into a mktemp sandbox, plants one drift there, and
# runs the sandbox's copy of the check, so nothing real is touched. Needs skill-validator and jq,
# like the checks themselves. Run it after changing a check:
#
#   test/checks.test.sh
#
# A check that passes proves nothing on its own: a check blind for a mechanical reason passes too.
# So every check is first run green on an untouched copy, the control for each drift case after it
# (fresh rebuilds that same copy), and a drift case must turn it red AND name the file that drifted.
# A case that leaves a changed fixture green is paired with one that fires on that same fixture.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT=$(mktemp -d)
S="$ROOT/repo"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s — %s\n' "$1" "$2"; }

finish() { if [ "$fail" = 0 ]; then rm -rf "$ROOT"; else printf 'sandbox kept: %s\n' "$ROOT"; fi; }
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fresh() {
  rm -rf "$S"; mkdir -p "$S/test"
  cp -R "$REPO/skills" "$REPO/scripts" "$REPO/baselines" "$S/"
  cp "$REPO/test/watchdog.test.sh" "$S/test/"
}
# edit <file> <sed expression>: in place through a temp file, since BSD and GNU sed -i disagree. An
# edit that errors or changes nothing is itself a failure: the case after it would test an untouched
# fixture, and a green case would pass blind.
edit() {
  if ! sed "$2" "$S/$1" > "$S/$1.new"; then bad "edit $1" "sed failed: $2"; return 1; fi
  if cmp -s "$S/$1" "$S/$1.new"; then bad "edit $1" "changed nothing: $2"; fi
  mv "$S/$1.new" "$S/$1"
}
run() { local c=$1; shift; "$S/scripts/$c.sh" "$@" >"$ROOT/out" 2>&1; }

green() {  # green <label> <check>
  run "$2"; local rc=$?
  if [ "$rc" = 0 ]; then ok "$1"; else bad "$1" "rc=$rc $(cat "$ROOT/out")"; fi
}
red() {  # red <label> <check> <pattern the output must hold> [check args...]
  local label=$1 c=$2 pat=$3; shift 3
  run "$c" "$@"; local rc=$?
  if [ "$rc" != 0 ] && grep -qF -- "$pat" "$ROOT/out"
  then ok "$label"; else bad "$label" "rc=$rc, want '$pat' in: $(cat "$ROOT/out")"; fi
}

SK=skills/crew/SKILL.md
CM=skills/crew/references/crew-md.md
BT=skills/crew/references/brief-template.md
LG=skills/crew/references/ledger.md
WD=skills/crew/scripts/watchdog.sh
OV=skills/crew/scripts/overlap.sh

# --- the controls: every check green on an untouched copy --------------------------------------------
fresh
for c in check-structure check-content check-budget check-invariants check-section-refs check-skill-frontmatter; do
  green "0  $c is green on an untouched copy" "$c"
done

# --- check-invariants -----------------------------------------------------------------------------------
fresh; edit "$SK" 's#(1200 / 3600 / 3)#(1200 / 1800 / 3)#'
red "1  a watchdog-defaults copy drifts" check-invariants "$SK"
fresh; edit "$SK" 's#absent, 60 minutes#absent, 30 minutes#'
red "2  the minutes copy drifts" check-invariants "$SK"
fresh; edit "$CM" 's#20 min · 60 min · step 3#20 min · 60 min · step 4#'
red "3  the interview-table copy drifts" check-invariants "$CM"
fresh; edit "$CM" 's#push pass 3#push pass 5#'
red "4  the template's watchdog line drifts" check-invariants "$CM"
fresh; edit "$WD" 's#nocommit=3600#nocommit=1800#'
red "5  the source changes and every copy is named" check-invariants "absent, 60 minutes"
fresh; edit "$SK" 's#`4` no usable#`5` no usable#'
red "6  a watchdog exit code drifts" check-invariants 'no launch-failure code `4`'
fresh; edit "$OV" 's#2 usage or git error#3 usage or git error#'
red "7  overlap's exit code drifts in its header" check-invariants "$OV"
fresh; edit "$SK" 's#2 = usage or git error#3 = usage or git error#'
red "8  overlap's exit code drifts in the skill" check-invariants "no '2 = usage or git error'"
fresh; edit "$BT" 's#^<!-- crew:brief v1#<!-- crew:task v1#'
red "9  the brief marker drifts" check-invariants "$SK"
fresh; edit "$BT" '/^<!-- crew:brief v1/d'
red "9b a brief with no marker line is reported, not a crash" check-invariants "the brief's '<!-- crew:…' first line not found"
if grep -qF "✖ 1 restated value(s) drifted" "$ROOT/out"; then ok "9c and the run reaches its summary"; else bad "9c no crash" "$(cat "$ROOT/out")"; fi
fresh; edit "$SK" 's#confirm with the `crew:brief` marker#confirm with the `crew:brf` marker#'
red "10 a stray spelling of the marker's name" check-invariants "'crew:brf'"
fresh; edit "$BT" 's#A `RELAY` carries#A relay carries#'
red "11 the fallback drops a message kind" check-invariants "doesn't name \`RELAY\`"

fresh; edit "$SK" "s#the worker's four reports#the worker's five reports#"
red "12 the description miscounts the reports" check-invariants "$SK"
fresh; edit "$SK" "s#the orchestrator's RELAY, START and ANSWER#the orchestrator's RELAY and START#"
red "12b the description drops an orchestrator kind" check-invariants "the description gives the orchestrator RELAY START"
fresh; edit "$BT" 's#`ANSWER`#the answer#g'
red "12c the fallback drops ANSWER" check-invariants "doesn't name \`ANSWER\`"
fresh; edit "$SK" 's#besides the four kinds#besides the three kinds#'
red "13 the worker rule miscounts the kinds" check-invariants "$SK"
fresh; edit "$LG" "s#sed 's\#/\#-\#g'#sed 's\#[/.]\#-\#g'#"
red "14 the crew-dir slug is unified with the transcript one" check-invariants "$LG"
fresh; edit test/watchdog.test.sh "s#^slug() { printf '%s' \"\$1\" | sed 's\#\[/.\]\#-\#g'; }#slug() { printf '%s' \"\$1\" | sed 's\#/\#-\#g'; }#"
red "15 the test's slug drifts from the watchdog's" check-invariants "test/watchdog.test.sh"
# the loop limit reaches a worker only through its brief: the Worker section never cites Counters
fresh; edit "$SK" 's@^### 0\. Resume from the ledger@Track `CREW.md` › Counters per worker in the ledger.\
\
&@'
green "15b the orchestrator's sections may cite CREW.md › Counters" check-invariants
edit "$SK" 's#absent one, \*\*two\*\*#absent one (`CREW.md` › Counters), **two**#'   # same fixture
red "15c the Worker section citing CREW.md › Counters" check-invariants "the Worker section cites CREW.md › Counters"
fresh; edit "$BT" 's#at most {ITERATIONS} review#at most two review#'
red "15d the brief hard-coding the limit again" check-invariants "$BT: the brief's Loop budget line"
fresh; edit "$BT" 's#^| `{ITERATIONS}` | `CREW.md` › Counters#|  `{ITERATIONS}`  |  `docs/CREW.md` › Counters#'
green "15e a padded placeholder row naming docs/CREW.md still counts" check-invariants
edit "$BT" 's#`docs/CREW.md` › Counters#`docs/CREW.md` › Ledger#'                  # same fixture
red "15f the row sourcing {ITERATIONS} from anything but Counters" check-invariants "$BT: no placeholder row sourcing"
# the roster format: watchdog.sh's header names the columns, and every copy names the same ones
fresh; edit "$LG" 's#<worktree-path> TAB <start epoch>, one per#<worktree-path>, one per#'
red "15g a roster copy drops the start column" check-invariants "$LG"
fresh; edit "$SK" 's#`<start epoch>`, one line per#`<started>`, one line per#'
red "15h a wrapped roster copy renames a column" check-invariants "$SK"
fresh; edit "$WD" 's#\[<TAB> <start epoch>\], one line per#[<TAB> <started>], one line per#'
red "15i the header changes and a copy is named" check-invariants "$LG"
fresh; edit "$WD" 's#roster.tsv    input:#roster.tsv    in:#'
red "15j a reworded header line is reported, not passed" check-invariants "the header's 'roster.tsv"
fresh; edit "$SK" 's#`<ticket>` TAB `<worktree-path>` TAB#one ticket TAB `<worktree-path>` TAB#'
red "15k one reworded copy fails though the other still matches" check-invariants "found in 1: $LG"
fresh; edit "$LG" 's#<ticket> TAB <worktree-path> TAB#one ticket TAB <worktree-path> TAB#'
red "15l and so does the other one" check-invariants "found in 1: $SK"
fresh; edit "$SK" 's#^- \*\*Its roster is `~/\.claude/crew/<slug>/roster\.tsv`\*\* — `<ticket>` TAB `<worktree-path>` TAB#- **Its roster is `~/.claude/crew/<slug>/roster.tsv`**, in references/watchdog.md. TAB#'
printf '\nroster.tsv: `<ticket>` TAB `<worktree-path>` TAB `<start epoch>`, one line per worker.\n' > "$S/skills/crew/references/watchdog.md"
green "15m a copy moved to another file still counts" check-invariants
edit skills/crew/references/watchdog.md 's# TAB `<start epoch>`##'                        # same fixture
red "15n and the moved copy is still checked" check-invariants "skills/crew/references/watchdog.md"
fresh; edit "$SK" 's#`<ticket>` TAB `<worktree-path>` TAB#one ticket TAB `<worktree-path>` TAB#'
edit "$LG" 's#<ticket> TAB <worktree-path> TAB#one ticket TAB <worktree-path> TAB#'
printf '\nroster.tsv: `<ticket>` TAB `<worktree-path>` TAB `<start epoch>`, one line per worker.\n' \
  > "$S/skills/crew/references/roster notes.md"
red "15r one copy in a file whose name has a space counts as one file" check-invariants "found in 1: skills/crew/references/roster notes.md"
# ANSWER never answers an in-session-only question: the Orchestrator, Worker and fallback sections say so
fresh; edit "$SK" 's#, say why, and send no `RELAY` or `ANSWER`\.#, and say why.#'
edit "$SK" 's#covers a question not marked `answer: in this session only`,#covers a question,#'
red "15o the orchestrator's guard drops out" check-invariants "the section headed '^#+ Orchestrator"
fresh; edit "$SK" 's#, a gated action or `answer: in this session only`\.#, or a gated action.#'
red "15p the worker's guard drops out" check-invariants "the section headed '^#+ Worker"
fresh; edit "$BT" 's#locked decision or `answer: in this session only`\.#locked decision.#'
red "15q the fallback's guard drops out" check-invariants "the section headed '^#+ If the"
fresh; edit "$SK" 's#, say why, and send no `RELAY` or `ANSWER`\.#, say why, and send an `ANSWER` if delegated.#'
# the first branch's "no nudge" is a refusal word too: the check pins presence, not meaning (CLAUDE.md)
edit "$SK" 's#covers a question not marked `answer: in this session only`,#covers a question marked `answer: in this session only`,#'
edit "$SK" 's#→ no nudge: read#→ skip the nudge: read#'
red "15s a guard sentence that no longer refuses" check-invariants "the section headed '^#+ Orchestrator"
fresh; edit "$SK" 's#^\#\# Worker$#\#\# The worker#'
red "15t a guard section's heading renamed is reported, not passed" check-invariants "a section headed '^#+ Worker"
fresh; edit "$SK" 's#^\#\#\# 6\. Handle messages#```bash\
\# a comment, not a heading\
```\
\
&#'
green "15u a heading-like comment in a code fence ends no section" check-invariants
fresh; edit "$SK" "s#the operator's words, never consent for a tool-permission prompt or a gated#the operator's words, even for a tool-permission prompt or a gated#"
red "15v the worker's RELAY rule stops refusing tool-permission consent" check-invariants "that a relayed answer is never consent for a tool-permission prompt"
fresh; edit "$BT" 's#Neither is consent for a tool-permission prompt#Both count for a tool-permission prompt#'
red "15w the fallback's RELAY rule stops refusing it" check-invariants "the section headed '^#+ If the"
fresh; edit "$SK" 's#^- \*\*Never relayed:\*\* tool-permission prompts#- **Relayed as usual:** tool-permission prompts#'
red "15x the contract's input invariant stops refusing it" check-invariants "the section headed '^#+ The contract'"
fresh; edit "$SK" "s#never consent for a tool-permission prompt or a gated#never consent for a tool-permission prompt, but consent for a#"
red "15y the worker's RELAY rule drops the gated-action half" check-invariants "or a gated action"
fresh; edit "$BT" 's#tool-permission prompt or a gated action (push, install,#tool-permission prompt; a yes for (push, install,#'
red "15z the fallback drops the gated-action half" check-invariants "the section headed '^#+ If the"

# --- check-section-refs ------------------------------------------------------------------------------------
fresh; printf '\nSee `CREW.md` › Nosuch for it.\n' >> "$S/$SK"
red "16 a CREW.md section that doesn't exist" check-section-refs "CREW.md › Nosuch"
fresh; printf '\nSee `CREW.md` › Integrations too.\n' >> "$S/$SK"
red "17 a heading's prefix is not the heading" check-section-refs "CREW.md › Integrations"
fresh; printf '\nRead `references/missing.md` first.\n' >> "$S/$SK"
red "18 a references/ file that doesn't exist" check-section-refs "references/missing.md"
fresh; printf '\nRun `<skill-dir>/scripts/gone.sh`.\n' >> "$S/$SK"
red "19 a skill script that doesn't exist" check-section-refs "<skill-dir>/scripts/gone.sh"

fresh; for f in "$SK" "$BT" "$LG"; do edit "$f" 's#CREW\.md` ›#CREW.md` -#g'; done
red "19b no CREW.md references at all fails, never passes" check-section-refs "found no 'CREW.md › Section' references"
fresh; grep -rl 'references/' "$S/skills/crew" | while IFS= read -r f; do edit "${f#"$S"/}" 's#references/#refs/#g'; done
red "19c no references/ mentions at all fails, never passes" check-section-refs "found no references/<name>.md mentions"
fresh; edit "$SK" 's#<skill-dir>/scripts/#<skill-dir>/bin/#g'
red "19d no <skill-dir>/scripts/ calls at all fails, never passes" check-section-refs "found no <skill-dir>/scripts/ calls"

# --- check-links: it needs lychee, which this job may lack, so only its own guard is tested here ---------------
# check-links.sh finds its repo from the working directory, as a hook does, so it runs from inside a
# repo of its own that holds no Markdown at all
L="$ROOT/links"; mkdir -p "$L/scripts"; git -C "$L" init -q; cp "$REPO/scripts/check-links.sh" "$L/scripts/"
(cd "$L" && scripts/check-links.sh) >"$ROOT/out" 2>&1; rc=$?
if [ "$rc" = 1 ] && grep -qF "git listed no markdown files" "$ROOT/out"
then ok "19e git listing no Markdown fails, never passes"; else bad "19e links guard" "rc=$rc $(cat "$ROOT/out")"; fi
printf '# doc\n' > "$L/doc.md"                   # positive control for 19e: one file gets past the guard
(cd "$L" && scripts/check-links.sh) >"$ROOT/out" 2>&1
if ! grep -qF "listed no markdown" "$ROOT/out"; then ok "19f same repo with a Markdown file gets past the guard"; else bad "19f links control" "$(cat "$ROOT/out")"; fi

# --- check-budget ---------------------------------------------------------------------------------------------
fresh; printf '\nfive more words right here\n' >> "$S/$LG"
red "20 a file grows past its budget" check-budget "$LG: "
if grep -qF "(+5)" "$ROOT/out"; then ok "21 and the delta is named"; else bad "21 budget delta" "$(cat "$ROOT/out")"; fi
red "22 --update never raises" check-budget "over its budget" --update
red "23 --allow-raise alone is refused" check-budget "only goes with --update" --allow-raise
fresh; printf 'a new reference\n' > "$S/skills/crew/references/new.md"
red "24 a new file has no budget" check-budget "references/new.md: 3 words and no budget"
fresh; edit "$LG" '$d'
run check-budget --update
if grep -qF "lowered" "$ROOT/out" && run check-budget; then ok "25 --update lowers, and stays green"; else bad "25 budget lower" "$(cat "$ROOT/out")"; fi
printf 'one two three\n' >> "$S/$LG"
red "26 the lowered budget holds the line" check-budget "$LG"
fresh; rm -r "$S/skills/crew/references"
red "26a no reference files at all fails before checking" check-budget "no *.md found — the lookup broke"
red "26d and --update doesn't drop their budgets" check-budget "no *.md found — the lookup broke" --update
if grep -qF "references/" "$S/baselines/budget.tsv"; then ok "26e the reference budgets are still there"; else bad "26e budgets kept" "$(cat "$S/baselines/budget.tsv")"; fi
cp -R "$REPO/skills/crew/references" "$S/skills/crew/"   # control for 26a, 26d, 26e: the same fixture, restored
green "26f with the references back, the kept budgets pass" check-budget
fresh; rm "$S/$LG"
red "26b a budgeted file that's gone fails" check-budget "$LG: budgeted but gone"
run check-budget --update                          # positive control for 26b: --update drops it
if grep -qF -- "- $LG: gone, budget dropped" "$ROOT/out" && run check-budget; then ok "26c --update drops a gone file's budget, then green"; else bad "26c gone file" "$(cat "$ROOT/out")"; fi

# --- check-content -------------------------------------------------------------------------------------------
fresh; printf '\nYou may skip this. It may help. You might try it. It could matter.\n' >> "$S/$SK"
red "27 weak markers lower instruction specificity" check-content "instruction_specificity fell"
red "28 --update never lowers a baseline" check-content "instruction_specificity fell" --update

# --- check-structure ------------------------------------------------------------------------------------------
fresh; printf 'scratch\n' > "$S/skills/crew/notes.txt"
red "29 a stray file at the skill root" check-structure "notes.txt"
fresh; run check-structure
if grep -qF "PR 3 removes this exemption" "$ROOT/out"; then ok "30 the exemption is printed on every run"; else bad "30 exemption" "$(cat "$ROOT/out")"; fi

# --- check-skill-frontmatter ----------------------------------------------------------------------------------
fresh; edit "$SK" '/^license: MIT$/d'
red "31 a missing license" check-skill-frontmatter "missing frontmatter: license"
# The line names "metadata" on purpose: an unanchored /metadata/ match would open the metadata block
# there, so 31b is what fails if the check's `^metadata:` anchor is lost.
fresh; edit "$SK" 's/^description: >-$/description: >-\
  author: a line in the description, and metadata mentioned/'
green "31b a description with its own author: line passes while metadata has one" check-skill-frontmatter
edit "$SK" '/^  author: Acatl Pacheco$/d'          # the same fixture, metadata's author removed
red "32 an author: line in the description doesn't stand in for metadata.author" check-skill-frontmatter "missing frontmatter: author"
fresh; edit "$SK" 's/^  author: Acatl Pacheco$/  author: Acatl Pacheco\
  links:\
    author: nested one level too deep/'
green "32b a nested author: beside the real one passes" check-skill-frontmatter
edit "$SK" '/^  author: Acatl Pacheco$/d'          # the same fixture, the real one removed
red "33 an author: nested under another metadata key doesn't count" check-skill-frontmatter "missing frontmatter: author"
fresh; edit "$SK" 's/^metadata:$/metadata:\
    # a comment, indented deeper than the keys/'
green "34 a comment opening metadata doesn't set the child indent" check-skill-frontmatter
edit "$SK" '/^  version: /d'                     # positive control for 34: the same fixture, a key removed
red "34b the same fixture still fails on a missing version" check-skill-frontmatter "missing frontmatter: version"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
