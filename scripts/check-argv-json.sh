#!/usr/bin/env bash
# check-argv-json.sh — a list that grows with the project never goes to jq on argv.
# One argument over 128 KiB (Linux) or the whole argv over ARG_MAX (macOS) fails with
# "Argument list too long", and the caller then acts on nothing: keep-fresh's state
# was wiped every pass at ~96 open PRs. Bind it through a file: jq_slurp
# (scripts/toolkit-env.sh), --slurpfile or --rawfile, or hand it on stdin.
#
#   check-argv-json.sh [--globs] [file…]   default: every non-test shell script of the kit
#
# Prints <file>:<line>: <text> for each `--argjson <name> "$VAR"` whose variable is named
# like a GitHub list (PRS, ISSUES, CLAIMS, ROWS, SHEET, CHECKS, any case), and each
# `--arg <name> "$VAR"` whose variable has a ROWS or CLAIMS part (a TSV of them). A value
# that is truly bounded says so on its line, or on the line above: `# argv-bounded: <why>`.
#
# The same for a glob over a state directory handed to a command: at 13,616 logs
# `ls -t "$SWARM_LOGS"/claim-*.log "$DRIVER_DIR"/*/steps/*.log` was never run, its error went
# to /dev/null, and every usage reader saw no log (2026-11-11). Flagged: an unquoted `*` in a
# word rooted at a state directory's variable (STATE_DIR, SWARM_LOGS, RUNS_DIR, DRIVER_DIR,
# COORD_DIR, …) or under a logs/, runs/, judges/ or steps/ folder of any variable, as an
# argument to a command. A `for … in` loop, a builtin (printf, echo, set, test),
# swarm_newest_logs, a case pattern and an assignment start no process and pass. List
# through swarm_newest_logs, a `for` loop or `find`. --globs checks this rule alone (the
# write-time hook sees one fragment of a file, without the line above it).
# Exit 1 when it printed any.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ONLY_GLOBS=""; [ "${1:-}" = --globs ] && { ONLY_GLOBS=1; shift; }
if [ $# -eq 0 ]; then
  set --
  while IFS= read -r f; do set -- "$@" "$ROOT/$f"; done < <(
    cd "$ROOT" && git ls-files 'scripts/*.sh' 'swarm/*.sh' 'driver/*.sh' 'hooks/*.sh' 'driver/build-ticket' 2>/dev/null \
      | grep -vE '(\.test\.sh$|/tests/|/fixtures/|^reference/)')
fi
[ $# -gt 0 ] || exit 0
rc=0
perl - "$@" <<'PL' || rc=1
use strict; use warnings;
my $ROOTED = qr/^"?\$\{?(?:STATE_DIR|STATE|SWARM_LOGS|RUNS_DIR|DRIVER_DIR|COORD_DIR|COORDINATOR_DIR|JDIR|SWARM_DIR)\b/;
my $FOLDER = qr!^(?:"?\$|~|/).*/(?:logs|runs|judges|steps)["}]*/!;
my %QUIET = map { $_ => 1 } qw(for case select printf echo set local declare typeset export readonly compgen [ [[ test : swarm_newest_logs);
my %KEYWORD = map { $_ => 1 } qw(! { then do else elif if while until time);
# One logical line: every word with an unquoted * and the command it is an argument of.
sub hits {
  my ($l) = @_; my @hit; my @ctx = ({ q => "", w => "", star => 0, cmd => undef });
  my $end = sub { my $c = $ctx[-1]; return if $c->{w} eq "";
    my ($w, $star) = ($c->{w}, $c->{star}); $c->{w} = ""; $c->{star} = 0;
    if (!defined $c->{cmd}) { $c->{cmd} = $w unless $KEYWORD{$w} || $w =~ /^[A-Za-z_][A-Za-z_0-9]*(\[[^\]]*\])?\+?=/; return }
    push @hit, $w if $star && !$QUIET{$c->{cmd}} && ($w =~ $ROOTED || $w =~ $FOLDER); };
  my @ch = split //, $l;
  for (my $i = 0; $i < @ch; $i++) {
    my ($x, $c) = ($ch[$i], $ctx[-1]);
    if ($c->{q} eq "\x27") { $c->{w} .= $x; $c->{q} = "" if $x eq "\x27"; next }
    if ($x eq "\\") { $c->{w} .= $x . ($ch[++$i] // ""); next }
    if ($x eq "\$" && ($ch[$i + 1] // "") eq "(") { $c->{w} .= "\$()"; $i++; push @ctx, { q => "", w => "", star => 0, cmd => undef }; next }
    if ($c->{q} eq "\"") { $c->{w} .= $x; $c->{q} = "" if $x eq "\""; next }
    if ($x eq "\"" || $x eq "\x27") { $c->{q} = $x; $c->{w} .= $x; next }
    if ($x eq "#" && $c->{w} eq "") { last }
    if ($x eq ")" && @ctx > 1) { $end->(); pop @ctx; next }
    if ($x =~ /\s/) { $end->(); next }
    if ($x =~ /[;|&()`<>]/) { $end->(); $c->{cmd} = undef unless $x =~ /[<>]/; next }
    $c->{star} = 1 if $x eq "*";
    $c->{w} .= $x;
  }
  $end->() while @ctx > 1 && pop @ctx; $end->();
  return @hit;
}
my $bad = 0;
for my $f (@ARGV) {
  open(my $fh, "<", $f) or do { print STDERR "check-argv-json: cannot read $f\n"; $bad = 1; next };
  my ($prev_ok, $buf, $at) = (0, "", 0);
  while (my $line = <$fh>) {
    chomp $line;
    if ($buf eq "") { $at = $. }
    if ($line =~ /\\$/) { $buf .= substr($line, 0, -1) . " "; next }
    my $l = $buf . $line; $buf = "";
    my $ok = $prev_ok; $prev_ok = $l =~ /^\s*#\s*argv-bounded:\s*\S/ ? 1 : 0;
    next if $l =~ /^\s*#/ || $ok || $l =~ /#\s*argv-bounded:\s*\S/;
    if (my @h = hits($l)) { print "$f:$at: a glob over a state directory as arguments (@h): $l\n"; $bad = 1 }
  }
  close $fh;
}
exit $bad;
PL
[ -z "$ONLY_GLOBS" ] || exit "$rc"
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
  END { exit $bad }' "$@" || rc=1
exit "$rc"
