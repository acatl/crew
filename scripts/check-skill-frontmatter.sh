#!/usr/bin/env bash
# Validate that every skill carries the required frontmatter: name, description,
# license, an author, and a version. Keeps the skill catalog uniform (and authored) for
# sharing / vercel-labs/skills consumption; the version is release-managed
# (release-please stamps it, so a new skill must ship the field). Exit 1 on any
# violation.
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
shopt -s nullglob
skills=(skills/*/SKILL.md)

if [ ${#skills[@]} -eq 0 ]; then
  echo "no skills found under skills/*/SKILL.md" >&2
  exit 1
fi

for f in "${skills[@]}"; do
  # Frontmatter = lines between the first two '---' markers.
  fm="$(awk 'NR==1 && $0=="---"{f=1;next} f && $0=="---"{exit} f{print}' "$f")"

  miss=()
  grep -qE '^name:[[:space:]]*[^[:space:]]'        <<<"$fm" || miss+=("name")
  grep -qE '^description:[[:space:]]*[^[:space:]]|^description:[[:space:]]*[>|]' <<<"$fm" || miss+=("description")
  grep -qE '^license:[[:space:]]*[^[:space:]]'   <<<"$fm" || miss+=("license")
  # author and version live under the top-level metadata: key. Matching them anywhere would let an
  # "author:" line inside the folded description, or some other nested key, stand in for them.
  # They are metadata's own children, at its first child's indent; a key nested deeper doesn't count.
  metadata="$(awk '/^metadata:[[:space:]]*$/ {m = 1; next} m && /^[^[:space:]]/ {exit} m' <<<"$fm")"
  indent="$(awk 'NF {match($0, /^[[:space:]]*/); print RLENGTH; exit}' <<<"$metadata")"
  child="^[[:space:]]{${indent:-0}}"
  grep -qE "${child}author:[[:space:]]*[^[:space:]]" <<<"$metadata" || miss+=("author")
  grep -qE "${child}version:[[:space:]]*[^[:space:]]" <<<"$metadata" || miss+=("version")

  if [ ${#miss[@]} -gt 0 ]; then
    echo "✗ $f — missing frontmatter: ${miss[*]}" >&2
    fail=1
  fi

  # The dir name is the skill's identity once installed (it is what gets
  # symlinked/copied into .claude/skills/), so a dir != name skill installs under
  # a name the router never announces. Catch the divergence here, not on a user's
  # machine.
  dir="$(basename "$(dirname "$f")")"
  declared="$(sed -n 's/^name:[[:space:]]*//p' <<<"$fm" | head -1 | tr -d '"'"'"' \r')"
  if [ -n "$declared" ] && [ "$declared" != "$dir" ]; then
    echo "✗ $f — frontmatter name '$declared' != directory '$dir'" >&2
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "✓ all ${#skills[@]} skills have name + description + license + author + version, name == dir"
fi
exit "$fail"
