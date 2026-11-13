#!/usr/bin/env bash
# escape-record.sh — every bad merge gets one record naming the layer that missed it, and one
# ticket to fix that layer's check, not the screen.
#
#   escape-record.sh scan     read new escapes, judge at most escapes.perPass, record, file
#
# An ESCAPE is a merged PR that was then
#   revert   named by a merged PR into the trunk titled Revert (build-measures.sh's search).
#            A commit revert (ship.sh undoing its own verdict commit) is no PR and never counts;
#            nor does a revert whose target is not a merged PR.
#   uat      cited by an issue labelled labels.escaped (default broken-on-uat) that a PERSON
#            opened: approval-kept.sh's rule, a Bot account or a [bot] login is the machine.
#
# Each new one: the merged PR's facts (compare on/off, proof shots, reviews, checks, files),
# one claude -p at low effort with Read/Grep/Glob only (briefs/escape.md), then one line on
# <stateDir>/swarm/escapes.jsonl. A layer outside picture|guideline|review|test|ci, or a fix
# naming only screen files, is recorded "unjudged" and files nothing. A judged one opens one
# issue titled for the layer's check, labelled labels.escapedLayer (default escaped-layer),
# marked <!-- escape-pr: N --> so no host files it twice. Both labels are made on first use.
#
# A PR already on the record, or already marked on a filed issue, is never judged again. The
# rest past escapes.perPass (3) wait for the next pass. A failed read is unknown: nothing is
# judged that pass. A model that fails or runs out records nothing; the next pass retries.
# Shadow (COORDINATOR_SHADOW not 0) reads, prints what it would judge, and writes nothing.
#
# Config: escapes.perPass (3), escapes.lookbackDays (14), labels.escaped, labels.escapedLayer.
# Seams: ESCAPE_CLAUDE, ESCAPE_TIMEOUT_SEC (600), ESCAPES_FILE, SWARM_GH, ESCAPE_NOW.
# Exit: 0 done · 1 a read or write failed · 2 usage.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../swarm/swarm-env.sh" || exit 1
declare -F gh_read >/dev/null 2>&1 || . "$SELF_DIR/gh-batch.sh" || exit 1

say() { echo "escape-record: $*"; }
die() { echo "escape-record: $*" >&2; exit "${2:-1}"; }
[ "${1:-}" = scan ] || die "usage: escape-record.sh scan" 2

num() { case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
PER_PASS=$(num "$(swarm_opt escapes.perPass 3)" 3)
LOOKBACK=$(num "$(swarm_opt escapes.lookbackDays 14)" 14)
LIMIT=$(num "${ESCAPE_TIMEOUT_SEC:-600}" 600)
UAT_LABEL=$(swarm_opt labels.escaped broken-on-uat)
LAYER_LABEL=$(swarm_opt labels.escapedLayer escaped-layer)
TRUNK="${INTEGRATION_BRANCH:-develop}"
LEDGER="${ESCAPES_FILE:-$STATE_DIR/swarm/escapes.jsonl}"
NOW=$(num "${ESCAPE_NOW:-}" "$(date +%s)")
SINCE=$(jq -nr --argjson t "$((NOW - LOOKBACK * 86400))" '$t | strftime("%Y-%m-%d")')
export GH_CALL_TIMEOUT="${GH_CALL_TIMEOUT:-60}"
live() { [ "${COORDINATOR_SHADOW:-1}" = 0 ]; }
if live; then mkdir -p "$(dirname "$LEDGER")" && touch "$LEDGER" || die "cannot write $LEDGER"; fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/escape.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# ---- the candidates: <pr> \t <cause> \t <source #> \t <text naming it>, oldest first ---------
GQL='query($q:String!){search(query:$q,type:ISSUE,first:100){nodes{... on PullRequest{number title body mergedAt}}}}'
gh_read "the merged revert pull requests" api graphql -f query="$GQL" \
  -f q="repo:$REPO_SLUG is:pr is:merged base:$TRUNK Revert in:title merged:>=$SINCE" > "$TMP/reverts.json" || die "nothing judged this pass"
gh_read "the issues labelled $UAT_LABEL" issue list --repo "$ISSUE_SLUG" --state all --label "$UAT_LABEL" \
  --limit 100 --json number,title,body,author,createdAt > "$TMP/uat.json" || die "nothing judged this pass"
gh_read "the escapes already filed" issue list --repo "$ISSUE_SLUG" --state all --label "$LAYER_LABEL" \
  --limit 500 --json number,body > "$TMP/filed.json" || die "nothing judged this pass"

# Candidates keep the order they are named in: the first merged one is the target. A revert that
# cites "Reverts <repo>#N", "PR #N" or /pull/N names only those; else any #N. Its own never.
DEDUP='def ordered: reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end);'
jq -r "$DEDUP"'[.data.search.nodes[]? | select(.title | test("^Revert\\b"; "i"))] | sort_by(.mergedAt)[]
  | .number as $own | ((.body // "") as $b
     | [$b, .title | scan("(?i)(?:reverts\\s+\\S*#|pr\\s*#|/pull/)([0-9]+)") | .[0] | tonumber] | map(select(. != $own)) as $cited
     | if ($cited | length) > 0 then $cited else [$b, .title | scan("#([0-9]+)") | .[0] | tonumber] end
     | map(select(. != $own)) | ordered) as $c
  | select($c | length > 0) | [($c | map(tostring) | join(",")), "revert", $own] | @tsv' "$TMP/reverts.json" > "$TMP/cand.tsv" \
  || die "the revert search could not be read as JSON"
jq -r "$DEDUP"'def human: (.type // "User") != "Bot" and ((.is_bot // false) | not) and ((.login // "") | endswith("[bot]") | not);
  [.[] | select(.author | human)] | sort_by(.createdAt)[]
  | .number as $own | ([(.title + "\n" + (.body // "")) | scan("#([0-9]+)") | .[0] | tonumber] | map(select(. != $own)) | ordered) as $c
  | select($c | length > 0) | [($c | map(tostring) | join(",")), "uat", $own] | @tsv' "$TMP/uat.json" >> "$TMP/cand.tsv" \
  || die "the $UAT_LABEL issues could not be read as JSON"
jq -r '.[] | (.body // "") | scan("<!-- escape-pr: ([0-9]+) -->") | .[0]' "$TMP/filed.json" > "$TMP/filed-prs.txt" 2>/dev/null || : > "$TMP/filed-prs.txt"

seen() { # <pr> — on the record, on a filed issue, or judged earlier this pass
  jq -e --argjson p "$1" 'select(.pr == $p)' "$LEDGER" >/dev/null 2>&1 && return 0
  grep -qx "$1" "$TMP/filed-prs.txt" "$TMP/done.txt" 2>/dev/null
}
: > "$TMP/done.txt"

# ---- the merged PR's facts -------------------------------------------------------------------
facts() { # <pr> → facts JSON; 1 when it is no merged PR, 2 when it could not be read
  local v rc=0
  v=$(gh_read "PR #$1" pr view "$1" --repo "$REPO_SLUG" \
        --json number,title,body,state,mergedAt,files,reviews,statusCheckRollup,comments 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] || { [ "$rc" = "$GH_READ_MISSING" ] && return 1; return 2; }
  jq -ce 'select(.state == "MERGED") | ([.body // "", (.comments // [])[].body // ""] | join("\n")) as $all
    | {pr: .number, title, mergedAt,
       compare: (if (.body // "") | test("[Nn]o picture, compare") then "off"
                 elif (.body // "") | test("Picture, compare") then "on" else "unknown" end),
       screenshots: ([$all | scan("!\\[[^]]*\\]\\(|<img ")] | length),
       reviews: [(.reviews // [])[] | .state],
       checks: [(.statusCheckRollup // [])[] | {name: (.name // .context // "?"), conclusion: (.conclusion // .state // "?")}],
       files: [(.files // [])[] | .path]}' <<<"$v"  || return 1
}

# ---- the judgement ---------------------------------------------------------------------------
check_name() {
  case "$1" in picture) echo "compare step" ;; guideline) echo "screen rules" ;; review) echo "review step" ;;
    test) echo "build proof" ;; ci) echo "CI" ;; esac
}
judge() { # <escape json> → the model's answer on stdout, or fail
  local rc=0
  printf '%s\n' "$1" > "$TMP/escape.json"
  awk -v f="$TMP/escape.json" '/^\{\{ESCAPE\}\}$/ { print "```json"; while ((getline l < f) > 0) print l; print "```"; next } { print }' \
    "$SELF_DIR/../briefs/escape.md" > "$TMP/prompt.md"
  (cd "$MAIN_REPO" && swarm_bounded "$LIMIT" "${ESCAPE_CLAUDE:-claude}" -p --effort low \
     --allowed-tools Read Grep Glob --disallowed-tools Bash Edit Write NotebookEdit WebFetch WebSearch \
     --output-format text < "$TMP/prompt.md") > "$TMP/answer" 2> "$TMP/claude.err" || rc=$?
  [ "$rc" = 0 ] || { say "the model failed on it (exit $rc): $(head -1 "$TMP/claude.err")"; return 1; }
  if grep -q '^[[:space:]]*```json' "$TMP/answer"; then
    sed -n '/^[[:space:]]*```json/,/^[[:space:]]*```[[:space:]]*$/p' "$TMP/answer" | sed '1d;$d'
  else cat "$TMP/answer"; fi
}
# Why an answer is refused, or nothing. A screen file: one the PR changed, or a UI source file;
# a test is a check, never a screen.
refusal() { # <answer> <facts>
  jq -r --argjson f "$2" '
    def screen: . as $p | ($f.files | index($p)) != null
      or (test("\\.(test|spec)\\.|(^|/)(e2e|tests?)/") | not) and test("\\.(tsx|jsx|vue|svelte|css|scss|html)$");
    if type != "object" then "the answer is not a JSON object"
    elif ([.layer] | inside(["picture","guideline","review","test","ci"]) | not) then "layer \(.layer | tostring) is not one of picture, guideline, review, test, ci"
    elif ((.check // "") | type) != "string" or (.check // "") == "" then "no check named"
    elif ((.why // "") | type) != "string" or (.why // "") == "" then "no reason the layer missed it"
    elif ((.fixFiles // []) | type) != "array" or ((.fixFiles // []) | length) == 0 then "the fix names no file"
    elif all(.fixFiles[]; tostring | screen) then "the fix names only screen files (\(.fixFiles | join(", "))), not the check"
    else "" end' <<<"$1" 2>/dev/null || echo "the answer is not JSON"
}
body() { # <record> → the issue body
  jq -r '
    "## What got through\nPR #\(.pr) (\(.facts.title)) merged \(.facts.mergedAt // "?") and was " +
    (if .cause == "revert" then "reverted by PR #\(.source)." else "marked broken on UAT in #\(.source)." end) +
    "\n\n## The layer that missed it: \(.layer) — \(.check)\n\(.why)\n\n## Fix the check, not the screen\n\(.fix // "")\n\n" +
    ([.fixFiles[] | "- `\(.)`"] | join("\n")) +
    "\n\n## What the merged PR had\n- compare: \(.facts.compare)\n- proof screenshots: \(.facts.screenshots)\n- reviews: \(if (.facts.reviews | length) == 0 then "none" else (.facts.reviews | join(", ")) end)\n- checks: \(if (.facts.checks | length) == 0 then "none ran" else ([.facts.checks[] | "\(.name) \(.conclusion)"] | join(", ")) end)\n\nFiled by escape-record.sh.\n\n<!-- escape-pr: \(.pr) -->"' <<<"$1"
}
labels_made=0
make_labels() {
  [ "$labels_made" = 1 ] && return 0
  local l stamp="${LEDGER%.jsonl}.labels"
  for l in "$LAYER_LABEL" "$UAT_LABEL"; do
    grep -qxF "$l" "$stamp" 2>/dev/null && continue
    gh_call label create "$l" --repo "$ISSUE_SLUG" --force --color B60205 \
      --description "escape-record.sh: a merged change that got past the checks" >/dev/null || return 1
    printf '%s\n' "$l" >> "$stamp"
  done
  labels_made=1
}

# ---- the pass --------------------------------------------------------------------------------
judged=0 waiting=0 failed=0
while IFS=$'\t' read -r cands cause source; do
  pr="" f=""
  for c in ${cands//,/ }; do
    seen "$c" && { pr=skip; break; }
    rc=0; f=$(facts "$c") || rc=$?
    [ "$rc" = 0 ] && { pr="$c"; break; }
    [ "$rc" = 1 ] || { pr=unread; break; }
  done
  # A failed read is unknown: trying the next number would blame the wrong PR.
  [ "$pr" = unread ] && { failed=1; say "#$c could not be read; nothing more judged this pass"; break; }
  [ -n "$pr" ] && [ "$pr" != skip ] || continue
  if [ "$judged" -ge "$PER_PASS" ]; then waiting=$((waiting + 1)); continue; fi
  judged=$((judged + 1)); printf '%s\n' "$pr" >> "$TMP/done.txt"
  if ! live; then say "would judge #$pr ($cause, #$source)"; continue; fi
  esc=$(jq -c --arg c "$cause" --argjson s "$source" '{cause: $c, source: $s, facts: .}' <<<"$f")
  ans=$(judge "$esc") || continue
  why=$(refusal "$ans" "$f")
  rec=$(jq -c --argjson f "$f" --arg c "$cause" --argjson s "$source" --arg why "$why" --argjson now "$NOW" '
    {at: ($now | todate), week: ($now | strftime("%G-W%V")), pr: $f.pr, cause: $c, source: $s, facts: $f}
    + (if $why == "" then {verdict: "judged", layer, check, why, fix, fixFiles}
       else {verdict: "unjudged", layer: null, reason: $why} end)' <<<"$ans" 2>/dev/null) \
    || rec=$(jq -nc --argjson f "$f" --arg c "$cause" --argjson s "$source" --argjson now "$NOW" \
         '{at: ($now | todate), week: ($now | strftime("%G-W%V")), pr: $f.pr, cause: $c, source: $s, facts: $f, verdict: "unjudged", layer: null, reason: "the answer is not JSON"}')
  if [ -n "$why" ]; then
    printf '%s\n' "$rec" >> "$LEDGER"; say "#$pr ($cause): unjudged — $why"; continue
  fi
  make_labels || { failed=1; say "#$pr: the labels could not be made; next pass"; break; }
  layer=$(jq -r '.layer' <<<"$rec")
  title="$(check_name "$layer"): $(jq -r '.check' <<<"$rec" | cut -c1-100) (let #$pr through)"
  body "$rec" > "$TMP/body.md"
  url=$(gh_call issue create --repo "$ISSUE_SLUG" --title "$title" --body-file "$TMP/body.md" --label "$LAYER_LABEL") \
    || { failed=1; say "#$pr: the issue could not be opened; next pass"; break; }
  printf '%s\n' "$(jq -c --arg u "$url" '. + {issue: $u}' <<<"$rec")" >> "$LEDGER"
  say "#$pr ($cause): $layer — $url"
done < "$TMP/cand.tsv"
[ "$waiting" = 0 ] || say "$waiting more past this pass's $PER_PASS; the next pass judges them"
[ "$failed" = 0 ] || exit 1
exit 0
