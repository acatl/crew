// Unit tests for scripts/lib/md.mjs, the text primitives every skill check stands on. Each pins one
// behaviour the checks' messages depend on, on a few lines of synthetic text:
//
//   node --test test/*.test.mjs
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  clauses,
  ere,
  ereU,
  fallbackCut,
  flat,
  frontmatter,
  lines,
  scan,
  section,
  sentenceWith,
  sentencesOf,
  sortC,
  ws,
} from '../scripts/lib/md.mjs';

test('ere translates POSIX bracket classes, and only ASCII whitespace is [:space:]', () => {
  assert.ok(ere('^a[[:space:]]+b$').test('a \t b'));
  assert.ok(!ere('^a[[:space:]]+b$').test('a b'));
  assert.ok(ere('[^`[:space:]]').test('x'));
  assert.ok(!ere('^[^`[:space:]]$').test('`'));
});

test('ws widens each space to any whitespace run', () => {
  assert.equal(ws('a b'), 'a[[:space:]]+b');
  assert.ok(ere(ws('max lines')).test('max\n  lines'));
});

test('lines reads records as awk does: a final newline ends a line, a missing one still counts', () => {
  assert.deepEqual(lines('a\nb\n'), ['a', 'b']);
  assert.deepEqual(lines('a\nb'), ['a', 'b']);
  assert.deepEqual(lines('a\n\n'), ['a', '']);
  assert.deepEqual(lines(''), []);
});

test('flat joins lines with a space and squeezes runs of spaces, never tabs', () => {
  assert.equal(flat(['a  b', '', 'c\t\td']), 'a b c\t\td ');
});

test('scan matches across a line break and reports the line the match starts on', () => {
  const hits = scan(ws('three four'), [['f.md', 'one two\nthree\nfour five\n']]);
  assert.deepEqual(
    hits.map(({ loc, match }) => [loc, match]),
    [['f.md:2', 'three four']],
  );
});

test('scan squeezes blanks inside a match and drops one trailing space', () => {
  const [hit] = scan('b[ \t]+c[ \t]*', [['f.md', 'a b \t c  \n']]);
  assert.equal(hit.match, 'b c');
});

test('scan restarts after each match, so ^ anchors on the rest of the text', () => {
  const hits = scan('^x', [['f.md', 'xx\n']]);
  assert.equal(hits.length, 2);
});

test('scan numbers each of several matches in one file by its own line', () => {
  const hits = scan('k', [['f.md', 'k\n\nk k\n\nk\n']]);
  assert.deepEqual(
    hits.map(({ loc }) => loc),
    ['f.md:1', 'f.md:3', 'f.md:3', 'f.md:5'],
  );
});

test('ere refuses a POSIX class it has no translation for, and an unclosed bracket or class', () => {
  assert.throws(() => ere('[[:punct:]]'), /no translation/);
  assert.throws(() => ere('a[b'), /unclosed \[/);
  assert.throws(() => ere('[[:space'), /unclosed \[:/);
});

test('ere leaves [:x:] outside a bracket a set of letters, as POSIX reads it', () => {
  assert.ok(ere('^x[:space:]y$').test('xsy'));
  assert.ok(!ere('^x[:space:]y$').test('x y'));
  assert.ok(ere('^\\[[[:space:]]\\]$').test('[ ]'));
});

test('ere takes ] first in a bracket as a member', () => {
  assert.ok(ere('^[]a]+$').test(']a]'));
  assert.ok(ere('^[^]a]$').test('b'));
});

test('scan reads each file on its own, with its own line numbers', () => {
  const hits = scan('k', [
    ['a.md', 'k\n'],
    ['b.md', '\n\nk\n'],
  ]);
  assert.deepEqual(
    hits.map(({ loc }) => loc),
    ['a.md:1', 'b.md:3'],
  );
});

test('section: from its heading to the next heading at the same level or above', () => {
  const md = '# T\n## A\na\n### A1\na1\n## B\nb\n';
  assert.equal(section([['f', md]], '^## A$', 0), 'a ### A1 a1 ');
  assert.equal(section([['f', md]], '^## C$', 0), '');
});

test('section: a heading-like line in a fence neither ends nor starts a section', () => {
  const md = '## A\na\n```bash\n# comment\n## B\n```\nstill a\n## B\nb\n';
  assert.equal(section([['f', md]], '^## A$', 0), 'a ```bash # comment ## B ``` still a ');
  assert.equal(section([['f', '```\n## B\n```\n']], '^## B$', 0), '');
  assert.equal(section([['f', '```\n## B\nx\n```\n']], '^## B$', 1), 'x ');
});

test('section: a fence closes only on its own character, at least as long', () => {
  const md = '````markdown\n## F\nin\n```\nstill in\n~~~~\nstill in\n````\nout\n';
  assert.equal(section([['f', md]], '^## F$', 1), 'in ``` still in ~~~~ still in ');
});

test('section: one begun outside a fence keeps the fence lines; one begun inside ends at its close', () => {
  assert.equal(section([['f', '## A\n```\nx\n```\ny\n']], '^## A$', 0), '``` x ``` y ');
  assert.equal(section([['f', '````\n## A\nx\n````\ny\n']], '^## A$', 1), 'x ');
});

test('section: a fence left open in one file does not carry into the next', () => {
  const ds = [
    ['a', '```\n'],
    ['b', '## A\nb\n'],
  ];
  assert.equal(section(ds, '^## A$', 0), 'b ');
});

test('sentenceWith: one sentence (split at every period) holds every string, and a refusal', () => {
  assert.ok(sentenceWith('Never send ANSWER for it. Fine.', ['ANSWER']));
  assert.ok(!sentenceWith('Send ANSWER for it. Never.', ['ANSWER']));
  assert.ok(!sentenceWith('ANSWER here. it never', ['ANSWER', 'never']));
  assert.ok(sentenceWith('Send ANSWER for it.', ['ANSWER'], true));
  assert.ok(!sentenceWith('Nothing here.', ['ANSWER'], true));
});

test('sentenceWith: a refusal word must stand alone', () => {
  assert.ok(!sentenceWith('Knot ANSWER', ['ANSWER']));
  assert.ok(sentenceWith('ANSWER, no.', ['ANSWER']));
});

test('sentencesOf splits at ". " and "; " only, wrapped lines joined', () => {
  assert.deepEqual(sentencesOf('a.b c. d;\ne; f\n'), ['a.b c', 'd', 'e', 'f ']);
});

test('clauses split at ", ", ": " and parentheses', () => {
  assert.deepEqual(clauses(['a, b: c (d) e']), ['a', 'b', 'c ', 'd', ' e']);
});

test('frontmatter: the lines between the first two ---, and the body after', () => {
  assert.deepEqual(frontmatter('---\nname: x\n---\nbody\n---\n'), { fm: ['name: x'], body: ['body', '---'] });
  assert.deepEqual(frontmatter('name: x\n---\n'), { fm: [], body: [] });
  assert.deepEqual(frontmatter('---\nname: x\n'), { fm: ['name: x'], body: [] });
});

test("fallbackCut drops the brief's fallback section up to the fence that closes it", () => {
  const md = 'a\n## If the `crew` skill is unavailable\nhidden\n````\nb\n';
  assert.deepEqual(fallbackCut(['f.md', md]), ['f.md:1: a', 'f.md:4: ````', 'f.md:5: b']);
});

test('sortC orders by code unit, as LC_ALL=C sort does', () => {
  assert.deepEqual(sortC(['b', 'B', 'a', '_']), ['B', '_', 'a', 'b']);
});

test("ere's . takes a \\r and U+2028, as awk's and grep's did", () => {
  assert.ok(ere('a.b').test('a\rb'));
  assert.ok(ere('a.b').test('a\u2028b'));
  assert.equal('ONLINE` |\r'.replace(ere('`.*'), ''), 'ONLINE');
});

test("ereU reads [[:space:]] as CI's UTF-8 grep did: Unicode spaces, but not the no-break ones", () => {
  assert.ok(ereU('^a[[:space:]]$').test('a\u2003'));
  assert.ok(ereU('^a[[:space:]]$').test('a\u3000'));
  assert.ok(!ereU('^a[[:space:]]$').test('a\u00a0'));
  assert.ok(!ereU('^a[[:space:]]$').test('a\u202f'));
  assert.ok(!ere('^a[[:space:]]$').test('a\u2003'), 'ere stays byte-wise, as LC_ALL=C');
  assert.throws(() => ereU('[[:alpha:]]'), /no translation/);
});

// A regex literal in a check whose . must stand for awk's or grep's needs the s flag (ere adds it to the
// patterns it builds). This reads the checks' own source, so a new literal without it fails here.
test('every regex literal in the checks with a . outside a bracket is dotAll', () => {
  const dotOutside = (src) => {
    for (let i = 0, inB = false; i < src.length; i++) {
      const c = src[i];
      if (c === '\\') i++;
      else if (inB) inB = c !== ']';
      else if (c === '[') {
        inB = true;
        if (src[i + 1] === '^') i++;
        if (src[i + 1] === ']') i++;
      } else if (c === '.') return true;
    }
    return false;
  };
  const scripts = join(dirname(fileURLToPath(import.meta.url)), '..', 'scripts');
  const files = [
    ...readdirSync(scripts).filter((f) => /^check-.*\.mjs$/.test(f)).map((f) => join(scripts, f)),
    ...readdirSync(join(scripts, 'lib')).filter((f) => f.endsWith('.mjs')).map((f) => join(scripts, 'lib', f)),
  ];
  const literal = /(?:^|[=(,:[!&|?{;>]|return)\s*\/((?:\\.|\[(?:\\.|[^\]\\])*\]|[^/\\[\n])+)\/([a-z]*)/g;
  const bare = [];
  let seen = 0;
  for (const f of files) {
    readFileSync(f, 'utf8')
      .split('\n')
      .forEach((l, n) => {
        if (/^\s*\/\//.test(l)) return;
        for (const [, src, flags] of l.matchAll(literal)) {
          seen++;
          if (dotOutside(src) && !flags.includes('s')) bare.push(`${f}:${n + 1}: /${src}/${flags}`);
        }
      });
  }
  assert.ok(seen > 50, `found only ${seen} regex literals: the scan broke`);
  assert.deepEqual(bare, []);
});
