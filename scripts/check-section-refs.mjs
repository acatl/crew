#!/usr/bin/env node
// Every prose reference the skill makes resolves. lychee checks Markdown links; these are the
// references it can't see:
//   - `CREW.md` › <Section> names a `## <Section>` heading of the docs/CREW.md template in
//     references/crew-md.md. Only the first level is checked: "Ledger › watchdog" checks "Ledger".
//   - every references/<name>.md mentioned under skills/crew exists;
//   - every <skill-dir>/scripts/<name> the skill runs exists under skills/crew/scripts/.
import { docs, lines, scan, sortC } from './lib/md.mjs';
import { Report, main } from './lib/tree.mjs';

const SKILL = 'skills/crew';
const TEMPLATE = `${SKILL}/references/crew-md.md`;

export function checkSectionRefs(tree) {
  const r = new Report();
  const files = sortC(tree.keys()).filter(
    (k) => k.startsWith(`${SKILL}/`) && (k.endsWith('.md') || k.endsWith('.sh')),
  );
  const D = docs(tree, files);

  let fails = 0;
  let refs = 0;
  const fail = (m) => {
    fails++;
    r.err(`✖ ${m}`);
  };
  // requireSome <kind> <refs before its loop>: every kind exists in the skill today, so none at all
  // means the pattern broke. A check that saw nothing must not pass.
  const requireSome = (kind, before) => {
    if (refs === before) {
      fail(`${SKILL}: found no ${kind} — the pattern or the skill changed; update scripts/check-section-refs.mjs`);
    }
  };

  const headings = [];
  {
    let f = false;
    for (const l of lines(tree.get(TEMPLATE) ?? '')) {
      if (/^## Template/.test(l)) {
        f = true;
        continue;
      }
      if (f && /^## /.test(l)) headings.push(l.replace(/^## /, ''));
    }
  }
  if (!headings.length) {
    fail(`${TEMPLATE}: no '## ' headings after '## Template' — reworded? update scripts/check-section-refs.mjs`);
    r.rc = 1;
    return r;
  }

  let before = refs;
  // `CREW.md` › <Section>: the match stops at the first character a heading can't hold, so what's left
  // must be a heading, alone or followed by a space and more words ("Integration allows it").
  for (const { loc, match } of scan('CREW\\.md`?[[:space:]]+›[[:space:]]+[A-Za-z][A-Za-z -]*', D)) {
    refs++;
    const name = match.slice(match.indexOf('› ') + 2);
    if (!headings.some((h) => name === h || name.startsWith(`${h} `))) {
      fail(
        `${loc}: 'CREW.md › ${name}' names no section of the CREW.md template in ${TEMPLATE} (${headings.join(', ')})`,
      );
    }
  }
  requireSome("'CREW.md › Section' references", before);

  // references/<name>.md, backticked or bare or linked
  before = refs;
  for (const { loc, match } of scan('references/[A-Za-z0-9._-]+\\.md', D)) {
    refs++;
    if (!tree.has(`${SKILL}/${match}`)) fail(`${loc}: ${match} doesn't exist under ${SKILL}/`);
  }
  requireSome('references/<name>.md mentions', before);

  // <skill-dir>/scripts/<name>
  before = refs;
  for (const { loc, match } of scan('<skill-dir>/scripts/[A-Za-z0-9._-]+', D)) {
    refs++;
    const path = `${SKILL}/${match.replace(/^<skill-dir>\//, '')}`;
    if (!tree.has(path)) fail(`${loc}: ${match} doesn't exist (${path})`);
  }
  requireSome('<skill-dir>/scripts/ calls', before);

  if (fails > 0) {
    r.err(`✖ ${fails} problem(s) across ${refs} references`);
    r.rc = 1;
    return r;
  }
  r.out(`✓ all ${refs} section, reference and script references resolve`);
  return r;
}

main(import.meta.url, checkSectionRefs);
