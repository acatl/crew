// The repo as the skill checks see it, and how each check reports. A check is a function of a tree
// (a Map of repo-relative path to text) that returns a Report, so the suite (test/checks.test.mjs)
// calls it in-process on an edited copy of the tree; run as a script, it reads the real repo.
import { readFileSync, readdirSync, realpathSync, renameSync, writeFileSync, writeSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// What the checks read: the skill, the baselines, this repo's workflows and integrations, and the
// watchdog suite (the slug check reads its slug()).
export const ROOTS = ['skills', 'baselines', 'docs/crew'];
export const FILES = ['test/watchdog.test.sh'];

// readTree <repo root>: every regular file under ROOTS, and FILES, as {path → text}. Symlinks are
// skipped, as find -type f skipped them; a root that's missing is simply absent.
export function readTree(root) {
  const tree = new Map();
  const walk = (rel) => {
    let entries;
    try {
      entries = readdirSync(join(root, rel), { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const p = `${rel}/${e.name}`;
      if (e.isDirectory()) walk(p);
      else if (e.isFile()) tree.set(p, readFileSync(join(root, p), 'utf8'));
    }
  };
  for (const r of ROOTS) walk(r);
  for (const f of FILES) {
    try {
      tree.set(f, readFileSync(join(root, f), 'utf8'));
    } catch {
      // absent: the check that reads it reports it
    }
  }
  return tree;
}

// What a check printed, in order and by stream, its exit code, and any file it rewrote.
export class Report {
  constructor() {
    this.chunks = [];
    this.rc = 0;
    this.writes = new Map();
  }
  out(line) {
    this.chunks.push([1, `${line}\n`]);
  }
  err(line) {
    this.chunks.push([2, `${line}\n`]);
  }
  // both streams as one, as a terminal or 2>&1 shows them
  get text() {
    return this.chunks.map(([, s]) => s).join('');
  }
}

// main <import.meta.url> <check>: run the check on the repo when its file is the script node was
// given, and do nothing when the suite imports it. Output is written synchronously, so stdout and
// stderr keep their order when both go to one pipe.
export function main(url, check) {
  const self = fileURLToPath(url);
  let given;
  try {
    given = realpathSync(process.argv[1]);
  } catch {
    return; // no script path (node -e, a REPL), or not a file: imported, not run
  }
  if (given !== realpathSync(self)) return;
  const root = resolve(dirname(self), '..');
  const report = check(readTree(root), process.argv.slice(2));
  for (const [path, text] of report.writes) {
    writeFileSync(join(root, `${path}.tmp`), text);
    renameSync(join(root, `${path}.tmp`), join(root, path));
  }
  for (const [fd, s] of report.chunks) writeSync(fd, s);
  process.exitCode = report.rc;
}
