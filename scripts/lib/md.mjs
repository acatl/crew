// The text primitives the skill checks share. Prose wraps, so a value restated in a sentence can
// straddle a line break; a line-by-line grep would miss that copy and call it gone.
//
// Each function keeps the semantics of the bash it replaced (scripts/lib/scan.sh and the awk, sed
// and tr in the checks), case for case, because test/checks.test.mjs pins the checks' messages and
// those messages quote what these functions return. A "doc" is a [name, text] pair: a file's
// repo-relative path and its contents, or a slice of one.

// POSIX bracket classes, as the C locale defines them. JavaScript's \s would also take Unicode
// spaces, which the bash never did.
const CLASSES = {
  '[:space:]': ' \\t\\n\\v\\f\\r',
  '[:blank:]': ' \\t',
  '[:alpha:]': 'A-Za-z',
  '[:digit:]': '0-9',
  '[:alnum:]': 'A-Za-z0-9',
  '[:upper:]': 'A-Z',
  '[:lower:]': 'a-z',
};

// ere <POSIX ERE> [flags]: the same pattern as a RegExp. The checks' patterns are written as EREs, so
// they read as they did in the bash; only the bracket classes need translating. A RegExp passes
// through unchanged.
export function ere(src, flags = '') {
  if (src instanceof RegExp) return src;
  return new RegExp(src.replace(/\[:[a-z]+:\]/g, (c) => CLASSES[c] ?? c), flags);
}

// ws <words>: an ERE for <words> with every space widened to any whitespace run, so the words can
// wrap across lines. <words> is itself an ERE, so the caller escapes what it means literally.
export const ws = (words) => words.replaceAll(' ', '[[:space:]]+');

// lines <text>: its lines as awk reads its records: a final newline ends the last line rather than
// starting an empty one, and a last line with no newline still counts.
export function lines(text) {
  if (!text) return [];
  const ls = text.split('\n');
  if (ls.at(-1) === '') ls.pop();
  return ls;
}

// here <string>: its lines as a here-string (<<<) feeds them to grep: the string plus a newline.
export const here = (s) => s.split('\n');

// flat <lines>: one line, each line break a space and runs of spaces squeezed to one (tr '\n' ' ' |
// tr -s ' '). Tabs are left alone, as tr left them.
export const flat = (ls) => ls.map((l) => `${l} `).join('').replace(/ +/g, ' ');

// docs <tree> <paths>: the [path, text] pairs for the paths the tree holds. A missing file is
// skipped, as the bash's awk and grep skipped one they couldn't open.
export const docs = (tree, paths) => paths.filter((p) => tree.has(p)).map((p) => [p, tree.get(p)]);

// scan <ERE> <docs>: every match as {file, line, match, loc}, loc being "<file>:<line>". Each doc is
// read with its line breaks as spaces, so a match may cross lines. <line> is where the match starts,
// and runs of blanks inside the match are squeezed to one space, less one trailing space. After a
// match the search restarts on the rest of the text, so ^ anchors there, as awk's match() on a
// substr() did.
export function scan(re, ds) {
  const rx = ere(re);
  const hits = [];
  for (const [file, src] of ds) {
    const ls = lines(src);
    if (!ls.length) continue;
    let text = '';
    const ends = [];
    for (const l of ls) {
      text += `${l} `;
      ends.push(text.length);
    }
    let pos = 0;
    while (pos < text.length) {
      const m = rx.exec(text.slice(pos));
      if (!m) break;
      const s = pos + m.index;
      let i = 0;
      while (i < ends.length - 1 && ends[i] <= s) i++;
      const match = m[0].replace(/[ \t]+/g, ' ').replace(/ $/, '');
      hits.push({ file, line: i + 1, match, loc: `${file}:${i + 1}` });
      pos = s + (m[0].length > 0 ? m[0].length : 1);
    }
  }
  return hits;
}

// section <docs> <heading ERE> <in-fence ok>: that section's text, one line. Fence-aware: a
// heading-like line inside a code fence neither starts (unless allowed) nor ends a section begun
// outside it, and a section begun inside a fence ends where that fence closes. A fence closes on a
// run of its own character at least as long as the one that opened it. The brief's fallback lives
// inside the template's ````markdown fence, and the template also embeds an "## Orchestrator".
export function section(ds, heading, inFenceOk) {
  const rx = ere(heading);
  const out = [];
  for (const [, src] of ds) {
    let w = false;
    let f = false;
    let frun = '';
    let lvl = 0;
    let wf = false;
    for (const line of lines(src)) {
      if (/^(```|~~~)/.test(line)) {
        const run = line.match(/^(`+|~+)/)[0];
        if (!f) {
          f = true;
          frun = run;
        } else if (run[0] === frun[0] && run.length >= frun.length) {
          f = false;
          if (w && wf) {
            w = false;
            continue;
          }
        }
        if (w) out.push(line);
        continue;
      }
      if (/^#+ /.test(line)) {
        const n = line.indexOf(' ');
        if (w && f === wf && n <= lvl) w = false;
        if (!w && rx.test(line) && (!f || inFenceOk)) {
          w = true;
          lvl = n;
          wf = f;
          continue;
        }
      }
      if (w) out.push(line);
    }
  }
  return flat(out);
}

// A refusal word, standing alone: never, neither, no, not, refuse.
export const REFUSAL = /(^|[^A-Za-z])([Nn]ever|[Nn]either|[Nn]o|[Nn]ot|[Rr]efuse)([^A-Za-z]|$)/;

// sentenceWith <text> <strings> [any]: true when one sentence holds every string and a refusal
// (any: no refusal needed). A sentence ends at every period, so the strings stop short of one.
export function sentenceWith(text, strings, any = false) {
  const hits = text.split('.').filter((s) => strings.every((x) => s.includes(x)));
  return any ? hits.length > 0 : hits.some((s) => REFUSAL.test(s));
}

// sentencesOf <text>: its sentences, wrapped lines joined; a sentence ends at ". " or "; "
export const sentencesOf = (text) => text.replaceAll('\n', ' ').replace(/ +/g, ' ').split(/[.;] /);

// clauses <sentences>: each sentence split at ", ", ": " and parentheses
export const clauses = (sentences) => sentences.flatMap((s) => s.split(/, |: |[()]/));

// frontmatter <text>: {fm, body}, the lines between a first-line "---" and the next one, and the
// lines after that. No opening "---", no frontmatter and no body; no closing one, no body.
export function frontmatter(text) {
  const ls = lines(text);
  if (ls[0] !== '---') return { fm: [], body: [] };
  const end = ls.indexOf('---', 1);
  if (end < 0) return { fm: ls.slice(1), body: [] };
  return { fm: ls.slice(1, end), body: ls.slice(end + 1) };
}

// fallbackCut <doc>: its lines as "<file>:<line>: <text>", less the brief's fallback section (from
// its heading to the ```` that closes the template's fence, which is kept)
export function fallbackCut([file, src]) {
  const out = [];
  let skip = false;
  lines(src).forEach((l, i) => {
    if (/^## If the `crew` skill is unavailable/.test(l)) skip = true;
    if (skip && /^````/.test(l)) skip = false;
    if (!skip) out.push(`${file}:${i + 1}: ${l}`);
  });
  return out;
}

// sortC <strings>: sorted by code unit, as LC_ALL=C sort orders bytes
export const sortC = (xs) => [...xs].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
export const uniqC = (xs) => sortC([...new Set(xs)]);
