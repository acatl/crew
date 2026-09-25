<!--
Explain WHAT changed (behavior level), WHY (trajectory, prerequisites, alternatives considered), and
the RISK surface (what to watch, what was deferred). One-line bodies are defects on non-trivial changes.
-->

## What

## Why

## Risk surface

## Checklist

- [ ] Conventional Commit subject(s)
- [ ] `./scripts/verify.sh` passes (the pre-push hook runs it; CI runs the same checks)
- [ ] Changed a value restated across files? Updated every copy (CLAUDE.md › Invariants that span files)
- [ ] No baseline raised or lowered, or the PR says the maintainer accepted it (`baselines/`)
