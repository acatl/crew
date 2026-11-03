// Tests for the skill checks in scripts/. The repo's skill, baselines, workflows and the watchdog
// suite (the slug check reads it) are read once into a tree, a Map of path to text. Each case takes a
// fresh copy, plants one drift there, and runs the check on it: the Node checks in-process, the bash
// ones (structure, content, links) on a temp copy written to disk. Nothing real is touched. The bash
// checks need skill-validator and jq. Run it after changing a check:
//
//   node --test test/*.test.mjs
//
// A check that passes proves nothing on its own: a check blind for a mechanical reason passes too.
// So every check is first run green on an untouched copy, the control for each drift case after it
// (fresh rebuilds that same copy), and a drift case must turn it red AND name the file that drifted.
// A case that leaves a changed fixture green is paired with one that fires on that same fixture.
//
// A case runs its check when it is declared and asserts in its test, so the cases that share a
// fixture ("same fixture") run in order on it, as written.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  chmodSync,
  closeSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { checkBudget } from '../scripts/check-budget.mjs';
import { checkInvariants } from '../scripts/check-invariants.mjs';
import { checkSectionRefs } from '../scripts/check-section-refs.mjs';
import { checkSkillFrontmatter } from '../scripts/check-skill-frontmatter.mjs';
import { bracket, lines } from '../scripts/lib/md.mjs';
import { readTree } from '../scripts/lib/tree.mjs';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');
const NODE = {
  'check-invariants': checkInvariants,
  'check-section-refs': checkSectionRefs,
  'check-budget': checkBudget,
  'check-skill-frontmatter': checkSkillFrontmatter,
};

// The tree, plus the checks themselves: the bash ones run from a temp copy, a case edits one, and the
// Node ones run there as scripts for the black-box pairs below.
const BASE = readTree(REPO);
for (const dir of ['scripts', 'scripts/lib']) {
  for (const f of readdirSync(join(REPO, dir))) {
    if (/^check-.*\.(sh|mjs)$/.test(f) || (dir === 'scripts/lib' && f.endsWith('.mjs'))) {
      BASE.set(`${dir}/${f}`, readFileSync(join(REPO, dir, f), 'utf8'));
    }
  }
}
const fresh = () => new Map(BASE);

// A git hook runs with the repository's own GIT_DIR (and GIT_INDEX_FILE, …) in its environment, and a
// git run from here would act on THIS repository instead of the temp one: the child gets none of them.
const ENV = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('GIT_')));
const temps = [];
after(() => {
  for (const d of temps) rmSync(d, { recursive: true, force: true });
});
const temp = () => {
  const d = mkdtempSync(join(tmpdir(), 'crew-checks-'));
  temps.push(d);
  return d;
};
// write <tree> <dir>: the tree as files, scripts executable
const write = (t, dir) => {
  for (const [p, text] of t) {
    mkdirSync(dirname(join(dir, p)), { recursive: true });
    writeFileSync(join(dir, p), text);
    if (/\.(sh|mjs)$/.test(p)) chmodSync(join(dir, p), 0o755);
  }
  return dir;
};
// execIn <cwd> <command> <args>: rc and both streams as one, in the order written; bounded
const execIn = (cwd, cmd, args = []) => {
  const out = join(temp(), 'out');
  const fd = openSync(out, 'w');
  const r = spawnSync(cmd, args, { cwd, env: ENV, stdio: ['ignore', fd, fd], timeout: 120_000 });
  closeSync(fd);
  // killed (the timeout, a signal) is not an exit code: red() never counts it as a check that fired
  const rc = r.status ?? `killed (${r.signal ?? r.error?.code ?? 'no status'})`;
  return { rc, out: readFileSync(out, 'utf8') };
};

// run <check> <tree> [args]: a Node check in-process (a rewritten baseline lands in the tree, as it
// would on disk), a bash one from a temp copy
let last = { rc: 0, out: '' };
// A check that throws fails its own case with the stack, not the whole file at load.
const run = (c, t, args = []) => {
  if (NODE[c]) {
    try {
      const r = NODE[c](t, args);
      for (const [p, text] of r.writes) t.set(p, text);
      last = { rc: r.rc, out: r.text };
    } catch (e) {
      last = { rc: 'threw', out: e.stack };
    }
  } else {
    const dir = write(t, temp());
    last = execIn(dir, join(dir, 'scripts', `${c}.sh`), args);
  }
  return last;
};

const ok = (label, pass, detail = '') => test(label, () => assert.ok(pass, detail));
const bad = (label, detail) => test(label, () => assert.fail(detail));
const green = (label, c, t) => {
  const { rc, out } = run(c, t);
  ok(label, rc === 0, `rc=${rc} ${out}`);
};
const red = (label, c, t, pat, ...args) => {
  const { rc, out } = run(c, t, args);
  ok(label, typeof rc === 'number' && rc !== 0 && out.includes(pat), `rc=${rc}, want '${pat}' in: ${out}`);
};

// --- edits: sed's, on a tree ---------------------------------------------------------------------------
// The drifts are written as the sed edits they always were: a POSIX basic regex, applied to each line,
// and a replacement where & is the match. An edit that changes nothing is itself a failure: the case
// after it would test an untouched fixture, and a green case would pass blind.

// bre <BRE>: the same pattern as a RegExp. In a BRE, ( ) { } | + ? are literal, ^ and $ anchor only at
// the ends, and \ makes the next character literal. A malformed pattern throws, and its edit fails.
const bre = (src) => {
  let re = '';
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (c === '\\') {
      const n = src[++i];
      if (n === undefined) throw new Error(`a trailing backslash in ${src}`);
      re += /[A-Za-z0-9]/.test(n) ? n : `\\${n}`;
    } else if (c === '[') {
      const { js, end } = bracket(src, i);
      re += js;
      i = end;
    } else if ((c === '^' && i === 0) || (c === '$' && i === src.length - 1) || c === '.' || c === '*') {
      re += c;
    } else {
      re += /[$^+?(){}|/]/.test(c) ? `\\${c}` : c;
    }
  }
  return new RegExp(re, 'g');
};
// rep <sed replacement>: & is the match, \& a literal &, \<newline> a line break, \x a literal x
const rep = (src) => (m) => src.replace(/\\(.)|&|\\\n/gs, (x, lit) => (x === '&' ? m : x === '\\\n' ? '\n' : lit));

const change = (t, p, fn, what) => {
  const before = t.get(p);
  if (before === undefined) return bad(`edit ${p}`, `no such file: ${what}`);
  const nl = before.endsWith('\n') ? '\n' : '';
  const ls = lines(before);
  let after;
  try {
    after = fn(ls).join('\n') + (ls.length ? nl : '');
  } catch (e) {
    return bad(`edit ${p}`, `${e.message}: ${what}`);
  }
  if (after === before) bad(`edit ${p}`, `changed nothing: ${what}`);
  t.set(p, after);
};
// range <lines> <opts>: the indexes an address covers: from (/re/,$), upto (1,/re/), or every line
const range = (ls, { from, upto } = {}) => {
  if (from) {
    const re = bre(from);
    const i = ls.findIndex((l) => matches(re, l));
    return (j) => i >= 0 && j >= i;
  }
  if (upto) {
    const re = bre(upto);
    const i = ls.findIndex((l, j) => j > 0 && matches(re, l));
    return (j) => i < 0 || j <= i;
  }
  return () => true;
};
// s <tree> <path> <BRE> <replacement> [{g, from, upto}]
const s = (t, p, pat, to, opts = {}) =>
  change(
    t,
    p,
    (ls) => {
      const inRange = range(ls, opts);
      const re = bre(pat);
      const replace = rep(to);
      return ls.map((l, j) => {
        if (!inRange(j)) return l;
        let n = 0;
        return l.replace(re, (m) => (opts.g || n++ === 0 ? replace(m) : m));
      });
    },
    `s#${pat}#${to}#`,
  );
// del: /re/d (in the range, if one is given) · delLast: $d · dup: /re/p · delWithNext: /re/,+1d
// A bre is global, so .test() keeps a lastIndex: each test resets it.
const matches = (re, l) => {
  re.lastIndex = 0;
  return re.test(l);
};
const del = (t, p, pat, opts = {}) =>
  change(t, p, (ls) => {
    const inRange = range(ls, opts);
    const re = bre(pat);
    return ls.filter((l, j) => !(inRange(j) && matches(re, l)));
  }, `/${pat}/d`);
const delLast = (t, p) => change(t, p, (ls) => ls.slice(0, -1), '$d');
const dup = (t, p, pat) =>
  change(t, p, (ls) => {
    const re = bre(pat);
    return ls.flatMap((l) => (matches(re, l) ? [l, l] : [l]));
  }, `/${pat}/p`);
// /re/,+1d: a matching line and the one after it go; the line after a range is tested afresh, the one
// inside it never is
const delWithNext = (t, p, pat) =>
  change(t, p, (ls) => {
    const re = bre(pat);
    const kept = [];
    for (let j = 0; j < ls.length; j++) {
      if (matches(re, ls[j])) j++;
      else kept.push(ls[j]);
    }
    return kept;
  }, `/${pat}/,+1d`);
const append = (t, p, text) => t.set(p, (t.get(p) ?? '') + text);
// lineOf: the line an edit landed on, read from the fixture, so a re-wrap above it never turns a case
// red; a start no line has fails as the fixture's, never reads as the check's line 0
const lineOf = (t, p, start) => {
  const i = lines(t.get(p) ?? '').findIndex((l) => l.startsWith(start));
  if (i < 0) bad(`lineOf ${p}`, `no line starts with: ${start}`);
  return i + 1;
};
const rmTree = (t, prefix) => {
  for (const k of [...t.keys()]) if (k === prefix || k.startsWith(`${prefix}/`)) t.delete(k);
};

const SK = 'skills/crew/SKILL.md';
const CM = 'skills/crew/references/crew-md.md';
const BT = 'skills/crew/references/brief-template.md';
const LG = 'skills/crew/references/ledger.md';
const WS = 'skills/crew/references/workflow-standard.md';
const IP = 'skills/crew/references/integration-pr.md';
const PR = 'docs/crew/integrations/pr.md';
const WD = 'skills/crew/scripts/watchdog.sh';
const OV = 'skills/crew/scripts/overlap.sh';
let t;

// --- the controls: every check green on an untouched copy --------------------------------------------
for (const c of [
  'check-structure',
  'check-content',
  'check-budget',
  'check-invariants',
  'check-section-refs',
  'check-skill-frontmatter',
]) {
  green(`0  ${c} is green on an untouched copy`, c, fresh());
}

// --- the Node checks as scripts: each a black box, green on the repo, red with its exit code on a drift --
{
  const cli = (c, t2, ...args) => execIn(write(t2, temp()), process.execPath, [`scripts/${c}.mjs`, ...args]);
  const pair = (c, drift, pat) => {
    let r = cli(c, fresh());
    ok(`0b ${c}.mjs run as a script is green on an untouched copy`, r.rc === 0 && r.out.startsWith('✓'), `rc=${r.rc} ${r.out}`);
    const d = fresh();
    drift(d);
    r = cli(c, d);
    ok(`0c ${c}.mjs run as a script exits 1 on a drift, naming it`, r.rc === 1 && r.out.includes(pat), `rc=${r.rc} ${r.out}`);
  };
  pair('check-invariants', (d) => s(d, SK, '(1200 / 3600 / 3)', '(1200 / 1800 / 3)'), SK);
  pair('check-section-refs', (d) => append(d, SK, '\nSee `CREW.md` › Nosuch for it.\n'), 'CREW.md › Nosuch');
  pair('check-budget', (d) => append(d, LG, '\nfive more words right here\n'), `${LG}: `);
  pair('check-skill-frontmatter', (d) => del(d, SK, '^license: MIT$'), 'missing frontmatter: license');
  const r = cli('check-budget', fresh(), '--nope');
  ok('0d check-budget.mjs exits 2 on a usage error', r.rc === 2 && r.out.includes('usage:'), `rc=${r.rc} ${r.out}`);
  const w = write(fresh(), temp());
  const u = execIn(w, process.execPath, ['scripts/check-budget.mjs', '--update']);
  const written = readFileSync(join(w, 'baselines/budget.tsv'), 'utf8');
  ok(
    '0e check-budget.mjs --update rewrites the baseline on disk, with its header',
    u.rc === 0 && written.startsWith('# Word budgets') && written.includes(`\n${LG}\t`),
    `rc=${u.rc} ${u.out}\n${written}`,
  );
  const imp = (...extra) =>
    execIn(w, process.execPath, ['--input-type=module', '-e', "await import('./scripts/check-budget.mjs')", ...extra]);
  let i = imp('not-a-file');
  ok('0f a check imported where argv[1] names no file neither throws nor runs', i.rc === 0 && i.out === '', `rc=${i.rc} ${i.out}`);
  i = imp();
  ok('0g nor where there is no argv[1] at all', i.rc === 0 && i.out === '', `rc=${i.rc} ${i.out}`);
  symlinkSync('loop', join(w, 'loop')); // a path that fails for a reason other than being absent
  i = imp('loop');
  ok('0h but one whose argv[1] fails to resolve for any other reason fails loudly', i.rc !== 0 && i.out.includes('ELOOP'), `rc=${i.rc} ${i.out}`);
}

// --- check-invariants -----------------------------------------------------------------------------------
t = fresh();
s(t, SK, '(1200 / 3600 / 3)', '(1200 / 1800 / 3)');
red('1  a watchdog-defaults copy drifts', 'check-invariants', t, SK);
t = fresh();
s(t, WS, 'absent, 60 minutes', 'absent, 30 minutes');
red('2  the minutes copy drifts', 'check-invariants', t, WS);
t = fresh();
s(t, CM, '20 min · 60 min · step 3', '20 min · 60 min · step 4');
red('3  the interview-table copy drifts', 'check-invariants', t, CM);
t = fresh();
s(t, CM, 'push pass 3', 'push pass 5');
red("4  the template's watchdog line drifts", 'check-invariants', t, CM);
t = fresh();
s(t, WD, 'nocommit=3600', 'nocommit=1800');
red('5  the source changes and every copy is named', 'check-invariants', t, 'absent, 60 minutes');
t = fresh();
s(t, SK, '`4` no usable', '`5` no usable');
red('6  a watchdog exit code drifts', 'check-invariants', t, 'no launch-failure code `4`');
t = fresh();
s(t, OV, '2 usage or git error', '3 usage or git error');
red("7  overlap's exit code drifts in its header", 'check-invariants', t, OV);
t = fresh();
s(t, SK, '2 = usage or git error', '3 = usage or git error');
red("8  overlap's exit code drifts in the skill", 'check-invariants', t, "no '2 = usage or git error'");
t = fresh();
s(t, BT, '^<!-- crew:brief v1', '<!-- crew:task v1');
red('9  the brief marker drifts', 'check-invariants', t, SK);
t = fresh();
del(t, BT, '^<!-- crew:brief v1');
red('9b a brief with no marker line is reported, not a crash', 'check-invariants', t, "the brief's '<!-- crew:…' first line not found");
ok('9c and the run reaches its summary', last.out.includes('✖ 1 restated value(s) drifted'), last.out);
t = fresh();
s(t, SK, 'confirm with the `crew:brief` marker', 'confirm with the `crew:brf` marker');
red("10 a stray spelling of the marker's name", 'check-invariants', t, "'crew:brf'");
t = fresh();
s(t, BT, 'A `RELAY` carries', 'A relay carries');
red('11 the fallback drops a message kind', 'check-invariants', t, "doesn't name `RELAY`");

t = fresh();
s(t, SK, "the worker's four reports", "the worker's five reports");
red('12 the description miscounts the reports', 'check-invariants', t, SK);
t = fresh();
s(t, SK, "the orchestrator's RELAY, START and ANSWER", "the orchestrator's RELAY and START");
red('12b the description drops an orchestrator kind', 'check-invariants', t, 'the description gives the orchestrator RELAY START');
t = fresh();
s(t, BT, '`ANSWER`', 'the answer', { g: true });
red('12c the fallback drops ANSWER', 'check-invariants', t, "doesn't name `ANSWER`");
t = fresh();
s(t, SK, 'besides the four kinds', 'besides the three kinds');
red('13 the worker rule miscounts the kinds', 'check-invariants', t, SK);
t = fresh();
s(t, LG, "sed 's\\#/\\#-\\#g'", "sed 's\\#[/.]\\#-\\#g'");
red('14 the crew-dir slug is unified with the transcript one', 'check-invariants', t, LG);
t = fresh();
s(
  t,
  'test/watchdog.test.sh',
  "^slug() { printf '%s' \"$1\" | sed 's\\#\\[/.\\]\\#-\\#g'; }",
  "slug() { printf '%s' \"$1\" | sed 's\\#/\\#-\\#g'; }",
);
red("15 the test's slug drifts from the watchdog's", 'check-invariants', t, 'test/watchdog.test.sh');
// the workflow reaches a worker only through its brief: the Worker section never cites CREW.md
t = fresh();
s(t, SK, '^### 0\\. Resume from the ledger', 'Track `CREW.md` › Workflows per worker in the ledger.\\\n\\\n&');
green("15b the orchestrator's sections may cite CREW.md", 'check-invariants', t);
s(t, SK, "^7\\. \\*\\*Loop budget:\\*\\* your workflow's Rules", "7. **Loop budget:** your workflow's Rules (`CREW.md` › Workflows)"); // same fixture
red('15c the Worker section citing CREW.md', 'check-invariants', t, 'the Worker section cites CREW.md');
t = fresh();
s(t, SK, "^7\\. \\*\\*Loop budget:\\*\\* your workflow's Rules", "7. **Loop budget:** your workflow's Rules (see CREW.md - Workflows)");
red('15c2 and so does any other spelling of the citation', 'check-invariants', t, 'the Worker section cites CREW.md');
t = fresh();
s(t, SK, "^7\\. \\*\\*Loop budget:\\*\\* your workflow's Rules", "7. **Loop budget:** your workflow's Rules (docs/crew.md)");
red('15c3 or case', 'check-invariants', t, 'the Worker section cites CREW.md');
t = fresh();
s(t, SK, 'any other plain `DONE` is a stop', 'any other is a stop');
red('15cd the orchestrator stops reading a legacy plain DONE', 'check-invariants', t, "older brief's DONE: 'plain `DONE` is a stop'");
t = fresh();
s(t, SK, 'From an older brief, `DONE · checkpoint: <boundary>` or', 'From an older brief,');
red('15ce or the legacy checkpoint form', 'check-invariants', t, "older brief's DONE: '`DONE · checkpoint: <boundary>`'");
t = fresh();
s(t, BT, 'Read `{WORKFLOW_PATH}` in full', 'Read the workflow in full', { g: true });
red('15d the brief no longer pointing the worker at its workflow', 'check-invariants', t, `${BT}: the brief's Job no longer says`);
t = fresh();
s(t, BT, '^| `{WORKFLOW_PATH}` | its file, absolute: its `CREW.md` › Workflows', '|  `{WORKFLOW_PATH}`  |  its file: `docs/CREW.md` › Workflows');
green('15e a padded placeholder row naming docs/CREW.md still counts', 'check-invariants', t);
s(t, BT, '`docs/CREW.md` › Workflows', '`docs/CREW.md` › Ledger'); // same fixture
red('15f the row sourcing {WORKFLOW_PATH} from anything but Workflows', 'check-invariants', t, `${BT}: no placeholder row sourcing`);
t = fresh();
s(t, SK, "^   brief → your brief's Job/Spec, Boundaries and Checkpoints are the workflow; follow them as written\\.", '   brief → ask the orchestrator.');
red('15ca the Worker section drops the line in-flight briefs rely on', 'check-invariants', t, 'lost the legacy line');
t = fresh();
s(t, SK, 'first line `checkpoint <stage>` or `stop <stage>`; branch', 'first line `checkpoint <stage>`; branch');
red("15cb the Messages table drops DONE's stop form", 'check-invariants', t, "the section headed '^### Messages' doesn't give DONE's `stop <stage>`");
t = fresh();
s(t, BT, '^`checkpoint <stage>` or `stop <stage>`, with branch', 'a checkpoint or a stop, with branch');
red("15cc the fallback drops DONE's stage form", 'check-invariants', t, "the section headed '^#+ If the");
// the roster format: watchdog.sh's header names the columns, and every copy names the same ones
t = fresh();
s(t, LG, '<worktree-path> TAB <start epoch>, one per', '<worktree-path>, one per');
red('15g a roster copy drops the start column', 'check-invariants', t, LG);
t = fresh();
s(t, SK, '`<start epoch>`, one line per', '`<started>`, one line per');
red('15h a wrapped roster copy renames a column', 'check-invariants', t, SK);
t = fresh();
s(t, WD, '\\[<TAB> <start epoch>\\], one line per', '[<TAB> <started>], one line per');
red('15i the header changes and a copy is named', 'check-invariants', t, LG);
t = fresh();
s(t, WD, 'roster.tsv    input:', 'roster.tsv    in:');
red('15j a reworded header line is reported, not passed', 'check-invariants', t, "the header's 'roster.tsv");
t = fresh();
s(t, SK, '`<ticket>` TAB `<worktree-path>` TAB', 'one ticket TAB `<worktree-path>` TAB');
red('15k one reworded copy fails though the other still matches', 'check-invariants', t, `found in 1: ${LG}`);
t = fresh();
s(t, LG, '<ticket> TAB <worktree-path> TAB', 'one ticket TAB <worktree-path> TAB');
red('15l and so does the other one', 'check-invariants', t, `found in 1: ${SK}`);
t = fresh();
s(
  t,
  SK,
  '^- \\*\\*Its roster is `~/\\.claude/crew/<slug>/roster\\.tsv`\\*\\* — `<ticket>` TAB `<worktree-path>` TAB',
  '- **Its roster is `~/.claude/crew/<slug>/roster.tsv`**, in references/watchdog.md. TAB',
);
t.set('skills/crew/references/watchdog.md', '\nroster.tsv: `<ticket>` TAB `<worktree-path>` TAB `<start epoch>`, one line per worker.\n');
green('15m a copy moved to another file still counts', 'check-invariants', t);
s(t, 'skills/crew/references/watchdog.md', ' TAB `<start epoch>`', ''); // same fixture
red('15n and the moved copy is still checked', 'check-invariants', t, 'skills/crew/references/watchdog.md');
t = fresh();
s(t, SK, '`<ticket>` TAB `<worktree-path>` TAB', 'one ticket TAB `<worktree-path>` TAB');
s(t, LG, '<ticket> TAB <worktree-path> TAB', 'one ticket TAB <worktree-path> TAB');
t.set('skills/crew/references/roster notes.md', '\nroster.tsv: `<ticket>` TAB `<worktree-path>` TAB `<start epoch>`, one line per worker.\n');
red('15r one copy in a file whose name has a space counts as one file', 'check-invariants', t, 'found in 1: skills/crew/references/roster notes.md');
// ANSWER never answers an in-session-only question: the Orchestrator, Worker and fallback sections say so
t = fresh();
s(t, SK, 'never send `ANSWER` or `RELAY` for `answer: in this session only`: nudge without', 'for `answer: in this session only`, nudge without');
red("15o the orchestrator's guard drops out", 'check-invariants', t, "the section headed '^#+ Orchestrator");
t = fresh();
s(t, SK, ', a gated action or `answer: in this session only`\\.', ', or a gated action.');
red("15p the worker's guard drops out", 'check-invariants', t, "the section headed '^#+ Worker");
t = fresh();
s(t, BT, 'locked decision or `answer: in this session only`\\.', 'locked decision.');
red("15q the fallback's guard drops out", 'check-invariants', t, "the section headed '^#+ If the");
t = fresh();
s(
  t,
  SK,
  'never send `ANSWER` or `RELAY` for `answer: in this session only`: nudge without',
  'send `ANSWER` or `RELAY` for `answer: in this session only` as usual: nudge without',
);
red('15s a guard sentence that no longer refuses', 'check-invariants', t, "the section headed '^#+ Orchestrator");
t = fresh();
s(t, SK, '^\\#\\# Worker$', '\\#\\# The worker');
red("15t a guard section's heading renamed is reported, not passed", 'check-invariants', t, "a section headed '^#+ Worker");
t = fresh();
s(t, SK, '^\\#\\#\\# 6\\. Handle messages', '```bash\\\n\\# a comment, not a heading\\\n```\\\n\\\n&');
green('15u a heading-like comment in a code fence ends no section', 'check-invariants', t);
s(
  t,
  SK,
  'never send `ANSWER` or `RELAY` for `answer: in this session only`: nudge without',
  'send `ANSWER` or `RELAY` for `answer: in this session only` as usual: nudge without',
); // same fixture, below the fence
red('15u2 and the section is still read past the fence', 'check-invariants', t, "'^#+ Orchestrator[[:space:]]*$' no longer says, in one sentence, that ANSWER never answers");
t = fresh();
s(t, SK, "the operator's words, never consent for a tool-permission prompt or a gated", "the operator's words, even for a tool-permission prompt or a gated");
red("15v the worker's RELAY rule stops refusing tool-permission consent", 'check-invariants', t, 'that a relayed answer is never consent for a tool-permission prompt');
t = fresh();
s(t, BT, 'Neither is consent for a tool-permission prompt', 'Both count for a tool-permission prompt');
red("15w the fallback's RELAY rule stops refusing it", 'check-invariants', t, "the section headed '^#+ If the");
t = fresh();
s(t, SK, '^- \\*\\*Never relayed:\\*\\* tool-permission prompts', '- **Relayed as usual:** tool-permission prompts');
red("15x the contract's input invariant stops refusing it", 'check-invariants', t, "the section headed '^#+ The contract'");
t = fresh();
s(t, SK, 'never consent for a tool-permission prompt or a gated', 'never consent for a tool-permission prompt, but consent for a');
red("15y the worker's RELAY rule drops the gated-action half", 'check-invariants', t, 'or a gated action');
t = fresh();
s(t, BT, 'tool-permission prompt or a gated action (push, install,', 'tool-permission prompt; a yes for (push, install,');
red('15z the fallback drops the gated-action half', 'check-invariants', t, "the section headed '^#+ If the");

// a merge go names its delegation: a sentence that tells the worker to merge names `landing:`
t = fresh();
s(t, PR, 'with no `landing: operator` on', 'with no `landing: delegated` on');
red("15da a project integration gates the merge on the card's delegation alone", 'check-invariants', t, `${PR}: tells the worker to merge without naming`);
t = fresh();
s(t, IP, 'Met, with no `landing: operator` on the card and its', 'Met, with its');
red('15db so does the built-in integration', 'check-invariants', t, `${IP}: tells the worker to merge`);
t = fresh();
s(t, PR, 'it tells the worker to merge by', 'it tells the worker to go by');
s(t, PR, ', tells the worker to merge\\.', ', tells the worker to go.');
s(t, IP, '^  tells the worker to merge by', '  tells the worker to go by');
red('15dc no merge sentence at all fails, never passes', 'check-invariants', t, 'a sentence that tells the worker to merge not found');
t = fresh();
t.delete(IP);
red('15dd a missing built-in integration is reported, not skipped', 'check-invariants', t, 'skills/crew/references/integration-*.md: the built-in file not found');
t = fresh();
rmTree(t, 'docs/crew/integrations');
green('15dd2 a project with no integrations or workflows dir is checked, not reported as reworded', 'check-invariants', t);
t.set('docs/crew/workflows/x.md', '---\nname: x\n---\n\nThe orchestrator tells the worker to merge.\n'); // same fixture
red('15dd3 and a project workflow planted there is still checked', 'check-invariants', t, 'docs/crew/workflows/x.md: tells the worker to merge without naming');
t = fresh();
s(t, PR, '^  card (', '  card, per docs/CREW.md (');
green("15de a dotted name inside the sentence doesn't split it", 'check-invariants', t);
s(t, PR, 'with no `landing: operator` on', 'with no `landing: delegated` on'); // same fixture
red('15df and the same fixture still fires on a missing withhold', 'check-invariants', t, `${PR}: tells the worker to merge without naming`);
// a relayed go is never a merge go: each file asking "merge?" refuses one beside it, accepts none, and marks it
t = fresh();
s(t, IP, 'yes in this session, never a relayed go\\.', 'yes in this session.');
red('15fa the built-in stops refusing a relayed go', 'check-invariants', t, `${IP}: asks "merge?" but no sentence naming it refuses a relayed go`);
t = fresh();
s(t, IP, ', never a relayed go\\.', ', or a relayed go.');
red('15fb a relayed go named but accepted, not refused', 'check-invariants', t, `${IP}: asks "merge?" but no sentence naming it refuses a relayed go`);
t = fresh();
s(t, PR, "withholds it), or the operator's yes", "withholds it), the operator's go relayed to it, or the operator's yes");
red('15fc the project copy accepts a relayed go again, beside its refusal', 'check-invariants', t, `${PR}: accepts a relayed go for the merge`);
t = fresh();
s(t, PR, 'who merges by hand or in the$', 'who merges by hand or says go, which it relays, or in the');
red("15fd or relays the operator's go", 'check-invariants', t, `${PR}: accepts a relayed go for the merge`);
t = fresh();
s(t, PR, 'who merges by hand or in the$', "who merges by hand or answers here, and it relays the operator's go, or in the");
red('15fd2 any phrasing that relays a go, while a refusal stands elsewhere', 'check-invariants', t, `${PR}: accepts a relayed go for the merge`);
t = fresh();
s(t, IP, '^Merge only on a go to your "merge?":', 'Never act on a go relayed from another session. Merge only on a go to your "merge?":');
green('15fd3 a refusal that says "go relayed" is a refusal, not an acceptance', 'check-invariants', t);
s(t, IP, ', never a relayed go\\.', ', or a relayed go.'); // same fixture
red('15fd4 and the same fixture fires once the merge sentence accepts one', 'check-invariants', t, `${IP}: asks "merge?" but no sentence naming it refuses a relayed go`);
t = fresh();
s(t, PR, '"merge?"', '`merge?`', { g: true });
s(t, PR, "withholds it), or the operator's yes", "withholds it), the operator's go relayed to it, or the operator's yes");
red('15fd5 a file quoting merge? another way is still checked', 'check-invariants', t, `${PR}: accepts a relayed go for the merge`);
t = fresh();
s(t, IP, 'marked$', 'sent');
s(t, IP, '^`answer: in this session only` unless the bar is met and your brief.s Landing is `delegated`, and$', 'and');
red('15fd6 the built-in stops marking its merge question by Landing', 'check-invariants', t, `${IP}: asks "merge?" but doesn't mark it`);
t = fresh();
s(
  t,
  PR,
  '^  a Hard Gate only this session approves. It marks that `NEED-INPUT` `answer: in this session only`$',
  '  a Hard Gate only this session approves. It marks that `NEED-INPUT`',
);
red('15fd7 so does the project copy', 'check-invariants', t, `${PR}: asks "merge?" but doesn't mark it`);
t = fresh();
s(t, IP, 'unless the bar is met and your brief.s Landing is `delegated`, and$', "when your brief's Landing is `delegated`, and");
red('15fd8 a marking with its condition reversed loses its "unless"', 'check-invariants', t, `${IP}: asks "merge?" but doesn't mark it`);
t = fresh();
s(t, PR, 'who merges by hand or in the$', "who merges by hand or in the worker's session, relays the operator's go and no other, or in the");
red("15fd9 a refusal word after the go doesn't refuse it", 'check-invariants', t, `${PR}: accepts a relayed go for the merge`);
t = fresh();
s(t, PR, 'who merges by hand or in the$', "who merges by hand or answers here, and it is relaying the operator's go, or in the");
red('15fd10 nor does "relaying" escape', 'check-invariants', t, `${PR}: accepts a relayed go for the merge`);
t = fresh();
s(t, IP, 'merge?', 'land?', { g: true });
s(t, PR, 'merge?', 'land?', { g: true });
red('15fe no file asks "merge?": reported, not passed', 'check-invariants', t, 'a "merge?" question not found');
// Landing reaches the worker through the brief: both Job lists carry it, and its row resolves it
t = fresh();
del(t, BT, '^- Landing: `{LANDING}`$');
red('15fe2 the brief and START drop the Landing line', 'check-invariants', t, `${BT}: the ready brief's Job list has no '- Landing: \`{LANDING}\`' line`);
t = fresh();
del(t, BT, '^| `{LANDING}` |');
red('15fe3 the {LANDING} row goes', 'check-invariants', t, `${BT}: no placeholder row resolving {LANDING}`);
t = fresh();
s(t, BT, '^| `{LANDING}` | card › Landing: ', '| `{LANDING}` | ');
red('15fe4 a {LANDING} row that drops its source, the card', 'check-invariants', t, `${BT}: no placeholder row resolving {LANDING}`);
// the integration's stop is the worker's stop: Authority and Eviction say so
t = fresh();
s(t, SK, 'up to its stop stage (its integration.s, if any), and', "up to the workflow's stop stage, and");
red("15ff the contract's Authority stops at the workflow's stop", 'check-invariants', t, "the section headed '^#+ Authority");
t = fresh();
s(t, LG, 'when its stop stage (its integration.s, if any) is reached', "when its workflow's stop stage is reached");
red("15fg the ledger evicts at the workflow's stop", 'check-invariants', t, "the section headed '^#+ Eviction");
t = fresh();
s(t, LG, '^\\#\\# Eviction$', '\\#\\# Evicting rows');
red('15fh a renamed Eviction heading is reported, not passed', 'check-invariants', t, "a section headed '^#+ Eviction");
// a queued unit's card lives in its ledger row: step 5's write, the spine, and START from the row
t = fresh();
s(t, SK, 'its overrides, `integration`, mode,', 'its overrides, mode,');
red("15fi step 5's row write drops the card's integration", 'check-invariants', t, "the section headed '^#+ 5[.] Spawn");
t = fresh();
s(t, LG, 'its overrides, `integration`, mode,', 'its overrides, mode,');
red("15fi2 the spine drops the card's integration", 'check-invariants', t, "the section headed '^#+ Shape");
t = fresh();
s(t, SK, 'landed state and its row.s$', 'landed state and the');
red("15fi3 START written without the row's card lines", 'check-invariants', t, "the section headed '^#+ 8[.] Sequences");
t = fresh();
s(t, BT, 'computed now, the card.s lines from the ledger row |', 'computed now |');
red("15fi4 the START template computes the card's lines afresh", 'check-invariants', t, "the section headed '^#+ START");
t = fresh();
s(t, SK, 'landed state and the unit.s ledger row\\. It replaces', 'current landed state. It replaces');
red("15fi5 the contract's START row computes the card afresh", 'check-invariants', t, "the section headed '^#+ Messages");
t = fresh();
s(t, SK, '^   START) with the new base sha', '   ) with the new base sha');
green("15fi6 a link cleanup in step 8's START line stays green", 'check-invariants', t);
s(t, SK, 'card lines, its Spec from `briefs/<row>-spec.md`, after', 'card lines, after'); // same fixture
red('15fi6b and the same fixture fails once step 8 drops the saved spec', 'check-invariants', t, "'^#+ 8[.] Sequences' no longer says, in one sentence, that START takes its Spec from briefs/<row>-spec.md");
// a queued unit's spec lives in briefs/<row>-spec.md: step 5 saves it, step 8, the spine and START read it
t = fresh();
s(t, SK, 'Save a queued brief.s `{SPEC}` to `briefs/<row>-spec.md`\\.', 'A queued brief drops its spec.');
red("15fj step 5 no longer saves a queued unit's spec", 'check-invariants', t, "the section headed '^#+ 5[.] Spawn");
t = fresh();
s(t, SK, 'card lines, its Spec from `briefs/<row>-spec.md`, after', 'card lines, after');
red('15fj2 START written without the saved spec', 'check-invariants', t, "the section headed '^#+ 8[.] Sequences");
t = fresh();
s(t, LG, 'takes its Spec from `briefs/<row>-spec.md`, never from memory', 'writes its Spec from memory');
red("15fj3 the spine takes START's Spec from memory", 'check-invariants', t, "the section headed '^#+ Shape");
t = fresh();
s(t, BT, '^| `{SPEC}` | never from memory:', '| `{SPEC}` | from memory, unless');
red('15fj4 the START template sources {SPEC} from memory', 'check-invariants', t, "the section headed '^#+ START");
t = fresh();
s(t, SK, '^landed state waits for START', 'landed-state details wait for START');
green('15fj5 a rewording outside the pinned sentences stays green', 'check-invariants', t);
s(t, SK, 'card lines, its Spec from `briefs/<row>-spec.md`, after', 'card lines, after'); // same fixture
red('15fj5b and the same fixture fails once step 8 drops the saved spec', 'check-invariants', t, "the section headed '^#+ 8[.] Sequences");
t = fresh();
s(t, SK, 'briefs/<row>-spec\\.md', 'briefs/<row>-spec.txt', { g: true });
red("15fj6 SKILL.md's spec file changes extension", 'check-invariants', t, `${SK}: no longer names briefs/<row>-spec.md`);
t = fresh();
s(t, LG, 'briefs/<row>-spec\\.md', 'briefs/<row>-spec.txt', { g: true });
red("15fj7 ledger.md's spec file changes extension", 'check-invariants', t, `${LG}: no longer names briefs/<row>-spec.md`);
t = fresh();
s(t, BT, 'briefs/<row>-spec\\.md', 'briefs/<row>-spec.txt', { g: true });
red("15fj8 the START template's spec file changes extension", 'check-invariants', t, `${BT}: no longer names briefs/<row>-spec.md`);
const save = 'Save a queued brief.s `{SPEC}` to `briefs/<row>-spec\\.md`';
t = fresh();
s(t, SK, save, "Save a queued brief's `{SPEC}` to `briefs/<row>-spec.txt`");
red('15fj9 step 5 saves to .txt while step 8 reads .md', 'check-invariants', t, "the queued unit's spec file reads 'briefs/<row>-spec.txt'");
t = fresh();
s(t, LG, '^  briefs/<row>-spec\\.md ', '  briefs/<row>-spec    ');
red('15fj10 one ledger copy loses its extension', 'check-invariants', t, "the queued unit's spec file reads 'briefs/<row>-spec'");
t = fresh();
s(t, SK, save, "Save a queued brief's `{SPEC}` to `briefs/<row>-spec.md.bak`");
red('15fj11 a compound suffix on the save is a drift too', 'check-invariants', t, "the queued unit's spec file reads 'briefs/<row>-spec.md.bak'");
t = fresh();
s(t, SK, save, "Save a queued brief's `{SPEC}` to `briefs/<row>-spec.md~`");
red('15fj12 so is any non-dot suffix', 'check-invariants', t, "the queued unit's spec file reads 'briefs/<row>-spec.md~'");
for (const sfx of [',v', ':old', ';bak', '|x', ')x', '-old', '/x']) {
  // any suffix up to a backtick or space
  t = fresh();
  s(t, SK, save, `Save a queued brief's \`{SPEC}\` to \`briefs/<row>-spec.md${sfx}\``);
  red(`15fj12b suffix '${sfx}' is a drift`, 'check-invariants', t, `the queued unit's spec file reads 'briefs/<row>-spec.md${sfx}'`);
}
t = fresh();
s(t, LG, '^  briefs/<row>-spec\\.md a queued', '  briefs/<row>-spec.md. A queued');
green("15fj13 a sentence's closing period isn't part of the name", 'check-invariants', t);
s(t, LG, '^  briefs/<row>-spec\\.md\\. A queued', '  briefs/<row>-spec.md.old A queued'); // same fixture
red('15fj14 and the same fixture fails once that copy drifts', 'check-invariants', t, "the queued unit's spec file reads 'briefs/<row>-spec.md.old'");
// a resume keeps the roster start: step 6 and the Watchdog roster bullet say so
t = fresh();
s(t, SK, 'holds a question, roster start kept\\.', 'holds a question, roster start epoch reset.');
red('15fk step 6 resets the roster start at a resume again', 'check-invariants', t, 'a resume keeps the roster start');
t = fresh();
s(t, SK, 'neither trigger counts from earlier\\. Keep it across resumes\\.', 'neither trigger counts from earlier.');
red('15fk2 the Watchdog roster bullet drops the kept start', 'check-invariants', t, 'the roster start survives a resume');
t = fresh();
s(t, SK, 'Keep it across resumes\\.', 'Keep it across resumes, clears included.');
green('15fk3 the pinned sentence grown by a clause stays green', 'check-invariants', t);
s(t, SK, 'Keep it across resumes, clears included\\.', 'Reset it at resumes, clears included.'); // same fixture
red('15fk4 and the same fixture fails once that sentence reverses', 'check-invariants', t, 'the roster start survives a resume');
t = fresh();
s(t, SK, '\\*\\*Spawn every unit now\\*\\*, each by step 5 (end your turn after the last):', '**Spawn every unit now**:');
red("15fi7 step 8 spawns the queue without step 5's row write", 'check-invariants', t, "the section headed '^#+ 8[.] Sequences");
t = fresh();
s(t, SK, 'integration`, mode, permission,', 'integration`, permission,');
red("15fi8 step 5's row write drops the mode", 'check-invariants', t, "the section headed '^#+ 5[.] Spawn");
t = fresh();
s(t, LG, '^`Do not touch`, any decision', 'any decision');
red('15fi9 the spine drops Do not touch', 'check-invariants', t, "the section headed '^#+ Shape");
t = fresh();
s(t, SK, 'Job section, written now from the landed state and its row.s', "Job section, written from the landed state and the row's");
green("15fi10 a same-meaning reword of step 8's START line stays green", 'check-invariants', t);
s(t, SK, "landed state and the row's$", 'landed state and the'); // same fixture
red("15fi10b and the same fixture fails once it drops the row's card lines", 'check-invariants', t, "'^#+ 8[.] Sequences' no longer says, in one sentence, that START is written from the row's card lines");

// a PR opens against the brief's base: every `gh pr create`/`new` reads `gh pr create --base <base>` (the
// controls cover green; no case pins a line number, so a re-wrap alone never turns one red)
t = fresh();
s(t, IP, '`gh pr create --base <base>`', '`gh pr create`');
red('15ei1 the built-in opens its PR against the default branch', 'check-invariants', t, "'gh pr create', not");
t = fresh();
s(t, PR, '`gh pr create --base <base>`', '`gh pr create --fill`');
red('15ei2 so does a project integration, whatever else it passes', 'check-invariants', t, "'gh pr create --fill', not");
t = fresh();
s(t, IP, '`gh pr create --base <base>`', '`gh pr create --base main`');
red('15ei3 a literal branch in place of <base> is the same bug', 'check-invariants', t, "'gh pr create --base main', not");
t = fresh();
s(t, PR, '`gh pr create --base <base>`', '`gh pr new`');
red("15ei4 gh's alias gh pr new is checked too", 'check-invariants', t, "'gh pr new', not");
t = fresh();
s(t, PR, '`gh pr create --base <base>`', '`gh pr create --base <base> --draft`');
green('15ei5 flags after the base pass', 'check-invariants', t);
s(t, PR, '`gh pr create --base <base> --draft`', '`gh pr create --draft --base <base>`'); // same fixture
red('15ei6 but a base after another flag is not the canonical form', 'check-invariants', t, "'gh pr create --draft --base', not");
t = fresh();
append(t, PR, '\n```bash\ngh pr create --base <base> --fill\ngh pr checks 5 --watch\n```\n');
green('15ei7 other gh pr commands beside a good call are not calls to judge', 'check-invariants', t);
append(t, PR, '```bash\n(gh pr create --fill)\n```\n'); // same fixture
red('15ei7b but each call in a fence is judged alone, wherever it starts', 'check-invariants', t, "'gh pr create --fill)', not");
t = fresh();
append(t, PR, '\n- Then\n  `gh pr\n  create --fill`.\n');
red('15ei8 a call wrapped across lines is still seen', 'check-invariants', t, "'gh pr create --fill', not");
t = fresh();
s(t, IP, '`gh pr create --base <base>`', 'the PR');
red('15ei9 the built-in without the call fails, though the project copy still names one', 'check-invariants', t, `${IP}: the call 'gh pr create --base <base>' not found`);
// a merge is confirmed before `stop merge`: each sentence naming `gh pr merge` waits for `gh pr view` to read
// `MERGED`, naming the merge queue (the controls cover green)
t = fresh();
s(t, IP, '^a merge queue or auto-merge only queues it', 'a queue or auto-merge only queues it');
red("15ej1 the built-in reports its merge without the queue's wait", 'check-invariants', t, `${IP}: names \`gh pr merge\` without waiting`);
t = fresh();
s(t, PR, '`MERGED`', 'merged', { g: true });
red('15ej2 so does a project integration', 'check-invariants', t, `${PR}: names \`gh pr merge\` without waiting`);
t = fresh();
s(t, IP, 'reads `MERGED`:$', 'reads `MERGED`.');
red("15ej3 the queue and the wait in two sentences don't count", 'check-invariants', t, `${IP}: names \`gh pr merge\` without waiting`);
t = fresh();
s(t, IP, '`gh pr merge <N>', '`gh pr land <N>');
red('15ej4 the built-in without the call fails, though the project copy still names one', 'check-invariants', t, `${IP}: the call 'gh pr merge' not found`);
t = fresh();
s(
  t,
  PR,
  '`gh pr view <N> --json state,mergeCommit` reads `MERGED` (a merge queue only queues it, as § merge',
  '`gh pr view <N> --json state,mergeCommit` reads merged (a merge queue only queues it, as § merge',
);
red('15ej5 one call site without its wait fails, though another sentence in the file still waits', 'check-invariants', t, `${PR}: names \`gh pr merge\` without waiting`);
t = fresh();
s(t, SK, '(Integration mode `pr`, once `gh pr view` reads `MERGED`)', '(Integration mode `pr`)');
red("15ej6 the orchestrator lands a PR it hasn't read as MERGED", 'check-invariants', t, `${SK}: no sentence runs Post-land only once`);
// the queue card shows each unit's workflow and landing
t = fresh();
s(t, SK, '^> | \\# | Unit | Title | Workflow | Integration | Scope | Landing | Cleanup |', '> | # | Unit | Title | Workflow | Integration | Scope | Cleanup |');
red('15dg the queue card loses its per-unit Landing', 'check-invariants', t, 'the queue card has no per-unit Landing column');
t = fresh();
s(t, SK, '^> | \\# | Unit | Title | Workflow | Integration | Scope | Landing | Cleanup |', '> | # | Unit | Title | Integration | Scope | Landing | Cleanup |');
red('15dh or its Workflow', 'check-invariants', t, 'the queue card has no per-unit Workflow column');
// a workflow's verify falls back as the orchestrator's does
const verifyRow = '| `CREW.md` › Verify, else `docs/HARNESS.md` › Sensors, else asked |';
t = fresh();
s(t, WS, verifyRow, '| `CREW.md` › Verify |');
red('15di a verify default that stops at CREW.md', 'check-invariants', t, `${WS}: the \`verify\` default falls back to`);
t = fresh();
s(t, PR, verifyRow, '| `docs/HARNESS.md` › Sensors |');
red("15dj a project workflow's too", 'check-invariants', t, `${PR}: the \`verify\` default falls back to`);
t = fresh();
s(t, SK, '^  `CREW.md` › Verify, else `docs/HARNESS.md` › Sensors, else ask)\\.', '  `CREW.md` › Verify, else ask).');
red("15dk the orchestrator's chain changes and the workflows are named", 'check-invariants', t, `${WS}: the \`verify\` default falls back to`);
t = fresh();
del(t, WS, '^| `verify` |');
red('15dl the built-in without a verify row is reported, not passed', 'check-invariants', t, 'the `verify` parameter row not found');
t = fresh();
del(t, IP, '^| `verify` |');
red('15dl2 and so is the built-in integration without one', 'check-invariants', t, `${IP}: the \`verify\` parameter row not found`);
t = fresh();
s(t, IP, verifyRow, '| `CREW.md` › Verify |');
red("15dl3 the built-in integration's verify default drifts", 'check-invariants', t, `${IP}: the \`verify\` default falls back to`);
t = fresh();
del(t, PR, '^| `verify` |');
green('15dm a project workflow may leave verify out', 'check-invariants', t);
del(t, WS, '^| `verify` |'); // same fixture
red('15dn but the same fixture fails once the built-in drops it', 'check-invariants', t, 'the `verify` parameter row not found');
// every brief state is handled on both sides: the brief template's {STATE} row is the source
t = fresh();
s(t, SK, '^A brief marked `state=resume` is a resume', 'A resumed brief is a resume');
red('15do the Worker section stops handling a resume', 'check-invariants', t, "handles no brief state 'resume'");
t = fresh();
s(t, SK, 'marker line set to `state=resume`', 'marker line set to resume');
red("15dp so does the Orchestrator's resume", 'check-invariants', t, "^#+ Orchestrator[[:space:]]*$' handles no brief state 'resume'");
t = fresh();
s(t, BT, 'unless marked `state=resume`:', 'unless resumed:');
red("15dq the brief's fallback stops telling a resume apart", 'check-invariants', t, "the fallback section handles no brief state 'resume'");
t = fresh();
s(t, BT, '^| `{STATE}` |', '| `{STATUS}` |');
red('15dr a reworded {STATE} row is reported, not passed', 'check-invariants', t, 'the {STATE} placeholder row not found');
t = fresh();
s(t, BT, '^| `{STATE}` | `ready`, `queued`, or', '| `{STATE}` | `ready`, `queued`, `paused`, or');
s(t, SK, '^  `state: queued` → status `queued`\\.', '  `state: queued` or `state: paused` → status `queued`.');
s(t, SK, '^A brief marked `state=resume` is a resume', 'A brief marked `state=resume` (not `state=paused`) is a resume');
s(t, BT, 'If queued, end your', 'If queued or paused, end your');
green('15ds a new state handled in all three places passes', 'check-invariants', t);
s(t, BT, 'If queued or paused, end your', 'If queued, end your'); // same fixture
red('15dt and the same fixture fails once the fallback drops it', 'check-invariants', t, "the fallback section handles no brief state 'paused'");
t = fresh();
s(t, BT, '(`ready` or `queued`)', '(`queued`)');
red('15dz the fallback stops naming the first state too', 'check-invariants', t, "the fallback section handles no brief state 'ready'");
// the reverse: a state SKILL.md handles must be in the {STATE} row
t = fresh();
s(t, BT, '^| `{STATE}` | `ready`, `queued`, or `resume` when', '| `{STATE}` | `ready` or `queued`, never');
red('15du a template that drops resume while SKILL.md still sends it', 'check-invariants', t, "handles brief state 'resume', which");
// a ready PR asks before it merges: `merge bar met` comes with a merge NEED-INPUT
t = fresh();
s(t, IP, '^sends the merge `NEED-INPUT`', 'asks the merge question');
red('15dv the built-in integration drops its merge NEED-INPUT', 'check-invariants', t, `${IP}: names \`merge bar met\` but no sentence`);
t = fresh();
s(t, PR, 'so it sends `NEED-INPUT` and ends', 'so it sends a question and ends');
s(t, PR, '^  `NEED-INPUT` that § Who runs', '  question that § Who runs');
red('15dv2 so does a project integration', 'check-invariants', t, `${PR}: names \`merge bar met\` but no sentence`);
s(t, PR, '`merge bar met`', 'the bar', { g: true }); // same fixture
green('15dw a file that never reaches merge bar met needs no merge NEED-INPUT', 'check-invariants', t);
s(t, IP, '^sends the merge `NEED-INPUT`', 'asks the merge question'); // same fixture
red('15dx and the same fixture fires once the built-in drops it', 'check-invariants', t, `${IP}: names \`merge bar met\` but no sentence`);
s(t, IP, '`merge bar met`', 'the bar', { g: true });
red('15dy no file names merge bar met: reported, not passed', 'check-invariants', t, '`merge bar met` not found');
// an ANSWER with no question pending is refused: the Worker section and the brief's fallback say so
t = fresh();
s(t, SK, 'refuse an `ANSWER` with no question pending or outside', 'refuse an `ANSWER` outside');
red(
  '15ea the worker stops refusing an ANSWER with nothing pending',
  'check-invariants',
  t,
  "'^#+ Worker[[:space:]]*$' no longer says, in one sentence, that an ANSWER with no question pending is refused",
);
t = fresh();
s(t, BT, 'Say so here and refuse an `ANSWER` with no question pending, or$', 'Say so here and act on an `ANSWER` with no question pending, or');
red(
  '15eb the fallback acts on one instead',
  'check-invariants',
  t,
  "skill is unavailable' no longer says, in one sentence, that an ANSWER with no question pending is refused",
);
// a resume never carries consent: the Orchestrator section and the ledger's cleared-worker invariant say so
t = fresh();
s(
  t,
  SK,
  'throttle, an operator call), and any message still pending\\. A resume never carries consent for a',
  'throttle, an operator call), and any message still pending. A resume carries consent for a',
);
red(
  "15ef the orchestrator's resume stops refusing consent",
  'check-invariants',
  t,
  "'^#+ Orchestrator[[:space:]]*$' no longer says, in one sentence, that a resume never carries consent",
);
t = fresh();
s(t, LG, '^- A resume never carries consent for a gated action or a plan approval, not even as', '- A resume carries consent for a gated action or a plan approval, even as');
red("15eg so does the ledger's cleared-worker invariant", 'check-invariants', t, "'^#+ The cleared-worker invariant' no longer says");
t = fresh();
s(t, LG, '^\\#\\# The cleared-worker invariant$', '\\#\\# Cleared workers');
red('15eh its heading renamed is reported, not passed', 'check-invariants', t, "a section headed '^#+ The cleared-worker invariant' not found");

// the integration reaches a worker through its brief: every Job block names {INTEGRATION_PATH}
const integrationLine = '^- Integration: `{INTEGRATION_PATH}`\\.';
t = fresh();
s(t, BT, integrationLine, '- Integration: none.', { from: '^## START' });
red('15ec START drops the integration line its brief carries', 'check-invariants', t, "START's Job list differs from the ready brief's");
t = fresh();
s(t, BT, integrationLine, '- Integration: none.');
red('15ed both Job lists drop it', 'check-invariants', t, "the ready brief's Job list has no '- Integration: `{INTEGRATION_PATH}`.' line");
t = fresh();
s(t, BT, integrationLine, '- Integration: none.', { from: '^## START' });
dup(t, BT, '^- Integration: `{INTEGRATION_PATH}`'); // same fixture
red("15ec2 one list's doubled line doesn't cover the other's missing one", 'check-invariants', t, "START's Job list differs from the ready brief's");
t = fresh();
s(t, BT, '^- Do not touch: {FORBIDDEN}$', '- Surface note: none', { from: '^## START' });
red('15ec3 START drops another Job line, Do not touch', 'check-invariants', t, "START's Job list differs from the ready brief's");
t = fresh();
del(t, BT, '^- Workflow: `{WORKFLOW}`', { from: '^## START' });
red('15ec4 or its Workflow line', 'check-invariants', t, "START's Job list differs from the ready brief's");
t = fresh();
s(t, BT, '^## Job$', '### Job', { from: '^## START' });
red("15ec5 START's Job heading renamed is reported, not passed on the brief's strength", 'check-invariants', t, "START's `## Job` section not found");
t = fresh();
s(t, BT, '^## Job$', '## The job', { upto: '^### Queued block' });
red("15ec6 the ready brief's Job heading renamed is reported", 'check-invariants', t, "the ready brief's `## Job` section not found");
t = fresh();
s(
  t,
  BT,
  '^- Workflow: `{WORKFLOW}`\\. Read `{WORKFLOW_PATH}` in full and follow it\\. Mode: `{MODE}`\\.$',
  '- Workflow: `{WORKFLOW}`. Read `{WORKFLOW_PATH}`\\\n  in full and follow it. Mode: `{MODE}`.',
  { from: '^## START' },
);
green('15ec7 a wrapped Job line still matches its copy', 'check-invariants', t);
s(t, BT, integrationLine, '- Integration: none.', { from: '^## START' }); // same fixture
red('15ec8 and the same fixture fires on a dropped Integration line', 'check-invariants', t, "START's Job list differs from the ready brief's");
t = fresh();
s(t, BT, 'its file, absolute: `CREW.md` › Integration.s `file:`', 'its file, absolute: `CREW.md` › Workflows row');
red('15ee the row sourcing {INTEGRATION_PATH} from anything but Integration', 'check-invariants', t, 'no placeholder row sourcing {INTEGRATION_PATH}');

// --- check-section-refs ------------------------------------------------------------------------------------
t = fresh();
append(t, SK, '\nSee `CREW.md` › Nosuch for it.\n');
red("16 a CREW.md section that doesn't exist", 'check-section-refs', t, 'CREW.md › Nosuch');
t = fresh();
append(t, SK, '\nSee `CREW.md` › Integrations too.\n');
red("17 a heading's prefix is not the heading", 'check-section-refs', t, 'CREW.md › Integrations');
t = fresh();
append(t, SK, '\nRead `references/missing.md` first.\n');
red("18 a references/ file that doesn't exist", 'check-section-refs', t, 'references/missing.md');
t = fresh();
append(t, SK, '\nRun `<skill-dir>/scripts/gone.sh`.\n');
red("19 a skill script that doesn't exist", 'check-section-refs', t, '<skill-dir>/scripts/gone.sh');

t = fresh();
for (const f of [SK, BT, LG, WS, IP]) s(t, f, 'CREW\\.md` ›', 'CREW.md` -', { g: true });
red('19b no CREW.md references at all fails, never passes', 'check-section-refs', t, "found no 'CREW.md › Section' references");
t = fresh();
for (const f of [...t.keys()].filter((k) => k.startsWith('skills/crew/') && t.get(k).includes('references/'))) {
  s(t, f, 'references/', 'refs/', { g: true });
}
red('19c no references/ mentions at all fails, never passes', 'check-section-refs', t, 'found no references/<name>.md mentions');
t = fresh();
s(t, SK, '<skill-dir>/scripts/', '<skill-dir>/bin/', { g: true });
red('19d no <skill-dir>/scripts/ calls at all fails, never passes', 'check-section-refs', t, 'found no <skill-dir>/scripts/ calls');

// --- check-links: it needs lychee, which this job may lack, so only its own guard is tested here ---------------
// check-links.sh finds its repo from the working directory, as a hook does, so it runs from inside a
// repo of its own that holds no Markdown at all
{
  const L = write(new Map([['scripts/check-links.sh', BASE.get('scripts/check-links.sh')]]), temp());
  spawnSync('git', ['-C', L, 'init', '-q'], { env: ENV });
  let r = execIn(L, join(L, 'scripts/check-links.sh'));
  ok('19e git listing no Markdown fails, never passes', r.rc === 1 && r.out.includes('git listed no markdown files'), `rc=${r.rc} ${r.out}`);
  writeFileSync(join(L, 'doc.md'), '# doc\n'); // positive control for 19e: one file gets past the guard
  r = execIn(L, join(L, 'scripts/check-links.sh'));
  ok('19f same repo with a Markdown file gets past the guard', !r.out.includes('listed no markdown'), r.out);
}

// --- check-budget ---------------------------------------------------------------------------------------------
t = fresh();
append(t, LG, '\nfive more words right here\n');
red('20 a file grows past its budget', 'check-budget', t, `${LG}: `);
ok('21 and the delta is named', last.out.includes('(+5)'), last.out);
red('22 --update never raises', 'check-budget', t, 'over its budget', '--update');
red('23 --allow-raise alone is refused', 'check-budget', t, 'only goes with --update', '--allow-raise');
t = fresh();
t.set('skills/crew/references/new.md', 'a new reference\n');
red('24 a new file has no budget', 'check-budget', t, 'references/new.md: 3 words and no budget');
t = fresh();
delLast(t, LG);
run('check-budget', t, ['--update']);
{
  const lowered = last.out.includes('lowered');
  const detail = last.out;
  ok('25 --update lowers, and stays green', lowered && run('check-budget', t).rc === 0, detail);
}
append(t, LG, 'one two three\n');
red('26 the lowered budget holds the line', 'check-budget', t, LG);
t = fresh();
rmTree(t, 'skills/crew/references');
red('26a no reference files at all fails before checking', 'check-budget', t, 'no *.md found — the lookup broke');
red("26d and --update doesn't drop their budgets", 'check-budget', t, 'no *.md found — the lookup broke', '--update');
ok('26e the reference budgets are still there', t.get('baselines/budget.tsv').includes('references/'), t.get('baselines/budget.tsv'));
for (const [k, v] of BASE) if (k.startsWith('skills/crew/references/')) t.set(k, v); // control for 26a, 26d, 26e: the same fixture, restored
green('26f with the references back, the kept budgets pass', 'check-budget', t);
t = fresh();
t.delete(LG);
red("26b a budgeted file that's gone fails", 'check-budget', t, `${LG}: budgeted but gone`);
run('check-budget', t, ['--update']); // positive control for 26b: --update drops it
{
  const dropped = last.out.includes(`- ${LG}: gone, budget dropped`);
  const detail = last.out;
  ok("26c --update drops a gone file's budget, then green", dropped && run('check-budget', t).rc === 0, detail);
}

t = fresh();
t.set('baselines/budget.tsv', `${t.get('baselines/budget.tsv')}skills/crew/references/gone.md\t10`);
red("26g a gone file's budget on a last line with no newline still fails", 'check-budget', t, 'skills/crew/references/gone.md: budgeted but gone');
t = fresh();
t.delete(SK);
red('26h no SKILL.md fails before counting it as 0 words', 'check-budget', t, `${SK}: not found`);
{
  const before = t.get('baselines/budget.tsv');
  red('26i and --update leaves its budget alone', 'check-budget', t, `${SK}: not found`, '--update');
  ok('26j the baseline is unchanged', t.get('baselines/budget.tsv') === before, t.get('baselines/budget.tsv'));
}

t = fresh();
s(t, 'baselines/budget.tsv', '^skills/crew/references/ledger\\.md', '\t&');
green('26k a budget row with a leading tab is read the same by the lookup and the gone pass', 'check-budget', t);
t.delete(LG); // same fixture
red('26l and its file gone is reported, from that same row', 'check-budget', t, `${LG}: budgeted but gone`);

t = fresh();
s(t, 'baselines/budget.tsv', '^skills/crew/references/ledger\\.md\t[0-9]*$', 'skills/crew/references/ledger.md\tmany');
red('26m a budget that is not a whole number fails, naming it', 'check-budget', t, `${LG}: its budget 'many'`);
red('26n and --update keeps that row as it is', 'check-budget', t, `${LG}: its budget 'many'`, '--update');
ok('26o the row is unchanged', t.get('baselines/budget.tsv').includes(`${LG}\tmany\n`), t.get('baselines/budget.tsv'));
run('check-budget', t, ['--update', '--allow-raise']); // same fixture: the repair the message names
ok(
  '26p --update --allow-raise re-budgets it at today\'s count, then green',
  last.rc === 0 && /\nskills\/crew\/references\/ledger\.md\t[0-9]+\n/.test(t.get('baselines/budget.tsv')) && run('check-budget', t).rc === 0,
  `${last.out}\n${t.get('baselines/budget.tsv')}`,
);
t = fresh();
s(t, 'baselines/budget.tsv', '^skills/crew/references/ledger\\.md\t[0-9]*$', '& \r');
green('26q a budget with a stray blank or \\r around its number still reads as that number', 'check-budget', t);
append(t, LG, '\nfive more words right here\n'); // same fixture
red('26r and that number still holds the line', 'check-budget', t, `${LG}: `);

// --- check-content ----------------------------------------------------------------------------------------
t = fresh();
append(t, SK, '\nYou may skip this. It may help. You might try it. It could matter.\n');
red('27 weak markers lower instruction specificity', 'check-content', t, 'instruction_specificity fell');
red('28 --update never lowers a baseline', 'check-content', t, 'instruction_specificity fell', '--update');

// --- check-structure ------------------------------------------------------------------------------------------
t = fresh();
t.set('skills/crew/notes.txt', 'scratch\n');
red('29 a stray file at the skill root', 'check-structure', t, 'notes.txt');
t = fresh();
run('check-structure', t);
ok('30 the exemption is printed on every run', last.out.includes('PR 3 removes this exemption'), last.out);
// The body's line count is exempt too, until PR 3, up to max_lines: today's body passes, printed as known.
ok(
  '30b a body over 500 lines, within max_lines, passes, printed as known',
  last.rc === 0 && /^known: SKILL\.md body is [0-9,]+ lines .*PR 3 removes this exemption/m.test(last.out),
  `rc=${last.rc} ${last.out}`,
);
s(t, 'scripts/check-structure.sh', '^max_lines=[0-9]*', 'max_lines=0'); // same fixture, no room left
red('30c and fails without its exemption', 'check-structure', t, 'SKILL.md: warning: SKILL.md body is');
t = fresh();
append(t, SK, Array.from({ length: 40 }, (_, i) => `\nPadding paragraph ${i + 1}.\n`).join(''));
red("30d a body grown past max_lines fails: the word budget can't see a rewrap", 'check-structure', t, 'lines (spec recommends');

// --- check-structure: the workflow files' shape ----------------------------------------------------------
t = fresh();
del(t, WS, '^- \\*\\*Ends:\\*\\* committed, `verify` green\\.$');
red('35 a stage that names no end', 'check-structure', t, `${WS}:`);
ok('35b and the stage is named', last.out.includes('stage build names no Ends'), last.out);
t = fresh();
s(t, WS, '^- \\*\\*Report:\\*\\* `checkpoint build`', '- **Report:** `checkpoint plan`');
red('36 a report naming another stage', 'check-structure', t, 'stage build: Report must be');
t = fresh();
s(t, WS, '^- \\*\\*Report:\\*\\* `checkpoint build`', '- **Report:** `stop build`');
red('37 two stop stages', 'check-structure', t, '2 stages report stop');
t = fresh();
s(t, WS, '^- \\*\\*Report:\\*\\* `stop handoff`', '- **Report:** `checkpoint handoff`');
red('37b no stop stage', 'check-structure', t, '0 stages report stop');
t = fresh();
s(t, WS, '^\\#\\# Parameters$', '\\#\\# Settings');
red('38 a section missing', 'check-structure', t, 'needs ## Parameters, ## Stages, ## Rules');
t = fresh();
s(t, WS, '^name: standard$', 'name: std');
red("39 a name that isn't the file's", 'check-structure', t, 'frontmatter name is "std"');
t = fresh();
delWithNext(t, PR, '^- \\*\\*Orchestrator:\\*\\* reads `MERGED` itself, runs Post-land');
red('40 a project workflow is checked too', 'check-structure', t, `${PR}:`);
t = fresh();
t.delete(WS);
red('41 no built-in workflow fails, never passes', 'check-structure', t, 'no workflow-*.md');
t = fresh();
t.delete(IP);
red('41a no built-in integration fails, never passes', 'check-structure', t, 'no integration-*.md');
t = fresh();
s(t, IP, '^- \\*\\*Report:\\*\\* `checkpoint open`', '- **Report:** `stop open`');
red('41b a built-in integration with two stops', 'check-structure', t, `${IP}:`);
ok('41c and the count is named', last.out.includes('2 stages report stop'), last.out);
t = fresh();
s(t, IP, '^name: pr$', 'name: integration-pr');
red("41d an integration's name keeps no integration- prefix", 'check-structure', t, 'frontmatter name is "integration-pr"');
t = fresh();
rmTree(t, 'docs/crew/integrations');
run('check-structure', t);
ok('41e no project integrations dir names no file', !last.out.includes('docs/crew'), last.out);
t.set('docs/crew/integrations/y.md', '---\nname: y\ndescription: d\n---\n\n## Parameters\n'); // same fixture
red('41f and a project integration planted there is checked', 'check-structure', t, 'docs/crew/integrations/y.md:');
t = fresh();
s(t, WS, '^\\#\\#\\# review$', '```text\\\n\\#\\#\\# not a stage\\\n```\\\n\\\n&');
green('42 a heading-like line in a code fence is no stage', 'check-structure', t);
del(t, WS, '^- \\*\\*Ends:\\*\\* every valid finding fixed'); // same fixture
red('42b the same fixture still fails on a stage with no end', 'check-structure', t, 'stage review names no Ends');

// --- check-invariants: the host layer ----------------------------------------------------------------------
const HO = 'skills/crew/references/host.md';
t = fresh();
s(t, HO, '^| \\*pr-state\\* | `gh pr view <N> --json state` | the same |$', '| *pr-state* | `gh pr view <N> --json state` |  |');
red('43 a verb with no terminal mechanism', 'check-invariants', t, "the verb *pr-state* doesn't say how both hosts do it");
t = fresh();
s(t, HO, '^| \\*pr-state\\* |', '| *ghost* | a | b |\\\n| *pr-state* |');
red('44 a verb no file cites', 'check-invariants', t, 'the verb *ghost* is cited nowhere else');
t = fresh();
s(t, SK, '^\\*roster\\* before anything else', '`get_session` before anything else');
red('45 an app tool named outside host.md', 'check-invariants', t, `${SK}:${lineOf(t, SK, '`get_session` before')}: names a host's tool outside references/host.md (get_session)`);
t = fresh();
s(t, BT, '^(\\*spawn\\*)\\. A field', '(spawn_task). A field');
red('46 the brief names one outside its fallback section, which alone may', 'check-invariants', t, `${BT}:${lineOf(t, BT, '(spawn_task). A field')}: names a host's tool`);
t = fresh();
del(t, BT, '^- host: `{HOST}`$');
red('47 the brief loses its host line', 'check-invariants', t, "no '- host: `{HOST}`' line");
t = fresh();
s(t, BT, '^| `{HOST}` | \\*self\\*:', '| `{HOST}` | the card:');
red('48 the {HOST} row stops sourcing it from self', 'check-invariants', t, 'no placeholder row sourcing {HOST}');
t = fresh();
s(t, SK, 'a brief with none is `desktop`', 'a brief with none is unclear');
red('49 the Worker section drops the no-host-line default', 'check-invariants', t, 'a brief with no host line is desktop');
t = fresh();
s(t, BT, '^- Keep your ledger in `{WORKER_LEDGER}`, the one', '- Keep your ledger nearby, the one');
red("49b the brief's Housekeeping loses the worker ledger", 'check-invariants', t, "Housekeeping section doesn't name {WORKER_LEDGER}");
t = fresh();
s(t, BT, '^| `{WORKER_LEDGER}` | `~/\\.claude/crew/', '| `{WORKER_LEDGER}` | `<git dir>/');
red('49c the {WORKER_LEDGER} row stops sourcing it from the crew dir', 'check-invariants', t, 'no placeholder row sourcing {WORKER_LEDGER}');
t = fresh();
s(t, SK, "brief's Housekeeping names", "brief's Boundaries names");
red('49d the Worker section stops reading its ledger from the brief', 'check-invariants', t, "a worker's ledger is the one its brief names");
t = fresh();
del(t, BT, '^- address: `{ORCH_ADDRESS}`$');
red("49e the brief loses the orchestrator's address", 'check-invariants', t, "no '- address: `{ORCH_ADDRESS}`' line");
t = fresh();
s(t, BT, '^| `{ORCH_ADDRESS}` | \\*self\\*', '| `{ORCH_ADDRESS}` | the card');
red('49f the {ORCH_ADDRESS} row stops sourcing it from self', 'check-invariants', t, 'no placeholder row sourcing {ORCH_ADDRESS}');
t = fresh();
s(t, BT, '`SendMessage` to `{ORCH_ADDRESS}`, else', '`SendMessage` to');
red('49g the fallback sends by title alone again', 'check-invariants', t, "doesn't send to {ORCH_ADDRESS}");
t = fresh();
s(t, BT, '\\. On the terminal, `clear` is `never`, whatever the card says |', ' |');
red('49h the {PARAMETERS} row stops resolving clear on the terminal', 'check-invariants', t, "doesn't resolve `clear` to `never` on the terminal");
t = fresh();
s(t, SK, "your brief's `clear` is `never`", "your brief's `clear` says");
red('49i the Worker section stops saying a terminal worker never clears', 'check-invariants', t, "a terminal worker's clear is never");
t = fresh();
s(t, HO, '--permission-mode <mode> --autocompact <compact> "$(cat <brief file>)"', '--permission-mode <mode> "$(cat <brief file>)"');
red('49j terminal spawn stops passing --autocompact', 'check-invariants', t, "doesn't pass --autocompact <compact>");
t = fresh();
s(t, SK, 'never the summary; ask again', 'and the summary; ask again');
red('49k consent may come from a compaction summary again', 'check-invariants', t, 'consent after a compaction comes from the ledger');
t = fresh();
s(t, SK, 'to its address, with no ids or paths', 'to its address, with your ids');
red('50 a terminal ONLINE may carry ids again', 'check-invariants', t, 'a terminal report carries no ids or paths');
t = fresh();
s(t, BT, 'with no ids or paths in a body', 'with ids in a body');
red("50b and so may the fallback's", 'check-invariants', t, 'a terminal report carries no ids or paths');
t = fresh();
s(t, SK, 'on the desktop host also its own sessionId', 'on the desktop host also its own id');
red("51 desktop ONLINE loses the worker's sessionId", 'check-invariants', t, "desktop ONLINE carries the worker's own sessionId");
t = fresh();
del(t, LG, '^  waiting.tsv ');
red('52 the crew dir listing drops a watchdog state file', 'check-invariants', t, `${LG}: the crew dir listing doesn't name waiting.tsv`);
t = fresh();
s(t, SK, '`active.tsv` and `waiting.tsv`, never', '`active.tsv`, never');
red('53 step 7 stops deleting it', 'check-invariants', t, "step 7 doesn't delete waiting.tsv");

// --- check-skill-frontmatter ----------------------------------------------------------------------------------
t = fresh();
del(t, SK, '^license: MIT$');
red('31 a missing license', 'check-skill-frontmatter', t, 'missing frontmatter: license');
// The line names "metadata" on purpose: an unanchored /metadata/ match would open the metadata block
// there, so 31b is what fails if the check's `^metadata:` anchor is lost.
t = fresh();
s(t, SK, '^description: >-$', 'description: >-\\\n  author: a line in the description, and metadata mentioned');
green('31b a description with its own author: line passes while metadata has one', 'check-skill-frontmatter', t);
del(t, SK, '^  author: Acatl Pacheco$'); // the same fixture, metadata's author removed
red("32 an author: line in the description doesn't stand in for metadata.author", 'check-skill-frontmatter', t, 'missing frontmatter: author');
t = fresh();
s(t, SK, '^  author: Acatl Pacheco$', '  author: Acatl Pacheco\\\n  links:\\\n    author: nested one level too deep');
green('32b a nested author: beside the real one passes', 'check-skill-frontmatter', t);
del(t, SK, '^  author: Acatl Pacheco$'); // the same fixture, the real one removed
red("33 an author: nested under another metadata key doesn't count", 'check-skill-frontmatter', t, 'missing frontmatter: author');
t = fresh();
s(t, SK, '^metadata:$', 'metadata:\\\n    # a comment, indented deeper than the keys');
green("34 a comment opening metadata doesn't set the child indent", 'check-skill-frontmatter', t);
del(t, SK, '^  version: '); // positive control for 34: the same fixture, a key removed
red('34b the same fixture still fails on a missing version', 'check-skill-frontmatter', t, 'missing frontmatter: version');

// --- bash compatibility: inputs where the port once parted from the bash checks --------------------------------
// The compatibility audit of 2026-11-03 ran each bash check at 77dfa9c and its port on the same trees. These
// are the inputs where the port got it wrong, each kept to the bash's result: a CRLF file (awk's and grep's .
// takes the \r, JavaScript's needs the s flag), a › at a line's end, the heading list's commas, a duplicated
// fallback section, Unicode spaces where the bash's grep ran in CI's UTF-8 locale, and symlinks.
const crlf = (t2, p) => t2.set(p, t2.get(p).replaceAll('\n', '\r\n'));

t = fresh();
crlf(t, HO);
green("54 a CRLF host.md's verbs are each cited elsewhere, as they are", 'check-invariants', t);
append(t, HO, '| *bogus* | a | b |\r\n'); // the same fixture, a verb nothing cites
red('54b and the same fixture names an uncited verb without its \\r', 'check-invariants', t, 'the verb *bogus* is cited nowhere else');
t = fresh();
crlf(t, SK);
run('check-invariants', t);
ok("55 a CRLF SKILL.md's message kinds carry no \\r into the fallback comparison", !last.out.includes('the fallback section'), last.out);
s(t, BT, 'A `RELAY` carries', 'A relay carries'); // the same fixture, a kind dropped
red('55b and the same fixture still finds a kind the fallback drops', 'check-invariants', t, "doesn't name `RELAY`");
t = fresh();
append(t, PR, '\nIt never relays\na go for the merge.\n'); // a refusal that wraps before its go
crlf(t, PR);
green("56 a CRLF integration's refusal, wrapped before its go, still refuses it", 'check-invariants', t);
s(t, PR, 'who merges by hand or in the', "who merges by hand or answers here, and it relays the operator's go, or in the");
red('56b and the same fixture catches one that relays a go', 'check-invariants', t, `${PR}: accepts a relayed go for the merge`);

t = fresh();
append(t, 'skills/crew/references/host.md', 'See `CREW.md` ›\r\nDefaults for it.\n');
red(
  "57 a › that ends a CRLF line keeps the whole match in the message, as ${hit#*› } did",
  'check-section-refs',
  t,
  "'CREW.md › CREW.md` ›\r Defaults for it' names no section",
);
t = fresh();
s(t, CM, '^## Defaults$', '## Defaults, more');
red("58 the heading list widens a heading's own comma, as the bash's sed did", 'check-section-refs', t, 'Ledger, Defaults,  more)');
t = fresh();
append(t, CM, '## \n## \n');
append(t, SK, '\nSee `CREW.md` › Nosuch for it.\n');
red('58b trailing empty headings are dropped, as $(…) dropped them', 'check-section-refs', t, 'Ledger, Defaults)');
t = fresh();
change(t, CM, (ls) => [...ls.slice(0, ls.findIndex((l) => l.startsWith('## Template')) + 1), '## '], 'cut the template to one empty heading');
red("58c a template whose only heading is empty has none", 'check-section-refs', t, "no '## ' headings after '## Template'");

t = fresh();
dup(t, BT, '^## If the `crew` skill is unavailable');
red('59 a duplicated fallback section fails, as the bash did', 'check-invariants', t, "two '## If the `crew` skill is unavailable' sections");

t = fresh();
s(t, SK, '^license: MIT$', 'license: ');
green("60 a license of one no-break space isn't blank to CI's grep (glibc's space class leaves it out)", 'check-skill-frontmatter', t);
s(t, SK, '^license: $', 'license: '); // the same fixture, an em space
red('60b but one of an em space is', 'check-skill-frontmatter', t, 'missing frontmatter: license');
t = fresh();
s(t, WD, '^    proj=', '    proj=');
green("61 watchdog.sh's proj= line indented with a Unicode space is still found, as CI's grep found it", 'check-invariants', t);
s(t, WD, "sed 's#\\[/\\.\\]#-#g'", "sed 's#/#-#g'"); // the same fixture, the slug drifted
red('61b and the same fixture still reads its slug', 'check-invariants', t, 'the transcript-dir slug is');

// symlinks, on disk: the bash read a file by its path through a link, but find -type f and grep -r never
// listed or entered one
{
  const script = (dir, c) => execIn(dir, process.execPath, [`scripts/${c}.mjs`]);
  const outside = (dir, p) => {
    const away = join(temp(), p.split('/').at(-1));
    writeFileSync(away, readFileSync(join(dir, p), 'utf8'));
    rmSync(join(dir, p));
    symlinkSync(away, join(dir, p));
    return away;
  };
  let dir = write(fresh(), temp());
  let away = outside(dir, HO);
  let r = script(dir, 'check-invariants');
  ok('62 a host.md linked from outside the repo is read through its link', r.rc === 0, `rc=${r.rc} ${r.out}`);
  writeFileSync(away, readFileSync(away, 'utf8').replace(/^\| \*[a-z-]+\* \|.*$/gm, ''));
  r = script(dir, 'check-invariants');
  ok('62b and its target losing the verb rows fails', r.rc === 1 && r.out.includes("the verb table's rows"), `rc=${r.rc} ${r.out}`);
  r = script(dir, 'check-budget');
  ok('62c a linked reference file is not gone: [ -f ] followed its link', r.rc === 0, `rc=${r.rc} ${r.out}`);
  rmSync(away);
  r = script(dir, 'check-budget');
  ok('62d but once its link dangles, its budget is gone', r.rc === 1 && r.out.includes(`${HO}: budgeted but gone`), `rc=${r.rc} ${r.out}`);

  dir = write(fresh(), temp());
  away = outside(dir, SK);
  r = script(dir, 'check-skill-frontmatter');
  ok('62e a SKILL.md linked from outside is globbed and read', r.rc === 0, `rc=${r.rc} ${r.out}`);
  writeFileSync(away, readFileSync(away, 'utf8').replace(/^license: MIT\n/m, ''));
  r = script(dir, 'check-skill-frontmatter');
  ok("62f and its target's missing license fails", r.rc === 1 && r.out.includes('missing frontmatter: license'), `rc=${r.rc} ${r.out}`);

  dir = write(fresh(), temp());
  symlinkSync('..', join(dir, 'skills/crew/references/up'));
  r = script(dir, 'check-invariants');
  ok('62g a link back up the skill neither loops nor adds files', r.rc === 0, `rc=${r.rc} ${r.out}`);
  writeFileSync(join(dir, SK), readFileSync(join(dir, SK), 'utf8').replace('(1200 / 3600 / 3)', '(1200 / 1800 / 3)'));
  r = script(dir, 'check-invariants');
  ok('62h and the same tree still fails on a drift', r.rc === 1 && r.out.includes(SK), `rc=${r.rc} ${r.out}`);

  // find and grep -r skip a link they meet below their start, but resolve one above it like any path
  const linkOut = (dir, p) => {
    const away = join(temp(), 'target');
    renameSync(join(dir, p), away);
    symlinkSync(away, join(dir, p));
  };
  const marker = 'Stray crew:breef here.\n';
  dir = write(fresh(), temp());
  away = join(temp(), 'm.md');
  writeFileSync(away, marker);
  symlinkSync(away, join(dir, 'skills/crew/references/m.md'));
  r = script(dir, 'check-invariants');
  ok("62i a linked .md under skills/crew isn't searched, as grep -r and find skipped it", r.rc === 0, `rc=${r.rc} ${r.out}`);
  dir = write(fresh(), temp());
  writeFileSync(join(dir, 'skills/crew/references/m.md'), marker);
  r = script(dir, 'check-invariants');
  ok('62j while the same file, not linked, is', r.rc === 1 && r.out.includes("'crew:breef'"), `rc=${r.rc} ${r.out}`);
  dir = write(fresh(), temp());
  away = join(temp(), 'ledger.md');
  writeFileSync(away, readFileSync(join(dir, LG), 'utf8').replace(/$/gm, ' more words here'));
  rmSync(join(dir, LG));
  symlinkSync(away, join(dir, LG));
  r = script(dir, 'check-budget');
  ok("62k a linked reference file isn't counted, as find skipped it", r.rc === 0, `rc=${r.rc} ${r.out}`);
  rmSync(join(dir, LG)); // the same fixture, the link replaced by its target's words
  writeFileSync(join(dir, LG), readFileSync(away, 'utf8'));
  r = script(dir, 'check-budget');
  ok('62l while the same words, not linked, are over budget', r.rc === 1 && r.out.includes(`${LG}: `), `rc=${r.rc} ${r.out}`);
  const prFix = (dir2) =>
    writeFileSync(join(dir2, PR), `${readFileSync(join(dir2, PR), 'utf8')}\nOpen it with gh pr create --fill now.\n`);
  dir = write(fresh(), temp());
  linkOut(dir, 'docs/crew/integrations');
  prFix(dir);
  r = script(dir, 'check-invariants');
  ok("62m a linked docs/crew/integrations isn't entered: find's start may not be a link", r.rc === 0, `rc=${r.rc} ${r.out}`);
  dir = write(fresh(), temp());
  linkOut(dir, 'docs/crew');
  prFix(dir);
  r = script(dir, 'check-invariants');
  ok('62n while a link above the start, docs/crew, is resolved', r.rc === 1 && r.out.includes(`${PR}:`) && r.out.includes('gh pr create --fill'), `rc=${r.rc} ${r.out}`);
  dir = write(fresh(), temp());
  linkOut(dir, 'skills');
  r = script(dir, 'check-budget');
  ok('62o a linked skills/ is resolved for every check', r.rc === 0 && script(dir, 'check-invariants').rc === 0 && script(dir, 'check-section-refs').rc === 0, `rc=${r.rc} ${r.out}`);
  writeFileSync(join(dir, LG), `${readFileSync(join(dir, LG), 'utf8')}${marker}`);
  r = script(dir, 'check-invariants');
  ok('62p and the same tree finds a stray marker there', r.rc === 1 && r.out.includes("'crew:breef'"), `rc=${r.rc} ${r.out}`);
}

// a check finds the repo from its own path, not the working directory
{
  const dir = write(fresh(), temp());
  const elsewhere = temp();
  let r = execIn(elsewhere, process.execPath, [join(dir, 'scripts/check-invariants.mjs')]);
  ok('63 a check run from another directory reads the repo beside it', r.rc === 0 && r.out.startsWith('✓'), `rc=${r.rc} ${r.out}`);
  writeFileSync(join(dir, SK), readFileSync(join(dir, SK), 'utf8').replace('(1200 / 3600 / 3)', '(1200 / 1800 / 3)'));
  r = execIn(elsewhere, process.execPath, [join(dir, 'scripts/check-invariants.mjs')]);
  ok('63b and fails on a drift there', r.rc === 1 && r.out.includes(SK), `rc=${r.rc} ${r.out}`);
}
