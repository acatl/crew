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
# Output: one TSV line per overlap: <branch> <TAB> <file> <TAB> <matched-path>. A backslash, tab or
#         newline in <file> prints as \\, \t or \n, so every overlap stays one line of three fields.
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
if [ -z "$base" ] || [ -z "$paths" ] || [ $# -eq 0 ]; then usage; fi

IFS=',' read -r -a candidates <<< "$paths"

g() { git -C "$wt" "$@"; }   # git in the worktree being listed
tsv() { local s=${1//\\/\\\\}; s=${s//$'\t'/\\t}; printf '%s' "${s//$'\n'/\\n}"; }   # one TSV field

# The listings are NUL-separated (-z), so every name arrives exactly as it is on disk: git C-quotes
# names with non-ASCII bytes, quotes, backslashes or control characters in its line output, and a
# quoted name can never match a candidate path. They go to files, not variables, since a variable
# can't hold a NUL.
tmp=$(mktemp -d 2>/dev/null) || { echo "cannot create a temp dir" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

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
  # files can't be read would come out clear. For the same reason --no-renames: a moved file lists
  # both paths, so the one it left still counts as touched.
  if ! g diff --no-renames --name-only -z "$mb" HEAD > "$tmp/committed" \
     || ! g diff --no-renames --name-only -z HEAD > "$tmp/changed" \
     || ! g ls-files -z --others --exclude-standard > "$tmp/untracked"; then
    echo "git could not list the files $branch touched in $wt" >&2; exit 2
  fi
  # merged into a file, not a pipe, so a failing sort can't read as "touched nothing"
  if ! LC_ALL=C sort -z -u "$tmp/committed" "$tmp/changed" "$tmp/untracked" > "$tmp/touched"; then
    echo "could not merge the files $branch touched in $wt" >&2; exit 2
  fi
  while IFS= read -r -d '' f; do
    for p in "${candidates[@]}"; do
      p="${p%/}"
      [ -n "$p" ] || continue
      case "$f" in
        "$p"|"$p"/*) printf '%s\t%s\t%s\n' "$branch" "$(tsv "$f")" "$p"; found=1 ;;
      esac
    done
  done < "$tmp/touched"
done

exit "$found"
