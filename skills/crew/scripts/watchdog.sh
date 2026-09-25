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
#   watchdog.pid  lock:   one watchdog per project. NEVER kill by name — every project's watchdog
#                 is a watchdog.sh, so `pkill -f watchdog.sh` takes out all of them at once.
#                 Stop one with:  kill "$(cat <crew-dir>/watchdog.pid)"
#
# Triggers, per worker:
#   1. a transcript was written in the last 15 min (the worker is alive) but nothing was committed
#      for --no-commit, counted from HEAD's commit or from the start of the worker's session,
#      whichever is later. A fresh worker is cut from a base that can be hours old, and counting
#      from HEAD alone fired at spawn. The session is the top-level transcript written most
#      recently, not the oldest one, because a worktree the app reuses keeps its earlier
#      occupants' transcripts; its start is the timestamp of its first record. Deduped per ticket
#      + head + elapsed window, so it re-arms once per --no-commit period rather than alerting once
#      and then going quiet forever at an unchanging head.
#   2. more than <count at the last alert> + --subagent-step sub-agent transcripts since the last
#      push. Re-alerts only on GROWTH, never on an absolute count: pre-PR work legitimately spawns
#      many sub-agents, and the absolute-count version fired constantly. A worker with no resolvable
#      push baseline is SKIPPED for this trigger and warned about, never counted from zero — that
#      would be the absolute count again.
#
# It says so on stderr, once, whenever it goes blind on a worker: a roster row whose worktree is
# missing or is not a git repo, a worker with no transcript directory, a worker with no push
# baseline, a malformed ticket id, or the roster disappearing. With no readable session start it
# counts trigger 1 from HEAD alone, and says that once too: an early alarm, never silence. Redirect stderr to a file the
# orchestrator can read; a silently unwatched worker is the failure this script exists to prevent.
#
# Portability: stat(1) is not portable — BSD/macOS takes -f, GNU takes -c. The BSD-only form
# produces nothing on Linux, which made the activity timestamp fall back to 0 and trigger 1 never
# fire, so both forms are probed at startup and neither working is exit 4, never silence. Birth time
# falls back to mtime per file, covering GNU's %W of 0 or "-" on filesystems that don't record it.
# mtime >= btime, so trigger 2 over-counts there and fires slightly early — toward a false alarm,
# never toward silence. date(1) splits the same way, BSD -j -f against GNU -d, for the session
# start's ISO-8601 timestamp; with neither, trigger 1 counts from HEAD alone and says so.
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

[ -n "$base" ] && [ $# -eq 1 ] || usage

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
pidfile="$crewdir/watchdog.pid"
[ -f "$roster" ] || { echo "no roster: $roster (the orchestrator writes it before launching)" >&2; exit 2; }
touch "$reported" 2>/dev/null || { echo "cannot write $reported" >&2; exit 2; }

# --- stat(1) flavour, probed once -------------------------------------------------------------
if probe=$(stat -f %m "$crewdir" 2>/dev/null) && [ -n "$probe" ] && [ -z "${probe//[0-9]/}" ]; then
  stat_m=(stat -f %m); stat_b=(stat -f '%B %m'); stat_n=(stat -f '%m %N')   # BSD / macOS
elif probe=$(stat -c %Y "$crewdir" 2>/dev/null) && [ -n "$probe" ] && [ -z "${probe//[0-9]/}" ]; then
  stat_m=(stat -c %Y); stat_b=(stat -c '%W %Y'); stat_n=(stat -c '%Y %n')   # GNU / coreutils
else
  echo "no usable stat(1): neither 'stat -f %m' (BSD) nor 'stat -c %Y' (GNU) works here" >&2
  exit 4
fi

# --- date(1) flavour, probed once --------------------------------------------------------------
# Only trigger 1's session clock needs it, and losing it only makes trigger 1 early, so a missing
# parser is a warning, not an exit.
if [ "$(date -j -u -f '%Y-%m-%dT%H:%M:%S' 1970-01-02T00:00:00 +%s 2>/dev/null)" = 86400 ]; then
  iso_epoch() { date -j -u -f '%Y-%m-%dT%H:%M:%S' "$1" +%s 2>/dev/null; }                # BSD
elif [ "$(date -u -d '1970-01-02 00:00:00' +%s 2>/dev/null)" = 86400 ]; then
  iso_epoch() { date -u -d "${1/T/ }" +%s 2>/dev/null; }                                # GNU
else
  iso_epoch() { return 1; }
  echo "no date(1) here parses ISO-8601 — trigger 1 counts from HEAD's commit alone" >&2
fi

# session_start <transcript-dir> -> epoch of the first record of the session written most recently
session_start() {
  local cur ts
  cur=$(find "$1" -maxdepth 1 -name '*.jsonl' -type f -exec "${stat_n[@]}" {} + 2>/dev/null \
        | sort -n | tail -n 1 | cut -d' ' -f2-)
  [ -n "$cur" ] || return 1
  ts=$(head -n 5 "$cur" 2>/dev/null \
       | grep -o '"timestamp":"[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | head -n 1)
  [ -n "$ts" ] || return 1
  iso_epoch "${ts#'"timestamp":"'}"
}

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
warn_once() {  # warn_once <key-without-spaces> <message>
  case " $warned " in *" $1 "*) return 0 ;; esac
  warned="$warned $1"
  echo "$2" >&2
}

while true; do
  if [ -f "$roster" ]; then
    snapshot=$(cat "$roster" 2>/dev/null)
  else
    # Transient: the orchestrator stops a watchdog by its pidfile, not by removing the roster.
    # Exiting here would wake the orchestrator with nothing to say.
    warn_once "roster" "roster gone, idling: $roster"
    snapshot=""
  fi

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

    if ! rev=$(git -C "$wt" rev-parse --short HEAD 2>/dev/null); then
      warn_once "$ticket:rev" "no HEAD in $wt for $ticket (not a repo, or no commits) — it is unwatched"
      continue
    fi
    commit_ts=$(git -C "$wt" log -1 --format=%ct 2>/dev/null || echo 0)
    case "$commit_ts" in ''|*[!0-9]*) commit_ts=0 ;; esac
    # activity = newest write to any transcript of this worker (its sub-agents included)
    last_act=$(find "$proj" -name '*.jsonl' -type f -exec "${stat_m[@]}" {} + 2>/dev/null | sort -n | tail -1)
    case "$last_act" in ''|*[!0-9]*) last_act=0 ;; esac
    t=$(now)

    # trigger 1: still working, but nothing committed in a long time. The clock starts at HEAD's
    # commit or at the session's start, whichever is later (see the header); the session is read
    # only once HEAD's clock alone has run out, since the later clock can't have run out before it.
    if [ "$commit_ts" -gt 0 ] && (( t - last_act < ACTIVE && t - commit_ts > nocommit )); then
      since=$commit_ts clock=""
      start=$(session_start "$proj") || start=""
      case "$start" in
        ''|*[!0-9]*) warn_once "$ticket:start" "no session start for $ticket (no readable first record in $proj) — trigger 1 counts from HEAD's commit alone, so it can fire early" ;;
        *) if [ "$start" -gt "$commit_ts" ]; then since=$start clock=" since its session started"; fi ;;
      esac
      # The head does not change while a worker is stuck, so keying on it alone means one alert
      # ever. The window number re-arms it once per --no-commit period. Window 1 keeps the
      # original key verbatim, so an existing reported.txt still suppresses what it suppressed.
      win=$(( (t - since) / nocommit ))
      key="$ticket nocommit $rev"
      [ "$win" -gt 1 ] && key="$key w$win"
      if (( t - since > nocommit )) && ! grep -qxF -- "$key" "$reported" 2>/dev/null; then
        printf '%s\n' "$key" >> "$reported"
        if ! dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' '); then dirty="?"; fi
        echo "WATCHDOG $ticket: active but no commit for $(( (t - since) / 60 )) min$clock (head $rev, $dirty dirty files) — check its tail"
        exit 0
      fi
    fi

    # trigger 2: sub-agents piling up since the last push (a review loop, roughly)
    br=$(git -C "$wt" branch --show-current 2>/dev/null)
    push_ts=""
    if [ -n "$br" ]; then push_ts=$(git -C "$wt" log -1 --format=%ct "origin/$br" 2>/dev/null || true); fi
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
    # Re-alert only on growth: new commits alone must not re-fire. The ""-concatenations keep awk
    # from coercing ids like "01" and "1" into the same number.
    last=$(awk -v k="$ticket" -v p="$push_ts" '$1""==k"" && $2=="subs" && $3""==p"" {n=$4} END{print n+0}' "$reported" 2>/dev/null)
    floor=$(( last > 0 ? last + step : step ))
    if (( subs > floor )); then
      printf '%s subs %s %s\n' "$ticket" "$push_ts" "$subs" >> "$reported"
      if [ "$last" -gt 0 ]; then seen="was $last at last alert"; else seen="first alert"; fi
      echo "WATCHDOG $ticket: $subs sub-agents since last push ($seen, threshold +$step) at head $rev — check for a review loop"
      exit 0
    fi
  done <<< "$snapshot"

  sleep "$interval" & sleep_pid=$!
  wait "$sleep_pid" 2>/dev/null
  sleep_pid=""
done
