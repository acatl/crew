#!/usr/bin/env bash
# Tests for watchdog.sh. Builds a throwaway repo, crew dir and fake transcript tree under a
# sandboxed $HOME, so it touches nothing real. Run it after any change:
#
#   test/watchdog.test.sh
#
# A machine has one stat(1) flavour, so a local run covers only its own branch of the portability
# probe. CI runs this suite on macOS (BSD) and Linux (GNU), which covers both.
#
# Reading a "stays silent" assertion: silence alone is weak evidence — a watchdog that is blind for
# a mechanical reason is also silent. Every `silent` call below is therefore PAIRED with a positive
# control on the same fixture: a later assertion crosses the threshold and must fire. Never add a
# `silent` assertion without its pair.
set -u
WD="$(cd "$(dirname "$0")/.." && pwd)/skills/crew/scripts/watchdog.sh"
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
reset()      { rm -f "$CREW/reported.txt" "$CREW/watchdog.pid"; touch "$CREW/reported.txt"; watched; }
# watched: the watchdog has watched every worker this suite uses active for a day, unbroken, so
# HEAD's clock rules and a trigger-1 case means what it did before the active clock existed. Rows
# are keyed by ticket and worktree, and a pass prunes those off the roster, so a case that changes
# the roster calls this again.
watched()    { local n; n=$(date +%s)
               printf '%s\t%s\t%s\t%s\n' '#1' "$WT" $((n - 86400)) "$n" '#2' "$WT2" $((n - 86400)) "$n" \
                 '#3' "$ROOT/empty" $((n - 86400)) "$n" '#4' "$ROOT/vanished" $((n - 86400)) "$n" \
                 '#9' "$WT2" $((n - 86400)) "$n" 'AB' "$WT" $((n - 86400)) "$n" > "$CREW/active.tsv"; }
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
run --no-commit 2; rc=$?                         # its idle pass restarted the clock
if [ "$rc" = 0 ] && grep -q "since it went active" "$ROOT/out"
then ok "11 same fixture fires once it has been active past --no-commit"; else bad "11 activity-gate control" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

# a repo with no commits must not fire or crash
reset; mkdir -p "$ROOT/empty"; git -C "$ROOT/empty" init -q -b main
mkdir -p "$HOME/.claude/projects/$(slug "$ROOT/empty")"
: > "$HOME/.claude/projects/$(slug "$ROOT/empty")/s.jsonl"
printf '#3\t%s\n' "$ROOT/empty" > "$CREW/roster.tsv"
if silent
then ok "12 repo with no commits -> no fire, no crash"; else bad "12 empty repo" "$(cat "$ROOT/out" "$ROOT/err")"; fi
if [ "$(grep -c "no HEAD in" "$ROOT/err" | tr -d ' ')" = 1 ]
then ok "12b and says once that it is unwatched"; else bad "12b empty-repo warning" "$(cat "$ROOT/err")"; fi
git -C "$ROOT/empty" config user.email t@t; git -C "$ROOT/empty" config user.name t
commit_in "$ROOT/empty" 7200                     # positive control for 12: the same repo, now committed
run; rc=$?
if [ "$rc" = 0 ] && grep -q "WATCHDOG #3: active but no commit" "$ROOT/out"
then ok "12e same repo fires once it has a stale commit"; else bad "12e empty-repo control" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

# A roster row whose worktree is gone used to be dropped in total silence.
reset; printf '#4\t%s\n' "$ROOT/vanished" > "$CREW/roster.tsv"
if silent && grep -q "no worktree at .* for #4" "$ROOT/err"
then ok "12c missing worktree is warned, not silently dropped"; else bad "12c missing worktree" "$(cat "$ROOT/err")"; fi
git clone -q "$WT" "$ROOT/vanished"              # positive control for 12c: the worktree is back
mkdir -p "$HOME/.claude/projects/$(slug "$ROOT/vanished")"; : > "$HOME/.claude/projects/$(slug "$ROOT/vanished")/s.jsonl"
run; rc=$?
if [ "$rc" = 0 ] && grep -q "WATCHDOG #4: active but no commit" "$ROOT/out"
then ok "12f same row fires once its worktree exists"; else bad "12f missing-worktree control" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

# A ticket id with whitespace would break the awk dedupe and re-fire forever; reject the row.
reset; printf 'A B\t%s\n' "$WT" > "$CREW/roster.tsv"
if silent && grep -q "whitespace" "$ROOT/err"
then ok "12d whitespace in a ticket id is rejected"; else bad "12d whitespace id" "$(cat "$ROOT/err")"; fi
watched; printf 'AB\t%s\n' "$WT" > "$CREW/roster.tsv"   # positive control for 12d: same worktree, valid id
run; rc=$?
if [ "$rc" = 0 ] && grep -q "WATCHDOG AB: active but no commit" "$ROOT/out"
then ok "12g same worktree fires under a valid id"; else bad "12g whitespace-id control" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi
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
sleep 1; subagents 3                             # born after the baseline commit, so all 3 count
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

reset; silence_t1; sleep 1; subagents 1        # born after the baseline commit, so it counts
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
sleep 1; subagents 20                            # positive control for 28c: a resolvable base counts them
run; rc=$?
if [ "$rc" = 0 ] && grep -q "20 sub-agents since last push" "$ROOT/out"
then ok "28e same fixture fires once the base resolves"; else bad "28e no-baseline control" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi
seed_commit 7200

# a push moves the baseline, so sub-agents from before it stop counting, including those between the
# commit and the push: that is a worker's self-review. The baseline is when the push happened, so the
# gaps below keep commit, sub-agents and push in separate seconds; timed from the commit instead, or
# from the merge-base fallback, these 8 would count.
reset; silence_t1; sleep 1; subagents 8; sleep 1
git init -q --bare "$ROOT/bare.git"
git -C "$WT" remote add origin "$ROOT/bare.git"
git -C "$WT" push -q origin main
if silent
then ok "29 a push re-baselines trigger 2, from when it was pushed"; else bad "29 push re-baseline" "fired: $(cat "$ROOT/out")"; fi
sleep 1; subagents 8                             # recreated strictly after the push
run; rc=$?
if [ "$rc" = 0 ] && grep -q "8 sub-agents since last push" "$ROOT/out"
then ok "30 sub-agents after the push do count"; else bad "30 post-push count" "rc=$rc $(cat "$ROOT/out")"; fi

# a second push re-baselines from itself: the newest push in the reflog, not the first
commit_in "$WT" 0; sleep 1; git -C "$WT" push -q origin main
reset; sleep 1; subagents 4
run; rc=$?
if [ "$rc" = 0 ] && grep -q "4 sub-agents since last push (first alert" "$ROOT/out"
then ok "30b a second push re-baselines from itself"; else bad "30b second push" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

# a fetch moves origin/<branch> too, but it is not this worker's push: its sub-agents still count
reset; sleep 1; subagents 4; sleep 1
git clone -q -b main "$ROOT/bare.git" "$ROOT/other"
git -C "$ROOT/other" config user.email t@t; git -C "$ROOT/other" config user.name t
git -C "$ROOT/other" config commit.gpgsign false
echo y >> "$ROOT/other/g"; git -C "$ROOT/other" add g; git -C "$ROOT/other" commit -qm other
git -C "$ROOT/other" push -q origin main; git -C "$WT" fetch -q origin
run; rc=$?
if [ "$rc" = 0 ] && grep -q "4 sub-agents since last push (first alert" "$ROOT/out"
then ok "30c a fetch doesn't re-baseline trigger 2"; else bad "30c fetch" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

# An alert keyed by the pushed commit's time, as before push times came from the reflog, still
# suppresses the same push's count.
git -C "$WT" pull -q --no-rebase origin main; commit_in "$WT" 0; reset; sleep 1; git -C "$WT" push -q origin main
sleep 1; subagents 8
printf '#1 subs %s 8\n' "$(git -C "$WT" log -1 --format=%ct origin/main)" > "$CREW/reported.txt"
if silent
then ok "30d an alert keyed by the commit's time still stands for its push"; else bad "30d old subs key" "fired: $(cat "$ROOT/out")"; fi
: > "$CREW/reported.txt"
run; rc=$?                                       # positive control for 30d
if [ "$rc" = 0 ] && grep -q "8 sub-agents since last push (first alert" "$ROOT/out"
then ok "30e same fixture fires once that key is gone"; else bad "30e old-key control" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

# No push in the reflog (core.logAllRefUpdates off): count from the pushed commit's time, and say so.
# A newer, unpushed commit separates that from the merge-base fallback, which would count none.
git -C "$WT" remote remove origin; git init -q --bare "$ROOT/bare2.git"; git -C "$WT" remote add origin "$ROOT/bare2.git"
reset; silence_t1; git -C "$WT" -c core.logAllRefUpdates=false push -q origin main
sleep 1; subagents 4; sleep 1; commit_in "$WT" 0
run; rc=$?
if [ "$rc" = 0 ] && grep -q "4 sub-agents since last push" "$ROOT/out" \
   && grep -q "no push in origin/main's reflog for #1" "$ROOT/err"
then ok "30f without a push in the reflog it counts from the pushed commit, and warns"; else bad "30f no reflog" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi
subagents 0
git -C "$WT" remote remove origin

# The last alert is a number even when reported.txt is gone: BSD awk exits 2 on a missing file
# without running END, and the empty string it printed broke `[ "$last" -gt 0 ]` and skipped the
# older-key lookup (seen in hg, 2026-10-01, after reported.txt was deleted under a live watchdog).
# GNU awk runs END anyway, so only a BSD run (macOS CI) can fail this case on the old code.
reset; silence_t1; active; sleep 1; subagents 3          # at the floor: silent until it grows
"$WD" --base main --no-commit 60 --interval 1 "$CREW" >"$ROOT/out" 2>"$ROOT/err" &
p=$!; sleep 2; rm -f "$CREW/reported.txt"; subagents 4
i=0; while kill -0 "$p" 2>/dev/null && [ $i -lt 8 ]; do sleep 1; i=$((i+1)); done
if kill -0 "$p" 2>/dev/null; then
  kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
  bad "30g reported.txt deleted mid-run" "still silent after growth past the floor"
else
  wait "$p" 2>/dev/null
  if grep -q "4 sub-agents since last push (first alert" "$ROOT/out" && ! grep -q "integer expression" "$ROOT/err"
  then ok "30g reported.txt deleted mid-run -> a first alert, no shell error"
  else bad "30g reported.txt deleted mid-run" "$(cat "$ROOT/out" "$ROOT/err")"; fi
fi
# Another ticket's key at the same push is not this worker's last alert ...
reset; silence_t1; active; sleep 1; subagents 4
printf '#2 subs %s 4\n' "$(git -C "$WT" log -1 --format=%ct)" > "$CREW/reported.txt"
run; rc=$?
if [ "$rc" = 0 ] && grep -q "4 sub-agents since last push (first alert" "$ROOT/out" && ! grep -q "integer expression" "$ROOT/err"
then ok "30h another ticket's key -> a first alert"; else bad "30h other ticket's key" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi
# ... and its own key is (positive control for 30g and 30h: the lookup does find a match).
printf '#1 subs %s 4\n' "$(git -C "$WT" log -1 --format=%ct)" > "$CREW/reported.txt"
subagents 8
run; rc=$?
if [ "$rc" = 0 ] && grep -q "8 sub-agents since last push (was 4 at last alert" "$ROOT/out"
then ok "30i its own key -> was 4 at last alert"; else bad "30i own key" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi
subagents 0

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
roster1                                          # an empty roster prunes no clock
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
"$WD" --base main --no-commit 2 --interval 1 "$CREW" >"$ROOT/out" 2>"$ROOT/err" &   # its clock starts on arrival
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

# --- trigger 1's clock: HEAD's commit or the start of the worker's active stretch -------------------------
# Counting from HEAD alone fired at spawn for a worker on an old base (seen live, 2026-09-25: 107 min),
# and again for one that waited overnight on the operator (2026-09-26: 1153 min).
reset; roster1; subagents 0; seed_commit 7200; go_quiet
"$WD" --base main --no-commit 60 --interval 1 "$CREW" >"$ROOT/out" 2>"$ROOT/err" &
p=$!; i=0                                        # wait for a pass that sees it idle and ends its stretch
while grep -q "^#1	" "$CREW/active.tsv" && [ $i -lt 40 ]; do sleep 0.25; i=$((i+1)); done
active; sleep 3                                  # then passes see it active
if kill -0 "$p" 2>/dev/null
then ok "44 idle for hours, then active -> silent"; else bad "44 idle then active" "fired: $(cat "$ROOT/out")"; fi
kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
since=$(awk -F'\t' '$1 == "#1" {print $3}' "$CREW/active.tsv")
case "$since" in ''|*[!0-9]*) since=0 ;; esac          # a non-number must fail the case, not abort it
if [ "$since" -gt 0 ] && [ $(( $(date +%s) - since )) -lt 60 ]
then ok "45 its clock starts when it went active, not a day ago"; else bad "45 stretch start" "$(cat "$CREW/active.tsv")"; fi
run --no-commit 2; rc=$?                         # positive control for 44: the same fixture, past it
if [ "$rc" = 0 ] && grep -q "WATCHDOG #1: active but no commit for 0 min since it went active" "$ROOT/out"
then ok "46 same fixture fires once it has been active past --no-commit"; else bad "46 stretch control" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

# A stretch nobody watched may hold idle time: a sighting long after the last one starts a new stretch.
reset; n=$(date +%s); printf '#1\t%s\t%s\t%s\n' "$WT" $((n - 86400)) $((n - 7200)) > "$CREW/active.tsv"
if silent
then ok "47 a two-hour gap in sightings restarts the clock"; else bad "47 sighting gap" "fired: $(cat "$ROOT/out")"; fi
run --no-commit 2; rc=$?                         # positive control for 47
if [ "$rc" = 0 ] && grep -q "since it went active" "$ROOT/out"
then ok "48 same fixture fires once it has been active past --no-commit"; else bad "48 gap control" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

# An unbroken watch keeps a worker's clock across the one-shot exit and relaunch.
reset
run; rc=$?
if [ "$rc" = 0 ] && grep -q "WATCHDOG #1: active but no commit for 12[0-9] min (head" "$ROOT/out"
then ok "49 an unbroken stretch counts from HEAD, the later clock"; else bad "49 unbroken stretch" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

# A new stretch at the same head is a new alert: the last stretch's dedupe key must not swallow it.
# Both alerts land in their stretch's first --no-commit window, where the keys used to collide; at
# --no-commit 5 the next window re-arms only after run's 8 s cap, so a swallowed alert shows.
go_quiet
if silent
then ok "50 the worker goes idle -> silent, and its stretch ends"; else bad "50 idle after alert" "fired: $(cat "$ROOT/out")"; fi
active
run --no-commit 5; rc=$?                         # positive control for 50: a first short stretch
if [ "$rc" = 0 ] && grep -q "since it went active" "$ROOT/out"
then ok "50b a stretch past --no-commit alerts"; else bad "50b first stretch" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi
go_quiet
if silent
then ok "50c idle again -> silent"; else bad "50c idle again" "fired: $(cat "$ROOT/out")"; fi
active
run --no-commit 5; rc=$?                         # positive control for 50c: a second stretch, same head
if [ "$rc" = 0 ] && grep -q "since it went active" "$ROOT/out"
then ok "51 a second stretch at the same head alerts again"; else bad "51 second stretch" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

# A worker spawned again for the same ticket, in a new worktree, starts its own clock.
WT3="$ROOT/wt3"; mkdir -p "$WT3"; git -C "$WT3" init -q -b main
git -C "$WT3" config user.email t@t; git -C "$WT3" config user.name t; commit_in "$WT3" 7200
mkdir -p "$HOME/.claude/projects/$(slug "$WT3")"; : > "$HOME/.claude/projects/$(slug "$WT3")/s.jsonl"
reset; printf '#1\t%s\n' "$WT3" > "$CREW/roster.tsv"
if silent
then ok "52 a re-spawned ticket doesn't inherit the last worker's clock"; else bad "52 re-spawn" "fired: $(cat "$ROOT/out")"; fi
run --no-commit 2; rc=$?                         # positive control for 52
if [ "$rc" = 0 ] && grep -q "WATCHDOG #1: active but no commit for 0 min since it went active" "$ROOT/out"
then ok "53 same fixture fires once the new worker is past --no-commit"; else bad "53 re-spawn control" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi
roster1

# A sighting within one pass plus the activity window keeps the clock; unwatched time past that
# restarts it, even when it is shorter than --no-commit, since it may have been spent waiting.
reset; n=$(date +%s); printf '#1\t%s\t%s\t%s\n' "$WT" $((n - 3000)) $((n - 600)) > "$CREW/active.tsv"
run --no-commit 2000; rc=$?
if [ "$rc" = 0 ] && grep -q "WATCHDOG #1: active but no commit for 50 min since it went active" "$ROOT/out"
then ok "54 a sighting within --interval + 15 min keeps the clock"; else bad "54 recent sighting" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi
reset; n=$(date +%s); printf '#1\t%s\t%s\t%s\n' "$WT" $((n - 3000)) $((n - 1500)) > "$CREW/active.tsv"
if silent --no-commit 2000
then ok "54b 25 unwatched minutes restart the clock, though under --no-commit"; else bad "54b unwatched gap" "fired: $(cat "$ROOT/out")"; fi
run --no-commit 2; rc=$?                         # positive control for 54b
if [ "$rc" = 0 ] && grep -q "since it went active" "$ROOT/out"
then ok "54c same fixture fires once it has been watched past --no-commit"; else bad "54c gap control" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

# One finding per run, but every rostered worker is sighted before the exit, so a stuck worker listed
# after the one that fired keeps its clock across the relaunch.
reset; : > "$PROJ2/sess.jsonl"; n=$(date +%s)
printf '#1\t%s\t%s\t%s\n#2\t%s\t%s\t%s\n' "$WT" $((n - 86400)) $((n - 100)) "$WT2" $((n - 86400)) $((n - 100)) > "$CREW/active.tsv"
printf '#1\t%s\n#2\t%s\n' "$WT" "$WT2" > "$CREW/roster.tsv"
run; rc=$?
seen2=$(awk -F'\t' '$1 == "#2" {print $4}' "$CREW/active.tsv"); case "$seen2" in ''|*[!0-9]*) seen2=0 ;; esac
if [ "$rc" = 0 ] && grep -q "WATCHDOG #1" "$ROOT/out" && [ "$seen2" -ge "$n" ]
then ok "54d an alert still records a sighting for the rest of the roster"; else bad "54d sight before exit" "rc=$rc seen2=$seen2 n=$n $(cat "$ROOT/out")"; fi
roster1

# HEAD's clock keeps the older dedupe key, so a reported.txt written before the stretch clock existed
# still suppresses what it suppressed.
reset; seed_commit 90
printf '#1 nocommit %s\n' "$(git -C "$WT" rev-parse --short HEAD)" > "$CREW/reported.txt"
if silent
then ok "54e an existing key suppresses the same HEAD-clock alert"; else bad "54e legacy key" "fired: $(cat "$ROOT/out")"; fi
: > "$CREW/reported.txt"
run; rc=$?                                       # positive control for 54e
if [ "$rc" = 0 ] && grep -q "WATCHDOG #1: active but no commit for 1 min (head" "$ROOT/out"
then ok "54f same fixture fires once the key is gone"; else bad "54f legacy-key control" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi
seed_commit 7200

# A worker dropped from the roster loses its row, so the next one in the same worktree starts fresh.
reset; printf '#2\t%s\n' "$WT2" > "$CREW/roster.tsv"; : > "$PROJ2/sess.jsonl"
run; roster1                                     # a pass without #1 prunes its row
if silent
then ok "54g a re-dispatch into the same worktree starts its own clock"; else bad "54g same-worktree re-dispatch" "fired: $(cat "$ROOT/out")"; fi
run --no-commit 2; rc=$?                         # positive control for 54g
if [ "$rc" = 0 ] && grep -q "since it went active" "$ROOT/out"
then ok "54h same fixture fires once it is past --no-commit"; else bad "54h re-dispatch control" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

# The roster start (column 3) floors the clock. The stretch alone misses a clock an earlier worker on
# the same ticket and worktree left in active.tsv: cleanup keeps that file, and a sighting inside
# --interval + 15 min keeps the stretch, so a re-dispatch inherits it and fires minutes in.
inherited() { n=$(date +%s); printf '#1\t%s\t%s\t%s\n' "$WT" $((n - 5400)) $((n - 60)) > "$CREW/active.tsv"; }
started()   { printf '#1\t%s\t%s\n' "$WT" "$1" > "$CREW/roster.tsv"; }
reset; active; inherited; started $((n - 30))
if silent
then ok "54i a worker started 30s ago doesn't inherit a stretch left in active.tsv"; else bad "54i start column" "fired: $(cat "$ROOT/out" "$ROOT/err")"; fi
reset; inherited; roster1
run; rc=$?                                       # control for 54i: without the start, it fires
if [ "$rc" = 0 ] && grep -q "WATCHDOG #1: active but no commit for 9[0-9] min since it went active" "$ROOT/out"
then ok "54j same fixture with no start fires on the inherited stretch"; else bad "54j no-start control" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi
reset; inherited; started $((n - 30))
run --no-commit 2; rc=$?                         # control for 54i: with the start, once past it
if [ "$rc" = 0 ] && grep -q "WATCHDOG #1: active but no commit for 0 min since it started" "$ROOT/out"
then ok "54k same fixture fires once the started worker is past --no-commit"; else bad "54k start control" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi
seed_commit 10800; reset; started $(( $(date +%s) - 7200 ))
run; rc=$?
if [ "$rc" = 0 ] && grep -q "WATCHDOG #1: active but no commit for 1[12][0-9] min since it started" "$ROOT/out"
then ok "54l a worker started 2h ago on a 3h-old head is timed from its start"; else bad "54l start clock" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi
seed_commit 7200; reset; started $(( $(date +%s) + 3600 ))
run; rc=$?                                       # a future start would hold trigger 1 off forever
if [ "$rc" = 0 ] && grep -q "WATCHDOG #1: active but no commit for 12[0-9] min (head" "$ROOT/out" \
   && [ "$(grep -c "roster start for #1 is not a past epoch" "$ROOT/err" | tr -d ' ')" = 1 ]
then ok "54m a future start is ignored, warned once, and HEAD's clock fires"; else bad "54m future start" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi
roster1

# A ticket id with a backslash keeps its clock (awk -v would unescape it and never find the row).
reset; printf 'T\\q\t%s\n' "$WT" > "$CREW/roster.tsv"
run --no-commit 2; rc=$?
if [ "$rc" = 0 ] && grep -qF 'WATCHDOG T\q: active but no commit' "$ROOT/out" \
   && [ "$(grep -cF 'T\q	' "$CREW/active.tsv" | tr -d ' ')" = 1 ]
then ok "55 a ticket id with a backslash keeps one row and its clock"; else bad "55 backslash id" "rc=$rc $(cat "$ROOT/out" "$ROOT/err") rows: $(cat "$CREW/active.tsv")"; fi
# and trigger 2 finds its last alert for such an id, so a relaunch doesn't re-fire the same count
reset; silence_t1; sleep 1; subagents 4
run; rc=$?
if [ "$rc" = 0 ] && grep -qF 'WATCHDOG T\q: 4 sub-agents since last push (first alert' "$ROOT/out"
then ok "56 trigger 2 fires for a backslash id"; else bad "56 backslash trigger 2" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi
if silent
then ok "57 and its relaunch at the same count stays silent"; else bad "57 backslash dedupe" "fired: $(cat "$ROOT/out")"; fi
subagents 8
run; rc=$?                                       # positive control for 57
if [ "$rc" = 0 ] && grep -qF 'was 4 at last alert' "$ROOT/out"
then ok "58 growth past its floor fires again"; else bad "58 backslash growth" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi
subagents 0; seed_commit 7200; roster1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
