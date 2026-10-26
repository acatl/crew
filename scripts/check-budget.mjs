#!/usr/bin/env node
// Word budget: SKILL.md and each references/*.md, per file, against baselines/budget.tsv. Every word
// is context a session loads, so a count may hold or fall, and a rise fails.
//
//   scripts/check-budget.mjs                         check; exit 1 on a rise, an unbudgeted file, a
//                                                    budgeted file that's gone, or a budget that isn't
//                                                    a whole number
//   scripts/check-budget.mjs --update                lower budgets to today's counts and drop a deleted
//                                                    file's budget; never raises
//   scripts/check-budget.mjs --update --allow-raise  set budgets to today's counts, rises and malformed
//                                                    budgets included
//
// --allow-raise is the operator's alone: a worker never raises a budget to get green.
//
// Words are runs of anything but spaces, tabs and line breaks, as awk's default field splitting counts
// them in the C locale, not wc -w: BSD and GNU wc can disagree on non-ASCII text, and the baseline is
// written on macOS but checked on Linux in CI.
import { lines, sortC } from './lib/md.mjs';
import { Report, main } from './lib/tree.mjs';

const BASELINE = 'baselines/budget.tsv';

const words = (text) => lines(text).reduce((n, l) => n + l.split(/[ \t]+/).filter(Boolean).length, 0);

export function checkBudget(tree, args = []) {
  const r = new Report();
  let update = false;
  let raise = false;
  for (const a of args) {
    if (a === '--update') update = true;
    else if (a === '--allow-raise') raise = true;
    else {
      r.err('usage: scripts/check-budget.mjs [--update [--allow-raise]]');
      r.rc = 2;
      return r;
    }
  }
  if (raise && !update) {
    r.err('--allow-raise only goes with --update: scripts/check-budget.mjs --update --allow-raise');
    r.rc = 2;
    return r;
  }
  const baseline = tree.get(BASELINE);
  if (baseline === undefined && !raise) {
    r.err(`✖ no ${BASELINE} — the operator creates it: scripts/check-budget.mjs --update --allow-raise`);
    r.rc = 1;
    return r;
  }
  // the baseline's rows, a last line with no newline included (the bash's `while read` skipped it, so a
  // gone file in that row went unreported while its budget still counted). Both passes read a row's
  // cells the same way, leading tabs dropped.
  const rows = lines(baseline ?? '').map((l) => l.replace(/^\t+/, '').split('\t'));
  const budgetOf = (f) => {
    const row = rows.find(([name]) => !name.startsWith('#') && name === f);
    // a hand edit's stray blank or \r around the number is not part of it
    return row === undefined ? '' : (row[1] ?? '').trim();
  };

  const files = [
    'skills/crew/SKILL.md',
    ...sortC(tree.keys()).filter((k) => k.startsWith('skills/crew/references/') && k.endsWith('.md')),
  ];
  // The skill always has reference files, so none means the lookup broke. Stop before either mode:
  // --update would otherwise drop every reference budget as "gone".
  if (files.length < 2) {
    r.err('✖ skills/crew/references: no *.md found — the lookup broke; update scripts/check-budget.mjs');
    r.rc = 1;
    return r;
  }

  // SKILL.md is always counted, so its absence is the lookup broken or the skill moved, never 0 words:
  // --update would budget it at 0, and drop it as gone in the same run.
  if (!tree.has(files[0])) {
    r.err(`✖ ${files[0]}: not found — the skill moved, or the lookup broke; update scripts/check-budget.mjs`);
    r.rc = 1;
    return r;
  }

  let fails = 0;
  let next = '';
  for (const f of files) {
    const have = words(tree.get(f));
    const budget = budgetOf(f);
    if (budget === '') {
      if (raise) {
        next += `${f}\t${have}\n`;
        r.out(`+ ${f}: ${have} words, budgeted`);
        continue;
      }
      r.err(
        `✖ ${f}: ${have} words and no budget — a new file; the operator budgets it with scripts/check-budget.mjs --update --allow-raise`,
      );
      fails++;
      continue;
    }
    // A budget that isn't a whole number: Number() reads 'many' as NaN, which compares false both ways
    // and --update wrote back as NaN, and reads '0x10' as 16 and '1e3' as 1000. The bash's integer test
    // aborted on each. --allow-raise re-budgets it at today's count, as it budgets a row with none.
    if (!/^[0-9]+$/.test(budget)) {
      if (raise) {
        next += `${f}\t${have}\n`;
        r.out(`+ ${f}: ${have} words, budgeted (was '${budget}')`);
        continue;
      }
      r.err(
        `✖ ${f}: its budget '${budget}' in ${BASELINE} is not a whole number — fix that row, or re-budget it with scripts/check-budget.mjs --update --allow-raise`,
      );
      fails++;
      next += `${f}\t${budget}\n`;
      continue;
    }
    const b = Number(budget);
    if (have > b) {
      if (raise) {
        next += `${f}\t${have}\n`;
        r.out(`↑ ${f}: ${budget} → ${have} words (+${have - b}), raised`);
        continue;
      }
      r.err(`✖ ${f}: ${have} words, over its budget of ${budget} (+${have - b}) — cut words, don't raise the budget`);
      fails++;
      next += `${f}\t${budget}\n`;
      continue;
    }
    if (have < b) {
      if (update) r.out(`↓ ${f}: ${budget} → ${have} words, lowered`);
      else r.out(`↓ ${f}: ${have} words, ${b - have} under its budget of ${budget} — lock it in with scripts/check-budget.mjs --update`);
    }
    next += `${f}\t${have < b ? have : b}\n`;
  }

  // budgets for files that no longer exist
  for (const [f] of rows) {
    if (f === '' || f.startsWith('#')) continue;
    if (tree.has(f)) continue;
    // Not a pass: a budgeted file that can't be found is either deleted (say so with --update) or
    // moved out of the files this check counts, where nothing would budget it.
    if (update) r.out(`- ${f}: gone, budget dropped`);
    else {
      r.err(`✖ ${f}: budgeted but gone — if it was deleted, drop its budget with scripts/check-budget.mjs --update`);
      fails++;
    }
  }

  if (update) {
    r.writes.set(
      BASELINE,
      '# Word budgets for the skill\'s files, checked by scripts/check-budget.mjs. A count may hold or\n' +
        '# fall; a rise fails. --update lowers these; only the operator raises one (--allow-raise).\n' +
        next,
    );
  }

  if (fails > 0) {
    r.err(`✖ ${fails} file(s) over budget, unbudgeted, gone or with a malformed budget (${BASELINE})`);
    r.rc = 1;
    return r;
  }
  r.out(`✓ every skill file is within its word budget (${BASELINE})`);
  return r;
}

main(import.meta.url, checkBudget);
