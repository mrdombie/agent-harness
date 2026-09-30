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
# Cases in the base copy that head no longer has, counted (two cases with one title
# are two cases). A case must also be in the merge-base copy to be this branch's
# deletion — a case the trunk added since is not something the branch removed.
lost_cases() { # <base-path> <head-path>
  local a b m
  a=$(mktemp); b=$(mktemp); m=$(mktemp)
  cases_at "$B" "$1" > "$a"; cases_at "$H" "$2" > "$b"
  if [ -n "$MB" ]; then cases_at "$MB" "$1" > "$m"; else cp "$a" "$m"; fi
  perl -e '
    my %c; my @f = @ARGV;
    for my $i (0..2) { open my $fh, "<", $f[$i] or die; while (<$fh>) { chomp; $c{$_}[$i]++ } }
    for my $t (sort keys %c) {
      my ($x, $y, $z) = map { $_ // 0 } @{$c{$t}}[0..2];
      my $gone = ($x < $z ? $x : $z) - $y;
      print "$t\n" for 1..$gone;
    }' "$a" "$b" "$m"
  rm -f "$a" "$b" "$m"
}

# ---- what the diff deletes -----------------------------------------------------------
# FOUND: path <TAB> what, one per file that owes a line. -z so a path is a path.
FOUND=""; DETAIL=""; seen_tests=0
add() { FOUND="${FOUND}$1	$2
"; }
while IFS= read -r -d '' st; do
  case "$st" in
    R*|C*) IFS= read -r -d '' old; IFS= read -r -d '' new ;;
    *)     IFS= read -r -d '' old; new="$old" ;;
  esac
  is_test "$old" || continue
  seen_tests=$((seen_tests + 1))
  case "$st" in
    C*) continue ;;   # a copy leaves the original where it was
    D)
      # Only on base, never at the merge-base: the trunk added it after the cut.
      if [ -n "$MB" ] && ! g cat-file -e "$MB:$old" 2>/dev/null; then continue; fi
      add "$old" "deleted ($(cases_at "$B" "$old" | grep -c .) cases)" ;;
    R*)
      if ! is_test "$new"; then
        add "$old" "renamed to $new, which is not a test file"
      else
        lost=$(lost_cases "$old" "$new")
        if [ -n "$lost" ]; then
          add "$old" "renamed to $new and lost $(printf '%s\n' "$lost" | grep -c .) case(s)"
          DETAIL="${DETAIL}$(printf '%s\n' "$lost" | sed "s|^|    $old: |")
"
        fi
      fi ;;
    M|T)
      lost=$(lost_cases "$old" "$new")
      if [ -n "$lost" ]; then
        add "$old" "lost $(printf '%s\n' "$lost" | grep -c .) case(s)"
        DETAIL="${DETAIL}$(printf '%s\n' "$lost" | sed "s|^|    $old: |")
"
      fi ;;
  esac
done < <(g -c diff.renameLimit=100000 diff -z --name-status -M --diff-filter=DMRTC "$B" "$H" 2>/dev/null)

# Control: prove the probe can see test files at all before its silence means
# anything. A zero from a strictness probe is clean, suppressed, or never ran.
tests_at_base=$(g ls-tree -r --name-only "$B" 2>/dev/null | while IFS= read -r p; do is_test "$p" && echo x; done | grep -c .)
printf 'control, test files at base          : %s (patterns: %s)\n' "$tests_at_base" "$PATTERNS"
printf 'test files the diff touches          : %s\n' "$seen_tests"
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
