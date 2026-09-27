# shellcheck shell=bash
# Sourced by the skill checks. Prose wraps, so a value restated in a sentence can straddle a line
# break; a line-by-line grep would miss that copy and call it gone.

# scan <ERE> <file>...: print every match as "<file>:<line><TAB><match>". Each file is read with
# its line breaks as spaces, so a match may cross lines. <line> is where the match starts, and runs
# of whitespace inside the match are squeezed to one space. Byte-wise (LC_ALL=C), so a pattern holds
# the same on BSD and GNU awk. The ERE travels through the environment, which awk never unescapes.
scan() {
  local re=$1; shift
  SCAN_RE=$re LC_ALL=C awk '
    function flush(   pos, rest, s, i, m) {
      pos = 1
      while (pos <= length(text)) {
        rest = substr(text, pos)
        if (!match(rest, ENVIRON["SCAN_RE"])) break
        s = pos + RSTART - 1
        for (i = 1; i < n && ends[i] < s; i++) ;
        m = substr(text, s, RLENGTH)
        gsub(/[ \t]+/, " ", m); sub(/ $/, "", m)
        printf "%s:%d\t%s\n", file, i, m
        pos = s + (RLENGTH > 0 ? RLENGTH : 1)
      }
      text = ""; n = 0; split("", ends)
    }
    FNR == 1 { if (n > 0) flush(); file = FILENAME }
    { text = text $0 " "; ends[++n] = length(text) }
    END { if (n > 0) flush() }
  ' "$@"
}

# ws <words>: an ERE for <words> with every space widened to any whitespace run, so the words can
# wrap across lines. <words> is itself an ERE, so the caller escapes what it means literally.
ws() { printf '%s' "$*" | sed 's/ /[[:space:]]+/g'; }
