#!/usr/bin/env bash
# crew parallel-safety check: does a candidate surface collide with in-flight workers?
#
# Usage: overlap.sh --base <ref> --paths <path>[,<path>...] <worktree>...
#
# For each worker worktree, its "touched" set is:
#   files committed on its branch since the merge-base with <ref>
#   + tracked files modified or staged but not committed
#   + untracked, non-ignored files
# A touched file overlaps a candidate path when it equals the path or sits under it
# (a trailing "/" on the path is optional). Paths are relative to the repo root.
#
# Output: one TSV line per overlap: <branch> <TAB> <file> <TAB> <matched-path>
# Exit:   0 no overlap · 1 overlap found · 2 usage or git error
set -u

usage() { echo "usage: overlap.sh --base <ref> --paths <p1,p2,...> <worktree>..." >&2; exit 2; }

base="" paths=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)  [ $# -ge 2 ] || usage; base="$2";  shift 2 ;;
    --paths) [ $# -ge 2 ] || usage; paths="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; usage ;;
    *) break ;;
  esac
done
[ -n "$base" ] && [ -n "$paths" ] && [ $# -gt 0 ] || usage

IFS=',' read -r -a candidates <<< "$paths"

g() { git -C "$wt" -c core.quotePath=false "$@"; }   # git in the worktree being listed

found=0
for wt in "$@"; do
  if ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    echo "not a git worktree: $wt" >&2; exit 2
  fi
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD)
  if ! mb=$(git -C "$wt" merge-base "$base" HEAD 2>/dev/null); then
    echo "no merge-base between '$base' and $branch in $wt (does '$base' exist?)" >&2; exit 2
  fi
  # Each listing is checked: one that fails would otherwise just list nothing, and a worker whose
  # files can't be read would come out clear. For the same reason:
  #   --no-renames      a moved file lists both paths, so the one it left still counts as touched;
  #   quotePath=false   a non-ASCII name lists as itself, not as a quoted "\303\257" form that no
  #                     candidate path could ever match (see g, above the loop).
  if ! committed=$(g diff --no-renames --name-only "$mb" HEAD) \
     || ! changed=$(g diff --no-renames --name-only HEAD) \
     || ! untracked=$(g ls-files --others --exclude-standard); then
    echo "git could not list the files $branch touched in $wt" >&2; exit 2
  fi
  touched=$(printf '%s\n%s\n%s\n' "$committed" "$changed" "$untracked" | sed '/^$/d' | sort -u)
  [ -n "$touched" ] || continue
  while IFS= read -r f; do
    for p in "${candidates[@]}"; do
      p="${p%/}"
      [ -n "$p" ] || continue
      case "$f" in
        "$p"|"$p"/*) printf '%s\t%s\t%s\n' "$branch" "$f" "$p"; found=1 ;;
      esac
    done
  done <<< "$touched"
done

exit "$found"
