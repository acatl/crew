# Security Policy

`crew` is a Claude Code skill: Markdown instructions that direct an orchestrator session and its worker
sessions, plus two bash scripts (`watchdog.sh`, `overlap.sh`) that the orchestrator runs locally. The
realistic attack surface is the skill telling a session to do something unsafe, or a script doing
something it shouldn't on the operator's machine.

## Reporting a vulnerability

Please **do not** open a public issue for a security concern.

- Preferred: on this repo's **Security** tab, choose **"Report a vulnerability"** (GitHub private
  vulnerability reporting).
- Fallback: email [acatl.pacheco@gmail.com](mailto:acatl.pacheco@gmail.com) with a description and,
  if possible, reproduction steps.

You should expect an initial response within 5 business days.

## Scope

- **Consent laundering.** The contract forbids relaying tool-permission answers or gated consent (push,
  deploy, install, destructive actions) from the orchestrator to a worker. Any wording in
  `skills/crew/**` that lets a relayed message, or the orchestrator's own `ANSWER`, stand in for the
  operator's approval in the worker's own session is a vulnerability. So is a workflow file that
  loosens the contract: workflows sit on top of it and can't change it.
- **Unsafe instructions.** Skill content that leads a session to merge, force, delete, or archive
  beyond what the operator agreed on the pre-spawn card.
- **Scripts.** `watchdog.sh` and `overlap.sh` run on the operator's machine. They read git state and
  the modification and creation times of files under `~/.claude/projects/`, never file contents. They
  write only inside the project's crew directory (`~/.claude/crew/<slug>/`). Anything that breaks those
  limits is in scope, as are `scripts/*.sh` and `.github/workflows/*`.

Out of scope: vulnerabilities in Claude Code or the Claude desktop app themselves (report those to
Anthropic), and in upstream tools (report those upstream).
