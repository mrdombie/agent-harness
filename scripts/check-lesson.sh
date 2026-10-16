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
# WHAT IS A FIX
#   Any one of:
#     - the pull request carries a label in lesson.fixLabels;
#     - it carries <lesson.classLabelPrefix><class> with the class in
#       lesson.fixClasses (a repair or approved-merge spawn), or --class names one;
#     - it closes an issue whose issue type is in lesson.fixIssueTypes, or whose
#       labels include one in lesson.fixLabels.
#   Anything else passes untouched.
#
# WHAT A FIX OWES
#   A `## Lesson` section in the body (HTML comments and code fences are ignored, so
#   a template's placeholder is not an answer):
#
#     ## Lesson
#     - Principle: <one sentence naming the class of mistake, not the instance>
#     - Guard: `path/to/the.test.ts`
#     - Before/after: <the guard fails on the pre-fix code and passes on the fix>
#     - Reach: <the sibling it also catches, or the search that found none>
#
#   The Guard must name at least one path that the diff ADDS or CHANGES (two dots,
#   base..head, read from commits; a deleted file does not count) and that matches
#   a guard pattern — a test, lint rule or gate file. Or the section carries one line
#   instead:
#
#     Not automatable because <the reason, in words>
#
#   which passes and prints `lesson: not-automatable` so a report can count them.
#
# CONFIG (.claude/harness.json, read at BASE when --base is given, so a pull request
# cannot loosen the check that judges it)
#   lesson.fixLabels        default ["bug", "type:bug"]
#   lesson.fixIssueTypes    default ["Bug"]
#   lesson.fixClasses       default ["repair", "approved-merge"]
#   lesson.classLabelPrefix default "class:"
#   lesson.guardPatterns    default: tests.patterns (or the test-file defaults) plus
#                           lint and gate globs — see GUARD_DEFAULT below. Globs are
#                           matched against the whole path; `*` crosses `/`.
#   HARNESS_GUARD_PATTERNS (space-separated) overrides lesson.guardPatterns.
#
# USAGE
#   check-lesson.sh [--pr <n>] [--event <payload.json>] [--slug <owner/name>]
#                   [--repo <dir>] [--base <ref> [--head <ref>]] [--files-file <f>]
#                   [--body-file <f>|-] [--labels <a,b>] [--closing-file <json>]
#                   [--class <c>]
#   Anything not passed is read from the event payload, then from GitHub (gh).
#   --closing-file is a JSON list: [{"number": 1, "type": "Bug", "labels": ["bug"]}].
#   --files-file lists the paths the diff adds or changes, one per line.
#   Exit 0 = not a fix, or a fix with a complete lesson.
#        1 = a fix whose lesson is missing or incomplete; the first line says what.
#        2 = refused: a ref, file, config or GitHub read that failed — a measurement
#            that could not be made is not a clean one.
set -uo pipefail

PR=""; EVENT=""; SLUG="${GITHUB_REPOSITORY:-}"; REPO=""; BASE=""; HEAD_REF="HEAD"
FILES_FILE=""; BODY_FILE=""; LABELS_ARG=""; LABELS_SET=0; CLOSING_FILE=""; CLASS="${HARNESS_SPAWN_CLASS:-}"
usage() { echo "usage: $(basename "$0") [--pr <n>] [--event <payload>] [--slug <o/n>] [--repo <dir>] [--base <ref> [--head <ref>]] [--files-file <f>] [--body-file <f>|-] [--labels <a,b>] [--closing-file <json>] [--class <c>]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)           PR="${2:-}"; shift 2 ;;
    --event)        EVENT="${2:-}"; shift 2 ;;
    --slug)         SLUG="${2:-}"; shift 2 ;;
    --repo)         REPO="${2:-}"; shift 2 ;;
    --base)         BASE="${2:-}"; shift 2 ;;
    --head)         HEAD_REF="${2:-}"; shift 2 ;;
    --files-file)   FILES_FILE="${2:-}"; shift 2 ;;
    --body-file)    BODY_FILE="${2:-}"; shift 2 ;;
    --labels)       LABELS_ARG="${2:-}"; LABELS_SET=1; shift 2 ;;
    --closing-file) CLOSING_FILE="${2:-}"; shift 2 ;;
    --class)        CLASS="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
die() { echo "check-lesson: $*" >&2; exit 2; }
[ -n "$REPO" ] || REPO=$(git rev-parse --show-toplevel 2>/dev/null || true)

# ---- the event payload -----------------------------------------------------------
EV_BODY=""; EV_HAS_BODY=0; EV_LABELS=""; EV_HAS_LABELS=0
if [ -n "$EVENT" ]; then
  [ -f "$EVENT" ] || die "no event payload '$EVENT'"
  jq -e '.pull_request' "$EVENT" >/dev/null 2>&1 || die "'$EVENT' carries no pull_request — refusing to report clean"
  [ -n "$PR" ] || PR=$(jq -r '.pull_request.number // empty' "$EVENT")
  [ -n "$SLUG" ] || SLUG=$(jq -r '.repository.full_name // empty' "$EVENT")
  EV_BODY=$(jq -r '.pull_request.body // ""' "$EVENT"); EV_HAS_BODY=1
  EV_LABELS=$(jq -r '[.pull_request.labels[]?.name] | join("\n")' "$EVENT"); EV_HAS_LABELS=1
fi

# ---- the config ------------------------------------------------------------------
CFG_REL=".claude/harness.json"
CFG_JSON='{}'
if [ -n "${HARNESS_CFG_PATH:-}" ]; then
  [ -f "$HARNESS_CFG_PATH" ] || die "HARNESS_CFG_PATH '$HARNESS_CFG_PATH' does not exist"
  CFG_JSON=$(cat "$HARNESS_CFG_PATH")
elif [ -n "$BASE" ] && [ -n "$REPO" ]; then
  CFG_JSON=$(git -C "$REPO" show "$BASE:$CFG_REL" 2>/dev/null || echo '{}')
elif [ -n "$REPO" ] && [ -f "$REPO/$CFG_REL" ]; then
  CFG_JSON=$(cat "$REPO/$CFG_REL")
fi
printf '%s' "$CFG_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || die "$CFG_REL is not one JSON object"
# cfg_list <key> <default words> — a list key as newline-separated strings; not a list is a refusal.
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
GUARD_DEFAULT="$TEST_PATTERNS
*.test.* *.spec.* *_test.* */test_*.py */__tests__/*
*eslint* *.semgrep.yml *.semgrep.yaml */lint-rules/* */eslint-rules/*
check-* */check-* gate-* */gate-* */gates/* .github/workflows/*"
if [ -n "${HARNESS_GUARD_PATTERNS:-}" ]; then GUARD_PATTERNS="$HARNESS_GUARD_PATTERNS"
else GUARD_PATTERNS=$(cfg_list lesson.guardPatterns "$(printf '%s' "$GUARD_DEFAULT" | tr '\n' ' ')") || exit 2; fi
GUARD_PATTERNS=$(printf '%s' "$GUARD_PATTERNS" | tr '\n' ' ')
is_guard() { # <path>
  local p
  set -f
  for p in $GUARD_PATTERNS; do
    # shellcheck disable=SC2254
    case "$1" in $p) set +f; return 0 ;; esac
  done
  set +f; return 1
}
in_list() { printf '%s\n' "$2" | grep -qixF -- "$1"; } # <needle> <newline list>

# ---- GitHub, once, for whatever was not passed -------------------------------------
GH_JSON=""
need_gh=0
[ -n "$BODY_FILE" ] || [ "$EV_HAS_BODY" = 1 ] || need_gh=1
[ "$LABELS_SET" = 1 ] || [ "$EV_HAS_LABELS" = 1 ] || need_gh=1
[ -n "$CLOSING_FILE" ] || need_gh=1
if [ "$need_gh" = 1 ]; then
  [ -n "$PR" ] || die "no --pr, event or --body-file/--labels/--closing-file: nothing to read the pull request from"
  [ -n "$SLUG" ] || die "no --slug or GITHUB_REPOSITORY: cannot ask GitHub about pull request $PR"
  # shellcheck disable=SC2016
  GH_JSON=$(gh api graphql -F owner="${SLUG%%/*}" -F name="${SLUG#*/}" -F pr="$PR" -f query='
    query($owner: String!, $name: String!, $pr: Int!) {
      repository(owner: $owner, name: $name) { pullRequest(number: $pr) {
        body
        labels(first: 100) { nodes { name } }
        closingIssuesReferences(first: 50) { nodes { number issueType { name } labels(first: 50) { nodes { name } } } }
      } } }' 2>/dev/null) || die "could not read pull request $PR from GitHub — refusing to report clean"
  printf '%s' "$GH_JSON" | jq -e '.data.repository.pullRequest' >/dev/null 2>&1 \
    || die "GitHub returned no pull request $PR in $SLUG — refusing to report clean"
fi

# Body: --body-file, else fresh from GitHub, else the event (a re-run's event is stale).
if [ -n "$BODY_FILE" ]; then
  if [ "$BODY_FILE" = "-" ]; then BODY=$(cat); else
    [ -f "$BODY_FILE" ] || die "no body file '$BODY_FILE'"; BODY=$(cat "$BODY_FILE"); fi
elif [ -n "$GH_JSON" ]; then BODY=$(printf '%s' "$GH_JSON" | jq -r '.data.repository.pullRequest.body // ""')
else BODY="$EV_BODY"; fi

if [ "$LABELS_SET" = 1 ]; then LABELS=$(printf '%s' "$LABELS_ARG" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep .)
elif [ -n "$GH_JSON" ]; then LABELS=$(printf '%s' "$GH_JSON" | jq -r '.data.repository.pullRequest.labels.nodes[].name')
else LABELS="$EV_LABELS"; fi

if [ -n "$CLOSING_FILE" ]; then
  [ -f "$CLOSING_FILE" ] || die "no closing-issues file '$CLOSING_FILE'"
  CLOSING=$(jq -c '[.[] | {number, type: (.type // null), labels: (.labels // [])}]' "$CLOSING_FILE" 2>/dev/null) \
    || die "'$CLOSING_FILE' is not a JSON list of issues"
else
  CLOSING=$(printf '%s' "$GH_JSON" | jq -c '[.data.repository.pullRequest.closingIssuesReferences.nodes[]
    | {number, type: (.issueType.name // null), labels: [.labels.nodes[].name]}]')
fi

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
if [ -z "$WHY_FIX" ]; then
  # A tab is IFS whitespace: an empty type would collapse and shift the labels into it.
  while IFS='|' read -r num typ lbls; do
    [ -n "$num" ] || continue
    if [ -n "$typ" ] && in_list "$typ" "$FIX_TYPES"; then WHY_FIX="it closes #$num, a $typ"; break; fi
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      if in_list "$l" "$FIX_LABELS"; then WHY_FIX="it closes #$num, labelled '$l'"; break 2; fi
    done <<EOF2
$(printf '%s' "$lbls" | tr ',' '\n')
EOF2
  done <<EOF
$(printf '%s' "$CLOSING" | jq -r '.[] | "\(.number)|\(.type // "" | gsub("[|]"; " "))|\(.labels | map(gsub("[|,]"; " ")) | join(","))"')
EOF
fi
if [ -z "$WHY_FIX" ]; then
  echo "lesson: not a fix pull request (no fix label, fix spawn class or bug-typed closing issue) — nothing owed"
  exit 0
fi

# ---- the lesson section ----------------------------------------------------------------
# key <TAB> value per recognised line; HTML comments and fenced blocks never count.
SECTION=$(printf '%s\n' "$BODY" | tr -d '\r' | perl -0777 -pe 's/<!--.*?-->//gs; s/^[ \t]*(```|~~~).*?^[ \t]*\1[^\n]*$//gms' | perl -ne '
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
# real <text> <min words> — not empty, not a placeholder, at least that many words.
real() {
  local t
  t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//; s/[ .]*$//')
  case "$t" in ""|"<"*">"|tbd|todo|n/a|na|none|-|...|…) return 1 ;; esac
  [ "$(printf '%s' "$t" | wc -w | tr -d ' ')" -ge "$2" ]
}

PASTE='## Lesson
- Principle: <one sentence naming the class of mistake, readable by someone who never saw the bug>
- Guard: `<a test, lint or gate file this pull request adds or changes>`
- Before/after: <the guard fails on the pre-fix code and passes on the fix>
- Reach: <the sibling it also catches, or the search that shows there are none>

(or, only when no machine check can hold it: Not automatable because <the reason>)'
refuse() { # <what is missing>
  echo "lesson: this is a fix pull request ($WHY_FIX), and $1."
  echo
  echo "Every fix ships a lesson: a machine check that would have caught this class of"
  echo "mistake. Add or complete this section in the pull request body:"
  echo
  printf '%s\n' "$PASTE"
  exit 1
}

[ -n "$(field has)" ] || refuse "its body has no '## Lesson' section"

NA=$(field na)
if [ -n "$NA" ] || printf '%s\n' "$SECTION" | grep -q '^na	'; then
  real "$NA" 3 || refuse "its 'Not automatable because' line gives no reason (write at least a few words)"
  echo "lesson: not-automatable — $NA"
  exit 0
fi

# ---- the diff: what this pull request adds or changes ------------------------------------
if [ -n "$BASE" ]; then
  [ -n "$REPO" ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "no git repo at '${REPO:-<cwd>}'"
  B=$(git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}" 2>/dev/null) \
    || die "base '$BASE' does not resolve to a commit — refusing to report clean"
  H=$(git -C "$REPO" rev-parse --verify --quiet "$HEAD_REF^{commit}" 2>/dev/null) \
    || die "head '$HEAD_REF' does not resolve to a commit — refusing to report clean"
  TOUCHED=$(git -C "$REPO" diff --name-only -M --diff-filter=AMRCT "$B" "$H" 2>/dev/null) \
    || die "could not diff $BASE..$HEAD_REF"
elif [ -n "$FILES_FILE" ]; then
  [ -f "$FILES_FILE" ] || die "no files list '$FILES_FILE'"
  TOUCHED=$(cat "$FILES_FILE")
elif [ -n "$PR" ] && [ -n "$SLUG" ]; then
  TOUCHED=$(gh api "repos/$SLUG/pulls/$PR/files" --paginate --jq '.[] | select(.status != "removed") | .filename' 2>/dev/null) \
    || die "could not read the files of pull request $PR"
else
  die "no --base, --files-file or pull request to read the diff from"
fi
in_diff() { printf '%s\n' "$TOUCHED" | grep -qxF -- "$1"; }

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
    if ! in_diff "$p"; then why_not="${why_not:+$why_not, }\`$p\` is not added or changed by this pull request"; continue; fi
    if ! is_guard "$p"; then why_not="${why_not:+$why_not, }\`$p\` is not a test, lint or gate file (patterns: $GUARD_PATTERNS)"; continue; fi
    GUARD_OK="$p"; break
  done <<EOF
$paths
EOF
  [ -n "$GUARD_OK" ] || add_missing "its Guard names no file the diff adds or changes that is a test, lint or gate (${why_not:-no path found})"
fi

real "$(field beforeafter)" 3 || add_missing "its Lesson has no Before/after line (how the guard fails before the fix and passes after)"
real "$(field reach)" 3 || add_missing "its Lesson has no Reach line (the sibling the guard also catches, or the search that found none)"

[ -z "$missing" ] || refuse "$missing"
echo "lesson: complete — guard \`$GUARD_OK\` is in the diff ($WHY_FIX)"
exit 0
