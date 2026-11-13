#!/usr/bin/env bash
# failing-tests.sh — failing_test_files <log> [tree]: the test files a runner printed on a
# failure line, each once, in the order they appear, named from the repo root. Given <tree>,
# an absolute path becomes the tracked file it ends with (the longest), or nothing when no
# tracked file does; without one it is kept as printed, less a leading '/'. Sourced, the only copy of this parse.
failing_test_files() {
  local tree="${2:-}"
  perl -ne 's/\e\[[0-9;]*[A-Za-z]//g;
    next unless /(\bFAIL(ED)?\b|\bfailed\b|\bnot ok\b|\xe2\x9c\x97|\xc3\x97|\xe2\x9c\x95|\xe2\x9c\x98)/;
    while (m{(/?(?:[\w@.+-]+/)*[\w@+-][\w.@+-]*\.(?:test|spec)\.[A-Za-z]+)}g) {
      my $p = $1; $p =~ s{^(\./)+}{}; print "$p\n" }' "$1" 2>/dev/null \
    | FT_TREE="$tree" awk '
        BEGIN { tree = ENVIRON["FT_TREE"]; if (tree != "") { cmd = "git -C \"$FT_TREE\" ls-files 2>/dev/null"; while ((cmd | getline f) > 0) t[f] = 1; close(cmd) } }
        substr($0, 1, 1) == "/" && tree != "" {
          p = $0; hit = ""
          while ((i = index(p, "/")) > 0) { p = substr(p, i + 1); if (p in t) { hit = p; break } }
          if (hit == "") next
          $0 = hit
        }
        tree == "" { sub(/^\/+/, "") }
        !seen[$0]++'
}
