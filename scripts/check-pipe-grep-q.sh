#!/usr/bin/env bash
# check-pipe-grep-q.sh — under `set -o pipefail`, `producer | grep -q` reports a
# match as a miss: grep quits on the first match, the producer still writing gets
# SIGPIPE (141), and pipefail makes the whole pipeline fail. Read the output into a
# variable and grep that (a here-string), or let grep read everything (`>/dev/null`).
#
#   check-pipe-grep-q.sh [file…]   default: every non-test .sh under the kit that sets pipefail
#
# Prints <file>:<line>: <text> for each `| grep -q` whose pipeline starts with
# anything but printf or echo (a builtin writing a short string finishes before grep
# can quit). Exit 1 when it printed any.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ $# -eq 0 ]; then
  set --
  while IFS= read -r f; do set -- "$@" "$f"; done < <(
    cd "$ROOT" && git ls-files '*.sh' 2>/dev/null | grep -vE '(\.test\.sh$|/tests/|^reference/)' \
      | while IFS= read -r f; do grep -l 'pipefail' "$f" 2>/dev/null; done | sed "s#^#$ROOT/#")
fi
[ $# -gt 0 ] || exit 0
perl -ne '
  BEGIN { $bad = 0 }
  $prev_cont = $cont; $cont = /\\\s*$/ ? 1 : 0;
  {
  last if /^\s*#/;
  my $l = $_; chomp $l;
  # Quoted text cannot hold a pipe that matters.
  (my $s = $l) =~ s/\x27[^\x27]*\x27/Q/g; $s =~ s/"(?:[^"\\]|\\.)*"/Q/g;
  $s =~ s/\s#.*$//;
  last unless $s =~ /\|\s*grep\s+(?:-[A-Za-z]*q[A-Za-z]*|--quiet)\b/;
  my $pre = substr($s, 0, $-[0]);
  my $flag = 0;
  my @chunks = split /\|\||&&|;|\$\(|\(|\{|\bif\b|\belif\b|\bthen\b|\belse\b|\bwhile\b|!|`/, $pre, -1;
  my $last = $chunks[-1] // "";
  if ($last =~ /^\s*$/ && (@chunks == 1 || $pre =~ /^\s*$/)) { $flag = 1 }   # the producer is on the line before
  elsif (@chunks == 1 && $prev_cont) { $flag = 1 }
  else {
    for my $stage (split /\|/, $last) {
      $stage =~ s/^\s+//;
      next if $stage eq "";
      $flag = 1 unless $stage =~ /^(printf|echo)\b/;
    }
  }
  if ($flag) { print "$ARGV:$.: $l\n"; $bad = 1 }
  }
  if (eof) { close ARGV; $cont = 0 }
  END { exit $bad }' "$@"
