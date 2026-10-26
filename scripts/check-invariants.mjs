#!/usr/bin/env node
// The values the skill restates across files must agree (CLAUDE.md › Invariants that span files).
//
// Each value is read from its source of truth. Every copy is then found by pattern in any Markdown
// file under skills/crew, not in a named section, so a section that moves to another file is still
// checked. Copies are matched across line breaks.
//
// A pattern that matches nothing fails with its own message: the copy was reworded and this script
// needs updating. That is a different failure from a copy whose value drifted.
import {
  REFUSAL,
  clauses,
  docs,
  ere,
  fallbackCut,
  flat,
  frontmatter,
  here,
  lines,
  scan,
  section,
  sentenceWith,
  sentencesOf,
  sortC,
  uniqC,
  ws,
} from './lib/md.mjs';
import { Report, main } from './lib/tree.mjs';

const SKILL = 'skills/crew';
const SKILLMD = `${SKILL}/SKILL.md`;
const WATCHDOG = `${SKILL}/scripts/watchdog.sh`;
const OVERLAP = `${SKILL}/scripts/overlap.sh`;
const BRIEF = `${SKILL}/references/brief-template.md`;
const LEDGER = `${SKILL}/references/ledger.md`;
const IPR = `${SKILL}/references/integration-pr.md`;
const HOST = `${SKILL}/references/host.md`;
const WDTEST = 'test/watchdog.test.sh';

const WORDS = ['one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine'];
const word = (n) => WORDS[n - 1] ?? String(n);

// multiset difference of two lists, as comm -23 gives it for sorted input
const minus = (a, b) => {
  const rest = [...b];
  return a.filter((x) => {
    const i = rest.indexOf(x);
    if (i < 0) return true;
    rest.splice(i, 1);
    return false;
  });
};

export function checkInvariants(tree) {
  const r = new Report();
  const keys = sortC(tree.keys());
  const mds = keys.filter((k) => k.startsWith(`${SKILL}/`) && k.endsWith('.md'));
  const read = (p) => tree.get(p) ?? '';
  const D = (paths) => docs(tree, paths);
  const fileLines = (p) => lines(read(p));

  let fails = 0;
  let held = 0;
  const fail = (m) => {
    fails++;
    r.err(`✖ ${m}`);
  };
  const reworded = (where, what) =>
    fail(`${where}: ${what} not found — reworded? update scripts/check-invariants.mjs`);

  // expect <what> <ERE> <expected> <source>: every copy of <what> under skills/crew reads <expected>,
  // and there is at least one
  const expect = (what, re, want, src) => {
    const out = scan(re, D(mds));
    if (!out.length) return reworded(`${SKILL}/*.md`, what);
    let drift = false;
    for (const { loc, match } of out) {
      if (match !== want) {
        fail(`${loc}: ${what} reads '${match}', but ${src} makes it '${want}'`);
        drift = true;
      }
    }
    if (!drift) held++;
  };

  // --- the watchdog defaults: watchdog.sh is the source ---------------------------------------------
  const defaults = fileLines(WATCHDOG).filter((l) =>
    /^base="" interval=[0-9]+ nocommit=[0-9]+ step=[0-9]+$/.test(l),
  );
  if (!defaults.length) {
    reworded(WATCHDOG, 'the defaults line (base="" interval=N nocommit=N step=N)');
  } else {
    const [, iv, nc, st] = defaults[0].match(/interval=([0-9]+) nocommit=([0-9]+) step=([0-9]+)/);
    expect(
      'the watchdog defaults (interval / no-commit / step)',
      ws('[(][0-9]+ / [0-9]+ / [0-9]+[)]'),
      `(${iv} / ${nc} / ${st})`,
      WATCHDOG,
    );
    if (Number(iv) % 60 || Number(nc) % 60) {
      fail(
        `${WATCHDOG}: interval ${iv} s and no-commit ${nc} s must be whole minutes; the skill restates them in minutes`,
      );
    } else {
      const ivm = Math.trunc(Number(iv) / 60);
      const ncm = Math.trunc(Number(nc) / 60);
      expect('the no-commit default in minutes', ws('absent, [0-9]+ minutes'), `absent, ${ncm} minutes`, WATCHDOG);
      expect(
        "the interview's watchdog defaults",
        ws('[0-9]+ min · [0-9]+ min · step [0-9]+'),
        `${ivm} min · ${ncm} min · step ${st}`,
        WATCHDOG,
      );
      expect(
        "the template's watchdog line",
        ws(
          'check every [0-9]+ min · warn at [0-9]+ min with no commit · warn once sub-agents since the last push pass [0-9]+',
        ),
        `check every ${ivm} min · warn at ${ncm} min with no commit · warn once sub-agents since the last push pass ${st}`,
        WATCHDOG,
      );
    }
  }

  // --- exit codes: each script's header is the source --------------------------------------------------
  // The header and the skill word a code differently, so each code carries the words that must appear
  // on both sides.
  const wdExit = [];
  {
    let f = false;
    for (const l of fileLines(WATCHDOG)) {
      if (/^# Exit:/.test(l)) f = true;
      if (f && !ere('^#[[:space:]]+(Exit:[[:space:]]+)?[0-9>]').test(l)) break;
      if (f) wdExit.push(l);
    }
  }
  const wdCode = (code, headerWords, skillWords) => {
    // wd_code <code> <header words> <skill words>
    const header = ere(`^#[[:space:]]+(Exit:[[:space:]]+)?${code}[[:space:]].*${headerWords}`);
    if (!here(wdExit.join('\n')).some((l) => header.test(l))) {
      return reworded(WATCHDOG, `exit ${code} ('${headerWords}') in the Exit header`);
    }
    if (!scan(`\`${code}\`[[:space:]]+[^\`]*${ws(skillWords)}`, D(mds)).length) {
      return fail(
        `${SKILL}/*.md: no launch-failure code \`${code}\` reading '${skillWords}', which ${WATCHDOG}'s Exit header defines`,
      );
    }
    held++;
  };
  wdCode(2, 'usage', 'usage');
  wdCode(3, 'already holds', 'already holds');
  wdCode(4, 'no usable', 'no usable');

  const ovExit = fileLines(OVERLAP).filter((l) => /^# Exit:/.test(l));
  const ovCode = (code, headerWords, skillWords) => {
    // ov_code <code> <header words> <skill words>
    const header = ere(`(^|[^0-9])${code}[[:space:]]+${headerWords}`);
    if (!here(ovExit.join('\n')).some((l) => header.test(l))) {
      return reworded(OVERLAP, `exit ${code} ('${headerWords}') in the Exit line`);
    }
    if (!scan(`(^|[^0-9])${code} = ${ws(skillWords)}`, D(mds)).length) {
      return fail(`${SKILL}/*.md: no '${code} = ${skillWords}', but ${OVERLAP} exits ${code} on '${headerWords}'`);
    }
    held++;
  };
  ovCode(0, 'no overlap', 'clear');
  ovCode(1, 'overlap found', 'overlap');
  ovCode(2, 'usage or git error', 'usage or git error');

  // SKILL.md's frontmatter and body, each on one line, for the checks that read them whole
  const { fm: fmLines, body: bodyLines } = frontmatter(read(SKILLMD));
  const fm = flat(fmLines);
  const body = flat(bodyLines);

  // --- the brief marker: the brief template's first line is the source ---------------------------------
  const markerLine = fileLines(BRIEF)
    .map((l) => l.match(/^(<!-- crew:[a-z]*) /))
    .find(Boolean);
  if (!markerLine) {
    reworded(BRIEF, "the brief's '<!-- crew:…' first line");
  } else {
    const marker = markerLine[1];
    const name = marker.replace(/^<!-- /, '');
    let markerOk = true;
    if (!fm.includes(`starts with \`${marker}\``)) {
      fail(
        `${SKILLMD}: the frontmatter description doesn't say a worker's first message starts with \`${marker}\`, the marker ${BRIEF} opens the brief with`,
      );
      markerOk = false;
    }
    if (!body.includes(`starts with \`${marker}\``)) {
      fail(
        `${SKILLMD}: the role detection doesn't say a worker's first message starts with \`${marker}\`, the marker ${BRIEF} opens the brief with`,
      );
      markerOk = false;
    }
    // any other spelling of the marker's name, anywhere under skills/crew
    const own = new RegExp(`:${name}$`);
    for (const f of keys.filter((k) => k.startsWith(`${SKILL}/`))) {
      lines(read(f)).forEach((l, i) => {
        for (const [m] of l.matchAll(/crew:[a-z]+/g)) {
          const hit = `${f}:${i + 1}:${m}`;
          if (own.test(hit)) continue;
          const loc = hit.slice(0, hit.lastIndexOf(':crew:'));
          fail(`${loc}: '${hit.slice(loc.length + 1)}' is not the brief marker's name '${name}'`);
          markerOk = false;
        }
      });
    }
    if (markerOk) held++;
  }

  // --- the message kinds: SKILL.md's two Messages tables are the source ---------------------------------
  const kinds = [];
  {
    let f = false;
    let d = '';
    for (const l of fileLines(SKILLMD)) {
      if (/^### Messages/.test(l)) {
        f = true;
        continue;
      }
      if (f && /^##/.test(l)) break;
      if (f && /^Worker → orchestrator/.test(l)) d = 'worker';
      if (f && /^Orchestrator → worker/.test(l)) d = 'orchestrator';
      if (f && d && /^\| `[A-Z][A-Z-]*` \|/.test(l)) kinds.push([d, l.replace(/^\| `/, '').replace(/`.*/, '')]);
    }
  }
  const wk = sortC(kinds.filter(([d]) => d === 'worker').map(([, k]) => k));
  const ok = sortC(kinds.filter(([d]) => d === 'orchestrator').map(([, k]) => k));
  if (!wk.length || !ok.length) {
    reworded(SKILLMD, "the worker → orchestrator and orchestrator → worker tables under '### Messages'");
  } else {
    const all = sortC([...wk, ...ok]);
    const nwk = wk.length;
    let kindsOk = true;

    // the brief template's fallback section names every kind, and nothing else
    const fbLines = [];
    fileLines(BRIEF).forEach((l, i) => {
      if (l.startsWith('## If the `crew` skill is unavailable')) fbLines.push(i + 1);
    });
    if (!fbLines.length) {
      reworded(BRIEF, "the '## If the `crew` skill is unavailable' section");
      kindsOk = false;
    } else {
      const fbLine = fbLines.join('\n');
      const after = [];
      for (const l of fileLines(BRIEF).slice(fbLines[0])) {
        if (/^````/.test(l)) break;
        after.push(l);
      }
      const fb = uniqC(after.flatMap((l) => [...l.matchAll(/`[A-Z][A-Z-]+`/g)].map(([m]) => m.replaceAll('`', ''))));
      for (const k of minus(all, fb)) {
        fail(`${BRIEF}:${fbLine}: the fallback section doesn't name \`${k}\`, one of SKILL.md's message kinds`);
        kindsOk = false;
      }
      for (const k of minus(fb, all)) {
        fail(`${BRIEF}:${fbLine}: the fallback section names \`${k}\`, which SKILL.md's Messages tables don't define`);
        kindsOk = false;
      }
    }

    // the frontmatter description: "the worker's four reports (…), the orchestrator's X, Y and Z"
    const dw = fm.match(/^.*the worker's ([a-z]+) reports \(([^)]*)\).*$/);
    const dor = fm.match(/^.*the orchestrator's (([A-Z-]+, )*[A-Z-]+) and ([A-Z-]+).*$/);
    if (!dw || !dor) {
      reworded(SKILLMD, `the description's "the worker's N reports (…), the orchestrator's X, Y and Z"`);
      kindsOk = false;
    } else {
      const [, count, list] = dw;
      const descO = `${dor[1]} ${dor[3]}`.replaceAll(',', '');
      const listed = sortC(list.replaceAll(' ', '').split(','));
      if (count !== word(nwk) || listed.join('\n') !== wk.join('\n')) {
        fail(
          `${SKILLMD}: the description says the worker's ${count} reports (${list}), but the table has ${word(nwk)}: ${wk.join(' ')}`,
        );
        kindsOk = false;
      }
      if (sortC(descO.split(' ')).join('\n') !== ok.join('\n')) {
        fail(`${SKILLMD}: the description gives the orchestrator ${descO}, but the table has ${ok.join(' ')}`);
        kindsOk = false;
      }
    }

    // the worker's closing rule: "send anything besides the four kinds"
    const besides = scan(ws('besides the [a-z]+ kinds'), D(mds));
    if (!besides.length) {
      reworded(`${SKILL}/*.md`, 'the worker rule "besides the N kinds"');
      kindsOk = false;
    } else {
      for (const { loc, match } of besides) {
        if (match !== `besides the ${word(nwk)} kinds`) {
          fail(`${loc}: '${match}', but a worker sends ${word(nwk)} kinds: ${wk.join(' ')}`);
          kindsOk = false;
        }
      }
    }
    if (kindsOk) held++;
  }

  // --- the two slug rules, different on purpose ----------------------------------------------------------
  // Transcript dirs mirror Claude Code's own naming (/ and . become -), and the test copies it. Crew
  // dirs replace only /. They must not be unified.
  const sedOf = (ls) => {
    for (const l of ls) {
      const m = l.match(/sed '[^']*'/);
      if (m) return m[0];
    }
    return '';
  };
  const tSlug = sedOf(fileLines(WATCHDOG).filter((l) => ere('^[[:space:]]*proj=').test(l)));
  const testSlug = sedOf(fileLines(WDTEST).filter((l) => /^slug\(\)/.test(l)));
  const crewFn = [];
  {
    let f = false;
    for (const l of fileLines(LEDGER)) {
      if (/^crewdir\(\) \{/.test(l)) f = true;
      if (f && /^\}/.test(l)) break;
      if (f) crewFn.push(l);
    }
  }
  const crewSlug = sedOf(crewFn);
  let slugOk = true;
  if (tSlug !== "sed 's#[/.]#-#g'") {
    fail(
      `${WATCHDOG}: the transcript-dir slug is '${tSlug || 'not found'}', but Claude Code names those dirs with sed 's#[/.]#-#g'`,
    );
    slugOk = false;
  }
  if (testSlug !== tSlug) {
    fail(`${WDTEST}: slug() uses '${testSlug || 'not found'}', but ${WATCHDOG} uses '${tSlug}'`);
    slugOk = false;
  }
  if (crewSlug !== "sed 's#/#-#g'") {
    fail(
      `${LEDGER}: crewdir() slugs with '${crewSlug || 'not found'}', but crew dirs replace only / (sed 's#/#-#g'); don't unify it with the transcript slug`,
    );
    slugOk = false;
  }
  if (slugOk) held++;

  // --- the roster format: watchdog.sh's header is the source ---------------------------------------------
  // Its roster.tsv line names the columns ("<ticket> <TAB> <worktree-path> [<TAB> <start epoch>]"). A
  // copy runs from `<ticket>` to the next comma and must name the same columns, in order. There are two
  // copies, in two files (SKILL.md's Watchdog section and ledger.md's file listing today), counted by
  // file rather than named, so a section that moves is still checked. A copy reworded out of the pattern
  // drops the count, so it can't pass on the strength of the other.
  const ROSTER_COPIES = 2;
  const cols = (s) => (s.match(/<[a-z][a-z -]*>/g) ?? []).join(' ');
  const want = cols(
    fileLines(WATCHDOG)
      .filter((l) => ere('^#[[:space:]]+roster\\.tsv[[:space:]]+input:').test(l))
      .map((l) => l.replace(/,.*/, ''))
      .join('\n'),
  );
  if (!want) {
    reworded(WATCHDOG, "the header's 'roster.tsv    input:  <ticket> …' line");
  } else {
    let rosterOk = true;
    const copies = scan('<ticket>[^,]*,', D(mds));
    for (const { loc, match } of copies) {
      if (cols(match) !== want) {
        fail(`${loc}: the roster columns read '${cols(match)}', but ${WATCHDOG}'s header makes them '${want}'`);
        rosterOk = false;
      }
    }
    const files = uniqC(copies.map(({ file }) => file));
    if (files.length < ROSTER_COPIES) {
      reworded(
        `${SKILL}/*.md`,
        `a roster format copy ('<ticket>' … up to a comma) in ${ROSTER_COPIES} files, found in ${files.length}:${files.length ? ` ${files.join(' ')}` : ''}`,
      );
      rosterOk = false;
    }
    if (rosterOk) held++;
  }

  // --- ANSWER never answers an `answer: in this session only` question ---------------------------------
  // That boundary is SECURITY.md's consent-laundering scope, and it fell out of the orchestrator's side
  // twice under word-budget tightening. Three places must state it, each found by heading, not file: the
  // Orchestrator section, the Worker section, and the brief's fallback section. "State it" means one
  // sentence holding the marker, an ANSWER and a refusal (never, neither, no, not, refuse): nearness alone passed with
  // the guard sentence deleted, and a sentence without the refusal could invert the rule.
  const marker = '`answer: in this session only`';
  // sectionRule [any] <what the rule says> <strings> <[in-fence ok, heading ERE]...>: every section
  // states the rule; one held invariant when all do. Presence, not meaning: a string check pins that the
  // sentence is there, and reviewers judge what it says. any passes on to sentenceWith.
  const sectionRule = (any, says, strings, specs) => {
    let allOk = true;
    for (const [inFence, where] of specs) {
      const text = section(D(mds), where, inFence);
      if (!text) {
        reworded(`${SKILL}/*.md`, `a section headed '${where}'`);
        allOk = false;
      } else if (!sentenceWith(text, strings, any)) {
        fail(`${SKILL}/*.md: the section headed '${where}' no longer says, in one sentence, that ${says}`);
        allOk = false;
      }
    }
    if (allOk) held++;
  };
  const ORCH = [0, '^#+ Orchestrator[[:space:]]*$'];
  const WORKER = [0, '^#+ Worker[[:space:]]*$'];
  const FALLBACK = [1, '^#+ If the `crew` skill is unavailable'];
  sectionRule(false, `ANSWER never answers an ${marker} question`, [marker, 'ANSWER'], [ORCH, WORKER, FALLBACK]);

  // --- a relayed answer is never consent for a tool-permission prompt or a gated action ---------------------
  // The same scope. The contract's input invariant, the Worker section and the brief's fallback each say it
  // in one sentence holding "consent", "tool-permission", "gate" and a refusal ("consent" keeps Worker step
  // 5's ANSWER sentence, which names both but grants nothing, from standing in for the RELAY rule).
  sectionRule(
    false,
    'a relayed answer is never consent for a tool-permission prompt or a gated action',
    ['consent', 'tool-permission', 'gate'],
    [[0, '^#+ The contract'], WORKER, FALLBACK],
  );

  // --- a resume never carries consent ------------------------------------------------------------------------
  // The orchestrator's resume for a cleared worker restates facts learned since the brief, an operator call
  // among them. Restating the operator's Hard Gate yes there is the same consent laundering (an auto-mode
  // classifier blocked one, 2026-10-02). The Orchestrator section and ledger.md's cleared-worker invariant each
  // say so in one sentence holding "resume", "never carries consent", "gated action" and "plan approval": the
  // refusal is pinned in the phrase, since the sentence's "not even" would satisfy a bare refusal match.
  sectionRule(
    false,
    'a resume never carries consent for a gated action or a plan approval',
    ['resume', 'never carries consent', 'gated action', 'plan approval'],
    [ORCH, [0, '^#+ The cleared-worker invariant']],
  );

  // --- an ANSWER with no question pending is refused ----------------------------------------------------------
  // An ANSWER's trigger is a pending question (its Messages row); one that arrives with none is off-contract,
  // not an instruction (seen from an orchestrator in hg, 2026-10-01). The Worker section and the brief's
  // fallback each say so in one sentence holding ANSWER, "question pending" and "refuse".
  sectionRule(
    false,
    'an ANSWER with no question pending is refused',
    ['ANSWER', 'question pending', 'refuse'],
    [WORKER, FALLBACK],
  );

  // --- the integration's stop is the worker's stop -------------------------------------------------------------
  // Under an integration, a workflow's `handoff` continues into the integration's stages, so the worker's stop
  // stage is the integration's (Codex on acatl/crew#7). Read as the workflow's, the contract's Authority would
  // stop a compliant worker before its PR opens, and the ledger would evict a row whose PR rounds still run. So
  // SKILL.md's Authority and ledger.md's Eviction each say "stop stage" and "integration's" in one sentence.
  // Presence, not meaning; no refusal to require here.
  sectionRule(
    true,
    "the stop stage is the integration's when there is one",
    ['stop stage', "integration's"],
    [
      [0, '^#+ Authority[[:space:]]*$'],
      [0, '^#+ Eviction[[:space:]]*$'],
    ],
  );

  // --- a queued unit's card lives in its ledger row -------------------------------------------------------------
  // A queued brief has no Job section: START writes it later, from the card. A compaction in between destroys
  // the card, so a card choice the row doesn't hold falls back to CREW.md's default, and an `integration: none`
  // unit would open a PR (Codex on acatl/crew#7). Step 5's row write and ledger.md's spine each name the card's
  // lines with `integration` in one sentence, step 8 spawns every unit by step 5, and step 8, the Messages
  // START row and the START template write START from the row.
  const SPAWN = [0, '^#+ 5[.] Spawn'];
  const SHAPE = [0, '^#+ Shape[[:space:]]*$'];
  const SEQUENCES = [0, '^#+ 8[.] Sequences'];
  const START = [0, '^#+ START[[:space:]]*$'];
  sectionRule(
    true,
    "the ledger row holds the card's lines: integration, mode, Do not touch, decisions",
    ["card's lines", '`integration`', 'mode', '`Do not touch`', 'decision only in'],
    [SPAWN, SHAPE],
  );
  sectionRule(true, "START is written from the row's card lines", ['new base sha', "row's card lines"], [SEQUENCES]);
  sectionRule(
    true,
    'every queued unit is spawned by step 5, which writes its row',
    ['Spawn every unit now', 'step 5'],
    [SEQUENCES],
  );
  sectionRule(
    true,
    "the contract's START row is written from the unit's ledger row",
    ['queued brief left out', "unit's ledger row"],
    [[0, '^#+ Messages[[:space:]]*$']],
  );
  sectionRule(
    true,
    "START's Job fields take the card's lines from the ledger row",
    ['Job and Spec fields', 'ledger row'],
    [START],
  );

  // --- a queued unit's spec lives in briefs/<row>-spec.md ------------------------------------------------------
  // A queued brief drops its Spec, and the row's card lines leave the spec out, so a spec that lived only in the
  // orchestrator's conversation (a ticket source of "the spec below") was gone after a compaction before START
  // (Codex on acatl/crew#7). Step 5 saves it when the unit is queued; step 8, ledger.md's spine and the START
  // template's placeholder table take START's Spec from that file. The strings stop short of ".md": a
  // sentence ends at a period.
  sectionRule(true, "a queued brief's spec is saved to briefs/<row>-spec.md", ['queued brief', 'briefs/<row>-spec'], [SPAWN]);
  sectionRule(true, 'START takes its Spec from briefs/<row>-spec.md', ['Spec from `briefs/<row>-spec'], [SEQUENCES, SHAPE]);
  sectionRule(
    true,
    'the START template sources {SPEC} from briefs/<row>-spec.md',
    ['`{SPEC}`', 'briefs/<row>-spec', 'never from memory'],
    [START],
  );
  // The sentences above stop short of ".md"; the file name itself, extension included, is pinned here:
  // every copy reads briefs/<row>-spec.md, the whole name up to a backtick or whitespace, where every real
  // copy ends (a save and a read that disagree lose the spec: ".md.bak", ".md~" or ".md,v" is not ".md";
  // a sentence's closing period is not part of the name; any other wrapper reads as part of it and fails
  // closed), and each of the three files still names it.
  expect(
    "the queued unit's spec file",
    'briefs/<row>-spec([^`[:space:]]*[^`[:space:].])?',
    'briefs/<row>-spec.md',
    "SKILL.md step 5's save",
  );
  let specOk = true;
  for (const f of [SKILLMD, LEDGER, BRIEF]) {
    if (!read(f).includes('briefs/<row>-spec.md')) {
      fail(`${f}: no longer names briefs/<row>-spec.md, the file a queued unit's spec is saved to and read from`);
      specOk = false;
    }
  }
  if (specOk) held++;

  // --- a resume keeps the roster start -----------------------------------------------------------------------
  // Trigger 2 floors its sub-agent baseline at the roster start. A start reset at a resume after a clear would
  // drop the same worker's pre-clear sub-agents since its push: three before plus three after read as three
  // (acatl/crew#14). Step 6's resume sentence says the start is kept, and the Watchdog roster bullet to keep it
  // across resumes.
  sectionRule(true, 'a resume keeps the roster start', ['resume', 'roster start kept'], [[0, '^#+ 6[.] Handle messages']]);
  sectionRule(true, 'the roster start survives a resume', ['Keep it across resumes'], [[0, '^#+ Watchdog']]);

  // --- the workflow reaches a worker through its brief ------------------------------------------------------
  // Workers never read CREW.md: the orchestrator resolves the workflow (CREW.md › Workflows) into the
  // brief's {WORKFLOW_PATH} and {PARAMETERS}, and the worker reads the file the brief names. So no Worker
  // section mentions CREW.md at all (the orchestrator's may), the brief's Job line carries {WORKFLOW_PATH}, and its
  // placeholder row sources it from Workflows. In-flight workers spawned before workflows re-read the
  // Worker section at every resume and their briefs name no workflow, so the Worker section keeps the
  // line that makes their brief the workflow. Both contract copies give DONE its stage form.
  let wfOk = true;
  const worker = section(D(mds), WORKER[1], 0);
  if (!worker) {
    reworded(`${SKILL}/*.md`, 'a Worker section heading');
    wfOk = false;
  } else {
    if (worker.toLowerCase().includes('crew.md')) {
      fail(`${SKILL}/*.md: the Worker section cites CREW.md, but workers never read it; it reaches them through the brief`);
      wfOk = false;
    }
    const legacy =
      "No workflow named in your brief → your brief's Job/Spec, Boundaries and Checkpoints are the workflow; follow them as written.";
    if (!worker.includes(legacy)) {
      fail(`${SKILL}/*.md: the Worker section lost the legacy line for briefs that name no workflow: '${legacy}'`);
      wfOk = false;
    }
  }
  if (!scan(ws('Read `[{]WORKFLOW_PATH[}]` in full'), D([BRIEF])).length) {
    fail(`${BRIEF}: the brief's Job no longer says 'Read \`{WORKFLOW_PATH}\` in full'`);
    wfOk = false;
  }
  if (!scan(ws('[|] `[{]WORKFLOW_PATH[}]` [|] [^|]*`[^`|]*CREW\\.md` › Workflows'), D([BRIEF])).length) {
    fail(`${BRIEF}: no placeholder row sourcing {WORKFLOW_PATH} from \`CREW.md\` › Workflows`);
    wfOk = false;
  }
  for (const [inFence, where] of [[0, '^### Messages'], FALLBACK]) {
    const text = section(D(mds), where, inFence);
    for (const form of ['`checkpoint <stage>`', '`stop <stage>`']) {
      if (!text.includes(form)) {
        fail(`${SKILL}/*.md: the section headed '${where}' doesn't give DONE's ${form} form`);
        wfOk = false;
      }
    }
  }
  // the orchestrator still reads an older brief's DONE: the boundary form is a checkpoint, a plain DONE a stop
  const orch = section(D(mds), ORCH[1], 0);
  for (const form of ['`DONE · checkpoint: <boundary>`', 'plain `DONE` is a stop']) {
    if (!orch.includes(form)) {
      fail(`${SKILL}/*.md: the Orchestrator section lost its rule for an older brief's DONE: '${form}'`);
      wfOk = false;
    }
  }
  if (wfOk) held++;

  // --- the integration reaches a worker through its brief too ------------------------------------------------
  // The orchestrator resolves CREW.md › Integration into the brief's {INTEGRATION_PATH}, beside the workflow.
  // The ready brief's Job list names {WORKFLOW_PATH} and {INTEGRATION_PATH}, and START's Job list, which replaces
  // it for a queued worker, is the same list: one that drifted would drop the integration (or the workflow, or
  // `Do not touch`) its brief carried. Each list is its `## Job` section, read as section() reads one (fence-
  // aware, wrapped lines joined), less its `<Ready: …>` annotation. The ready one is cut off at the queued
  // block's heading; a renamed heading pulls the queued Job in, which fails as a mismatch, never passes.
  let ipOk = true;
  const jobList = (ls) =>
    section([[BRIEF, ls.map((l) => `${l}\n`).join('')]], '^## Job[[:space:]]*$', 1).replace(
      /<[A-Z][a-z]+: [^>]*> ?/g,
      '',
    );
  const briefLines = fileLines(BRIEF);
  const queued = briefLines.findIndex((l) => /^### Queued block/.test(l));
  const startAt = briefLines.findIndex((l) => ere('^## START[[:space:]]*$').test(l));
  const readyJob = jobList(queued < 0 ? briefLines : briefLines.slice(0, queued));
  const startJob = jobList(startAt < 0 ? [] : briefLines.slice(startAt));
  if (!readyJob) {
    reworded(BRIEF, "the ready brief's `## Job` section");
    ipOk = false;
  }
  if (!startJob) {
    reworded(BRIEF, "START's `## Job` section");
    ipOk = false;
  }
  if (readyJob) {
    for (const line of [
      '- Workflow: `{WORKFLOW}`. Read `{WORKFLOW_PATH}` in full',
      '- Integration: `{INTEGRATION_PATH}`.',
      '- Landing: `{LANDING}`',
    ]) {
      if (!readyJob.includes(line)) {
        fail(`${BRIEF}: the ready brief's Job list has no '${line}' line`);
        ipOk = false;
      }
    }
  }
  if (readyJob && startJob && readyJob !== startJob) {
    fail(
      `${BRIEF}: START's Job list differs from the ready brief's, which it replaces\n  brief: ${readyJob}\n  START: ${startJob}`,
    );
    ipOk = false;
  }
  if (!scan(ws('[|] `[{]INTEGRATION_PATH[}]` [|] [^|]*`[^`|]*CREW\\.md` › Integration'), D([BRIEF])).length) {
    fail(`${BRIEF}: no placeholder row sourcing {INTEGRATION_PATH} from \`CREW.md\` › Integration`);
    ipOk = false;
  }
  if (!scan(ws('[|] `[{]LANDING[}]` [|] card › Landing[^|]*`delegated`[^|]*`operator`'), D([BRIEF])).length) {
    fail(`${BRIEF}: no placeholder row resolving {LANDING} from card › Landing to \`delegated\` or \`operator\``);
    ipOk = false;
  }
  if (ipOk) held++;

  // --- the files that hold stages -------------------------------------------------------------------------------
  // The built-in workflow and integration must exist, or the checks over them would check nothing. A project's
  // own (docs/crew/workflows/, docs/crew/integrations/) may be absent: that dir is found, never globbed, so a
  // deleted one reads as empty, not as a reworded file.
  const stageFiles = [];
  for (const kind of ['workflow', 'integration']) {
    const glob = new RegExp(`^${SKILL}/references/${kind}-[^/]*\\.md$`);
    const found = keys.filter((k) => glob.test(k));
    if (!found.length) reworded(`${SKILL}/references/${kind}-*.md`, 'the built-in file');
    stageFiles.push(...found);
  }
  stageFiles.push(
    ...keys.filter(
      (k) => (k.startsWith('docs/crew/workflows/') || k.startsWith('docs/crew/integrations/')) && k.endsWith('.md'),
    ),
  );

  // --- a merge go names its delegation -----------------------------------------------------------------------
  // Landing needs delegation (the contract's Authority), and under Integration mode `pr` the written merge
  // rule delegates every card that doesn't say `landing: operator`. So every sentence that tells the worker
  // to merge, in a workflow or integration file, names that withholding: a merge ordered on the rule alone
  // would bypass the card.
  let mergeOk = true;
  let mergeSeen = false;
  for (const f of stageFiles) {
    for (const sentence of sentencesOf(read(f)).filter((s) => /tells? the worker to merge/i.test(s))) {
      mergeSeen = true;
      if (!sentence.toLowerCase().includes('`landing: operator`')) {
        fail(`${f}: tells the worker to merge without naming \`landing: operator\`: '${sentence}'`);
        mergeOk = false;
      }
    }
  }
  if (!mergeSeen) {
    reworded('the workflow and integration files', 'a sentence that tells the worker to merge');
    mergeOk = false;
  }
  if (mergeOk) held++;

  // --- a relayed go is never a merge go ---------------------------------------------------------------------------
  // A card's `landing: operator` voids the merge rule, so a merge under it is a Hard Gate; so is a merge on a missed
  // bar. Acting on a relayed go would launder consent across sessions (SECURITY.md; Codex on acatl/crew#7). The
  // brief carries the card's Landing, so every workflow or integration file that asks "merge?" (any quoting):
  // - refuses a relayed go in a sentence that names the "merge?" too, so a refusal elsewhere can't stand in;
  // - accepts none: no clause relays a go without a refusal in it ("relays the operator's go");
  // - marks the question `answer: in this session only` by the brief's Landing, in one sentence holding
  //   NEED-INPUT, that marker, "Landing", "unless" and `delegated`, which leaves the orchestrator nothing to
  //   relay. Presence, not meaning: the strings pin the sentence's shape, and reviewers judge its logic.
  // At least one file must ask, so finding none fails.
  let relayOk = true;
  let relaySeen = false;
  const goRefused =
    /(^|[^A-Za-z])([Nn]ever|[Nn]either|[Nn]o|[Nn]ot|[Rr]efuse)([^A-Za-z].*)?[^A-Za-z][Gg]o([^A-Za-z]|$)/;
  for (const f of stageFiles) {
    const sentences = sentencesOf(read(f));
    if (!sentences.some((s) => /merge\?/i.test(s))) continue;
    relaySeen = true;
    if (!sentences.some((s) => /merge\?/i.test(s) && s.includes('relayed go') && REFUSAL.test(s))) {
      fail(`${f}: asks "merge?" but no sentence naming it refuses a relayed go`);
      relayOk = false;
    }
    // Judged per clause (split at ", ", ": " and parentheses), so a refusal in the same sentence can't cover an
    // acceptance beside it ("…, the operator's go relayed to it, …, never a relayed go"), and the refusal must
    // come before the go ("relays no go"; not "relays the operator's go and no other"). The one shape a comma
    // splits ("says go, which it relays") is matched whole. The `answer: here or relay` marker names a channel,
    // not a relay: it is dropped first.
    const parts = clauses(sentences.map((s) => s.replaceAll('`answer: here or relay`', '')));
    if (
      parts.some(
        (c) =>
          /(^|[^a-z])relay(s|ed|ing)?([^a-z]|$)/i.test(c) && /(^|[^a-z])go([^a-z]|$)/i.test(c) && !goRefused.test(c),
      ) ||
      sentences.some((s) => s.toLowerCase().includes('says go, which it relays'))
    ) {
      fail(`${f}: accepts a relayed go for the merge`);
      relayOk = false;
    }
    if (
      !sentences.some(
        (s) =>
          s.includes('NEED-INPUT') &&
          s.includes(marker) &&
          s.includes('Landing') &&
          s.includes('unless') &&
          s.includes('`delegated`'),
      )
    ) {
      fail(`${f}: asks "merge?" but doesn't mark it ${marker} by the brief's Landing`);
      relayOk = false;
    }
  }
  if (!relaySeen) {
    reworded('the workflow and integration files', 'a "merge?" question');
    relayOk = false;
  }
  if (relayOk) held++;

  // --- a PR opens against the brief's base ----------------------------------------------------------------------
  // Without --base, `gh pr create` (alias `gh pr new`) targets the repo's default branch or the branch's
  // gh-merge-base, not the base the brief chose (SKILL.md step 3.4). The files spell the call one way,
  // `gh pr create --base <base>`, prose included: one canonical form is checkable exactly, where judging gh's
  // every spelling means parsing shell. Each call is matched on its own, with its own line, wrapped or not. The
  // built-in must name the call itself; a project's file can't stand in for it.
  let prOk = true;
  const prCanon = 'gh pr create --base <base>';
  // the call and its first two arguments, each a run of non-space; a backtick ends a code span
  const prRe =
    'gh[[:space:]]+pr[[:space:]]+(create|new)([[:space:]]+[^[:space:]`]+)?([[:space:]]+[^[:space:]`]+)?';
  for (const f of stageFiles) {
    for (const { loc, match } of scan(prRe, D([f]))) {
      if (match !== prCanon) {
        fail(`${loc}: opens a PR as '${match}', not '${prCanon}': without the brief's base it opens against the default branch`);
        prOk = false;
      }
    }
  }
  if (!scan(ws('gh pr create --base <base>'), D([IPR])).length) {
    reworded(IPR, `the call '${prCanon}'`);
    prOk = false;
  }
  if (prOk) held++;

  // --- a merge is confirmed before `stop merge` -------------------------------------------------------------------
  // On a base that requires a merge queue, `gh pr merge` only queues the PR (gh's own help), so a worker that reports
  // `stop merge` right after it has the orchestrator run Post-land and start the next unit on a PR that may still
  // fail the queue (Codex on acatl/crew#7). Every sentence in a workflow or integration file that names
  // `gh pr merge` also waits for `gh pr view` to read `MERGED` and names the merge queue: judged per sentence, so a
  // wait at one call site can't stand in for another. Presence, not meaning. The built-in names the call itself,
  // so the check can't pass on finding none.
  let mqOk = true;
  let mqSeen = false;
  for (const f of stageFiles) {
    for (const sentence of sentencesOf(read(f)).filter((s) => s.includes('gh pr merge'))) {
      if (f === IPR) mqSeen = true;
      if (
        !(
          sentence.includes('gh pr view') &&
          sentence.includes('`MERGED`') &&
          sentence.toLowerCase().includes('merge queue')
        )
      ) {
        fail(
          `${f}: names \`gh pr merge\` without waiting for \`gh pr view\` to read \`MERGED\` past a merge queue: '${sentence}'`,
        );
        mqOk = false;
      }
    }
  }
  if (!mqSeen) {
    reworded(IPR, "the call 'gh pr merge'");
    mqOk = false;
  }
  // The orchestrator lands on its own read, not the worker's word: SKILL.md's Land holds a sentence that runs
  // Post-land once `gh pr view` reads `MERGED`, which covers a workflow with its own PR stages too.
  if (
    !sentencesOf(read(SKILLMD)).some(
      (s) => s.includes('Post-land') && s.includes('gh pr view') && s.includes('`MERGED`'),
    )
  ) {
    fail(`${SKILLMD}: no sentence runs Post-land only once \`gh pr view\` reads \`MERGED\``);
    mqOk = false;
  }
  if (mqOk) held++;

  // --- the queue card shows each unit's workflow and landing ----------------------------------------------------
  // Under Integration mode `pr` landing is per unit (a PR-merging unit is delegated by the merge rule), so one
  // card-wide Landing line can show a delegated unit as "operator decides". The queue card's table carries both.
  const qhead = fileLines(SKILLMD).find((l) => /^> \| # \| Unit \|/.test(l));
  if (qhead === undefined) {
    reworded(SKILLMD, "the queue card's '> | # | Unit |' table header");
  } else {
    let qOk = true;
    for (const col of ['Workflow', 'Landing']) {
      if (!qhead.includes(`| ${col} |`)) {
        fail(`${SKILLMD}: the queue card has no per-unit ${col} column: '${qhead}'`);
        qOk = false;
      }
    }
    if (qOk) held++;
  }

  // --- a workflow's verify falls back as the orchestrator's does ------------------------------------------------
  // A worker's build ends on `verify` green, and the orchestrator verifies a stop by the brief's `verify`, else
  // its own chain (SKILL.md's "DONE `stop <stage>`" bullet, the source). A workflow's or integration's `verify`
  // default names the same sources, or a project missing one leaves the two sides verifying different things.
  // Each built-in must carry the row, so the check can't pass on finding none.
  let vOk = true;
  const sources = (s) => uniqC((s.match(/(CREW\.md|docs\/HARNESS\.md)` › [A-Z][a-z]+/g) ?? []));
  const stop = (orch.match(/[*][*]DONE `stop <stage>`[*][*][^-]*/) ?? [''])[0];
  const chain = sources(stop);
  if (!chain.length) {
    reworded(SKILLMD, "the Orchestrator's DONE `stop <stage>` verify chain");
    vOk = false;
  }
  for (const f of stageFiles) {
    const rows = lines(read(f)).filter((l) => /^\| `verify` \|/.test(l));
    if (!rows.length) {
      if (f.startsWith(`${SKILL}/references/`)) {
        reworded(f, 'the `verify` parameter row');
        vOk = false;
      }
      continue;
    }
    const got = sources(rows.join('\n'));
    if (chain.length && got.join('\n') !== chain.join('\n')) {
      fail(
        `${f}: the \`verify\` default falls back to '${got.join(',')}', but the orchestrator's verify falls back to '${chain.join(',')}'`,
      );
      vOk = false;
    }
  }
  if (vOk) held++;

  // --- a ready PR asks before it merges ----------------------------------------------------------------------
  // After `merge bar met` the worker waits on the merge, so it sends NEED-INPUT (SKILL.md Worker step 4), and
  // the merge go is an ANSWER to that question: no other kind can carry it. Every workflow or integration
  // file that names `merge bar met` holds a sentence that sends NEED-INPUT for the merge (the worker's;
  // the orchestrator's "answers only the worker's merge NEED-INPUT" doesn't count). At least one must
  // name it, so the check can't pass on finding none.
  let askOk = true;
  let askSeen = false;
  for (const f of stageFiles) {
    const sentences = sentencesOf(read(f));
    if (!sentences.some((s) => s.includes('merge bar met'))) continue;
    askSeen = true;
    if (
      !sentences.some(
        (s) => s.includes('NEED-INPUT') && /(^|[^a-z])sends /.test(s) && /merge([^a-z]|$)/i.test(s),
      )
    ) {
      fail(`${f}: names \`merge bar met\` but no sentence sends the merge \`NEED-INPUT\``);
      askOk = false;
    }
  }
  if (!askSeen) {
    reworded('the workflow and integration files', '`merge bar met`');
    askOk = false;
  }
  if (askOk) held++;

  // --- every brief state is handled on both sides ---------------------------------------------------------
  // A brief's marker line carries `state=`, and each value means a different first move: ready starts,
  // queued waits for START, resume (a re-send after a clear) skips ONLINE and the base step. The brief
  // template's {STATE} row is the source. SKILL.md's Orchestrator and Worker sections each name every value
  // (`state: <v>` or `state=<v>`), and the brief's fallback names every value, so a worker without the
  // skill still tells a resume from a fresh start. Both ways: a state SKILL.md handles that the row doesn't
  // list fails too, so a template that drops `resume` can't pass while SKILL.md still sends it.
  let stOk = true;
  const states = briefLines
    .filter((l) => /^\| `\{STATE\}` \|/.test(l))
    .flatMap((l) => [...l.replace(/^\| `\{STATE\}` \|/, '').matchAll(/`[a-z]+`/g)].map(([m]) => m.replaceAll('`', '')));
  if (!states.length) {
    reworded(BRIEF, 'the {STATE} placeholder row');
    stOk = false;
  } else {
    for (const spec of [ORCH[1], WORKER[1]]) {
      const text = section(D([SKILLMD]), spec, 0);
      for (const v of states) {
        if (!new RegExp(`state(: |=)${v}([^a-z]|$)`).test(text)) {
          fail(`${SKILLMD}: the section headed '${spec}' handles no brief state '${v}'`);
          stOk = false;
        }
      }
      for (const v of uniqC([...text.matchAll(/state(: |=)[a-z]+/g)].map(([m]) => m.replace(/^state(: |=)/, '')))) {
        if (!states.includes(v)) {
          fail(`${SKILLMD}: the section headed '${spec}' handles brief state '${v}', which ${BRIEF}'s {STATE} row doesn't list`);
          stOk = false;
        }
      }
    }
    const text = section(D([BRIEF]), FALLBACK[1], 1);
    for (const v of states) {
      if (!new RegExp(`(^|[^a-z])${v}([^a-z]|$)`).test(text)) {
        fail(`${BRIEF}: the fallback section handles no brief state '${v}'`);
        stOk = false;
      }
    }
  }
  if (stOk) held++;

  // --- the host layer: every verb has both hosts, and no app tool leaks past it ------------------------------
  // The skill names a verb in italics (*spawn*, *identify*) and references/host.md says how each host does
  // it, so the same skill runs in the desktop app and the terminal CLI. A verb row with an empty column is
  // a host the skill can't run on; a verb no file cites is dead; and an app tool named outside host.md
  // would run on one host only. The brief's fallback section is the one exception: a worker without the
  // skill can't read host.md, so it names both hosts' send mechanisms itself.
  let hOk = true;
  const others = mds.filter((f) => f !== HOST);
  const verbRows = fileLines(HOST).filter((l) => /^\| \*[a-z-]+\* \|/.test(l));
  const verbOf = (row) => row.replace(/^\| \*([a-z-]+)\* \|.*/, '$1');
  if (!verbRows.length) {
    reworded(HOST, "the verb table's rows ('| *verb* | desktop | terminal |')");
    hOk = false;
  } else {
    for (const row of verbRows) {
      const cells = row
        .split(/ \| /)
        .slice(1)
        .filter((c) => /[^ |]/.test(c)).length;
      if (cells < 2) {
        fail(`${HOST}: the verb *${verbOf(row)}* doesn't say how both hosts do it`);
        hOk = false;
      }
    }
    for (const v of verbRows.map(verbOf)) {
      if (!others.some((f) => read(f).includes(`*${v}*`))) {
        fail(`${HOST}: the verb *${v}* is cited nowhere else in the skill`);
        hOk = false;
      }
    }
  }
  const appTools = /mcp__ccd_|spawn_task|get_session|list_sessions|list_events|archive_session|clear_session|send_message/;
  const projects = keys.filter((k) => k.startsWith('docs/crew/') && k.endsWith('.md'));
  for (const doc of D([...others, ...projects])) {
    for (const hit of fallbackCut(doc).filter((l) => appTools.test(l))) {
      const at = hit.indexOf(': ');
      const tool = (hit.slice(at + 2).match(appTools) ?? [''])[0];
      fail(`${hit.slice(0, at)}: names a host's tool outside references/host.md (${tool}); name the verb instead`);
      hOk = false;
    }
  }
  if (hOk) held++;

  // --- the brief carries its host ----------------------------------------------------------------------------
  // A worker learns its host from the brief, and a brief from before hosts names none: it is desktop. The
  // brief's Orchestrator section carries `- host:`, the {HOST} row sources it from *self*, and the Worker
  // section says a brief with no host line is desktop.
  let hoOk = true;
  const briefOrch = section(D([BRIEF]), '^## Orchestrator[[:space:]]*$', 1);
  if (!briefOrch.includes('- host: `{HOST}`')) {
    fail(`${BRIEF}: the brief's Orchestrator section has no '- host: \`{HOST}\`' line`);
    hoOk = false;
  }
  if (!briefLines.some((l) => /^\| `\{HOST\}` \| \*self\*/.test(l))) {
    fail(`${BRIEF}: no placeholder row sourcing {HOST} from *self*`);
    hoOk = false;
  }
  // A title can be shared by two live sessions (two orchestrators, seen live 2026-10-15); a socket can't. On
  // the terminal the brief carries the orchestrator's socket address, and the fallback section sends to it.
  if (!briefOrch.includes('- address: `{ORCH_ADDRESS}`')) {
    fail(`${BRIEF}: the brief's Orchestrator section has no '- address: \`{ORCH_ADDRESS}\`' line`);
    hoOk = false;
  }
  if (!briefLines.some((l) => /^\| `\{ORCH_ADDRESS\}` \| \*self\*/.test(l))) {
    fail(`${BRIEF}: no placeholder row sourcing {ORCH_ADDRESS} from *self*`);
    hoOk = false;
  }
  if (!section(D([BRIEF]), FALLBACK[1], 1).includes('`SendMessage` to `{ORCH_ADDRESS}`')) {
    fail(`${BRIEF}: the fallback section doesn't send to {ORCH_ADDRESS} on the terminal`);
    hoOk = false;
  }
  if (hoOk) held++;
  sectionRule(true, 'a brief with no host line is desktop', ['host:', 'none is `desktop`'], [WORKER]);

  // --- the worker's ledger is the brief's ----------------------------------------------------------------------
  // A terminal worker can't write its git dir (worktree isolation, seen live 2026-10-15), so the brief names
  // the ledger in the crew dir. It holds the consent a resume must never carry, so a brief that lost the line
  // would leave a restarted worker with nothing. The brief's Housekeeping carries {WORKER_LEDGER}, its row
  // sources it from the crew dir, and the Worker section reads its ledger from the brief.
  let wlOk = true;
  if (!section(D([BRIEF]), '^## Housekeeping[[:space:]]*$', 1).includes('{WORKER_LEDGER}')) {
    fail(`${BRIEF}: the brief's Housekeeping section doesn't name {WORKER_LEDGER}`);
    wlOk = false;
  }
  if (!briefLines.some((l) => /^\| `\{WORKER_LEDGER\}` \| `~\/\.claude\/crew\/<slug>\/briefs\/<row>-worker-ledger\.md`/.test(l))) {
    fail(`${BRIEF}: no placeholder row sourcing {WORKER_LEDGER} from the crew dir`);
    wlOk = false;
  }
  if (wlOk) held++;
  sectionRule(true, "a worker's ledger is the one its brief names", ['ledger', 'Housekeeping names'], [WORKER]);

  // --- a terminal worker never clears --------------------------------------------------------------------------
  // A terminal worker can't clear itself, and restarting it at every checkpoint closed the operator's attached
  // view each time (seen live, 2026-10-15). So on the terminal `clear` resolves to `never` and the worker
  // compacts in place; a restart only recovers a crashed or wedged worker. The brief's {PARAMETERS} row and the
  // Worker section each say so.
  if (briefLines.some((l) => /^\| `\{PARAMETERS\}` \|/.test(l) && l.includes('On the terminal, `clear` is `never`'))) held++;
  else fail(`${BRIEF}: the {PARAMETERS} row doesn't resolve \`clear\` to \`never\` on the terminal`);
  sectionRule(true, "a terminal worker's clear is never", ['terminal', '`clear` is `never`'], [WORKER]);
  // It compacts at the card's size instead, so terminal *spawn* passes --autocompact; and a compaction summary
  // is never the source of consent, which only the worker's ledger holds.
  if (fileLines(HOST).some((l) => /^\| \*spawn\* \|/.test(l) && l.includes('--autocompact <compact>'))) held++;
  else fail(`${HOST}: terminal *spawn* doesn't pass --autocompact <compact>`);
  sectionRule(true, 'consent after a compaction comes from the ledger', ['ledger', 'consent', 'never the summary'], [WORKER]);

  // --- a terminal report carries no ids or paths -------------------------------------------------------------
  // Auto mode's classifier refused an ONLINE carrying a session id, a worktree path and the peer list as data
  // exfiltration (seen live, 2026-10-14), so on the terminal the orchestrator reads those itself. Desktop
  // ONLINE keeps the worker's sessionId: spawn_task returns only a task_id, so it is how the orchestrator
  // learns the worker. Both copies of the contract say each.
  sectionRule(true, 'a terminal report carries no ids or paths', ['terminal', 'no ids or paths'], [WORKER, FALLBACK]);
  sectionRule(
    true,
    "desktop ONLINE carries the worker's own sessionId",
    ['desktop host', 'sessionId'],
    [[0, '^#+ Messages[[:space:]]*$']],
  );

  // --- the watchdog's state files are listed and cleaned up --------------------------------------------------
  // Each file the watchdog keeps across runs (its dedupe and clocks) is listed in ledger.md's crew dir, and
  // step 7 deletes it when the last worker goes: one left behind dedupes or clocks a later worker reusing a
  // ticket id. The watchdog header is the source.
  let sfOk = true;
  const stateFiles = [];
  {
    // the header from '# State, all in' through the next '# Triggers' line, as sed -n '/a/,/b/p' reads it
    let inRange = false;
    for (const l of fileLines(WATCHDOG)) {
      if (inRange) {
        if (/^# Triggers/.test(l)) inRange = false;
      } else if (/^# State, all in/.test(l)) {
        inRange = true;
      } else {
        continue;
      }
      const m = l.match(/^# {3}[a-z]+\.(txt|tsv)/);
      if (m) stateFiles.push(m[0].slice(4));
    }
  }
  if (!stateFiles.length) {
    reworded(WATCHDOG, "the header's state-file list");
    sfOk = false;
  }
  const cleanupText = section(D([SKILLMD]), '^#+ 7\\. Cleanup', 0);
  for (const f of stateFiles) {
    if (f === 'roster.tsv') continue; // the orchestrator's input, rewritten, never deleted
    if (!read(LEDGER).includes(f)) {
      fail(`${LEDGER}: the crew dir listing doesn't name ${f}, which ${WATCHDOG} keeps`);
      sfOk = false;
    }
    if (!cleanupText.includes(f)) {
      fail(`${SKILLMD}: step 7 doesn't delete ${f}, which ${WATCHDOG} keeps`);
      sfOk = false;
    }
  }
  if (sfOk) held++;

  if (fails > 0) {
    r.err(`✖ ${fails} restated value(s) drifted; CLAUDE.md › Invariants that span files lists every copy`);
    r.rc = 1;
    return r;
  }
  r.out(`✓ every restated value agrees (${held} invariants)`);
  return r;
}

main(import.meta.url, checkInvariants);
