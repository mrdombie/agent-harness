#!/usr/bin/env bash
# check-gh-read.sh — a GitHub read that discards gh's errors never feeds a decision unchecked.
# A failed call (rate limit, secondary limit, 5xx, network) prints nothing, and a caller
# that counts, loops over or tests that nothing reads "no rows": on 2026-10-22 an issue
# list with stderr discarded said 1 open, then 0, while 17 and 18 were. A read that
# decides something goes through gh_read (scripts/gh-batch.sh), which never answers empty
# on a failure; its caller logs "unknown" and acts on nothing that pass.
#
#   check-gh-read.sh [file…]   default: every non-test shell script of the kit
#
# Prints <file>:<line>: <text> for each `gh api` read (gh, gh_call, swarm_gh, _base_gh,
# "$GH", ghr_api, …) whose statement discards stderr (2>/dev/null, &>/dev/null) and
#   - pipes its answer on (a pipe hides gh's exit unless the caller's shell set pipefail), or
#   - checks no exit at all (no `if`/`until`/`while` around it, no `|| return|exit|die`).
# `|| true`, `|| x=""`, `|| echo '[]'` and `|| continue` are no check: each is the failure
# read as empty. A write (-X POST/PATCH/PUT/DELETE, --method, a field with no -X GET) is
# not a read. A read whose failure is harmless says why, on its line or the line above:
# `# gh-read-ok: <why>`. Exit 1 when it printed any.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ $# -eq 0 ]; then
  set --
  while IFS= read -r f; do set -- "$@" "$ROOT/$f"; done < <(
    cd "$ROOT" && git ls-files 'scripts/*.sh' 'swarm/*.sh' 'driver/*.sh' 'driver/steps/*.sh' 'hooks/*.sh' 'hooks/lib/*.sh' 'driver/build-ticket' 2>/dev/null \
      | grep -vE '(\.test\.sh$|/tests/|/fixtures/|^reference/)')
fi
[ $# -gt 0 ] || exit 0
perl - "$@" <<'PL'
  my $bad = 0;
  my $call = qr/(?:^|[\s(;|&`])(?:gh|gh_call|swarm_gh|_base_gh|"?\$\{?(?:GH|ghf|GH_BIN|SWARM_GH)\}?"?|"\$\(gh_batch_bin\)")\s+api\s|(?:^|[\s(;|&`])ghr_api\s/;
  for my $file (@ARGV) {
    open(my $fh, "<", $file) or next;
    my @lines = <$fh>; close $fh;
    for (my $i = 0; $i < @lines; $i++) {
      my $start = $i;
      my $stmt = $lines[$i];
      # A statement runs on over lines ending in a backslash, and a line ending in a pipe.
      while ($i + 1 < @lines && ($stmt =~ /\\\s*$/ || $stmt =~ /(?<!\|)\|\s*$/)) { $i++; $stmt .= $lines[$i]; }
      # ... and onto a next line that opens with a pipe or an ||.
      while ($i + 1 < @lines && $lines[$i + 1] =~ /^\s*(\|\|?|&&)/) { $i++; $stmt .= $lines[$i]; }
      my $first = $lines[$start];
      next if $first =~ /^\s*#/;
      next unless $stmt =~ $call;
      next if $stmt =~ /^\s*[a-z_]+\s*\(\)\s*\{.*\bgh\s+api\s+"\$p"/;   # the ghr_api wrapper itself
      my $marked = ($first =~ /#\s*gh-read-ok:\s*\S/) || ($start > 0 && $lines[$start - 1] =~ /^\s*#\s*gh-read-ok:\s*\S/);
      next if $marked;
      # Quoted jq and nested $( ) that hold no gh call are not this statement's pipes;
      # quotes go first, so a "#" inside one is not read as a comment.
      (my $code = $stmt) =~ s/\x27[^\x27]*\x27/\x27\x27/g;
      $code =~ s/(^|\s)#[^\n]*//g;
      1 while $code =~ s/\$\((?![^()]*api\s)[^()]*\)/X/;
      # A write is not a read.
      next if $code =~ /(-X|--method)\s+"?(POST|PATCH|PUT|DELETE)/;
      next if $code !~ /\bgraphql\b/ && $code =~ /\s-[fF]\s/ && $code !~ /-X\s+GET/;
      next if $code =~ /\bgraphql\b/ && $code =~ /\bmutation\b/;
      next unless $code =~ /(?:2>\s*\/dev\/null|&>\s*\/dev\/null|>\s*\/dev\/null\s+2>&1)/;
      # From the gh call on: does its answer go down a pipe?
      my ($after) = $code =~ /((?:gh|gh_call|swarm_gh|_base_gh|\$\{?\w+\}?"?|\))\s+api\s.*|ghr_api\s.*)/s;
      $after //= $code;
      my $piped = $after =~ /(?<![|>&])\|(?![|&])/;
      my $guarded = $code =~ /^\s*(?:if|elif|until|while)\b/ || $code =~ /(?:^|[;&|]\s*|\bthen\s+)(?:if|elif|until|while)\s+!?\s*/
                 || $code =~ /\|\|\s*(?:return|exit|die|gh_die|\{.*?\b(?:return|exit|die)\b)/s;
      if ($piped || !$guarded) {
        my $l = $first; chomp $l; $l =~ s/^\s+//;
        print "$file:" . ($start + 1) . ": $l\n"; $bad = 1;
      }
    }
  }
  exit $bad;
PL
