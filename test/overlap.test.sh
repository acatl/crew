#!/usr/bin/env bash
# Tests for overlap.sh. Builds throwaway repos and worktrees under a mktemp sandbox, so it touches
# nothing real. Run it after any change:
#
#   test/overlap.test.sh
#
# Reading a "no overlap" assertion: exit 0 alone is weak evidence — a check that is blind for a
# mechanical reason also exits 0. Every `clear` call below is therefore PAIRED with a positive control
# on the same fixture: the next assertion asks about a path that does collide and must see it. Never
# add a `clear` assertion without its pair.
set -u
OV="$(cd "$(dirname "$0")/.." && pwd)/skills/crew/scripts/overlap.sh"
ROOT=$(mktemp -d)
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s — %s\n' "$1" "$2"; }

# Keep the sandbox when something failed, so the evidence survives.
finish() { if [ "$fail" = 0 ]; then rm -rf "$ROOT"; else printf 'sandbox kept: %s\n' "$ROOT"; fi; }
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

new_repo() {  # new_repo <dir>: a repo on main with one commit holding base.txt
  git init -q -b main "$1"
  git -C "$1" config user.email t@t; git -C "$1" config user.name t
  git -C "$1" config commit.gpgsign false
  echo base > "$1/base.txt"; git -C "$1" add base.txt; git -C "$1" commit -qm base
}
put() { mkdir -p "$(dirname "$1")"; echo "${2:-x}" > "$1"; }   # put <file> [content]

# ov <args...>: run overlap.sh, capture stdout/stderr, return its exit code
ov() { "$OV" "$@" >"$ROOT/out" 2>"$ROOT/err"; }
has() { grep -qxF -- "$1" "$ROOT/out"; }                        # has <exact TSV line>
clear() {  # clear <label> <args...>: exit 0 and no output. ALWAYS pair with a positive control.
  local label=$1; shift
  ov "$@"; local rc=$?
  if [ "$rc" = 0 ] && [ ! -s "$ROOT/out" ]
  then ok "$label"; else bad "$label" "rc=$rc out=$(cat "$ROOT/out") err=$(cat "$ROOT/err")"; fi
}
hits() {  # hits <label> <expected TSV line> <args...>: exit 1 and that exact line
  local label=$1 line=$2; shift 2
  ov "$@"; local rc=$?
  if [ "$rc" = 1 ] && has "$line"
  then ok "$label"; else bad "$label" "rc=$rc want [$line] got [$(cat "$ROOT/out")] err=$(cat "$ROOT/err")"; fi
}
usage() {  # usage <label> <stderr pattern> <args...>: exit 2 and the message
  local label=$1 pat=$2; shift 2
  ov "$@"; local rc=$?
  if [ "$rc" = 2 ] && grep -q -- "$pat" "$ROOT/err"
  then ok "$label"; else bad "$label" "rc=$rc err=$(cat "$ROOT/err")"; fi
}

T=$'\t'
R="$ROOT/repo"
new_repo "$R"
git -C "$R" switch -q -c w1

# --- a clean worker touches nothing --------------------------------------------------------------------
clear "1  nothing touched -> 0" --base main --paths base.txt,src "$R"
put "$R/src/a.txt"                                                # positive control for 1
hits "2  same fixture, an untracked file under src -> 1" "w1${T}src/a.txt${T}src" --base main --paths src "$R"
rm -rf "$R/src"

# --- each kind of touched file -------------------------------------------------------------------------
put "$R/src/committed.txt"; git -C "$R" add src/committed.txt; git -C "$R" commit -qm c
clear "3  a committed file outside the surface -> 0" --base main --paths docs "$R"
hits "4  committed on the branch -> 1" "w1${T}src/committed.txt${T}src/committed.txt" --base main --paths src/committed.txt "$R"

put "$R/lib/staged.txt"; git -C "$R" add lib/staged.txt
hits "5  staged, not committed -> 1" "w1${T}lib/staged.txt${T}lib/staged.txt" --base main --paths lib/staged.txt "$R"

put "$R/base.txt" changed
hits "6  modified, not staged -> 1" "w1${T}base.txt${T}base.txt" --base main --paths base.txt "$R"

put "$R/docs/new.md"
hits "7  untracked -> 1" "w1${T}docs/new.md${T}docs/new.md" --base main --paths docs/new.md "$R"

# every kind in one run, one line each
ov --base main --paths src,lib,base.txt,docs "$R"; rc=$?
if [ "$rc" = 1 ] && [ "$(wc -l < "$ROOT/out" | tr -d ' ')" = 4 ] \
   && has "w1${T}src/committed.txt${T}src" && has "w1${T}lib/staged.txt${T}lib" \
   && has "w1${T}base.txt${T}base.txt" && has "w1${T}docs/new.md${T}docs"
then ok "8  all four kinds reported together, one line each"; else bad "8  all kinds" "rc=$rc $(cat "$ROOT/out")"; fi

# --- how a path matches ----------------------------------------------------------------------------------
hits "9  a directory covers files under it" "w1${T}src/committed.txt${T}src" --base main --paths src "$R"
hits "10 a trailing / is optional" "w1${T}src/committed.txt${T}src" --base main --paths src/ "$R"
clear "11 a name prefix is not a directory (sr vs src/)" --base main --paths sr,src/committed "$R"
hits "12 same fixture, the full name matches" "w1${T}src/committed.txt${T}src" --base main --paths sr,src "$R"

printf 'ignored/\n' > "$R/.git/info/exclude"; put "$R/ignored/x.txt"
clear "13 an ignored file is not touched" --base main --paths ignored "$R"
: > "$R/.git/info/exclude"                                        # positive control for 13
hits "14 same fixture, no longer ignored -> 1" "w1${T}ignored/x.txt${T}ignored" --base main --paths ignored "$R"
rm -rf "$R/ignored"

# --- several worktrees -------------------------------------------------------------------------------------
git -C "$R" worktree add -q -b w2 "$ROOT/wt2" main
git -C "$R" worktree add -q -b w3 "$ROOT/wt3" main
put "$ROOT/wt3/api/b.txt"; git -C "$ROOT/wt3" add api/b.txt; git -C "$ROOT/wt3" commit -qm b
clear "15 two clean worktrees -> 0" --base main --paths api "$ROOT/wt2" "$R"
hits "16 same surface with the worker that touched it -> 1, named by its branch" \
  "w3${T}api/b.txt${T}api" --base main --paths api "$ROOT/wt2" "$R" "$ROOT/wt3"
if ! grep -q "^w2${T}" "$ROOT/out"
then ok "17 the clean worktree adds no line"; else bad "17 clean worktree" "$(cat "$ROOT/out")"; fi
put "$ROOT/wt2/api/c.txt"                                         # positive control for 15 and 17
ov --base main --paths api "$ROOT/wt2" "$ROOT/wt3"; rc=$?
if [ "$rc" = 1 ] && has "w2${T}api/c.txt${T}api" && has "w3${T}api/b.txt${T}api"
then ok "18 overlaps in two worktrees both reported"; else bad "18 two overlaps" "rc=$rc $(cat "$ROOT/out")"; fi

# --- usage and git errors -----------------------------------------------------------------------------------
usage "19 no arguments -> 2" "usage:"
usage "20 no --base -> 2" "usage:" --paths src "$R"
usage "21 no --paths -> 2" "usage:" --base main "$R"
usage "22 no worktree -> 2" "usage:" --base main --paths src
usage "23 --base with no value -> 2" "usage:" --base
usage "24 unknown flag -> 2" "unknown flag" --nope --base main --paths src "$R"
mkdir -p "$ROOT/plain"
usage "25 not a git worktree -> 2" "not a git worktree" --base main --paths src "$ROOT/plain"
usage "26 a base with no merge-base -> 2" "no merge-base" --base no-such-ref --paths src "$R"
# a bad worktree anywhere in the list fails the run, even after a clean one
usage "27 a bad worktree after a good one -> 2" "not a git worktree" --base main --paths api "$ROOT/wt2" "$ROOT/plain"

# A listing that fails must stop the run, never read as "touched nothing". A corrupt index fails
# the working-tree listings for root too, which a chmod would not.
cp "$R/.git/index" "$ROOT/index.keep"; printf 'garbage' > "$R/.git/index"
usage "28 a git listing that fails -> 2, not a silent clear" "could not list the files w1 touched" --base main --paths base.txt "$R"
cp "$ROOT/index.keep" "$R/.git/index"                            # positive control for 28
hits "29 same fixture, index restored -> reports the file again" "w1${T}base.txt${T}base.txt" --base main --paths base.txt "$R"

# --- a moved file counts at both paths; a non-ASCII name counts as itself --------------------------------------
R2="$ROOT/r2"
new_repo "$R2"
put "$R2/api/old.txt"; put "$R2/keep/k.txt"; git -C "$R2" add api keep; git -C "$R2" commit -qm files
git -C "$R2" switch -q -c m1
clear "30 a fresh branch touches nothing" --base main --paths api,keep,docs,src "$R2"
mkdir -p "$R2/lib"; git -C "$R2" mv api/old.txt lib/new.txt; git -C "$R2" commit -qm move
hits "31 a committed move counts the path it left (control for 30)" "m1${T}api/old.txt${T}api" --base main --paths api "$R2"
git -C "$R2" mv keep/k.txt moved.txt
hits "32 a staged move counts the path it left" "m1${T}keep/k.txt${T}keep" --base main --paths keep "$R2"
put "$R2/docs/naïve.md"
hits "33 an untracked non-ASCII name matches as itself" "m1${T}docs/naïve.md${T}docs" --base main --paths docs "$R2"
put "$R2/src/café.txt"; git -C "$R2" add src; git -C "$R2" commit -qm cafe
hits "34 a committed non-ASCII name matches as itself" "m1${T}src/café.txt${T}src" --base main --paths src "$R2"

# --- each listing's failure stops the run on its own -------------------------------------------------------------
# The shim fails exactly the git call whose arguments match FAIL_ON (a case pattern) and passes the
# rest to the real git, so each guard is exercised alone, not just the first one a broken repo trips.
mkdir -p "$ROOT/shim"
cat > "$ROOT/shim/git" <<'SHIM'
#!/bin/sh
case " $* " in $FAIL_ON) echo "fatal: injected failure" >&2; exit 128 ;; esac
exec "$REAL_GIT" "$@"
SHIM
chmod +x "$ROOT/shim/git"
REAL_GIT=$(command -v git)
via_shim() { FAIL_ON=$1 REAL_GIT=$REAL_GIT PATH="$ROOT/shim:$PATH" "$OV" --base main --paths docs "$R2" >"$ROOT/out" 2>"$ROOT/err"; }
for c in "35|the committed listing|* diff --no-renames --name-only [0-9a-f]* HEAD *" \
         "36|the working-tree listing|* diff --no-renames --name-only HEAD *" \
         "37|the untracked listing|* ls-files *"; do
  n=${c%%|*}; rest=${c#*|}; what=${rest%%|*}; pat=${rest#*|}
  via_shim "$pat"; rc=$?
  if [ "$rc" = 2 ] && grep -q "could not list the files m1 touched" "$ROOT/err" && [ ! -s "$ROOT/out" ]
  then ok "$n $what failing -> 2"; else bad "$n $what failing" "rc=$rc out=$(cat "$ROOT/out") err=$(cat "$ROOT/err")"; fi
done
via_shim "no-such-call"; rc=$?                    # positive control for 35-37: the shim passes through
if [ "$rc" = 1 ] && has "m1${T}docs/naïve.md${T}docs"
then ok "38 through the shim with nothing failing -> reports as usual"; else bad "38 shim control" "rc=$rc $(cat "$ROOT/out" "$ROOT/err")"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
