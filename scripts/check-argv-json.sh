#!/usr/bin/env bash
# check-argv-json.sh — a list that grows with the project never goes to jq on argv.
# One argument over 128 KiB (Linux) or the whole argv over ARG_MAX (macOS) fails with
# "Argument list too long", and the caller then acts on nothing: keep-fresh's state
# was wiped every pass at ~96 open PRs. Bind it through a file: jq_slurp
# (scripts/toolkit-env.sh), --slurpfile or --rawfile, or hand it on stdin.
#
#   check-argv-json.sh [file…]   default: every non-test shell script of the kit
#
# Prints <file>:<line>: <text> for each `--argjson <name> "$VAR"` whose variable is named
# like a GitHub list (PRS, ISSUES, CLAIMS, ROWS, SHEET, CHECKS, any case), and each
# `--arg <name> "$VAR"` whose variable has a ROWS or CLAIMS part (a TSV of them). A value
# that is truly bounded says so on its line, or on the line above: `# argv-bounded: <why>`.
# Exit 1 when it printed any.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ $# -eq 0 ]; then
  set --
  while IFS= read -r f; do set -- "$@" "$ROOT/$f"; done < <(
    cd "$ROOT" && git ls-files 'scripts/*.sh' 'swarm/*.sh' 'driver/*.sh' 'hooks/*.sh' 'driver/build-ticket' 2>/dev/null \
      | grep -vE '(\.test\.sh$|/tests/|/fixtures/|^reference/)')
fi
[ $# -gt 0 ] || exit 0
perl -ne '
  BEGIN { $bad = 0 }
  my $ok = $prev_ok; $prev_ok = /^\s*#\s*argv-bounded:\s*\S/ ? 1 : 0;
  next if /^\s*#/ || $ok || /#\s*argv-bounded:\s*\S/;
  my $hit = 0;
  while (/--(argjson|arg)\s+[A-Za-z_][A-Za-z_0-9]*\s+"\$\{?([A-Za-z_][A-Za-z_0-9]*)/g) {
    my ($k, $v) = ($1, $2);
    $hit = 1 if $k eq "argjson" && $v =~ /PRS|ISSUES|CLAIMS|ROWS|SHEET|CHECKS/i;
    $hit = 1 if $k eq "arg" && grep { /^(ROWS|CLAIMS)$/i } split /_/, $v;
  }
  if ($hit) { chomp; print "$ARGV:$.: $_\n"; $bad = 1 }
  if (eof) { close ARGV; $prev_ok = 0 }
  END { exit $bad }' "$@"
