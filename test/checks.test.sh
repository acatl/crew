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
# So every check is first run green on an untouched copy, and every case after that must turn it
# red AND name the file that drifted.
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
# edit <file> <sed expression>: in place through a temp file, since BSD and GNU sed -i disagree
edit() { sed "$2" "$S/$1" > "$S/$1.new" && mv "$S/$1.new" "$S/$1"; }
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
fresh; edit "$SK" 's#besides the four kinds#besides the three kinds#'
red "13 the worker rule miscounts the kinds" check-invariants "$SK"
fresh; edit "$LG" "s#sed 's\#/\#-\#g'#sed 's\#[/.]\#-\#g'#"
red "14 the crew-dir slug is unified with the transcript one" check-invariants "$LG"
fresh; edit test/watchdog.test.sh "s#^slug() { printf '%s' \"\$1\" | sed 's\#\[/.\]\#-\#g'; }#slug() { printf '%s' \"\$1\" | sed 's\#/\#-\#g'; }#"
red "15 the test's slug drifts from the watchdog's" check-invariants "test/watchdog.test.sh"

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
