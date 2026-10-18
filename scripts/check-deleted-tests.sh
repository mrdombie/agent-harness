#!/usr/bin/env bash
# check-deleted-tests.sh — a pull request that deletes a test says what took its place.
#
# WHY
#   On the origin project a rebuild merged in one pull request that deleted eleven
#   old test files. One of them pinned "a writer can post for a teammate". The new
#   screen dropped that behaviour, every check stayed green — the test that would
#   have gone red was one of the files deleted — and a real user was blocked for a
#   week before anybody noticed. A deleted test is the one regression no test can
#   catch, so the pull request has to account for it in words a reviewer can check.
#
# WHAT IT CHECKS
#   The diff base..head — TWO dots, read from the two commits, never the working
#   tree — for:
#     1. a test file that is DELETED (or renamed to a path that is no longer a
#        test file), and
#     2. a test file that stays but LOSES `it(` / `test(` cases. A case turned off
#        (.skip, .todo, an x prefix, a skipped describe around it, or a
#        .only elsewhere in the file) counts as lost: it no longer runs, and a new
#        case in the same file never stands in for it.
#   A file git sees as RENAMED is not a deletion; its cases are compared across
#   the rename, so a move that drops cases on the way is still caught.
#
#   It counts cases, not titles. A title that leaves is matched to one the diff
#   adds — the same words in any test file, else any new case in the same file
#   (a rewrite in place), else one sharing more than half its words, filler left
#   out, in another file. Only a case left with no match owes a line, so a renamed,
#   reworded or moved case passes, while a drop in a file's count, or a case gone
#   from a file with nothing like it in the file it went to, still fails. Measured on the origin project before this: 74 of 85 files
#   it flagged kept or grew their case count.
#
#   Something only on BASE is not this pull request's deletion. A test the trunk
#   added after the branch was cut is absent at head too, and two dots alone would
#   call it deleted; anything absent at the merge-base is excluded. In CI, run on
#   the pull request's merge commit (head = HEAD, base = HEAD^1) the two are the
#   same commit and nothing is excluded.
#
#   Every file found must have ONE line in a `## Deleted tests` section of the
#   pull request body:
#
#     ## Deleted tests
#     - `path/to/old.test.ts` → covered by `path/to/new.test.ts`
#     - `path/to/other.test.ts` → removed on purpose: the export feature was retired
#
#   "covered by" must name a test file that exists at head and has at least one
#   live case — the test that now pins the same behaviour. "removed on purpose"
#   must give a reason. `->` works as well as `→`; the backticks are optional.
#
# CONFIG
#   Test-file patterns: `tests.patterns` in the consuming repo's
#   .claude/harness.json — a list of shell globs matched against the whole path
#   (`*` crosses `/`). HARNESS_TEST_PATTERNS (space-separated) overrides it, as
#   every HARNESS_* env does. Absent both: *.test.ts *.test.tsx *.spec.ts.
#
# USAGE
#   check-deleted-tests.sh --base <ref> [--head <ref>] [--body-file <file>|-] [--pr <n>] [--repo <dir>]
#   Exit 0 = nothing deleted, or every deletion accounted for.
#        1 = a deletion the body does not account for (each one is named, with
#            a line ready to paste).
#        2 = refused: a ref that does not resolve, an unreadable config, or a diff,
#            file or tree git could not read — a measurement that could not be
#            made is not a clean one.
set -uo pipefail

BASE=""; HEAD_REF="HEAD"; BODY_FILE=""; PR=""; REPO=""
refuse() { echo "check-deleted-tests: $1 — refusing to report clean" >&2; exit 2; }
usage() { echo "usage: $(basename "$0") --base <ref> [--head <ref>] [--body-file <file>|-] [--pr <n>] [--repo <dir>]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --base)      BASE="${2:-}"; shift 2 ;;
    --head)      HEAD_REF="${2:-}"; shift 2 ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 ;;
    --pr)        PR="${2:-}"; shift 2 ;;
    --repo)      REPO="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$BASE" ] || usage
[ -n "$REPO" ] || REPO=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO" ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || refuse "no git repo at '${REPO:-<cwd>}'"
g() { git -C "$REPO" "$@"; }

# --verify --quiet: a bare rev-parse ECHOES a ref it cannot resolve to stdout, and a
# diff against that string is a diff against nothing.
B=$(g rev-parse --verify --quiet "$BASE^{commit}" 2>/dev/null) \
  || refuse "base '$BASE' does not resolve to a commit"
H=$(g rev-parse --verify --quiet "$HEAD_REF^{commit}" 2>/dev/null) \
  || refuse "head '$HEAD_REF' does not resolve to a commit"
# No merge-base fails safe: a test the trunk added since then reads as deleted, a red.
MB=$(g merge-base "$B" "$H" 2>/dev/null || true)

# ---- the patterns --------------------------------------------------------------
CFG="${HARNESS_CFG_PATH:-$REPO/.claude/harness.json}"
PATTERNS="${HARNESS_TEST_PATTERNS:-}"
if [ -z "$PATTERNS" ] && [ -f "$CFG" ]; then
  ptype=$(jq -r '(.tests.patterns // null) | type' "$CFG" 2>/dev/null) \
    || refuse "cannot read '$CFG' as JSON"
  case "$ptype" in
    null) : ;;
    array) PATTERNS=$(jq -r '.tests.patterns | map(select(type == "string")) | join(" ")' "$CFG") ;;
    *) refuse "tests.patterns in $CFG is a $ptype; it must be a list of globs" ;;
  esac
fi
[ -n "$PATTERNS" ] || PATTERNS="*.test.ts *.test.tsx *.spec.ts"
is_test() { # <path>
  local p
  set -f
  for p in $PATTERNS; do
    # shellcheck disable=SC2254
    case "$1" in $p) set +f; return 0 ;; esac
  done
  set +f; return 1
}

# ---- the cases in one file at one commit -----------------------------------------
# One case per line: `run<TAB>title`, or `off<TAB>title` for a case that pins nothing —
# .skip / .todo, an x prefix, inside a skipped or x-prefixed describe, or outside
# every .only when the file has one. .skipIf / .runIf run wherever CI meets the condition.
# `x.test(` is a method call, not a case, and a whole-line // comment is not code.
# Fails when git cannot read the file: every caller checks, as an unread file is not an empty one.
cases_at() { # <commit> <path>
  g show "$1:$2" 2>/dev/null | perl -0777 -ne '
    s{^[ \t]*//[^\n]*}{}mg;
    my $src = $_; my $code = $src; my $n = length $src;
    # $code is $src with strings, comments and regex literals blanked, so a bracket
    # inside one never opens or closes a describe block.
    my $blank = sub { my ($a, $e) = @_; (my $s = substr($src, $a, $e - $a)) =~ s/[^\n]/ /g; substr($code, $a, $e - $a) = $s };
    my ($i, $prev) = (0, "(");
    while ($i < $n) {
      my $ch = substr($src, $i, 1); my $nx = substr($src, $i + 1, 1);
      if ($ch eq "/" && $nx eq "/") { my $e = index($src, "\n", $i); $e = $n if $e < 0; $blank->($i, $e); $i = $e; next }
      if ($ch eq "/" && $nx eq "*") { my $e = index($src, "*/", $i + 2); $e = $e < 0 ? $n : $e + 2; $blank->($i, $e); $i = $e; next }
      if ($ch =~ /["\x27`]/ || ($ch eq "/" && $prev =~ m{[(,=:\[!&|?{};+\-*%<>~^]})) {
        my $j = $i + 1;
        while ($j < $n) { my $c = substr($src, $j, 1);
          if ($c eq "\\") { $j += 2; next } last if $c eq $ch || ($c eq "\n" && $ch ne "`"); $j++ }
        $j = $n if $j > $n; $blank->($i + 1, $j); $i = $j + 1; $prev = "a"; next }
      $prev = $ch if $ch =~ /\S/; $i++;
    }
    my (%close, @open);
    while ($code =~ /([()])/g) { if ($1 eq "(") { push @open, $-[0] } elsif (@open) { $close{pop @open} = $-[0] } }
    my $mods = qr/(?:\.(?:only|skip|todo|concurrent|sequential|failing|fails|(?:each|skipIf|runIf)\s*\((?:[^()]|\([^()]*\))*\)))*/;
    my $isoff = qr/\.(?:skip|todo)\b/;
    my (@blk, @case, $only);
    while ($code =~ /(?<![\w.\$])(x?)describe($mods)\s*\(/g) {
      my ($x, $m, $o) = ($1, $2, $+[0] - 1); my $on = $m =~ /\.only\b/ ? 1 : 0; $only ||= $on;
      push @blk, [$o, $close{$o} // $n, ($x || $m =~ $isoff) ? 1 : 0, $on] }
    while ($src =~ /(?<![\w.\$])(x?)(?:it|test)($mods)\s*\(\s*(["\x27`])((?:\\.|(?!\3).)*?)\3/gs) {
      my ($x, $m, $t, $p) = ($1, $2, $4, $-[0]);
      my $off = ($x || $m =~ $isoff) ? 1 : 0; my $on = $m =~ /\.only\b/ ? 1 : 0; $only ||= $on;
      for my $b (@blk) { next unless $b->[0] < $p && $p < $b->[1]; $off ||= $b->[2]; $on ||= $b->[3] }
      $t =~ s/\s+/ /g; push @case, [$off, $on, $t] }
    for (@case) { my ($off, $on, $t) = @$_; print +($off || ($only && !$on) ? "off" : "run"), "\t$t\n" }'
}
runs() { grep -c '^run	'; }
# Filler words carry no meaning, so they never count towards "like it" (Dice over word sets).
WORDS='my %stop = map { $_ => 1 } qw(a an the and or of to in on for is are it its by with as at be not no from this that when);
  sub words { my %w = map { $_ => 1 } grep { length && !$stop{$_} } split /[^a-z0-9%]+/, lc shift; \%w }
  sub dice { my ($p, $q) = @_; my $n = keys(%$p) + keys(%$q); return 0 unless $n;
             my $s = grep { $q->{$_} } keys %$p; 2 * $s / $n }
'
# ---- what the diff loses and gains, per file ---------------------------------------------
# A file can lose a title for three reasons, and only one of them loses a test: the case
# was renamed or rewritten where it stands, it moved to another file, or it is gone. So a
# lost title is first matched to a title the diff GAINS — the same words anywhere, then any
# new case in the same file (a rewrite in place), then a case with most of the same words in
# another file (a move with a reword). Only a lost case left with no match is a deletion.
#
# A case lost must also be in the merge-base copy to be this branch's deletion — a case the
# trunk added since is not something the branch removed. Two cases with one title are two.
#
# A case turned off keeps its title in the file, so before any matching each case newly off
# at head claims one of its file's lost cases — the same title, else the closest words past
# half. The claimed case goes to OFFF and is never matched: no new case can stand in for it.
LOSTF=$(mktemp); GAINF=$(mktemp); OFFF=$(mktemp); DIFFF=$(mktemp)
trap 'rm -f "$LOSTF" "$GAINF" "$OFFF" "$DIFFF"' EXIT
CASES_BASE=0; CASES_HEAD=0
diff_cases() { # <owner> <base-path|""> <head-path|"">  appends owner<TAB>title to LOSTF / GAINF / OFFF
  local a b m
  a=$(mktemp); b=$(mktemp); m=$(mktemp)
  if [ -n "$2" ]; then cases_at "$B" "$2" > "$a" || refuse "could not read $2 at $B"; fi
  if [ -n "$3" ]; then cases_at "$H" "$3" > "$b" || refuse "could not read $3 at $H"; fi
  if [ -n "$2" ] && [ -n "$MB" ]; then cases_at "$MB" "$2" > "$m" || refuse "could not read $2 at $MB"
  else cp "$a" "$m"; fi
  CASES_BASE=$((CASES_BASE + $(runs < "$a"))); CASES_HEAD=$((CASES_HEAD + $(runs < "$b")))
  perl -e "$WORDS"'
    my ($owner, @f) = @ARGV; my (%c, %o, @lost, @off);
    for my $i (0..2) { open my $fh, "<", $f[$i] or die;
      while (<$fh>) { chomp; my ($k, $t) = split /\t/, $_, 2; ($k eq "run" ? \%c : \%o)->{$t}[$i]++ } }
    open my $lo, ">>", $f[3] or die; open my $ga, ">>", $f[4] or die; open my $of, ">>", $f[5] or die;
    for my $t (sort keys %c) {
      my ($x, $y, $z) = map { $_ // 0 } @{$c{$t}}[0..2];
      push @lost, $t for 1..(($x < $z ? $x : $z) - $y);
      # Gained since the merge-base, not since base: a case the trunk retired after the
      # cut, which the branch still carries, is not a new case the branch wrote.
      my $was = $x > $z ? $x : $z;
      print $ga "$owner\t$t\n" for 1..($y - $was);
    }
    for my $t (sort keys %o) {
      my ($x, $y, $z) = map { $_ // 0 } @{$o{$t}}[0..2];
      push @off, $t for 1..($y - ($x > $z ? $x : $z));
    }
    my @rest;
    for my $t (@off) { my ($i) = grep { $lost[$_] eq $t } 0..$#lost;
      if (defined $i) { print $of "$owner\t" . splice(@lost, $i, 1) . "\n" } else { push @rest, $t } }
    for my $t (@rest) { last unless @lost; my ($best, $bd, $w) = (-1, 0.5, words($t));
      for my $i (0..$#lost) { my $d = dice($w, words($lost[$i])); ($best, $bd) = ($i, $d) if $d > $bd }
      print $of "$owner\t" . splice(@lost, $best, 1) . "\n" if $best >= 0 }
    print $lo "$owner\t$_\n" for @lost;
    ' "$1" "$a" "$b" "$m" "$LOSTF" "$GAINF" "$OFFF" \
    || refuse "could not compare the cases in $1"
  rm -f "$a" "$b" "$m"
}

# LABEL: owner <TAB> what happened to the file, for the files that may owe a line.
LABEL=""; seen_tests=0
label() { LABEL="${LABEL}$1	$2
"; }
# Read to a file, not a process substitution: its exit status is never seen, and a
# diff git could not make would read as a diff that touches nothing.
g -c diff.renameLimit=100000 diff -z --name-status -M --diff-filter=ADMRTC "$B" "$H" > "$DIFFF" 2>/dev/null \
  || refuse "could not read the diff $B..$H"
while IFS= read -r -d '' st; do
  old=""; new=""
  case "$st" in
    R*|C*) IFS= read -r -d '' old && IFS= read -r -d '' new ;;
    A|D|M|T) IFS= read -r -d '' old; new="$old" ;;
  esac
  [ -n "$old" ] && [ -n "$new" ] || refuse "could not parse the diff $B..$H at the record '$st'"
  if ! is_test "$old"; then
    # A test file that is new at head, under any name, is where moved cases land.
    case "$st" in A|R*|C*) is_test "$new" && { seen_tests=$((seen_tests + 1)); diff_cases "$new" "" "$new"; } ;; esac
    continue
  fi
  seen_tests=$((seen_tests + 1))
  case "$st" in
    A)  diff_cases "$new" "" "$new" ;;
    C*) is_test "$new" && diff_cases "$new" "" "$new" ;;   # a copy leaves the original where it was
    D)
      # Only on base, never at the merge-base: the trunk added it after the cut.
      if [ -n "$MB" ]; then
        inmb=$(g ls-tree --full-tree --name-only "$MB" -- "$old" 2>/dev/null) \
          || refuse "could not read the tree at the merge-base $MB"
        [ -n "$inmb" ] || continue
      fi
      label "$old" "deleted"; diff_cases "$old" "$old" "" ;;
    R*)
      if ! is_test "$new"; then
        label "$old" "renamed to $new, which is not a test file"; diff_cases "$old" "$old" ""
      else
        label "$old" "renamed to $new and"; diff_cases "$old" "$old" "$new"
      fi ;;
    M|T) label "$old" ""; diff_cases "$old" "$old" "$old" ;;
  esac
done < "$DIFFF"

# The matching. Out: "lost" owner<TAB>title for a case with nothing like it at head, and
# "kept" owner<TAB>title<TAB>where it went<TAB>its title now<TAB>how, for one matched.
# "Like it" across files: more than half the words shared, filler words left out (Dice
# over word sets). Inside one file there is no floor: the file kept the case count, and
# measured in-place rewrites share as little as no word at all with their old title.
MATCH=$(perl -e "$WORDS"'
  my ($lf, $gf) = @ARGV; my (@L, @G);
  open my $lh, "<", $lf or die; while (<$lh>) { chomp; push @L, [split /\t/, $_, 2] }
  open my $gh, "<", $gf or die; while (<$gh>) { chomp; push @G, [split /\t/, $_, 2] }
  my (%lu, %gu, @kept);
  my $pair = sub { my ($i, $j, $how) = @_; $lu{$i} = $gu{$j} = 1; push @kept, [$i, $j, $how] };
  # 1. The same words anywhere: a move.
  for my $i (0..$#L) { for my $j (0..$#G) { next if $gu{$j};
    if ($L[$i][1] eq $G[$j][1]) { $pair->($i, $j, "moved"); last } } }
  # 2. Any new case in the same file, closest words first: a rewrite in place.
  # 3. Most of the same words in another file: a move with a reword.
  for my $pass (2, 3) {
    my @c;
    for my $i (grep { !$lu{$_} } 0..$#L) { my $wi = words($L[$i][1]);
      for my $j (grep { !$gu{$_} } 0..$#G) {
        my $same = $L[$i][0] eq $G[$j][0];
        next if $pass == 2 ? !$same : $same;
        my $d = dice($wi, words($G[$j][1]));
        next if $pass == 3 && $d <= 0.5;
        push @c, [$d, $i, $j] } }
    for my $c (sort { $b->[0] <=> $a->[0] || $a->[1] <=> $b->[1] || $a->[2] <=> $b->[2] } @c) {
      my (undef, $i, $j) = @$c; next if $lu{$i} || $gu{$j};
      $pair->($i, $j, $pass == 2 ? "rewritten" : "moved") }
  }
  print "kept\t$L[$_->[0]][0]\t$L[$_->[0]][1]\t$G[$_->[1]][0]\t$G[$_->[1]][1]\t$_->[2]\n" for @kept;
  print "lost\t$L[$_][0]\t$L[$_][1]\n" for grep { !$lu{$_} } 0..$#L;
' "$LOSTF" "$GAINF") \
  || refuse "matching lost cases to new ones failed"
LOST=$(printf '%s\n' "$MATCH" | awk -F'\t' '$1 == "lost" { print $2 "\t" $3 }')
KEPT_N=$(printf '%s\n' "$MATCH" | grep -c '^kept	')
OFF=$(cat "$OFFF")

# FOUND: path <TAB> what, one per file that owes a line; DETAIL / DETAIL_OFF: its cases.
FOUND=""; DETAIL=""; DETAIL_OFF=""
while IFS='	' read -r path how; do
  [ -n "$path" ] || continue
  k=$(printf '%s\n' "$LOST" | awk -F'\t' -v p="$path" '$1 == p' | grep -c .)
  o=$(printf '%s\n' "$OFF" | awk -F'\t' -v p="$path" '$1 == p' | grep -c .)
  case "$how" in
    deleted)
      c=$(cases_at "$B" "$path") || refuse "could not read $path at $B"
      total=$(printf '%s\n' "$c" | runs)
      [ "$k" -eq 0 ] && [ "$total" -gt 0 ] && continue
      if [ "$k" -eq "$total" ]; then what="deleted ($total cases)"
      else what="deleted ($total cases; $k of them have nothing like them at head)"; fi ;;
    *"not a test file") what="$how" ;;
    *) [ $((k + o)) -eq 0 ] && continue
       if [ "$o" -eq 0 ]; then what="lost $k case(s)"
       elif [ "$k" -eq 0 ]; then what="turned off $o case(s)"
       else what="lost $k case(s), turned off $o"; fi
       what="${how:+$how }$what" ;;
  esac
  FOUND="${FOUND}${path}	${what}
"
  [ "$k" -gt 0 ] && DETAIL="${DETAIL}$(printf '%s\n' "$LOST" | awk -F'\t' -v p="$path" '$1 == p { print "    " $1 ": " $2 }')
"
  [ "$o" -gt 0 ] && DETAIL_OFF="${DETAIL_OFF}$(printf '%s\n' "$OFF" | awk -F'\t' -v p="$path" '$1 == p { print "    " $1 ": " $2 }')
"
done <<EOF
$LABEL
EOF

# Control: prove the probe can see test files at all before its silence means
# anything. A zero from a strictness probe is clean, suppressed, or never ran.
files_at_base=$(g ls-tree -r --name-only "$B" 2>/dev/null) \
  || refuse "could not list the files at base $B for the control count"
tests_at_base=0
while IFS= read -r p; do is_test "$p" && tests_at_base=$((tests_at_base + 1)); done <<EOF
$files_at_base
EOF
printf 'control, test files at base          : %s (patterns: %s)\n' "$tests_at_base" "$PATTERNS"
printf 'test files the diff touches          : %s\n' "$seen_tests"
printf 'cases in them, base -> head          : %s -> %s\n' "$CASES_BASE" "$CASES_HEAD"
printf 'cases renamed, rewritten or moved    : %s\n' "$KEPT_N"
n=$(printf '%s' "$FOUND" | grep -c .)
printf 'test files deleted or losing cases   : %s\n' "$n"
[ "$n" -eq 0 ] && exit 0

# ---- the accounting ------------------------------------------------------------------
BODY=""
if [ -n "$BODY_FILE" ]; then
  if [ "$BODY_FILE" = "-" ]; then BODY=$(cat); else
    [ -f "$BODY_FILE" ] || refuse "no body file '$BODY_FILE'"
    BODY=$(cat "$BODY_FILE"); fi
elif [ -n "$PR" ]; then
  BODY=$(cd "$REPO" && gh pr view "$PR" --json body -q .body 2>/dev/null) \
    || refuse "could not read the body of pull request $PR"
fi
# path <TAB> covered|purpose <TAB> value, one per accounting line in the section.
LINES=$(printf '%s\n' "$BODY" | tr -d '\r' | perl -ne '
  if (/^\s*##\s*Deleted tests\s*$/i) { $in = 1; next }
  if ($in && /^\s*#{1,2}\s/) { $in = 0 }
  next unless $in;
  next unless /^\s*[-*]\s+(.+?)\s*(?:\xe2\x86\x92|->)\s*(.+?)\s*$/;
  my ($p, $r) = ($1, $2); $p =~ s/^`|`$//g;
  if ($r =~ /^covered by\s+`?([^`\s]+)`?\s*$/i) { print "$p\tcovered\t$1\n" }
  elsif ($r =~ /^removed on purpose\s*:\s*(.*)$/i) { print "$p\tpurpose\t$1\n" }
  else { print "$p\tbad\t$r\n" }')

fail=""; ok=0
while IFS='	' read -r path what; do
  [ -n "$path" ] || continue
  line=$(printf '%s\n' "$LINES" | awk -F'\t' -v p="$path" '$1 == p' | tail -1)
  kind=$(printf '%s' "$line" | cut -f2); val=$(printf '%s' "$line" | cut -f3-)
  why=""
  case "$kind" in
    "") why="no line for it under '## Deleted tests'" ;;
    covered)
      if ! g cat-file -e "$H:$val" 2>/dev/null; then why="'covered by $val' — that file does not exist at head"
      elif ! is_test "$val"; then why="'covered by $val' — that is not a test file (patterns: $PATTERNS)"
      else
        c=$(cases_at "$H" "$val") || refuse "could not read $val at $H"
        [ "$(printf '%s\n' "$c" | runs)" -eq 0 ] && why="'covered by $val' — it has no live it(/test( case at head"
      fi ;;
    purpose)
      r=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//; s/[ .]*$//')
      case "$r" in
        ""|"<"*">"|tbd|todo|n/a|na|none|-) why="'removed on purpose' needs a real reason, not '${val}'" ;;
      esac ;;
    *) why="the line does not say 'covered by <path>' or 'removed on purpose: <reason>' — got '$val'" ;;
  esac
  if [ -n "$why" ]; then fail="${fail}  ${path} — ${what}: ${why}
"; else ok=$((ok + 1)); fi
done <<EOF
$FOUND
EOF

printf 'accounted for in the body            : %s of %s\n' "$ok" "$n"
[ -z "$fail" ] && exit 0

echo
echo "These test files are deleted or lose cases, and the pull request does not account for them:"
printf '%s' "$fail"
if [ -n "$DETAIL" ]; then echo; echo "  the cases lost:"; printf '%s' "$DETAIL"; fi
if [ -n "$DETAIL_OFF" ]; then echo; echo "  the cases turned off:"; printf '%s' "$DETAIL_OFF"; fi
cat <<MSG

A deleted test is the one regression no other test can catch. Add a section to
the pull request body, one line per file, naming the test that now pins the same
behaviour or why the behaviour is gone:

## Deleted tests
MSG
printf '%s' "$FOUND" | while IFS='	' read -r path _; do
  [ -n "$path" ] && printf -- '- `%s` → covered by `<test file at head>`  |  removed on purpose: <reason>\n' "$path"
done
exit 1
