#!/usr/bin/env bash
# Tests for watchdog.sh. Builds a throwaway repo, crew dir and fake transcript tree under a
# sandboxed $HOME, so it touches nothing real. Run it after any change:
#
#   ~/.claude/skills/crew/watchdog.test.sh
#
# The portability branch cannot be covered here: a machine has one stat(1) flavour, so whichever
# branch this machine does not use ships code-reviewed, not tested.
#
# Reading a "stays silent" assertion: silence alone is weak evidence — a watchdog that is blind for
# a mechanical reason is also silent. Every `silent` call below is therefore PAIRED with a positive
# control on the same fixture: a later assertion crosses the threshold and must fire. Never add a
# `silent` assertion without its pair.
set -u
WD="$(cd "$(dirname "$0")" && pwd)/watchdog.sh"
ROOT=$(mktemp -d)
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s — %s\n' "$1" "$2"; }

# Kill anything still running, and keep the sandbox when something failed so evidence survives.
finish() {
  local j; j=$(jobs -p 2>/dev/null)
  # shellcheck disable=SC2086  # word splitting is the point: one kill per job
  if [ -n "$j" ]; then kill $j 2>/dev/null; fi
  if [ "$fail" = 0 ]; then rm -rf "$ROOT"; else printf 'sandbox kept: %s\n' "$ROOT"; fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export HOME="$ROOT/home"            # sandbox the transcript lookup
CREW="$HOME/.claude/crew/proj"
WT="$ROOT/wt"
WT2="$ROOT/wt2"
mkdir -p "$CREW" "$WT" "$WT2"
slug() { printf '%s' "$1" | sed 's#[/.]#-#g'; }
PROJ="$HOME/.claude/projects/$(slug "$WT")"
PROJ2="$HOME/.claude/projects/$(slug "$WT2")"
mkdir -p "$PROJ/sess/subagents" "$PROJ2/sess/subagents"

for d in "$WT" "$WT2"; do
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
done

commit_in()  { local d="@$(( $(date +%s) - $2 )) +0000"
               echo x >> "$1/f"; git -C "$1" add f
               GIT_COMMITTER_DATE="$d" GIT_AUTHOR_DATE="$d" git -C "$1" commit -qm c; }
seed_commit(){ commit_in "$WT" "$1"; }
active()     { : > "$PROJ/sess.jsonl"; }
# push every transcript outside the script's fixed 900s activity window
stale_stamp(){ date -v-30M +%Y%m%d%H%M 2>/dev/null || date -d '30 minutes ago' +%Y%m%d%H%M; }
go_quiet()   { find "$PROJ" -name '*.jsonl' -exec touch -t "$(stale_stamp)" {} +; }
subagents()  { local i; rm -f "$PROJ"/sess/subagents/*.jsonl
               for ((i=1;i<=$1;i++)); do : > "$PROJ/sess/subagents/a$i.jsonl"; done; }
roster1()    { printf '#1\t%s\n' "$WT" > "$CREW/roster.tsv"; }
reset()      { rm -f "$CREW/reported.txt" "$CREW/watchdog.pid"; touch "$CREW/reported.txt"; }
# Trigger 1 needs an OLD head; a fresh commit makes it structurally impossible. Preferred over
# pre-seeding a reported.txt key, which coupled the suite to that key's exact format.
silence_t1() { commit_in "$WT" 0; }

# run to completion, capped so a case that should fire but doesn't fails instead of hanging
run() {
  "$WD" --base main --no-commit 60 --interval 1 "$@" "$CREW" >"$ROOT/out" 2>"$ROOT/err" &
  local p=$! i=0
  while kill -0 "$p" 2>/dev/null && [ $i -lt 8 ]; do sleep 1; i=$((i+1)); done
  if kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 99; fi
  wait "$p" 2>/dev/null; return $?
}
# 0 when it was still running after a few passes. ALWAYS pair with a positive control.
silent() {
  "$WD" --base main --no-commit 60 --interval 1 "$@" "$CREW" >"$ROOT/out" 2>"$ROOT/err" &
  local p=$!; sleep 3
  if kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 0; fi
  wait "$p" 2>/dev/null; return 1
}

seed_commit 7200; active; subagents 0; roster1; reset

# --- startup errors -------------------------------------------------------------------------------
"$WD" --base main "$ROOT/nope" >/dev/null 2>"$ROOT/err"; rc=$?
if [ "$rc" = 2 ] && grep -q "no such crew dir" "$ROOT/err"
then ok "1  missing crew dir -> 2"; else bad "1  missing crew dir" "rc=$rc $(cat "$ROOT/err")"; fi

mv "$CREW/roster.tsv" "$ROOT/keep"
"$WD" --base main "$CREW" >/dev/null 2>"$ROOT/err"; rc=$?
if [ "$rc" = 2 ] && grep -q "no roster" "$ROOT/err"
then ok "2  missing roster -> 2"; else bad "2  missing roster" "rc=$rc $(cat "$ROOT/err")"; fi
mv "$ROOT/keep" "$CREW/roster.tsv"

for f in --interval --no-commit --subagent-step; do
  "$WD" --base main "$f" abc "$CREW" >/dev/null 2>"$ROOT/err"; rc=$?
  if [ "$rc" = 2 ] && grep -q "whole number" "$ROOT/err"
  then ok "3  non-numeric $f -> 2"; else bad "3  non-numeric $f" "rc=$rc $(cat "$ROOT/err")"; fi
done

for args in "" "--base" "--nope x" "$CREW extra"; do
  # shellcheck disable=SC2086
  "$WD" $args >/dev/null 2>"$ROOT/err"; rc=$?
  if [ "$rc" = 2 ] && grep -q "usage:" "$ROOT/err"
  then ok "4  bad args [$args] -> 2"; else bad "4  bad args [$args]" "rc=$rc $(cat "$ROOT/err")"; fi
done

# A value reaching `sleep` or an arithmetic context must be validated whole and normalised.
# 0 made `sleep` return instantly and the loop spin silently at full tilt; a ':' slipped past a
# prefix check; a leading zero made 0600 octal (384s) and 08 a fatal arithmetic error.
for v in 0 "5:00" 99999999999999999999; do
  "$WD" --base main --interval "$v" "$CREW" >/dev/null 2>"$ROOT/err"; rc=$?
  if [ "$rc" = 2 ]
  then ok "4b --interval $v rejected"; else bad "4b --interval $v" "rc=$rc $(cat "$ROOT/err")"; fi
done

# --- trigger 1: active but not committing -----------------------------------------------------------
reset
run; rc=$?
if [ "$rc" = 0 ] && grep -q "WATCHDOG #1: active but no commit" "$ROOT/out"
then ok "5  no-commit trigger -> 0 + line"; else bad "5  no-commit trigger" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

if [ "$(wc -l < "$ROOT/out" | tr -d ' ')" = 1 ]
then ok "6  exactly one line on stdout"; else bad "6  one line" "got $(wc -l < "$ROOT/out" | tr -d ' ')"; fi

# the dedupe key must reach disk — test 8's silence only means something if it did
if grep -q "^#1 nocommit $(git -C "$WT" rev-parse --short HEAD)" "$CREW/reported.txt"
then ok "7  dedupe key written to reported.txt"; else bad "7  dedupe key" "$(cat "$CREW/reported.txt")"; fi

if silent
then ok "8  relaunch does not re-fire (paired with 5)"; else bad "8  no re-fire" "fired: $(cat "$ROOT/out")"; fi

seed_commit 7200                                 # the key carries the head sha, so a new commit re-arms
run; rc=$?
if [ "$rc" = 0 ] && grep -q "WATCHDOG #1: active but no commit" "$ROOT/out"
then ok "9  a new head re-arms the dedupe"; else bad "9  new head re-arms" "rc=$rc $(cat "$ROOT/out")"; fi

# A stuck worker does not commit, so keying on the head alone would mean ONE alert ever. The key
# also carries the elapsed --no-commit window, so it re-arms once per window at an unchanged head.
reset; seed_commit 5; active
head_before=$(git -C "$WT" rev-parse --short HEAD)
"$WD" --base main --no-commit 2 --interval 1 "$CREW" >"$ROOT/out" 2>"$ROOT/err"; rc=$?
sleep 3                                          # cross into the next window, same head
"$WD" --base main --no-commit 2 --interval 1 "$CREW" >"$ROOT/out2" 2>>"$ROOT/err"; rc2=$?
if [ "$rc" = 0 ] && [ "$rc2" = 0 ] && [ "$head_before" = "$(git -C "$WT" rev-parse --short HEAD)" ]
then ok "9b re-arms once per no-commit window at an unchanged head"
else bad "9b window re-arm" "rc=$rc rc2=$rc2 $(cat "$ROOT/out" "$ROOT/out2")"; fi
seed_commit 7200

# the 900s activity gate: an old commit is not reported once the worker stops writing
reset; go_quiet
if silent
then ok "10 stale worker is not reported (activity gate)"; else bad "10 activity gate" "fired: $(cat "$ROOT/out")"; fi
active                                           # positive control for 10, same fixture
run; rc=$?
if [ "$rc" = 0 ]
then ok "11 same fixture fires once it writes again"; else bad "11 activity-gate control" "rc=$rc"; fi

# a repo with no commits must not fire or crash
reset; mkdir -p "$ROOT/empty"; git -C "$ROOT/empty" init -q -b main
mkdir -p "$HOME/.claude/projects/$(slug "$ROOT/empty")"
: > "$HOME/.claude/projects/$(slug "$ROOT/empty")/s.jsonl"
printf '#3\t%s\n' "$ROOT/empty" > "$CREW/roster.tsv"
if silent
then ok "12 repo with no commits -> no fire, no crash"; else bad "12 empty repo" "$(cat "$ROOT/out" "$ROOT/err")"; fi
if [ "$(grep -c "no HEAD in" "$ROOT/err" | tr -d ' ')" = 1 ]
then ok "12b and says once that it is unwatched"; else bad "12b empty-repo warning" "$(cat "$ROOT/err")"; fi

# A roster row whose worktree is gone used to be dropped in total silence.
reset; printf '#4\t%s\n' "$ROOT/vanished" > "$CREW/roster.tsv"
if silent && grep -q "no worktree at .* for #4" "$ROOT/err"
then ok "12c missing worktree is warned, not silently dropped"; else bad "12c missing worktree" "$(cat "$ROOT/err")"; fi

# A ticket id with whitespace would break the awk dedupe and re-fire forever; reject the row.
reset; printf 'A B\t%s\n' "$WT" > "$CREW/roster.tsv"
if silent && grep -q "whitespace" "$ROOT/err"
then ok "12d whitespace in a ticket id is rejected"; else bad "12d whitespace id" "$(cat "$ROOT/err")"; fi
roster1

# --- built-in defaults -------------------------------------------------------------------------------
reset; active
"$WD" --base main --interval 1 "$CREW" >"$ROOT/out" 2>"$ROOT/err" &
p=$!; i=0; while kill -0 "$p" 2>/dev/null && [ $i -lt 8 ]; do sleep 1; i=$((i+1)); done
if kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; rc=99; else wait "$p" 2>/dev/null; rc=$?; fi
if [ "$rc" = 0 ] && grep -q "WATCHDOG #1" "$ROOT/out"
then ok "13 default --no-commit 3600 applies"; else bad "13 default no-commit" "rc=$rc $(cat "$ROOT/out")"; fi

# --- single instance ---------------------------------------------------------------------------------
reset; silence_t1
"$WD" --base main --no-commit 60 --interval 30 "$CREW" >"$ROOT/holder.out" 2>&1 &
holder=$!; sleep 2
if [ "$(cat "$CREW/watchdog.pid" 2>/dev/null)" = "$holder" ]
then ok "14 pidfile holds the running pid"; else bad "14 pidfile contents" "want $holder got $(cat "$CREW/watchdog.pid" 2>/dev/null)"; fi

"$WD" --base main --no-commit 60 --interval 1 "$CREW" >/dev/null 2>"$ROOT/err"; rc=$?
if [ "$rc" = 3 ] && grep -q "already running" "$ROOT/err"
then ok "15 second watchdog -> 3"; else bad "15 second watchdog" "rc=$rc $(cat "$ROOT/err")"; fi

if [ "$(cat "$CREW/watchdog.pid" 2>/dev/null)" = "$holder" ]
then ok "16 a refused start leaves the holder's pidfile intact"; else bad "16 pidfile after refusal" "$(cat "$CREW/watchdog.pid" 2>/dev/null)"; fi

if ! grep -q WATCHDOG "$ROOT/holder.out"
then ok "17 holder still silent"; else bad "17 holder unaffected" "holder fired: $(cat "$ROOT/holder.out")"; fi

kill "$holder" 2>/dev/null; s=0
while kill -0 "$holder" 2>/dev/null && [ $s -lt 5 ]; do sleep 1; s=$((s+1)); done
wait "$holder" 2>/dev/null; hrc=$?
if [ "$s" -lt 3 ]
then ok "18 TERM lands mid-sleep (${s}s, interval 30)"; else bad "18 prompt TERM" "took ${s}s"; fi
if [ "$hrc" = 143 ]
then ok "19 signal exit is 143, not 0"; else bad "19 signal exit" "rc=$hrc"; fi
if [ ! -f "$CREW/watchdog.pid" ]
then ok "20 pidfile cleaned after TERM"; else bad "20 pidfile after TERM" "still present"; fi

reset; silence_t1; echo 999999 > "$CREW/watchdog.pid"
"$WD" --base main --no-commit 60 --interval 30 "$CREW" >/dev/null 2>"$ROOT/err" &
p=$!; sleep 2
if [ "$(cat "$CREW/watchdog.pid" 2>/dev/null)" = "$p" ]
then ok "21 stale pidfile reclaimed and overwritten"; else bad "21 stale pidfile" "want $p got $(cat "$CREW/watchdog.pid" 2>/dev/null) $(cat "$ROOT/err")"; fi
kill "$p" 2>/dev/null; wait "$p" 2>/dev/null

# --- trigger 2: the growth floor ----------------------------------------------------------------------
reset; silence_t1; active
subagents 3
if silent
then ok "22 at the floor -> silent"; else bad "22 at floor" "fired: $(cat "$ROOT/out")"; fi

subagents 4
run; rc=$?
if [ "$rc" = 0 ] && grep -q "4 sub-agents since last push" "$ROOT/out"
then ok "23 past the floor -> fires"; else bad "23 past floor" "rc=$rc $(cat "$ROOT/out")"; fi

subagents 6
if silent
then ok "24 growth floor holds after an alert"; else bad "24 growth floor" "fired: $(cat "$ROOT/out")"; fi

subagents 8
run; rc=$?
if [ "$rc" = 0 ] && grep -q "was 4 at last alert" "$ROOT/out"
then ok "25 growth past the new floor -> fires"; else bad "25 growth past floor" "rc=$rc $(cat "$ROOT/out")"; fi

# The threshold is a sub-agent count, so it must be stated as one. It read "budget ≈ 3 review
# passes" once, from --subagent-step, which is the wrong unit: a review spawns more than one.
if grep -q "threshold +3" "$ROOT/out" && ! grep -q "review passes" "$ROOT/out"
then ok "26 threshold stated in sub-agents, not reviews"; else bad "26 threshold unit" "$(cat "$ROOT/out")"; fi

reset; silence_t1; subagents 1
if silent --subagent-step 1
then ok "27 --subagent-step 1, at the floor -> silent"; else bad "27 step flag silent" "fired: $(cat "$ROOT/out")"; fi
subagents 2
run --subagent-step 1; rc=$?
if [ "$rc" = 0 ] && grep -q "threshold +1" "$ROOT/out"
then ok "28 --subagent-step 1, past it -> fires"; else bad "28 step flag fires" "rc=$rc $(cat "$ROOT/out")"; fi

# A leading zero must be decimal, not octal, and must not be a fatal arithmetic error.
reset; silence_t1; sleep 1; subagents 9
run --subagent-step 08; rc=$?
if [ "$rc" = 0 ] && grep -q "threshold +8" "$ROOT/out"
then ok "28b leading zero is decimal, not octal"; else bad "28b leading zero" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

# With no resolvable push baseline, counting from 0 would mean "every sub-agent that ever existed" —
# the absolute count the growth floor exists to replace. Skip the worker and say so instead.
reset; seed_commit 0; active; subagents 20
if silent --base no-such-ref
then ok "28c no push baseline -> does not fire"; else bad "28c no baseline" "fired: $(cat "$ROOT/out")"; fi
if grep -q "no push baseline for #1" "$ROOT/err"
then ok "28d and says trigger 2 is off for it"; else bad "28d no-baseline warning" "$(cat "$ROOT/err")"; fi
seed_commit 7200

# a push moves the baseline, so sub-agents older than it stop counting
reset; silence_t1; subagents 8
git init -q --bare "$ROOT/bare.git"
git -C "$WT" remote add origin "$ROOT/bare.git"
git -C "$WT" push -q origin main
if silent
then ok "29 a push re-baselines trigger 2"; else bad "29 push re-baseline" "fired: $(cat "$ROOT/out")"; fi
sleep 1; subagents 8                             # recreated strictly after the push
run; rc=$?
if [ "$rc" = 0 ] && grep -q "8 sub-agents since last push" "$ROOT/out"
then ok "30 sub-agents after the push do count"; else bad "30 post-push count" "rc=$rc $(cat "$ROOT/out")"; fi
git -C "$WT" remote remove origin

# --- several workers ----------------------------------------------------------------------------------
reset; subagents 0; seed_commit 7200; commit_in "$WT2" 7200; : > "$PROJ2/sess.jsonl"; active
printf '#1\t%s\n#2\t%s\n' "$WT" "$WT2" > "$CREW/roster.tsv"
run; rc=$?
first=$(sed -n 's/^WATCHDOG \(#[0-9]*\).*/\1/p' "$ROOT/out")
if [ "$rc" = 0 ] && [ -n "$first" ]
then ok "31 one of two stalled workers fires"; else bad "31 two workers" "rc=$rc $(cat "$ROOT/out")"; fi
run; rc=$?
second=$(sed -n 's/^WATCHDOG \(#[0-9]*\).*/\1/p' "$ROOT/out")
if [ "$rc" = 0 ] && [ -n "$second" ] && [ "$second" != "$first" ]
then ok "32 the other fires next, so dedupe is per ticket"; else bad "32 per-ticket dedupe" "first=$first second=$second rc=$rc"; fi
roster1

# --- roster handling ------------------------------------------------------------------------------------
reset; subagents 0; : > "$CREW/roster.tsv"
if silent
then ok "33 empty roster -> keeps sleeping"; else bad "33 empty roster" "exited: $(cat "$ROOT/err")"; fi
if [ ! -s "$ROOT/err" ]
then ok "34 an empty roster is not an error"; else bad "34 empty roster stderr" "$(cat "$ROOT/err")"; fi
roster1
run; rc=$?                                       # positive control for 33/34
if [ "$rc" = 0 ]
then ok "35 same fixture fires once the roster has a row"; else bad "35 empty-roster control" "rc=$rc"; fi

# the roster vanishing mid-run must idle, not exit — an exit would wake the orchestrator for nothing
reset; silence_t1; subagents 0
"$WD" --base main --no-commit 60 --interval 1 "$CREW" >"$ROOT/out" 2>"$ROOT/err" &
p=$!; sleep 1; rm -f "$CREW/roster.tsv"; sleep 3
if kill -0 "$p" 2>/dev/null
then ok "36 roster removed mid-run -> idles"; else bad "36 roster removed mid-run" "exited: $(cat "$ROOT/out" "$ROOT/err")"; fi
if [ "$(grep -c "roster gone" "$ROOT/err" | tr -d ' ')" = 1 ]
then ok "37 it says so once, not every pass"; else bad "37 roster-gone warning" "$(grep -c "roster gone" "$ROOT/err" | tr -d ' ') times"; fi
kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; roster1; seed_commit 7200

reset; printf '#1\t%s\tnote\n' "$WT" > "$CREW/roster.tsv"
run; rc=$?
if [ "$rc" = 0 ] && grep -q "WATCHDOG #1" "$ROOT/out"
then ok "38 extra roster column ignored"; else bad "38 extra column" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

reset; printf '#1\t%s' "$WT" > "$CREW/roster.tsv"
run; rc=$?
if [ "$rc" = 0 ] && grep -q "WATCHDOG #1" "$ROOT/out"
then ok "39 unterminated last line is read"; else bad "39 unterminated line" "rc=$rc $(cat "$ROOT/out")"; fi

reset; : > "$CREW/roster.tsv"
"$WD" --base main --no-commit 60 --interval 1 "$CREW" >"$ROOT/out" 2>"$ROOT/err" &
p=$!; sleep 2
printf '#1\t%s\n' "$WT" > "$ROOT/t.tsv"; mv "$ROOT/t.tsv" "$CREW/roster.tsv"   # write-then-mv
i=0; while kill -0 "$p" 2>/dev/null && [ $i -lt 6 ]; do sleep 1; i=$((i+1)); done
if kill -0 "$p" 2>/dev/null; then
  kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
  bad "40 roster picked up mid-run" "still silent after the roster gained a stalled worker"
else
  wait "$p" 2>/dev/null
  if grep -q "WATCHDOG #1" "$ROOT/out"
  then ok "40 roster picked up mid-run, no restart"; else bad "40 roster mid-run" "no line: $(cat "$ROOT/out")"; fi
fi

# --- a worker with no transcript dir is unwatched, and must say so ---------------------------------------
reset; printf '#9\t%s\n' "$WT2" > "$CREW/roster.tsv"
mv "$PROJ2" "$ROOT/hidden"
if silent
then ok "41 unwatched worker does not fire"; else bad "41 unwatched worker" "$(cat "$ROOT/out" "$ROOT/err")"; fi
if [ "$(grep -c "no transcript dir for #9" "$ROOT/err" | tr -d ' ')" = 1 ]
then ok "42 warned once on stderr, not every pass"; else bad "42 unwatched warning" "$(cat "$ROOT/err")"; fi
mv "$ROOT/hidden" "$PROJ2"
run; rc=$?                                       # positive control for 41
if [ "$rc" = 0 ] && grep -q "WATCHDOG #9" "$ROOT/out"
then ok "43 it fires once the transcript dir is back"; else bad "43 unwatched control" "rc=$rc $(cat "$ROOT/out")"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
