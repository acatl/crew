#!/usr/bin/env node
// Validate that every skill carries the required frontmatter: name, description,
// license, an author, and a version. Keeps the skill catalog uniform (and authored) for
// sharing / vercel-labs/skills consumption; the version is release-managed
// (release-please stamps it, so a new skill must ship the field). Exit 1 on any
// violation.
import { ere, frontmatter, sortC } from './lib/md.mjs';
import { Report, main } from './lib/tree.mjs';

export function checkSkillFrontmatter(tree) {
  const r = new Report();
  let failed = false;
  const skills = sortC(tree.keys()).filter((k) => /^skills\/[^/.][^/]*\/SKILL\.md$/.test(k));

  if (!skills.length) {
    r.err('no skills found under skills/*/SKILL.md');
    r.rc = 1;
    return r;
  }

  for (const f of skills) {
    // Frontmatter = lines between the first two '---' markers.
    const { fm } = frontmatter(tree.get(f));
    const has = (ls, re) => (ls.length ? ls : ['']).some((l) => ere(re).test(l));

    const miss = [];
    if (!has(fm, '^name:[[:space:]]*[^[:space:]]')) miss.push('name');
    if (!has(fm, '^description:[[:space:]]*[^[:space:]]|^description:[[:space:]]*[>|]')) miss.push('description');
    if (!has(fm, '^license:[[:space:]]*[^[:space:]]')) miss.push('license');
    // author and version live under the top-level metadata: key. Matching them anywhere would let an
    // "author:" line inside the folded description, or some other nested key, stand in for them.
    // They are metadata's own children, at its first child's indent; a key nested deeper doesn't count.
    const metadata = [];
    {
      let m = false;
      for (const l of fm) {
        if (ere('^metadata:[[:space:]]*$').test(l)) {
          m = true;
          continue;
        }
        if (m && ere('^[^[:space:]]').test(l)) break;
        if (m) metadata.push(l);
      }
    }
    const first = metadata.find((l) => {
      const fields = l.split(/[ \t]+/).filter(Boolean);
      return fields.length && !fields[0].startsWith('#');
    });
    const indent = first === undefined ? 0 : first.match(ere('^[[:space:]]*'))[0].length;
    const child = `^[[:space:]]{${indent}}`;
    if (!has(metadata, `${child}author:[[:space:]]*[^[:space:]]`)) miss.push('author');
    if (!has(metadata, `${child}version:[[:space:]]*[^[:space:]]`)) miss.push('version');

    if (miss.length) {
      r.err(`✗ ${f} — missing frontmatter: ${miss.join(' ')}`);
      failed = true;
    }

    // The dir name is the skill's identity once installed (it is what gets
    // symlinked/copied into .claude/skills/), so a dir != name skill installs under
    // a name the router never announces. Catch the divergence here, not on a user's
    // machine.
    const dir = f.split('/').at(-2);
    const nameLine = fm.find((l) => l.startsWith('name:'));
    const declared = nameLine === undefined ? '' : nameLine.replace(ere('^name:[[:space:]]*'), '').replace(/["' \r]/g, '');
    if (declared && declared !== dir) {
      r.err(`✗ ${f} — frontmatter name '${declared}' != directory '${dir}'`);
      failed = true;
    }
  }

  if (!failed) r.out(`✓ all ${skills.length} skills have name + description + license + author + version, name == dir`);
  r.rc = failed ? 1 : 0;
  return r;
}

main(import.meta.url, checkSkillFrontmatter);
