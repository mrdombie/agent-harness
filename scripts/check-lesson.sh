#!/usr/bin/env bash
# check-lesson.sh — a fix pull request ships a lesson, and the lesson's guard is in the diff.
#
# WHY
#   Healing a build is pointless if the same class of mistake comes back. A fix is
#   finished when it leaves behind a machine check that would have caught it, named
#   at the level of the principle so it catches the next sibling too. Asking agents
#   to do that is advisory and gets skipped; this check is the seat that cannot be,
#   because it runs as a required CI check on the pull request itself.
#
# WHAT IS A FIX — known by what it is, not by one tag. Any one of:
#   - a pull request label in lesson.fixLabels;
#   - a <lesson.classLabelPrefix><class> label with the class in lesson.fixClasses
#     (a repair or approved-merge spawn), or --class naming one;
#   - a title of conventional type fix (`fix: …`, `fix(scope): …`, `fix!: …`) or a
#     branch starting `fix/` or `fix-`;
#   - a linked issue — closed by it, or referenced (`Refs #N`, `Part of #N`, …) —
#     whose issue type is in lesson.fixIssueTypes or whose labels meet fixLabels.
#   Relabelling an issue does not re-run the check; a push or a body edit does.
#
# WHAT A FIX OWES
#   A `## Lesson` section in the body. HTML comments, fenced and indented code never
#   count, and an unclosed comment or fence runs to the end of the body:
#
#     ## Lesson
#     - Principle: <one sentence naming the class of mistake, not the instance>
#     - Guard: `path/to/the.test.ts`
#     - Before/after: <the guard fails on the pre-fix code and passes on the fix>
#     - Reach: <the sibling it also catches, or the search that found none>
#
#   The Guard must name a path the diff (two dots, base..head, from commits) adds or
#   changes IN SUBSTANCE — a non-whitespace content change; a pure rename or a
#   whitespace edit is not one — and that is an executable check: it matches a guard
#   pattern and no exclude (docs and prose never count). Or, instead of a Guard, one
#   line of at least eight words:
#
#     Not automatable because <the reason, in words>
#
#   which passes and prints `lesson: not-automatable` so a report can count them.
#
# EVERYTHING IT JUDGES BY COMES FROM THE BASE
#   .claude/harness.json is read at --base, never at head. HARNESS_GUARD_PATTERNS
#   (the workflow's guard-patterns input) can only NARROW the guard set: a path must
#   match it as well. The CI seat runs the script from a trusted ref, never the
#   pull request's own copy (see .github/workflows/lesson.yml).
#
# CONFIG (lesson block of .claude/harness.json)
#   fixLabels        default ["bug", "type:bug"]
#   fixIssueTypes    default ["Bug"]
#   fixClasses       default ["repair", "approved-merge"]
#   classLabelPrefix default "class:"
#   guardPatterns    default GUARD_DEFAULT below plus tests.patterns; set, it replaces both
#   guardExclude     default EXCLUDE_DEFAULT below
#   Globs: a pattern with no `/` matches the file name anywhere; one with a `/` is
#   anchored at the repo root. `*` and `?` stay inside one directory; `**` crosses.
#
# USAGE
#   check-lesson.sh --base <ref> [--head <ref>] [--repo <dir>]
#                   [--pr <n>] [--slug <owner/name>] [--event <payload.json>]
#                   [--body-file <f>|-] [--labels <a,b>] [--title <t>] [--branch <b>]
#                   [--closing-file <json>] [--issues-file <json>] [--class <c>]
#   Anything not passed is read from the event payload, then from GitHub (gh).
#   --closing-file: the issues GitHub says the PR closes, [{"number","type","labels"}].
#   --issues-file: the issues to look linked numbers up in, same shape (offline).
#   Exit 0 = not a fix, or a fix with a complete lesson.
#        1 = a fix whose lesson is missing or incomplete; the first line says what.
#        2 = could not measure (GitHub, a ref, the config, a file). The first line
#            says so and that it is not a missing lesson.
set -uo pipefail

PR=""; EVENT=""; SLUG="${GITHUB_REPOSITORY:-}"; REPO=""; BASE=""; HEAD_REF="HEAD"
BODY_FILE=""; LABELS_ARG=""; LABELS_SET=0; TITLE=""; TITLE_SET=0; BRANCH=""; BRANCH_SET=0
CLOSING_FILE=""; ISSUES_FILE=""; CLASS="${HARNESS_SPAWN_CLASS:-}"
usage() { echo "lesson: could not run — bad arguments, not a missing lesson"; echo "usage: $(basename "$0") --base <ref> [--head <ref>] [--repo <dir>] [--pr <n>] [--slug <o/n>] [--event <payload>] [--body-file <f>|-] [--labels <a,b>] [--title <t>] [--branch <b>] [--closing-file <json>] [--issues-file <json>] [--class <c>]"; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)           PR="${2:-}"; shift 2 ;;
    --event)        EVENT="${2:-}"; shift 2 ;;
    --slug)         SLUG="${2:-}"; shift 2 ;;
    --repo)         REPO="${2:-}"; shift 2 ;;
    --base)         BASE="${2:-}"; shift 2 ;;
    --head)         HEAD_REF="${2:-}"; shift 2 ;;
    --body-file)    BODY_FILE="${2:-}"; shift 2 ;;
    --labels)       LABELS_ARG="${2:-}"; LABELS_SET=1; shift 2 ;;
    --title)        TITLE="${2:-}"; TITLE_SET=1; shift 2 ;;
    --branch)       BRANCH="${2:-}"; BRANCH_SET=1; shift 2 ;;
    --closing-file) CLOSING_FILE="${2:-}"; shift 2 ;;
    --issues-file)  ISSUES_FILE="${2:-}"; shift 2 ;;
    --class)        CLASS="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
# die <why> — could not measure. The first line is the one CI shows.
die() { echo "lesson: could not measure ($*), not a missing lesson" >&2; exit 2; }
gh_die() { { echo "lesson: could not read GitHub, not a missing lesson"; echo "  $*"; } >&2; exit 2; }
ERRF=$(mktemp); trap 'rm -f "$ERRF"' EXIT

if [ "${GITHUB_EVENT_NAME:-}" = "pull_request_target" ]; then
  echo "lesson: refused to run on pull_request_target, not a missing lesson"
  echo "  pull_request_target runs with the base's write token against a fork's code; call this from pull_request."
  exit 2
fi

[ -n "$BASE" ] || usage
[ -n "$REPO" ] || REPO=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO" ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "no git repo at '${REPO:-<cwd>}'"
g() { git -C "$REPO" "$@"; }
B=$(g rev-parse --verify --quiet "$BASE^{commit}" 2>/dev/null) || die "base '$BASE' does not resolve to a commit"
H=$(g rev-parse --verify --quiet "$HEAD_REF^{commit}" 2>/dev/null) || die "head '$HEAD_REF' does not resolve to a commit"

# ---- the event payload -----------------------------------------------------------
EV_BODY=""; EV_LABELS=""; EV_TITLE=""; EV_BRANCH=""; HAVE_EV=0
if [ -n "$EVENT" ]; then
  [ -f "$EVENT" ] || die "no event payload '$EVENT'"
  jq -e '.pull_request' "$EVENT" >/dev/null 2>&1 || die "'$EVENT' carries no pull_request"
  [ -n "$PR" ] || PR=$(jq -r '.pull_request.number // empty' "$EVENT")
  [ -n "$SLUG" ] || SLUG=$(jq -r '.repository.full_name // empty' "$EVENT")
  EV_BODY=$(jq -r '.pull_request.body // ""' "$EVENT")
  EV_LABELS=$(jq -r '[.pull_request.labels[]?.name] | join("\n")' "$EVENT")
  EV_TITLE=$(jq -r '.pull_request.title // ""' "$EVENT")
  EV_BRANCH=$(jq -r '.pull_request.head.ref // ""' "$EVENT")
  HAVE_EV=1
fi

# ---- the config, at base -------------------------------------------------------------
CFG_REL=".claude/harness.json"
CFG_JSON='{}'
if [ -n "${HARNESS_CFG_PATH:-}" ]; then
  [ -f "$HARNESS_CFG_PATH" ] || die "HARNESS_CFG_PATH '$HARNESS_CFG_PATH' does not exist"
  CFG_JSON=$(cat "$HARNESS_CFG_PATH")
elif g cat-file -e "$B:$CFG_REL" 2>/dev/null; then
  CFG_JSON=$(g show "$B:$CFG_REL") || die "cannot read $CFG_REL at base"
fi
printf '%s' "$CFG_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || die "$CFG_REL at base is not one JSON object"
# cfg_list <key> <default words> — newline-separated strings; a non-list is a refusal.
cfg_list() {
  local t
  t=$(printf '%s' "$CFG_JSON" | jq -r "(.$1 // null) | type")
  case "$t" in
    null)  set -f; printf '%s\n' $2; set +f ;;
    array) printf '%s' "$CFG_JSON" | jq -r ".$1 | map(select(type == \"string\")) | .[]" ;;
    *)     die "$1 in $CFG_REL is a $t; it must be a list" ;;
  esac
}
FIX_LABELS=$(cfg_list lesson.fixLabels "bug type:bug") || exit 2
FIX_TYPES=$(cfg_list lesson.fixIssueTypes "Bug") || exit 2
FIX_CLASSES=$(cfg_list lesson.fixClasses "repair approved-merge") || exit 2
CLASS_PREFIX=$(printf '%s' "$CFG_JSON" | jq -r '.lesson.classLabelPrefix // "class:"')
TEST_PATTERNS=$(cfg_list tests.patterns "*.test.ts *.test.tsx *.spec.ts") || exit 2
GUARD_DEFAULT="**/*.test.* **/*.spec.* **/*_test.* **/test_*.py **/__tests__/** **/test.sh **/test.*.sh **/tests/**
**/.eslintrc* **/eslint.config.* **/eslint-rules/** **/lint-rules/**
**/*.semgrep.yml **/*.semgrep.yaml **/.semgrep/** **/check-*.* **/gates/**"
EXCLUDE_DEFAULT="*.md *.mdx *.markdown *.txt *.rst *.adoc docs/** **/docs/**"
GUARD_INCLUDE=$(cfg_list lesson.guardPatterns "$(printf '%s' "$GUARD_DEFAULT" | tr '\n' ' ')") || exit 2
# tests.patterns join the defaults; an explicit guardPatterns replaces both.
if [ "$(printf '%s' "$CFG_JSON" | jq -r '.lesson.guardPatterns | type')" = null ]; then
  GUARD_INCLUDE="$GUARD_INCLUDE
$TEST_PATTERNS"
fi
GUARD_EXCLUDE=$(cfg_list lesson.guardExclude "$EXCLUDE_DEFAULT") || exit 2
GUARD_NARROW="${HARNESS_GUARD_PATTERNS:-}"
# glob_any <path> <patterns, whitespace-separated> — 0 when one matches.
glob_any() {
  P="$1" perl -e '
    sub rx { my $g = shift; my $base = ($g !~ m{/}); my $r = "";
      while (length $g) {
        if    ($g =~ s{^\*\*/}{}) { $r .= "(?:.*/)?" }
        elsif ($g =~ s{^\*\*}{})  { $r .= ".*" }
        elsif ($g =~ s{^\*}{})    { $r .= "[^/]*" }
        elsif ($g =~ s{^\?}{})    { $r .= "[^/]" }
        else  { $g =~ s{^(.)}{}s; $r .= quotemeta($1) } }
      return $base ? qr{(?:^|/)$r\z} : qr{^$r\z}; }
    for my $g (split /\s+/, $ARGV[0]) { next unless length $g; exit 0 if $ENV{P} =~ rx($g) }
    exit 1' "$2"
}
is_guard() { # <path> — an executable check: included, not excluded, and inside any narrowing.
  glob_any "$1" "$GUARD_INCLUDE" || return 1
  glob_any "$1" "$GUARD_EXCLUDE" && return 1
  [ -z "$GUARD_NARROW" ] || glob_any "$1" "$GUARD_NARROW" || return 1
  return 0
}
in_list() { printf '%s\n' "$2" | grep -qixF -- "$1"; } # <needle> <newline list>

# ---- GitHub, once, for whatever was not passed -------------------------------------
GH_JSON=""
need_gh=0
[ -n "$BODY_FILE" ] || [ "$HAVE_EV" = 1 ] || need_gh=1
[ "$LABELS_SET" = 1 ] || [ "$HAVE_EV" = 1 ] || need_gh=1
[ "$TITLE_SET" = 1 ] || [ "$HAVE_EV" = 1 ] || need_gh=1
[ -n "$CLOSING_FILE" ] || need_gh=1
if [ "$need_gh" = 1 ]; then
  [ -n "$PR" ] || die "no --pr, event or --body-file/--labels/--title/--closing-file to read the pull request from"
  [ -n "$SLUG" ] || die "no --slug or GITHUB_REPOSITORY to ask GitHub about pull request $PR"
  # shellcheck disable=SC2016
  GH_JSON=$(gh api graphql -F owner="${SLUG%%/*}" -F name="${SLUG#*/}" -F pr="$PR" -f query='
    query($owner: String!, $name: String!, $pr: Int!) {
      repository(owner: $owner, name: $name) { pullRequest(number: $pr) {
        body title headRefName
        labels(first: 100) { nodes { name } }
        closingIssuesReferences(first: 50) { nodes { number issueType { name } labels(first: 50) { nodes { name } } } }
      } } }' 2>"$ERRF") || gh_die "pull request $PR in $SLUG: $(head -1 "$ERRF")"
  printf '%s' "$GH_JSON" | jq -e '.data.repository.pullRequest' >/dev/null 2>&1 \
    || gh_die "GitHub returned no pull request $PR in $SLUG"
fi
ghf() { printf '%s' "$GH_JSON" | jq -r "$1"; }

# Body, labels, title: an explicit argument, else fresh from GitHub, else the event.
if [ -n "$BODY_FILE" ]; then
  if [ "$BODY_FILE" = "-" ]; then BODY=$(cat); else
    [ -f "$BODY_FILE" ] || die "no body file '$BODY_FILE'"; BODY=$(cat "$BODY_FILE"); fi
elif [ -n "$GH_JSON" ]; then BODY=$(ghf '.data.repository.pullRequest.body // ""')
else BODY="$EV_BODY"; fi
if [ "$LABELS_SET" = 1 ]; then LABELS=$(printf '%s' "$LABELS_ARG" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep .)
elif [ -n "$GH_JSON" ]; then LABELS=$(ghf '.data.repository.pullRequest.labels.nodes[].name')
else LABELS="$EV_LABELS"; fi
if [ "$TITLE_SET" != 1 ]; then
  if [ -n "$GH_JSON" ]; then TITLE=$(ghf '.data.repository.pullRequest.title // ""'); else TITLE="$EV_TITLE"; fi
fi
if [ "$BRANCH_SET" != 1 ]; then
  if [ -n "$GH_JSON" ]; then BRANCH=$(ghf '.data.repository.pullRequest.headRefName // ""')
  elif [ -n "$EV_BRANCH" ]; then BRANCH="$EV_BRANCH"; else BRANCH="${GITHUB_HEAD_REF:-}"; fi
fi
if [ -n "$CLOSING_FILE" ]; then
  [ -f "$CLOSING_FILE" ] || die "no closing-issues file '$CLOSING_FILE'"
  CLOSING=$(jq -c '[.[] | {number, type: (.type // null), labels: (.labels // [])}]' "$CLOSING_FILE" 2>/dev/null) \
    || die "'$CLOSING_FILE' is not a JSON list of issues"
else
  CLOSING=$(ghf '[.data.repository.pullRequest.closingIssuesReferences.nodes[]
    | {number, type: (.issueType.name // null), labels: [.labels.nodes[].name]}] | tostring')
fi

# ---- the body, as prose: comments, fences and indented code never count ------------
CLEAN=$(printf '%s\n' "$BODY" | tr -d '\r' | perl -0777 -pe '
  s/<!--.*?(?:-->|\z)//gs;
  s/^[ \t]*(`{3,}|~{3,})[^\n]*\n.*?(?:^[ \t]*\1[ \t]*$|\z)//gms;
  s/^(?: {4,}|\t)[^\n]*$//gm;')

# ---- is it a fix? -------------------------------------------------------------------
WHY_FIX=""
while IFS= read -r l; do
  [ -n "$l" ] || continue
  if in_list "$l" "$FIX_LABELS"; then WHY_FIX="it carries the '$l' label"; break; fi
  case "$l" in "$CLASS_PREFIX"*)
    c="${l#"$CLASS_PREFIX"}"
    if in_list "$c" "$FIX_CLASSES"; then WHY_FIX="it carries the '$l' label (a $c spawn)"; break; fi ;;
  esac
done <<EOF
$LABELS
EOF
if [ -z "$WHY_FIX" ] && [ -n "$CLASS" ] && in_list "$CLASS" "$FIX_CLASSES"; then
  WHY_FIX="it comes from a $CLASS spawn"
fi
if [ -z "$WHY_FIX" ] && printf '%s' "$TITLE" | grep -qiE '^[[:space:]]*fix(\([^)]*\))?!?:'; then
  WHY_FIX="its title is a fix ('$(printf '%s' "$TITLE" | cut -c1-60)')"
fi
if [ -z "$WHY_FIX" ] && printf '%s' "$BRANCH" | grep -qiE '^fix[/-]'; then
  WHY_FIX="its branch '$BRANCH' is a fix branch"
fi
# Linked issues: what GitHub says it closes (only on a default-branch base), plus every
# same-repo #N the prose closes or references.
LINKED=$(printf '%s\n' "$CLEAN" | perl -ne '
  while (/\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?|references?|related to|part of|see)\b\s*:?\s*(?:ticket\s+|issue\s+)?#(\d+)/gi) { print "$1\n" }' | sort -un)
issue_is_bug() { # <type> <comma labels> — 0 when the type or a label marks a bug
  [ -n "$1" ] && in_list "$1" "$FIX_TYPES" && return 0
  local l
  for l in $(printf '%s' "$2" | tr ' ,' '_\n'); do
    in_list "$(printf '%s' "$l" | tr '_' ' ')" "$FIX_LABELS" && return 0
  done
  return 1
}
if [ -z "$WHY_FIX" ]; then
  # A tab is IFS whitespace: an empty type would collapse and shift the labels into it.
  while IFS='|' read -r num typ lbls; do
    [ -n "$num" ] || continue
    if issue_is_bug "$typ" "$lbls"; then WHY_FIX="it closes #$num, a bug"; break; fi
  done <<EOF
$(printf '%s' "$CLOSING" | jq -r '.[] | "\(.number)|\(.type // "" | gsub("[|]"; " "))|\(.labels | map(gsub("[|,]"; " ")) | join(","))"')
EOF
fi
if [ -z "$WHY_FIX" ] && [ -n "$LINKED" ]; then
  if [ -n "$ISSUES_FILE" ]; then
    [ -f "$ISSUES_FILE" ] || die "no issues file '$ISSUES_FILE'"
    jq -e 'type == "array"' "$ISSUES_FILE" >/dev/null 2>&1 || die "'$ISSUES_FILE' is not a JSON list of issues"
  fi
  for n in $LINKED; do
    if [ -n "$ISSUES_FILE" ]; then
      row=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | "\(.type // "")|\(.labels // [] | join(","))"' "$ISSUES_FILE" | head -1)
    else
      [ -n "$SLUG" ] || die "no --slug to look up #$n"
      if ! row=$(gh api "repos/$SLUG/issues/$n" --jq '"\(.type.name // "")|\([.labels[].name] | join(","))"' 2>"$ERRF"); then
        case "$(cat "$ERRF")" in *"404"*|*"Not Found"*) row="" ;; *) gh_die "issue #$n in $SLUG: $(head -1 "$ERRF")" ;; esac
      fi
    fi
    [ -n "$row" ] || continue
    if issue_is_bug "${row%%|*}" "${row#*|}"; then WHY_FIX="it references #$n, a bug"; break; fi
  done
fi
if [ -z "$WHY_FIX" ]; then
  echo "lesson: not a fix pull request (no fix label, class, fix title or branch, or linked bug) — nothing owed"
  exit 0
fi

# ---- the lesson section ----------------------------------------------------------------
SECTION=$(printf '%s\n' "$CLEAN" | perl -ne '
  if (/^\s*##\s*Lesson\s*$/i) { $in = 1; print "has\tsection\n"; next }
  if ($in && /^\s*#{1,2}\s/) { $in = 0 }
  next unless $in;
  s/\*\*//g;
  if (/^\s*[-*]?\s*not automatable because\b\s*(.*?)\s*$/i) { print "na\t$1\n"; next }
  if (/^\s*[-*]?\s*(principle|guard|before\s*\/\s*after|before-after|before and after|reach)\s*:\s*(.*?)\s*$/i) {
    my ($k, $v) = (lc $1, $2); $k =~ s/[^a-z]//g; $k = "beforeafter" if $k =~ /^before/;
    print "$k\t$v\n";
  }')
field() { printf '%s\n' "$SECTION" | awk -F'\t' -v k="$1" '$1 == k { sub(/^[^\t]*\t/, ""); print; exit }'; }
has_field() { printf '%s\n' "$SECTION" | awk -F'\t' -v k="$1" '$1 == k { f = 1 } END { exit !f }'; }
# real <text> <min words> — not empty, not a placeholder, at least that many words.
real() {
  local t
  t=$(printf '%s' "$1" | tr -d '`' | tr '[:upper:]' '[:lower:]' | sed 's/^ *//; s/[ .]*$//')
  case "$t" in ""|"<"*">"|tbd|todo|n/a|na|none|-|...|…) return 1 ;; esac
  [ "$(printf '%s' "$t" | wc -w | tr -d ' ')" -ge "$2" ]
}

PASTE='## Lesson
- Principle: <one sentence naming the class of mistake, readable by someone who never saw the bug>
- Guard: `<a test, lint or gate file this pull request adds or changes>`
- Before/after: <the guard fails on the pre-fix code and passes on the fix>
- Reach: <the sibling it also catches, or the search that shows there are none>

(or, only when no machine check can hold it, instead of the Guard:
Not automatable because <the reason, in at least eight words>)'
refuse() { # <what is missing>
  echo "lesson: this is a fix pull request ($WHY_FIX), and $1."
  echo
  echo "Every fix ships a lesson: a machine check that would have caught this class of"
  echo "mistake. Add or complete this section in the pull request body:"
  echo
  printf '%s\n' "$PASTE"
  exit 1
}

if ! has_field has; then
  near=$(printf '%s\n' "$CLEAN" | perl -ne 'chomp; s/^\s+|\s+$//g;
    if (/^#{1,6}\s*lessons?\b.*$/i || /^#{1,6}lessons?\b/i || /^\*\*\s*lessons?\b[^*]*\*\*:?$/i || /^lessons?\s*:?$/i) { print; exit }')
  if [ -n "$near" ]; then refuse "its body has no '## Lesson' section (found '$near'; use '## Lesson')"; fi
  refuse "its body has no '## Lesson' section"
fi

if has_field na; then
  NA=$(field na)
  real "$NA" 8 || refuse "its 'Not automatable because' line needs a reason of at least eight words"
  if real "$(field guard)" 1; then
    refuse "it gives both a Guard and a 'Not automatable because' line; a Lesson is one or the other"
  fi
  echo "lesson: not-automatable — $NA"
  exit 0
fi

# ---- the diff: what this pull request changes, in substance ---------------------------------
# status <TAB> old <TAB> new for every path the diff adds, modifies, renames or copies.
CHANGES=$(g -c diff.renameLimit=100000 diff -z --name-status -M --diff-filter=AMRCT "$B" "$H" 2>/dev/null | perl -0 -ne '
  chomp; if (/^[RC]/) { $s = $_; $o = <>; chomp $o; $n = <>; chomp $n; print "$s\t$o\t$n\n" }
  else { $s = $_; $p = <>; chomp $p; print "$s\t$p\t$p\n" }') || die "could not diff $BASE..$HEAD_REF"
# substance <status> <old> <new> — 0 when the change is more than whitespace or a move.
substance() {
  local d
  case "$1" in
    A) g show "$H:$3" 2>/dev/null | grep '[^[:space:]]' >/dev/null; return ;;
    *) d=$(g diff -w --ignore-blank-lines "$B:$2" "$H:$3" 2>/dev/null) ;;
  esac
  printf '%s\n' "$d" | grep -vE '^(\+\+\+|---)( |$)' | grep -E '^[+-].*[^[:space:]]' >/dev/null
}

missing=""
add_missing() { if [ -z "$missing" ]; then missing="$1"; else missing="$missing; $1"; fi; }

real "$(field principle)" 4 || add_missing "its Lesson has no Principle line (one sentence naming the class of mistake, at least four words)"

GUARD=$(field guard)
GUARD_OK=""
if ! real "$GUARD" 1; then
  add_missing "its Lesson has no Guard line naming a test, lint or gate file"
else
  # Backticked paths if any, else the bare tokens; a trailing :line is dropped.
  paths=$(printf '%s' "$GUARD" | perl -ne 'my @b = /`([^`]+)`/g; @b = split /[\s,;]+/ unless @b; for (@b) { s/:\d+(?::\d+)?$//; s/^\.\///; print "$_\n" if length }')
  why_not=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    row=$(printf '%s\n' "$CHANGES" | awk -F'\t' -v p="$p" '$3 == p' | head -1)
    if [ -z "$row" ]; then why_not="${why_not:+$why_not, }\`$p\` is not added or changed by this pull request"; continue; fi
    if ! is_guard "$p"; then why_not="${why_not:+$why_not, }\`$p\` is not an executable test, lint or gate file"; continue; fi
    st=$(printf '%s' "$row" | cut -f1); old=$(printf '%s' "$row" | cut -f2)
    if ! substance "${st:0:1}" "$old" "$p"; then why_not="${why_not:+$why_not, }\`$p\` only moves or re-spaces (no change in substance)"; continue; fi
    GUARD_OK="$p"; break
  done <<EOF
$paths
EOF
  [ -n "$GUARD_OK" ] || add_missing "its Guard names no executable check the diff changes in substance (${why_not:-no path found})"
fi

real "$(field beforeafter)" 3 || add_missing "its Lesson has no Before/after line (how the guard fails before the fix and passes after)"
real "$(field reach)" 3 || add_missing "its Lesson has no Reach line (the sibling the guard also catches, or the search that found none)"

[ -z "$missing" ] || refuse "$missing"
echo "lesson: complete — guard \`$GUARD_OK\` is in the diff ($WHY_FIX)"
exit 0
