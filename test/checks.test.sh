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
  rm -rf "$S"; mkdir -p "$S/test" "$S/docs"
  cp -R "$REPO/skills" "$REPO/scripts" "$REPO/baselines" "$S/"
  cp -R "$REPO/docs/crew" "$REPO/docs/pr-round-workflow.md" "$S/docs/"
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
WS=skills/crew/references/workflow-standard.md
PR=docs/crew/workflows/pr.md
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
fresh; edit "$WS" 's#absent, 60 minutes#absent, 30 minutes#'
red "2  the minutes copy drifts" check-invariants "$WS"
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
# the workflow reaches a worker only through its brief: the Worker section never cites CREW.md
fresh; edit "$SK" 's@^### 0\. Resume from the ledger@Track `CREW.md` › Workflows per worker in the ledger.\
\
&@'
green "15b the orchestrator's sections may cite CREW.md" check-invariants
edit "$SK" "s#^7\. \*\*Loop budget:\*\* your workflow's Rules#7. **Loop budget:** your workflow's Rules (\`CREW.md\` › Workflows)#"   # same fixture
red "15c the Worker section citing CREW.md" check-invariants "the Worker section cites CREW.md"
fresh; edit "$SK" "s#^7\\. \\*\\*Loop budget:\\*\\* your workflow's Rules#7. **Loop budget:** your workflow's Rules (see CREW.md - Workflows)#"
red "15c2 and so does any other spelling of the citation" check-invariants "the Worker section cites CREW.md"
fresh; edit "$SK" "s#^7\\. \\*\\*Loop budget:\\*\\* your workflow's Rules#7. **Loop budget:** your workflow's Rules (docs/crew.md)#"
red "15c3 or case" check-invariants "the Worker section cites CREW.md"
fresh; edit "$SK" 's#any other plain `DONE` is a stop#any other is a stop#'
red "15cd the orchestrator stops reading a legacy plain DONE" check-invariants "older brief's DONE: 'plain \`DONE\` is a stop'"
fresh; edit "$SK" 's#From an older brief, `DONE · checkpoint: <boundary>` or#From an older brief,#'
red "15ce or the legacy checkpoint form" check-invariants "older brief's DONE: '\`DONE · checkpoint: <boundary>\`'"
fresh; edit "$BT" 's#Read `{WORKFLOW_PATH}` in full#Read the workflow in full#g'
red "15d the brief no longer pointing the worker at its workflow" check-invariants "$BT: the brief's Job no longer says"
fresh; edit "$BT" 's#^| `{WORKFLOW_PATH}` | its file, absolute: its `CREW.md` › Workflows#|  `{WORKFLOW_PATH}`  |  its file: `docs/CREW.md` › Workflows#'
green "15e a padded placeholder row naming docs/CREW.md still counts" check-invariants
edit "$BT" 's#`docs/CREW.md` › Workflows#`docs/CREW.md` › Ledger#'                  # same fixture
red "15f the row sourcing {WORKFLOW_PATH} from anything but Workflows" check-invariants "$BT: no placeholder row sourcing"
fresh; edit "$SK" "s#^   brief → your brief's Job/Spec, Boundaries and Checkpoints are the workflow; follow them as written\.#   brief → ask the orchestrator.#"
red "15ca the Worker section drops the line in-flight briefs rely on" check-invariants "lost the legacy line"
fresh; edit "$SK" 's#first line `checkpoint <stage>` or `stop <stage>`; branch#first line `checkpoint <stage>`; branch#'
red "15cb the Messages table drops DONE's stop form" check-invariants "the section headed '^### Messages' doesn't give DONE's \`stop <stage>\`"
fresh; edit "$BT" 's#^`checkpoint <stage>` or `stop <stage>`, with branch#a checkpoint or a stop, with branch#'
red "15cc the fallback drops DONE's stage form" check-invariants "the section headed '^#+ If the"
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
fresh; edit "$SK" 's#never send `ANSWER` or `RELAY` for `answer: in this session only`: nudge without#for `answer: in this session only`, nudge without#'
red "15o the orchestrator's guard drops out" check-invariants "the section headed '^#+ Orchestrator"
fresh; edit "$SK" 's#, a gated action or `answer: in this session only`\.#, or a gated action.#'
red "15p the worker's guard drops out" check-invariants "the section headed '^#+ Worker"
fresh; edit "$BT" 's#locked decision or `answer: in this session only`\.#locked decision.#'
red "15q the fallback's guard drops out" check-invariants "the section headed '^#+ If the"
fresh; edit "$SK" 's#never send `ANSWER` or `RELAY` for `answer: in this session only`: nudge without#send `ANSWER` or `RELAY` for `answer: in this session only` as usual: nudge without#'
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

# a merge go names its delegation: a sentence that tells the worker to merge names `landing:`
fresh; edit "$PR" 's#with no `landing: operator` on#with no `landing: delegated` on#'
red "15da a workflow gates the merge on the card's delegation alone" check-invariants "$PR: tells the worker to merge without naming"
fresh; edit docs/pr-round-workflow.md 's#unless the card says `landing: operator`, tells#tells#'
red "15db so does the round procedure" check-invariants "docs/pr-round-workflow.md: tells the worker to merge"
fresh; edit "$PR" 's#it tells the worker to merge by#it tells the worker to go by#'
edit docs/pr-round-workflow.md 's#, tells the worker to merge\.#, tells the worker to go.#'
red "15dc no merge sentence at all fails, never passes" check-invariants "a sentence that tells the worker to merge not found"
fresh; rm "$S/docs/pr-round-workflow.md"
red "15dd a missing round procedure is reported, not skipped" check-invariants "docs/pr-round-workflow.md: the file not found"
fresh; edit "$PR" 's#on the card (#on the card, per docs/CREW.md (#'
green "15de a dotted name inside the sentence doesn't split it" check-invariants
edit "$PR" 's#with no `landing: operator` on#with no `landing: delegated` on#'              # same fixture
red "15df and the same fixture still fires on a missing withhold" check-invariants "$PR: tells the worker to merge without naming"

# the queue card shows each unit's workflow and landing
fresh; edit "$SK" 's#^> | \# | Unit | Title | Workflow | Scope | Landing | Cleanup |#> | \# | Unit | Title | Workflow | Scope | Cleanup |#'
red "15dg the queue card loses its per-unit Landing" check-invariants "the queue card has no per-unit Landing column"
fresh; edit "$SK" 's#^> | \# | Unit | Title | Workflow | Scope | Landing | Cleanup |#> | \# | Unit | Title | Scope | Landing | Cleanup |#'
red "15dh or its Workflow" check-invariants "the queue card has no per-unit Workflow column"
# a workflow's verify falls back as the orchestrator's does
fresh; edit "$WS" 's#| `CREW.md` › Verify, else `docs/HARNESS.md` › Sensors, else asked |#| `CREW.md` › Verify |#'
red "15di a verify default that stops at CREW.md" check-invariants "$WS: the \`verify\` default falls back to"
fresh; edit "$PR" 's#| `CREW.md` › Verify, else `docs/HARNESS.md` › Sensors, else asked |#| `docs/HARNESS.md` › Sensors |#'
red "15dj a project workflow's too" check-invariants "$PR: the \`verify\` default falls back to"
fresh; edit "$SK" 's#^  `CREW.md` › Verify, else `docs/HARNESS.md` › Sensors, else ask)\.#  `CREW.md` › Verify, else ask).#'
red "15dk the orchestrator's chain changes and the workflows are named" check-invariants "$WS: the \`verify\` default falls back to"
fresh; edit "$WS" '/^| `verify` |/d'
red "15dl the built-in without a verify row is reported, not passed" check-invariants "the \`verify\` parameter row not found"
fresh; edit "$PR" '/^| `verify` |/d'
green "15dm a project workflow may leave verify out" check-invariants
edit "$WS" '/^| `verify` |/d'                                                            # same fixture
red "15dn but the same fixture fails once the built-in drops it" check-invariants "the \`verify\` parameter row not found"
# every brief state is handled on both sides: the brief template's {STATE} row is the source
fresh; edit "$SK" 's#^A brief marked `state=resume` is a resume#A resumed brief is a resume#'
red "15do the Worker section stops handling a resume" check-invariants "handles no brief state 'resume'"
fresh; edit "$SK" 's#the saved brief with `state=resume` in its#the saved brief with a resume flag in its#'
red "15dp so does the Orchestrator's resume" check-invariants "^#+ Orchestrator[[:space:]]*\$' handles no brief state 'resume'"
fresh; edit "$BT" 's#unless `resume`: then#unless resumed: then#'
red "15dq the brief's fallback stops telling a resume apart" check-invariants "the fallback section handles no brief state 'resume'"
fresh; edit "$BT" 's#^| `{STATE}` |#| `{STATUS}` |#'
red "15dr a reworded {STATE} row is reported, not passed" check-invariants "the {STATE} placeholder row not found"
fresh; edit "$BT" 's#^| `{STATE}` | `ready`, `queued`, or#| `{STATE}` | `ready`, `queued`, `paused`, or#'
edit "$SK" 's#^  `state: queued` → status `queued`\.#  `state: queued` or `state: paused` → status `queued`.#'
edit "$SK" 's#^A brief marked `state=resume` is a resume#A brief marked `state=resume` (not `state=paused`) is a resume#'
edit "$BT" 's#If queued, end your#If queued or paused, end your#'
green "15ds a new state handled in all three places passes" check-invariants
edit "$BT" 's#If queued or paused, end your#If queued, end your#'                           # same fixture
red "15dt and the same fixture fails once the fallback drops it" check-invariants "the fallback section handles no brief state 'paused'"

# --- check-section-refs ------------------------------------------------------------------------------------
fresh; printf '\nSee `CREW.md` › Nosuch for it.\n' >> "$S/$SK"
red "16 a CREW.md section that doesn't exist" check-section-refs "CREW.md › Nosuch"
fresh; printf '\nSee `CREW.md` › Integrations too.\n' >> "$S/$SK"
red "17 a heading's prefix is not the heading" check-section-refs "CREW.md › Integrations"
fresh; printf '\nRead `references/missing.md` first.\n' >> "$S/$SK"
red "18 a references/ file that doesn't exist" check-section-refs "references/missing.md"
fresh; printf '\nRun `<skill-dir>/scripts/gone.sh`.\n' >> "$S/$SK"
red "19 a skill script that doesn't exist" check-section-refs "<skill-dir>/scripts/gone.sh"

fresh; for f in "$SK" "$BT" "$LG" "$WS"; do edit "$f" 's#CREW\.md` ›#CREW.md` -#g'; done
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

# --- check-structure: the workflow files' shape ----------------------------------------------------------
fresh; edit "$WS" '/^- \*\*Ends:\*\* committed, `verify` green\.$/d'
red "35 a stage that names no end" check-structure "$WS:"
if grep -qF "stage build names no Ends" "$ROOT/out"; then ok "35b and the stage is named"; else bad "35b stage named" "$(cat "$ROOT/out")"; fi
fresh; edit "$WS" 's#^- \*\*Report:\*\* `checkpoint build`#- **Report:** `checkpoint plan`#'
red "36 a report naming another stage" check-structure "stage build: Report must be"
fresh; edit "$WS" 's#^- \*\*Report:\*\* `checkpoint build`#- **Report:** `stop build`#'
red "37 two stop stages" check-structure "2 stages report stop"
fresh; edit "$WS" 's#^- \*\*Report:\*\* `stop handoff`#- **Report:** `checkpoint handoff`#'
red "37b no stop stage" check-structure "0 stages report stop"
fresh; edit "$WS" 's#^\#\# Parameters$#\#\# Settings#'
red "38 a section missing" check-structure "needs ## Parameters, ## Stages, ## Rules"
fresh; edit "$WS" 's#^name: standard$#name: std#'
red "39 a name that isn't the file's" check-structure 'frontmatter name is "std"'
fresh; edit "$PR" '/^- \*\*Orchestrator:\*\* runs Post-land/d'
red "40 a project workflow is checked too" check-structure "$PR:"
fresh; rm "$S/$WS"
red "41 no built-in workflow fails, never passes" check-structure "no workflow-*.md"
fresh; edit "$WS" 's#^\#\#\# review$#```text\
\#\#\# not a stage\
```\
\
&#'
green "42 a heading-like line in a code fence is no stage" check-structure
edit "$WS" '/^- \*\*Ends:\*\* every valid finding fixed/d'                         # same fixture
red "42b the same fixture still fails on a stage with no end" check-structure "stage review names no Ends"

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
