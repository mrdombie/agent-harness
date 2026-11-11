#!/usr/bin/env bash
# state-archive.sh — runs that ended long ago leave the live folders. Every run leaves a log
# in $STATE_DIR/logs and up to six record files in $STATE_DIR/runs, nothing ever took them
# away, and every tick and every reader walks both folders (2026-11-11: 5,256 logs, 3.0 GB,
# and 25,817 record files; the log names alone had outgrown one command line).
#
#   state-archive.sh            the count of what would move, and what is kept. Moves nothing.
#   state-archive.sh --apply    moves them
#   --days N                    the age (default swarm.archiveDays, 14)
#
# A run is its id, `claim-<ticket>-<stamp>-<pid>`: runs/<id>.* and logs/<id>.log. It moves,
# whole, to <archive>/<today>/runs and /logs (swarm.archiveDir, default $STATE_DIR/archive)
# only when ALL of these hold:
#   - no run of its ticket, itself included, has a record with no .ended: that run may
#     still be going, and it may read what the ticket's earlier runs left;
#   - every one of its files was last written more than N days ago, by the file's own mtime,
#     at the count and again as each file moves.
# Anything else in either folder (the daemons' own logs, briefs, hand-made files) is not a
# run's and is never touched. Moved, never deleted, never overwritten: a name already in
# the archive stays where it is and is counted. Exit 1 when a folder could not be read or
# a move failed; never a quiet zero.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../swarm/swarm-env.sh" || exit 1

APPLY=0; DAYS="${STATE_ARCHIVE_DAYS:-$(swarm_opt swarm.archiveDays 14)}"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --days) DAYS="${2:-}"; shift ;;
    *) echo "state-archive: unknown argument '$1' (usage: state-archive.sh [--apply] [--days N])" >&2; exit 2 ;;
  esac
  shift
done
case "$DAYS" in ''|*[!0-9]*|0) echo "state-archive: --days must be a whole number of days, 1 or more (got '$DAYS')" >&2; exit 2 ;; esac
ARCHIVE="${STATE_ARCHIVE_DIR:-$(swarm_opt swarm.archiveDir "$STATE_DIR/archive")}"
NOW=$(swarm_now)

perl - "$RUNS_DIR" "$SWARM_LOGS" "$ARCHIVE/$(date -u -r "$NOW" +%Y-%m-%d 2>/dev/null || date -u -d "@$NOW" +%Y-%m-%d)" "$NOW" "$DAYS" "$APPLY" <<'PL'
use strict; use warnings; use File::Path qw(make_path);
my ($runs, $logs, $dest, $now, $days, $apply) = @ARGV;
my $cutoff = $now - $days * 86400;
my (%run, %open_ticket, $other);
$other = 0;
sub ticket_of { $_[0] =~ /^claim-(.+)-\d{8}T\d{6}Z-\d+$/ ? $1 : $_[0] }
for my $d ([runs => $runs], [logs => $logs]) {
  my ($kind, $dir) = @$d;
  opendir(my $h, $dir) or do { print STDERR "state-archive: cannot read $dir: $!\n"; exit 1 };
  while (defined(my $n = readdir $h)) {
    next if $n eq "." || $n eq "..";
    my @s = lstat "$dir/$n"; next unless @s;
    unless (-f _ && $n =~ /^(claim-[^.]+)\.(.+)$/ && ($kind eq "runs" || $2 eq "log")) { $other++; next }
    my ($id, $suffix) = ($1, $2);
    my $r = $run{$id} ||= { newest => 0, bytes => 0, files => [], ended => 0, record => 0 };
    push @{ $r->{files} }, [$kind, $n];
    $r->{newest} = $s[9] if $s[9] > $r->{newest};
    $r->{bytes} += $s[7];
    if ($kind eq "runs") { $r->{record} = 1; $r->{ended} = 1 if $suffix eq "ended" }
  }
  closedir $h;
}
for my $id (keys %run) { my $r = $run{$id}; $open_ticket{ ticket_of($id) } = 1 if $r->{record} && !$r->{ended} }
my (%n, @move); $n{$_} = 0 for qw(runs logs bytes groups live young clash failed);
for my $id (sort keys %run) {
  my $r = $run{$id};
  if ($open_ticket{ ticket_of($id) }) { $n{live}++; next }
  if ($r->{newest} > $cutoff) { $n{young}++; next }
  $n{groups}++; $n{bytes} += $r->{bytes};
  for my $f (@{ $r->{files} }) { $n{ $f->[0] }++; push @move, $f }
}
my $size = $n{bytes} >= 1e9 ? sprintf("%.1f GB", $n{bytes} / 1e9) : sprintf("%d MB", $n{bytes} / 1e6 + 0.5);
my $what = "$n{logs} logs and $n{runs} run-record files of $n{groups} runs that ended over $days days ago ($size)";
my $kept = "kept: $n{live} runs of a ticket with a run not ended, $n{young} younger; $other files that are no run's left alone";
if (!$apply) { print "state-archive (dry run): would archive $what to $dest — $kept. Pass --apply to move them.\n"; exit 0 }
if (@move) { for my $k (qw(runs logs)) { make_path("$dest/$k"); -d "$dest/$k" or do { print STDERR "state-archive: cannot make $dest/$k\n"; exit 1 } } }
my %src = (runs => $runs, logs => $logs); my $moved = 0;
for my $f (@move) {
  my ($k, $name) = @$f; my ($from, $to) = ("$src{$k}/$name", "$dest/$k/$name");
  if (-e $to) { $n{clash}++; next }
  # Still old at the moment it moves: a run that woke between the count and now keeps its files.
  my @s = lstat $from; next unless @s;
  if ($s[9] > $cutoff) { $n{young}++; next }
  if (rename $from, $to) { $moved++ } else { $n{failed}++; print STDERR "state-archive: could not move $from: $!\n" }
}
print "state-archive: archived $moved of " . scalar(@move) . " files ($what) to $dest — $kept"
    . ($n{clash} ? "; $n{clash} already in the archive, left in place" : "") . ($n{failed} ? "; $n{failed} could not be moved" : "") . ".\n";
exit($n{failed} ? 1 : 0);
PL
