# Hosts — how each verb runs in the desktop app and in the terminal

Workers run on the orchestrator's **host**; mixed hosts are not supported. The skill names a verb in
*italics* (*spawn*, *identify*); this file says how each host does it. The contract (the messages, the input
invariant, authority) is the same on both.

**Which host.** The `mcp__ccd_session__spawn_task` tool is present → `desktop`. Else
`claude agents --json` runs → `terminal`. Neither → tell the operator crew has no host here, and
stop. The brief's `- host:` line tells the worker; a brief with no host line is `desktop`.

## Verbs

| Verb | Desktop (the app's Code tab) | Terminal (the Claude Code CLI) |
|---|---|---|
| *self* | `mcp__ccd_session_mgmt__get_session("self")` → `sessionId`, `title`, `permissionMode` | `$CLAUDE_CODE_SESSION_ID`; name: the `claude agents --json` row with that `sessionId`; mode: `permissionMode` of the last `"type":"permission-mode"` line in your transcript (*tail*'s file); address: `uds:/tmp/cc-socks/<pid>.sock`, `pid` from that row |
| *spawn* | `mcp__ccd_session__spawn_task` with `title`, `tldr`, `prompt` = the brief (`cwd` only for another repo) → a `task_id` and a chip the operator clicks | from the main checkout, in a subshell: `(cd <main> && claude --bg -w <ticket-slug>-<row> -n "<title>" --permission-mode <mode> "$(cat <brief file>)")` → `backgrounded · <id> · <title>`; the worker starts at once. `--session-id` is ignored with `--bg` |
| *identify* | `mcp__ccd_session_mgmt__get_session(<worker sessionId>)` → `parentSessionId` (must be yours), `worktreePath`, `sourceBranch` | `claude agents --json`: the row whose `cwd` is `<main>/.claude/worktrees/<worktree name>` → `sessionId`, `id`, `pid` (its address, as *self*'s), `cwd` (the worktree path, byte-identical); branch: `git -C <cwd> branch --show-current` |
| *message* | `mcp__ccd_session_mgmt__send_message` to the sessionId | `SendMessage` to the session's address (*self*, *identify*); its title, `[ref]` from `ListAgents`, as a fallback |
| *subscribe* | `SendMessage(to: "<title> [ref]", notify_when_idle: true)`, no message; by title, never by id | the same, to its address |
| *tail* | `mcp__ccd_session_mgmt__list_events(<sessionId>, limit)` | `~/.claude/projects/<cwd with / and . as ->/<sessionId>.jsonl`: `tail -n 400 <file> \| jq -c 'select(.type=="user" or .type=="assistant") \| {at: .timestamp, who: .type, text: ((.message.content \| if type=="string" then . else (map(if .type=="text" then .text elif .type=="tool_use" then "[tool_use " + .name + "]" elif .type=="tool_result" then "[tool_result]" else empty end) \| join(" ")) end)[0:160])}' \| tail -n <limit>` |
| *roster* | `mcp__ccd_session_mgmt__list_sessions`, then *identify* on each, keeping your `parentSessionId` | the ledger's rows (each holds its worktree name) joined to `claude agents --json --all` by `cwd`; there is no parent field |
| *permission-wait* | not observable: the app's attention badge on the worker is the only signal | `claude agents --json` shows the worker `status` `waiting`; the watchdog reports it with `--permission-wait` |
| *stop* | `mcp__ccd_session_mgmt__archive_session`: worktree to the app's reuse pool, branch kept, reversible (`unarchive_session`) | `claude stop <id>`: conversation and worktree kept. **Never `claude rm`:** it deletes the worktree and its branch |
| *restart* | the worker clears its own context as its last action; you send its resume | the worker can't clear itself: it ends its turn instead. Once its agents row reads `idle`, `claude stop <id>`, then `(cd <worktree> && claude --bg -n "<title>" --permission-mode <mode> "$(cat <resume file>)")`, and record the new session and its address in the row. Give the operator its *link* at once: the stop closed any attached view |
| *pr-state* | `gh pr view <N> --json state` | the same |
| *link* | `[<title>](#<worker-sessionId>)`, a link the operator clicks | said in full, since a background session has no tab: "it runs in the background; to watch or answer it, open another terminal and run `claude attach <id>`" |

**A worker's permission mode** (terminal *spawn* and *restart*) is yours, with `plan` → `default` and
`bypassPermissions` → `auto`. Never pass `bypassPermissions` or `--dangerously-skip-permissions`:
a worker never runs with permissions its card didn't show. Write the mode on the card's
`Permission` line; the operator can name another, never a bypass.

## Gotchas on both hosts

- **Never assume which commit a worker was cut from.** Seen live: the app cut five of five from `main`
  while the checkout sat on `graph-port` (hg, 2026-09-22), and so did `-w` from a feature branch
  (2026-10-15, E2E-1). Use the guarded re-point (*Worker* step 2) to set the base.

## Desktop gotchas

- **Address by sessionId, not name.** Name-based `SendMessage` breaks when a session is renamed, and
  Remote Control copies show up as duplicate names. Seen live: the app prefixed `🌳 ` to a worktree
  session mid-turn, and a `SendMessage` to the old name failed while `send_message` by id worked. Names only as a fallback, resolved just in time.
- **Subscribe by title; an id is refused.** Verified 2026-10-01: `SendMessage(to: "local_…",
  notify_when_idle: true)` subscribes nothing. Seen live in hg (2026-09-30): right after a clear, the by-title
  subscribe was "not reachable" three times while `get_session` showed that title.
- **You can't clear a worker's context for it.** `clear_session` refuses a chip-started worker: the
  operator's click started it.
  The worker clears itself last, and you re-send its brief. *(Reported live 2026-09-23; not reproduced.)*
- **`send_message` doesn't work in unattended sessions** (scheduled-task runs, remote-dispatched
  sessions), in either direction. Don't spawn a worker there.
- **An archived worker's worktree stays on disk.** Seen live: after `archive_session`, `git worktree
  list` still showed it, at a detached HEAD, with the branch intact, in the app's reuse pool. Use `parentSessionId` for the roster,
  never `git worktree list`: pooled worktrees aren't workers.

## Terminal gotchas

- **The classifier refuses an identity-heavy message.** Seen live (2026-10-14, spike 1): auto mode
  denied an `ONLINE` carrying the worker's session id, worktree path and `ListAgents` output as "Data
  Exfiltration"; its first line passed, as did a `DONE` (branch, sha, verify) and a `NEED-INPUT`.
  Keep ids, paths and peer lists out of a terminal report: the orchestrator reads them (*identify*).
- **Worktree isolation fences a worker.** Seen live: a Bash line holding several `git` commands was
  refused (2026-10-14, spike 1), and so was a write to `.git/worktrees/<name>/`, the shared checkout
  (2026-10-15, E2E-1), while a probe's crew-dir writes passed. Run one git command per call. Keep the
  ledger only where its brief names it.
- **`claude rm` is destructive.** Seen live (2026-10-14): it deletes the worktree and its
  `worktree-<name>` branch, refusing only on a held lock or an unpushed commit. Use `claude stop`
  for cleanup, always. It leaves git's worktree lock naming the dead pid (seen live 2026-10-15).
  Check the pid is gone, then run `git worktree unlock` to prune a kept worktree; don't force it.
- **Two sessions can share a name; a socket can't.** Seen live: a desktop session and its resume
  (2026-10-14), two orchestrators, and a probe's send and subscribe by socket, which worked
  (2026-10-15). A quit and `--resume` change the pid: the title must stay the fallback.
- **A stopped worker lingers after a *restart*.** Seen live (2026-10-15, E2E-1, #14): its stale
  idle notice arrived (don't act on it), a Remote Control copy kept its title, and its exit screen
  offered `claude --resume`. Never resume it: it would share a branch with its successor.
- **No review monitor.** The PR integrations' settle timer and a background
  `gh pr checks <N> --watch` wake the worker. A review landing on the same head after a clean round
  wakes no one; your merge-rule check before any merge `ANSWER` catches it.
