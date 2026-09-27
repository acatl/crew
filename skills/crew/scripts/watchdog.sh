#!/usr/bin/env bash
# crew watchdog: a looping worker never goes idle, so nothing ever wakes the orchestrator.
#
# Usage: watchdog.sh --base <ref> [--interval <secs>] [--no-commit <secs>]
#                    [--subagent-step <n>] <crew-dir>
#
# The orchestrator launches this as a background process. It polls every running worker WITHOUT
# waking the orchestrator, and stays silent until a loop-budget trigger shows. On the first trigger
# it prints ONE line to stdout and exits — which re-invokes the orchestrator with the finding
# already in hand. The orchestrator handles it, then launches a fresh watchdog.
#
# State, all in <crew-dir> (this project's ~/.claude/crew/<slug>/, see references/ledger.md):
#   roster.tsv    input:  <ticket> <TAB> <worktree-path>, one line per RUNNING worker, written by
#                 the orchestrator. A leading "#" is part of a ticket id, not a comment; a ticket id
#                 may not contain whitespace. Re-read every pass, so a worker can be added or
#                 dropped with no restart and no signal. The orchestrator rewrites it
#                 write-to-temp-then-mv, never in place.
#   reported.txt  dedupe: a relaunched watchdog re-scans from the top and would re-fire on the
#                 same unchanged condition, so what has been reported must outlive the process.
#   active.tsv    clock:  <ticket> <TAB> <worktree> <TAB> <since> <TAB> <seen>: when the watchdog
#                 first saw each worker active after an idle pass, and when it last saw it active.
#                 It outlives the process too, so a relaunch keeps a worker's clock. Keyed by ticket
#                 AND worktree, and pruned to a non-empty roster every pass, so a worker spawned again
#                 for the same ticket starts its own clock rather than inheriting the last one's.
#   watchdog.pid  lock:   one watchdog per project. NEVER kill by name — every project's watchdog
#                 is a watchdog.sh, so `pkill -f watchdog.sh` takes out all of them at once.
#                 Stop one with:  kill "$(cat <crew-dir>/watchdog.pid)"
#
# Triggers, per worker:
#   1. a transcript was written in the last 15 min (the worker is alive) but nothing was committed
#      for --no-commit, counted from HEAD's commit or from when the watchdog first saw the worker
#      active after an idle pass, whichever is later. Counting from HEAD alone fired at spawn for a
#      worker cut from an old base, and again for one that waited hours on the operator. An idle
#      pass ends a stretch. So does a gap in sightings longer than --interval + 15 min, one pass
#      plus the activity window: longer than that, the watchdog wasn't watching, and the gap may
#      hold idle time. Before it exits on a finding it records a sighting for every rostered
#      worker, so a prompt relaunch keeps each clock. A stretch starts when the watchdog first sees
#      it, so a worker already active before the watchdog started is counted from then. Deduped
#      per ticket + head + elapsed window, plus the stretch's start when the stretch is the later
#      clock, so each stretch alerts on its own; it re-arms once per --no-commit period rather
#      than alerting once and then going quiet forever at an unchanging head.
#   2. more than <count at the last alert> + --subagent-step sub-agent transcripts since the last
#      push. Re-alerts only on GROWTH, never on an absolute count: pre-PR work legitimately spawns
#      many sub-agents, and the absolute-count version fired constantly. The last push is the
#      newest "update by push" in origin/<branch>'s reflog, not the pushed commit's own time: a
#      worker's self-review runs between its commit and its push, and counting from the commit
#      reported that review as a loop after every push. A fetch moves the ref too, but isn't a
#      push. With no push in the reflog it falls back to the commit's time and says so.
#      A worker with no resolvable push baseline is SKIPPED for this trigger and warned about,
#      never counted from zero — that would be the absolute count again.
#
# It says so on stderr, once, whenever it goes blind on a worker: a roster row whose worktree is
# missing or is not a git repo, a worker with no transcript directory, a worker with no push
# baseline, a malformed ticket id, a clock it can no longer write, or the roster disappearing.
# Redirect stderr to a file the orchestrator can read; a silently unwatched worker is the failure
# this script exists to prevent.
#
# Portability: stat(1) is not portable — BSD/macOS takes -f, GNU takes -c. The BSD-only form
# produces nothing on Linux, which made the activity timestamp fall back to 0 and trigger 1 never
# fire, so both forms are probed at startup and neither working is exit 4, never silence. Birth time
# falls back to mtime per file, covering GNU's %W of 0 or "-" on filesystems that don't record it.
# mtime >= btime, so trigger 2 over-counts there and fires slightly early — toward a false alarm,
# never toward silence.
#
# Output: one line on stdout, at the first trigger only, prefixed WATCHDOG.
# Exit:   0     a trigger fired; the finding is the single line on stdout (the normal exit)
#         1     unexpected internal error — it died mid-watch and watched nothing further
#         2     usage error, or <crew-dir>/roster.tsv missing at startup, or state not writable
#         3     another live watchdog already holds <crew-dir>/watchdog.pid
#         4     no usable stat(1)
#         >128  killed by a signal (128+signo) — a deliberate stop, not a finding
set -u

usage() {
  echo "usage: watchdog.sh --base <ref> [--interval <secs>] [--no-commit <secs>] [--subagent-step <n>] <crew-dir>" >&2
  exit 2
}

# Defaults are hg's measured values (2026-09), the only ones proven in production.
base="" interval=1200 nocommit=3600 step=3
ACTIVE=900   # the "this worker is alive right now" window; a property of workers, not project policy

while [ $# -gt 0 ]; do
  case "$1" in
    --base)          [ $# -ge 2 ] || usage; base="$2";     shift 2 ;;
    --interval)      [ $# -ge 2 ] || usage; interval="$2"; shift 2 ;;
    --no-commit)     [ $# -ge 2 ] || usage; nocommit="$2"; shift 2 ;;
    --subagent-step) [ $# -ge 2 ] || usage; step="$2";     shift 2 ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; usage ;;
    *) break ;;
  esac
done

if [ -z "$base" ] || [ $# -ne 1 ]; then usage; fi

# Every one of these reaches an arithmetic context or `sleep`, so validate the WHOLE value and
# normalise it. A stray ':' used to slip through a prefix check; a leading zero made 0600 octal
# (384s, silently early) and 08 a fatal arithmetic error; 0 made `sleep` return instantly and the
# whole loop spin at full tilt, in silence.
num() {  # num <flag> <value> <min> <max> -> normalised value on stdout
  case "$2" in
    ''|*[!0-9]*) echo "$1 takes a whole number, got '$2'" >&2; return 1 ;;
  esac
  [ "${#2}" -le 9 ] || { echo "$1 is out of range, got '$2'" >&2; return 1; }
  local v=$((10#$2))
  if [ "$v" -lt "$3" ] || [ "$v" -gt "$4" ]; then
    echo "$1 must be between $3 and $4, got '$2'" >&2; return 1
  fi
  printf '%s' "$v"
}
interval=$(num --interval      "$interval" 1 86400)  || usage
nocommit=$(num --no-commit     "$nocommit" 1 604800) || usage
step=$(num     --subagent-step "$step"     1 10000)  || usage

: "${HOME:?watchdog needs HOME to find worker transcripts}"

crewdir=$(cd "${1%/}" 2>/dev/null && pwd) || { echo "no such crew dir: $1" >&2; exit 2; }
roster="$crewdir/roster.tsv"
reported="$crewdir/reported.txt"
active="$crewdir/active.tsv"
pidfile="$crewdir/watchdog.pid"
[ -f "$roster" ] || { echo "no roster: $roster (the orchestrator writes it before launching)" >&2; exit 2; }
touch "$reported" 2>/dev/null || { echo "cannot write $reported" >&2; exit 2; }
touch "$active" 2>/dev/null || { echo "cannot write $active" >&2; exit 2; }

# --- stat(1) flavour, probed once -------------------------------------------------------------
if probe=$(stat -f %m "$crewdir" 2>/dev/null) && [ -n "$probe" ] && [ -z "${probe//[0-9]/}" ]; then
  stat_m=(stat -f %m); stat_b=(stat -f '%B %m')          # BSD / macOS
elif probe=$(stat -c %Y "$crewdir" 2>/dev/null) && [ -n "$probe" ] && [ -z "${probe//[0-9]/}" ]; then
  stat_m=(stat -c %Y); stat_b=(stat -c '%W %Y')          # GNU / coreutils
else
  echo "no usable stat(1): neither 'stat -f %m' (BSD) nor 'stat -c %Y' (GNU) works here" >&2
  exit 4
fi

# --- one watchdog per project -----------------------------------------------------------------
# The lock must be per project, not per script name: every project's watchdog is a watchdog.sh, and
# most share one install path, so matching the basename alone would let one project's watchdog
# block another's after a pid is recycled — and then name a stranger's pid to kill. Match the crew
# dir, which is on the command line.
sleep_pid=""
cleanup() {
  if [ -n "$sleep_pid" ]; then kill "$sleep_pid" 2>/dev/null; fi
  if [ "$(cat "$pidfile" 2>/dev/null)" = "$$" ]; then rm -f "$pidfile"; fi
}
trap cleanup EXIT                 # installed BEFORE the pidfile exists, so no window leaks it
# Bash defers a trap until the running foreground command returns, so a foreground `sleep` would
# hold the pidfile for up to a full interval after a kill. The sleep is backgrounded and waited on.
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

if [ -f "$pidfile" ]; then
  old=$(cat "$pidfile" 2>/dev/null || true)
  case "${old:-}" in
    ''|*[!0-9]*) : ;;
    *) if kill -0 "$old" 2>/dev/null \
         && ps -o command= -p "$old" 2>/dev/null | grep -qF -- "$crewdir"; then
         echo "watchdog already running for $crewdir (pid $old) — stop it with: kill $old" >&2
         exit 3
       fi ;;
  esac
  rm -f "$pidfile"
fi
if ! (set -o noclobber; printf '%s\n' "$$" > "$pidfile") 2>/dev/null; then
  [ -e "$pidfile" ] && { echo "lost the race for $pidfile to another watchdog" >&2; exit 3; }
  echo "cannot write $pidfile" >&2; exit 2
fi

# --- watch --------------------------------------------------------------------------------------
now() { date +%s; }
warned=""
warn_once() {  # warn_once <key-without-spaces> <message>...
  case " $warned " in *" $1 "*) return 0 ;; esac
  warned="$warned $1"
  shift
  echo "$*" >&2
}

# active.tsv, one line per rostered worker seen active, rewritten write-to-temp-then-mv. Ticket ids
# and paths reach awk through the environment, which it never unescapes (awk -v turns a backslash
# in an id into an escape), and compare as strings (""), so "01" and "1" stay different ids.
# THIS_ROW is the one test every lookup and removal uses, so the key can't drift between them.
# shellcheck disable=SC2016  # awk source: its $1 and $2 are awk fields, not shell expansions
THIS_ROW='$1"" == ENVIRON["K"]"" && $2"" == ENVIRON["W"]""'
row_of()  { K="$1" W="$2" awk -F'\t' "$THIS_ROW"' {print $3 "\t" $4}' "$active" 2>/dev/null; }
without() { K="$1" W="$2" awk -F'\t' '!('"$THIS_ROW"')' "$active" 2>/dev/null; }
save_active() {  # save_active <new content>
  if ! { if [ -n "$1" ]; then printf '%s\n' "$1"; fi > "$active.tmp" && mv "$active.tmp" "$active"; }; then
    warn_once "active" "cannot write $active — trigger 1 can't keep a worker's clock"
  fi
}
# A gap in sightings longer than one pass plus the activity window is time nobody watched, and may
# hold idle time, so it ends the stretch. Longer thresholds let unwatched waiting count as work.
gap=$(( interval + ACTIVE ))
# saw_active <ticket> <worktree> <now>: sets $stretch, when the worker's current active stretch began
saw_active() {
  local since="" seen="" rest
  IFS=$'\t' read -r since seen rest < <(row_of "$1" "$2")
  case "$since:$seen" in *[!0-9:]*|:*|*:) since=$3 seen=$3 ;; esac
  if (( $3 - seen > gap )); then since=$3; fi
  save_active "$(without "$1" "$2"; printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$since" "$3")"
  stretch=$since
}
saw_idle() {  # saw_idle <ticket> <worktree>: an idle pass ends the worker's stretch
  if [ -n "$(row_of "$1" "$2")" ]; then save_active "$(without "$1" "$2")"; fi
}
# last_alert <ticket> <push time>: the sub-agent count trigger 2 last alerted at for that push, or 0.
# The ""-concatenations keep awk from coercing ids like "01" and "1" into the same number.
last_alert() {
  K="$1" P="$2" awk '$1"" == ENVIRON["K"]"" && $2 == "subs" && $3"" == ENVIRON["P"]"" {n = $4} END {print n + 0}' \
    "$reported" 2>/dev/null
}
prune_active() {  # prune_active <roster snapshot>: drop the rows of workers no longer on it
  local kept
  [ -s "$active" ] || return 0
  kept=$(ROSTER="$1" awk -F'\t' 'BEGIN {n = split(ENVIRON["ROSTER"], r, "\n")
           for (i = 1; i <= n; i++) {split(r[i], f, "\t"); on[f[1] "\t" f[2]] = 1}}
         ($1 "\t" $2) in on' "$active" 2>/dev/null)
  if [ "$kept" != "$(cat "$active" 2>/dev/null)" ]; then save_active "$kept"; fi
}

while true; do
  readable=0
  if [ -f "$roster" ]; then
    if snapshot=$(cat "$roster" 2>/dev/null); then readable=1
    else warn_once "rosterread" "cannot read $roster — this pass watches nothing"; snapshot=""; fi
  else
    # Transient: the orchestrator stops a watchdog by its pidfile, not by removing the roster.
    # Exiting here would wake the orchestrator with nothing to say.
    warn_once "roster" "roster gone, idling: $roster"
    snapshot=""
  fi
  # Only a roster read whole says who left. A missing, unreadable or empty one keeps every clock:
  # an empty roster means the orchestrator is about to stop this watchdog, and the rows it would
  # prune go at the next non-empty pass.
  if [ "$readable" = 1 ] && [ -n "$snapshot" ]; then prune_active "$snapshot"; fi
  alert=""

  # Snapshot per pass rather than holding the fd open across the git calls: a non-atomic rewrite
  # can then tear at most one pass, and a trailing line with no newline is still read.
  while IFS=$'\t' read -r ticket wt rest; do
    [ -n "${ticket:-}" ] || continue
    # Whitespace in a ticket id breaks the awk dedupe below, which field-splits on it, so the
    # trigger-2 memory would silently reset and re-fire forever. Reject the row instead.
    case "$ticket" in
      *[[:space:]]*) warn_once "wsid" "roster ticket id contains whitespace, row skipped: '$ticket'"
                     continue ;;
    esac
    if [ -z "${wt:-}" ] || [ ! -d "$wt" ]; then
      warn_once "$ticket:wt" "no worktree at '${wt:-}' for $ticket — it is unwatched"
      continue
    fi

    proj="$HOME/.claude/projects/$(printf '%s' "$wt" | sed 's#[/.]#-#g')"
    if [ ! -d "$proj" ]; then
      # Both triggers read transcripts, so no transcript dir means this worker is unwatched.
      # The roster path must match the app's byte for byte; this is where a mismatch shows up.
      warn_once "$ticket:proj" "no transcript dir for $ticket ($proj) — it is unwatched"
      continue
    fi

    # activity = newest write to any transcript of this worker (its sub-agents included). Its
    # clock is kept before the git checks, so a worker whose repo can't be read yet keeps its own.
    last_act=$(find "$proj" -name '*.jsonl' -type f -exec "${stat_m[@]}" {} + 2>/dev/null | sort -n | tail -1)
    case "$last_act" in ''|*[!0-9]*) last_act=0 ;; esac
    t=$(now)
    stretch=0
    if (( t - last_act < ACTIVE )); then saw_active "$ticket" "$wt" "$t"; else saw_idle "$ticket" "$wt"; fi

    if ! rev=$(git -C "$wt" rev-parse --short HEAD 2>/dev/null); then
      warn_once "$ticket:rev" "no HEAD in $wt for $ticket (not a repo, or no commits) — it is unwatched"
      continue
    fi
    commit_ts=$(git -C "$wt" log -1 --format=%ct 2>/dev/null || echo 0)
    case "$commit_ts" in ''|*[!0-9]*) commit_ts=0 ;; esac

    # One finding per run. Once there is one, the rest of the roster is only sighted, so every
    # clock is fresh when the orchestrator relaunches.
    [ -z "$alert" ] || continue

    # trigger 1: still working, but nothing committed in a long time. The clock starts at HEAD's
    # commit or at the start of the worker's active stretch, whichever is later (see the header).
    if [ "$commit_ts" -gt 0 ] && (( t - last_act < ACTIVE )); then
      since=$commit_ts clock=""
      if [ "$stretch" -gt "$commit_ts" ]; then since=$stretch clock=" since it went active"; fi
      # The head does not change while a worker is stuck, so keying on it alone means one alert
      # ever. The window number re-arms it once per --no-commit period, and a stretch clock's start
      # separates one stretch from the next at the same head. HEAD's clock keeps the older key, so
      # an existing reported.txt still suppresses what it suppressed.
      win=$(( (t - since) / nocommit ))
      key="$ticket nocommit $rev"
      if [ "$since" != "$commit_ts" ]; then key="$key s$since"; fi
      [ "$win" -gt 1 ] && key="$key w$win"
      if (( t - since > nocommit )) && ! grep -qxF -- "$key" "$reported" 2>/dev/null; then
        printf '%s\n' "$key" >> "$reported"
        if ! dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' '); then dirty="?"; fi
        alert="WATCHDOG $ticket: active but no commit for $(( (t - since) / 60 )) min$clock (head $rev, $dirty dirty files) — check its tail"
        continue
      fi
    fi

    # trigger 2: sub-agents piling up since the last push (a review loop, roughly)
    br=$(git -C "$wt" branch --show-current 2>/dev/null)
    push_ts="" commit_ct=""
    if [ -n "$br" ]; then   # the newest push (see the header); the pattern takes an epoch, not @{0}
      push_ts=$(git -C "$wt" reflog -1 --grep-reflog='^update by push' --format=%gd --date=unix \
                  "refs/remotes/origin/$br" 2>/dev/null | sed -n 's/.*@{\([1-9][0-9]\{8,\}\)}$/\1/p')
      commit_ct=$(git -C "$wt" log -1 --format=%ct "origin/$br" 2>/dev/null || true)
      if [ -z "$push_ts" ] && [ -n "$commit_ct" ]; then
        warn_once "$ticket:reflog" "no push in origin/$br's reflog for $ticket — trigger 2 counts from" \
          "the pushed commit's time, so a self-review before a push can read as a loop"
        push_ts=$commit_ct
      fi
    fi
    if [ -z "$push_ts" ] && mb=$(git -C "$wt" merge-base HEAD "$base" 2>/dev/null); then
      push_ts=$(git -C "$wt" log -1 --format=%ct "$mb" 2>/dev/null || true)
    fi
    case "${push_ts:-}" in
      ''|*[!0-9]*)
        # Counting from 0 here would mean "every sub-agent that ever existed", i.e. the absolute
        # count this trigger exists to avoid. Skip the worker and say why, once.
        warn_once "$ticket:base" "no push baseline for $ticket (no origin/$br, and '$base' has no merge-base in $wt) — trigger 2 is off for it"
        continue ;;
    esac

    subs=$(find "$proj" -path '*/subagents/*.jsonl' -type f -exec "${stat_b[@]}" {} + 2>/dev/null \
           | awk -v p="$push_ts" '{b=($1>0?$1:$2)} b>p{n++} END{print n+0}')
    # Re-alert only on growth: new commits alone must not re-fire.
    last=$(last_alert "$ticket" "$push_ts")
    # Before push times came from the reflog, an alert keyed the push by its commit's time; that
    # key still stands for the same push.
    if [ "$last" = 0 ] && [ -n "$commit_ct" ] && [ "$commit_ct" != "$push_ts" ]; then
      last=$(last_alert "$ticket" "$commit_ct")
    fi
    floor=$(( last > 0 ? last + step : step ))
    if (( subs > floor )); then
      printf '%s subs %s %s\n' "$ticket" "$push_ts" "$subs" >> "$reported"
      if [ "$last" -gt 0 ]; then seen="was $last at last alert"; else seen="first alert"; fi
      alert="WATCHDOG $ticket: $subs sub-agents since last push ($seen, threshold +$step) at head $rev — check for a review loop"
    fi
  done <<< "$snapshot"

  if [ -n "$alert" ]; then
    echo "$alert"
    exit 0
  fi

  sleep "$interval" & sleep_pid=$!
  wait "$sleep_pid" 2>/dev/null
  sleep_pid=""
done
