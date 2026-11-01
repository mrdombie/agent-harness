#!/usr/bin/env bash
# check-hook-pipe-grep.sh — no hook pipes text into a grep that stops at its first match.
#
#   check-hook-pipe-grep.sh [file…]   default: every non-test .sh under hooks/
#
# Under `set -o pipefail`, `printf '%s' "$cmd" | grep -q …` on a long command fails
# when grep matches early: grep quits, printf takes SIGPIPE (141), the pipeline
# fails, and the match reads as "no match" — so the guard allows what it exists to
# deny. A builtin writing a variable is no exception: the variable is the command,
# the file content or the message, and any of them can be long. Grep a here-string
# (`grep -qE "$re" <<<"$cmd"`) instead.
#
# Judged: a file that sets pipefail, and every file under a lib/ directory (it is
# sourced into hooks that may set it). Flagged: a `|` into grep with -q, -m, -l,
# --quiet, --silent, --max-count or --files-with-matches. Prints <file>:<line>: <text>;
# exit 1 when it printed any.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ $# -eq 0 ]; then
  set --
  while IFS= read -r f; do set -- "$@" "$ROOT/$f"; done < <(
    cd "$ROOT" && git ls-files 'hooks/*.sh' | grep -v '\.test\.sh$')
fi
[ $# -gt 0 ] || { echo "check-hook-pipe-grep: no files to check"; exit 2; }
judged=()
for f in "$@"; do
  [ -f "$f" ] || { echo "  $f: not a file"; exit 2; }
  case "$f" in */lib/*) judged+=("$f"); continue ;; esac
  grep -qE '^[^#]*set[[:space:]]+(-[a-zA-Z]*o[[:space:]]+pipefail|-o[[:space:]]+pipefail)' "$f" && judged+=("$f")
done
[ "${#judged[@]}" -gt 0 ] || { echo "check-hook-pipe-grep: $# files, none under pipefail"; exit 0; }
perl -ne '
  BEGIN { $bad = 0 }
  {
    last if /^\s*#/;
    my $l = $_; chomp $l;
    # Quoted text cannot hold a pipe that matters.
    # Read left to right, so mixed quoting like \x27a"\x27"\x27b\x27 stays paired.
    my ($s, $q) = ("", "");
    for (my $i = 0; $i < length $l; $i++) {
      my $c = substr($l, $i, 1);
      if ($q eq "\x27") { $q = "" if $c eq "\x27"; next }
      if ($q eq "\"") { if ($c eq "\\") { $i++ } elsif ($c eq "\"") { $q = "" } next }
      if ($c eq "\\") { $s .= "Q"; $i++; next }
      if ($c eq "\x27" || $c eq "\"") { $q = $c; $s .= "Q"; next }
      last if $c eq "#" && ($s eq "" || $s =~ /\s$/);
      $s .= $c;
    }
    while ($s =~ /(?<![|])\|(?![|])\s*grep((?:\s+-\S*)*)/g) {
      my $hit = 0;
      for my $o (split /\s+/, $1) {
        last if $o eq "--";
        next unless $o =~ /^-/;
        if ($o =~ /^--(quiet|silent|max-count|files-with-matches)\b/) { $hit = 1 }
        elsif ($o =~ /^-[A-Za-z0-9]*[qlm]/ && $o !~ /^--/) { $hit = 1 }
      }
      if ($hit) { print "$ARGV:$.: $l\n"; $bad = 1; last }
    }
  }
  if (eof) { close ARGV }
  END { exit $bad }' "${judged[@]}"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "check-hook-pipe-grep: under pipefail a pipe into an early-exit grep reads an early match on long text as \"no match\" — grep a here-string: grep -qE \"\$re\" <<<\"\$text\""
  exit 1
fi
echo "check-hook-pipe-grep: ${#judged[@]} hook files under pipefail, none pipes into an early-exit grep"
