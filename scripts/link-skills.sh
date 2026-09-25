#!/usr/bin/env bash
# Symlink this repo's skills into a Claude Code skills dir, live.
#
# WHY: `npx skills add` resolves a *package* — it fetches a snapshot into its own
# store and links that. Correct for consuming a release, wrong while developing:
# edits here would not surface until the next `skills update`. This links the
# working tree directly, so a SKILL.md edit is live in the next session.
#
#   link   (default) create the symlinks; idempotent, never clobbers
#   check            report status only; exit 1 unless every skill is linked
#
# Target defaults to the user-global dir (~/.claude/skills, available in every
# project). Override for a project-local install:
#   CLAUDE_SKILLS_DIR=/path/to/project/.claude/skills scripts/link-skills.sh

set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"

target_dir="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
mode="${1:-link}"
case "$mode" in link|check) ;; *) echo "usage: $0 [link|check]" >&2; exit 2;; esac

shopt -s nullglob
manifests=(skills/*/SKILL.md)
[ ${#manifests[@]} -gt 0 ] || { echo "⛔ no skills found under skills/*/SKILL.md" >&2; exit 2; }

# Physical path of a dir, so a symlinked $HOME or /tmp can't fake a mismatch.
phys() { (cd "$1" 2>/dev/null && pwd -P); }

[ "$mode" = link ] && mkdir -p "$target_dir"

fail=0
linked=0
for manifest in "${manifests[@]}"; do
  name="$(basename "$(dirname "$manifest")")"
  src="$repo/skills/$name"
  dst="$target_dir/$name"

  # Already ours? Idempotent no-op in link mode, pass in check mode.
  if [ -L "$dst" ] && [ "$(phys "$dst")" = "$(phys "$src")" ]; then
    echo "✓ $name — already linked"
    linked=$((linked + 1))
    continue
  fi

  # Anything else occupying the name is somebody's; report, never clobber.
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    if [ -L "$dst" ]; then
      echo "⛔ $name — occupied by a symlink to $(readlink "$dst")" >&2
    else
      echo "⛔ $name — occupied by an existing directory or file" >&2
    fi
    echo "   resolve by hand: $dst" >&2
    fail=1
    continue
  fi

  if [ "$mode" = check ]; then
    echo "✗ $name — not linked" >&2
    fail=1
    continue
  fi

  ln -s "$src" "$dst"
  echo "✓ $name — linked -> $dst"
  linked=$((linked + 1))
done

if [ "$fail" -eq 0 ]; then
  echo "✅ $linked/${#manifests[@]} skills linked into $target_dir"
else
  [ "$mode" = check ] && echo "Run: scripts/link-skills.sh" >&2
  exit 1
fi
