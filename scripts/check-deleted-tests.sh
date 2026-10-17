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
#     2. a test file that stays but LOSES `it(` / `test(` cases. A case turned into
#        `it.skip` / `it.todo` counts as lost: it no longer runs.
#   A file git sees as RENAMED is not a deletion; its cases are compared across
#   the rename, so a move that drops cases on the way is still caught.
#
#   It counts cases, not titles. A title that leaves is matched to one the diff
#   adds — the same words in any test file, else any new case in the same file
#   (a rewrite in place), else one sharing half its words in another file. Only a
#   case left with no match owes a line, so a renamed, reworded or moved case
#   passes, while a drop in the count, or a named case with nothing like it at
#   head, still fails. Measured on the origin project before this: 74 of 85 files
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
#        2 = refused: a ref that does not resolve, an unreadable config — a
#            measurement that could not be made is not a clean one.
set -uo pipefail

BASE=""; HEAD_REF="HEAD"; BODY_FILE=""; PR=""; REPO=""
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
  || { echo "check-deleted-tests: no git repo at '${REPO:-<cwd>}'" >&2; exit 2; }
g() { git -C "$REPO" "$@"; }

# --verify --quiet: a bare rev-parse ECHOES a ref it cannot resolve to stdout, and a
# diff against that string is a diff against nothing.
B=$(g rev-parse --verify --quiet "$BASE^{commit}" 2>/dev/null) \
  || { echo "check-deleted-tests: base '$BASE' does not resolve to a commit — refusing to report clean" >&2; exit 2; }
H=$(g rev-parse --verify --quiet "$HEAD_REF^{commit}" 2>/dev/null) \
  || { echo "check-deleted-tests: head '$HEAD_REF' does not resolve to a commit — refusing to report clean" >&2; exit 2; }
MB=$(g merge-base "$B" "$H" 2>/dev/null || true)

# ---- the patterns --------------------------------------------------------------
CFG="${HARNESS_CFG_PATH:-$REPO/.claude/harness.json}"
PATTERNS="${HARNESS_TEST_PATTERNS:-}"
if [ -z "$PATTERNS" ] && [ -f "$CFG" ]; then
  ptype=$(jq -r '(.tests.patterns // null) | type' "$CFG" 2>/dev/null) \
    || { echo "check-deleted-tests: cannot read '$CFG' as JSON" >&2; exit 2; }
  case "$ptype" in
    null) : ;;
    array) PATTERNS=$(jq -r '.tests.patterns | map(select(type == "string")) | join(" ")' "$CFG") ;;
    *) echo "check-deleted-tests: tests.patterns in $CFG is a $ptype; it must be a list of globs" >&2; exit 2 ;;
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
# One title per line. `it(`/`test(` and their .only / .concurrent / .each(...) forms
# count; .skip / .todo do not, because a skipped case pins nothing. `x.test(` is a
# method call, not a case, and a whole-line // comment is not code.
cases_at() { # <commit> <path>
  g show "$1:$2" 2>/dev/null | perl -0777 -ne '
    s{^[ \t]*//[^\n]*}{}mg;
    while (/(?<![\w.\$])(?:it|test)((?:\.(?:only|skip|todo|concurrent|failing|each\s*\((?:[^()]|\([^()]*\))*\)))*)\s*\(\s*(["\x27`])((?:\\.|(?!\2).)*?)\2/gs) {
      my ($mods, $t) = ($1, $3);
      next if $mods =~ /\.(?:skip|todo)\b/;
      $t =~ s/\s+/ /g;
      print "$t\n";
    }'
}
# ---- what the diff loses and gains, per file ---------------------------------------------
# A file can lose a title for three reasons, and only one of them loses a test: the case
# was renamed or rewritten where it stands, it moved to another file, or it is gone. So a
# lost title is first matched to a title the diff GAINS — the same words anywhere, then any
# new case in the same file (a rewrite in place), then a case with most of the same words in
# another file (a move with a reword). Only a lost case left with no match is a deletion.
#
# A case lost must also be in the merge-base copy to be this branch's deletion — a case the
# trunk added since is not something the branch removed. Two cases with one title are two.
LOSTF=$(mktemp); GAINF=$(mktemp)
trap 'rm -f "$LOSTF" "$GAINF"' EXIT
CASES_BASE=0; CASES_HEAD=0
diff_cases() { # <owner> <base-path|""> <head-path|"">  appends owner<TAB>title to LOSTF / GAINF
  local a b m
  a=$(mktemp); b=$(mktemp); m=$(mktemp)
  [ -n "$2" ] && cases_at "$B" "$2" > "$a"
  [ -n "$3" ] && cases_at "$H" "$3" > "$b"
  if [ -n "$2" ] && [ -n "$MB" ]; then cases_at "$MB" "$2" > "$m"; else cp "$a" "$m"; fi
  CASES_BASE=$((CASES_BASE + $(grep -c . "$a"))); CASES_HEAD=$((CASES_HEAD + $(grep -c . "$b")))
  perl -e '
    my ($owner, @f) = @ARGV; my %c;
    for my $i (0..2) { open my $fh, "<", $f[$i] or die; while (<$fh>) { chomp; $c{$_}[$i]++ } }
    open my $lo, ">>", $f[3] or die; open my $ga, ">>", $f[4] or die;
    for my $t (sort keys %c) {
      my ($x, $y, $z) = map { $_ // 0 } @{$c{$t}}[0..2];
      my $gone = ($x < $z ? $x : $z) - $y;
      print $lo "$owner\t$t\n" for 1..$gone;
      print $ga "$owner\t$t\n" for 1..($y - $x);
    }' "$1" "$a" "$b" "$m" "$LOSTF" "$GAINF" \
    || { echo "check-deleted-tests: could not compare the cases in $1 — refusing to report clean" >&2; exit 2; }
  rm -f "$a" "$b" "$m"
}

# LABEL: owner <TAB> what happened to the file, for the files that may owe a line.
LABEL=""; seen_tests=0
label() { LABEL="${LABEL}$1	$2
"; }
while IFS= read -r -d '' st; do
  case "$st" in
    R*|C*) IFS= read -r -d '' old; IFS= read -r -d '' new ;;
    *)     IFS= read -r -d '' old; new="$old" ;;
  esac
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
      if [ -n "$MB" ] && ! g cat-file -e "$MB:$old" 2>/dev/null; then continue; fi
      label "$old" "deleted"; diff_cases "$old" "$old" "" ;;
    R*)
      if ! is_test "$new"; then
        label "$old" "renamed to $new, which is not a test file"; diff_cases "$old" "$old" ""
      else
        label "$old" "renamed to $new and"; diff_cases "$old" "$old" "$new"
      fi ;;
    M|T) label "$old" ""; diff_cases "$old" "$old" "$old" ;;
  esac
done < <(g -c diff.renameLimit=100000 diff -z --name-status -M --diff-filter=ADMRTC "$B" "$H" 2>/dev/null)

# The matching. Out: "lost" owner<TAB>title for a case with nothing like it at head, and
# "kept" owner<TAB>title<TAB>where it went<TAB>its title now<TAB>how, for one matched.
# "Like it" across files: half or more of the words shared (Dice over word sets).
MATCH=$(perl -e '
  my ($lf, $gf) = @ARGV; my (@L, @G);
  open my $lh, "<", $lf or die; while (<$lh>) { chomp; push @L, [split /\t/, $_, 2] }
  open my $gh, "<", $gf or die; while (<$gh>) { chomp; push @G, [split /\t/, $_, 2] }
  sub words { my %w = map { $_ => 1 } grep { length } split /[^a-z0-9%]+/, lc shift; \%w }
  sub dice { my ($p, $q) = @_; my $n = keys(%$p) + keys(%$q); return 0 unless $n;
             my $s = grep { $q->{$_} } keys %$p; 2 * $s / $n }
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
        next if $pass == 3 && $d < 0.5;
        push @c, [$d, $i, $j] } }
    for my $c (sort { $b->[0] <=> $a->[0] || $a->[1] <=> $b->[1] || $a->[2] <=> $b->[2] } @c) {
      my (undef, $i, $j) = @$c; next if $lu{$i} || $gu{$j};
      $pair->($i, $j, $pass == 2 ? "rewritten" : "moved") }
  }
  print "kept\t$L[$_->[0]][0]\t$L[$_->[0]][1]\t$G[$_->[1]][0]\t$G[$_->[1]][1]\t$_->[2]\n" for @kept;
  print "lost\t$L[$_][0]\t$L[$_][1]\n" for grep { !$lu{$_} } 0..$#L;
' "$LOSTF" "$GAINF") \
  || { echo "check-deleted-tests: matching lost cases to new ones failed — refusing to report clean" >&2; exit 2; }
LOST=$(printf '%s\n' "$MATCH" | awk -F'\t' '$1 == "lost" { print $2 "\t" $3 }')
KEPT_N=$(printf '%s\n' "$MATCH" | grep -c '^kept	')

# FOUND: path <TAB> what, one per file that owes a line; DETAIL: the cases it lost.
FOUND=""; DETAIL=""
while IFS='	' read -r path how; do
  [ -n "$path" ] || continue
  k=$(printf '%s\n' "$LOST" | awk -F'\t' -v p="$path" '$1 == p' | grep -c .)
  case "$how" in
    deleted)
      total=$(cases_at "$B" "$path" | grep -c .)
      [ "$k" -eq 0 ] && [ "$total" -gt 0 ] && continue
      if [ "$k" -eq "$total" ]; then what="deleted ($total cases)"
      else what="deleted ($total cases; $k of them have nothing like them at head)"; fi ;;
    *"not a test file") what="$how" ;;
    *) [ "$k" -eq 0 ] && continue
       what="${how:+$how }lost $k case(s)" ;;
  esac
  FOUND="${FOUND}${path}	${what}
"
  [ "$k" -gt 0 ] && DETAIL="${DETAIL}$(printf '%s\n' "$LOST" | awk -F'\t' -v p="$path" '$1 == p { print "    " $1 ": " $2 }')
"
done <<EOF
$LABEL
EOF

# Control: prove the probe can see test files at all before its silence means
# anything. A zero from a strictness probe is clean, suppressed, or never ran.
tests_at_base=$(g ls-tree -r --name-only "$B" 2>/dev/null | while IFS= read -r p; do is_test "$p" && echo x; done | grep -c .)
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
    [ -f "$BODY_FILE" ] || { echo "check-deleted-tests: no body file '$BODY_FILE'" >&2; exit 2; }
    BODY=$(cat "$BODY_FILE"); fi
elif [ -n "$PR" ]; then
  BODY=$(cd "$REPO" && gh pr view "$PR" --json body -q .body 2>/dev/null) \
    || { echo "check-deleted-tests: could not read the body of pull request $PR" >&2; exit 2; }
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
      elif [ "$(cases_at "$H" "$val" | grep -c .)" -eq 0 ]; then why="'covered by $val' — it has no live it(/test( case at head"
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
