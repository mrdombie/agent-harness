#!/usr/bin/env bash
# person-stop.test.sh — a person's stop wins over the machine. A PR a person put back
# to draft, a Critical a person named since the last hand-off, and a do-not-merge label
# each stop it; the bot's own convert_to_draft, the driver's own comments, a count of
# no Criticals and a stop a person later cleared do not. Unreadable is never clear.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
P="$HERE/person-stop.sh"

cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
ep=""; skip=0
for a in "${@:2}"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in -X|-f|-F|-H|-q|--jq|--method|--input) skip=1 ;; -*) ;; *) [ -n "$ep" ] || ep="$a" ;; esac
done
[ "$1" = api ] || exit 0
f="$FIX/gh/api-$(printf '%s' "$ep" | tr '/?&=' '____').json"
[ -f "$f" ] || exit 1
cat "$f"
GH
chmod +x "$BIN/gh"

R=acme/widgets T=5 N=50
api() { printf '%s\n' "$2" > "$FIX/gh/api-$(printf '%s' "$1" | tr '/?&=' '____').json"; }
PERSON='{"login":"pm","type":"User"}'
BOT='{"login":"github-actions[bot]","type":"Bot"}'
HANDOFF='{"created_at":"2026-10-22T15:41:00Z","user":{"login":"pm","type":"User"},"body":"Handed off at 073c14a — pull request ready, auto-merge armed."}'
world() { # <ticket comments> <pr comments> <timeline> <pr json>
  api "repos/$R/issues/$T/comments?per_page=100" "$1"
  api "repos/$R/issues/$N/comments?per_page=100" "$2"
  api "repos/$R/pulls/$N/reviews?per_page=100" "[]"
  api "repos/$R/issues/$N/timeline?per_page=100" "$3"
  api "repos/$R/pulls/$N" "$4"
}
run() { out=$(bash "$P" check "$@" 2>&1); rc=$?; }
READY='{"number":50,"draft":false,"labels":[]}'
DRAFT='{"number":50,"draft":true,"labels":[]}'

echo "--- a PR a person put back to draft stops it, naming them and their words ---"
world "[$HANDOFF]" \
  '[{"created_at":"2026-10-22T17:32:12Z","user":'"$PERSON"',"body":"Back to draft: must not merge until the key is fixed."}]' \
  '[{"event":"ready_for_review","created_at":"2026-10-22T15:40:53Z","actor":'"$PERSON"'},{"event":"convert_to_draft","created_at":"2026-10-22T17:32:10Z","actor":'"$PERSON"'}]' \
  "$DRAFT"
run "$T" "$N"
want "stopped"                                  "1" "$rc"
want_in "who and when"                          'a person \(pm\) put this back to draft on 2026-10-22' "$out"
want_in "with their last comment"               'must not merge until the key is fixed' "$out"

echo "--- the bot's own convert_to_draft does not count ---"
world "[$HANDOFF]" '[]' \
  '[{"event":"convert_to_draft","created_at":"2026-10-22T17:32:10Z","actor":'"$BOT"'}]' "$DRAFT"
run "$T" "$N"
want "the bot's draft is no person's stop"      "0" "$rc"
want "and says nothing"                         "" "$out"

echo "--- nor does the driver's own account, named in driver.accounts ---"
jq '.driver = {accounts: ["driver-bot-user"]}' "$HARNESS_CFG_PATH" > "$FIX/h.json" && cp "$HARNESS_CFG_PATH" "$FIX/h.orig" && mv "$FIX/h.json" "$HARNESS_CFG_PATH"
world "[$HANDOFF]" '[]' \
  '[{"event":"convert_to_draft","created_at":"2026-10-22T17:32:10Z","actor":{"login":"driver-bot-user","type":"User"}}]' "$DRAFT"
run "$T" "$N"
want "the driver's account is the machine"      "0" "$rc"
cp "$FIX/h.orig" "$HARNESS_CFG_PATH"

echo "--- a person's Critical newer than the last hand-off stops it ---"
world "[$HANDOFF"',{"created_at":"2026-10-22T18:00:00Z","user":'"$PERSON"',"body":"PM review of the data model:\n1. **Critical (lost data):** same-name colleagues fold into one key."}]' \
  '[]' '[]' "$READY"
run "$T" "$N"
want "stopped"                                  "1" "$rc"
want_in "naming the finding and where"          'pm named a blocking finding on #5 on 2026-10-22: 1. \*\*Critical \(lost data\)' "$out"

echo "--- the same Critical before the last hand-off is history ---"
world '[{"created_at":"2026-10-22T13:01:00Z","user":'"$PERSON"',"body":"**Critical (lost data):** same-name colleagues fold."},'"$HANDOFF"']' '[]' '[]' "$READY"
run "$T" "$N"
want "an older Critical the run already took up" "0" "$rc"
run "$T" "$N" --since 2026-10-22T12:00:00Z
want "unless the caller reads from earlier"     "1" "$rc"

echo "--- a count of none, a list of grades, and the driver's own words are not a stop ---"
world "[$HANDOFF"',{"created_at":"2026-10-22T18:00:00Z","user":'"$PERSON"',"body":"Review: 0 Critical, 2 Minor. Critical: 0."},
  {"created_at":"2026-10-22T18:01:00Z","user":'"$PERSON"',"body":"Rule: Critical, Major and Minor all block."},
  {"created_at":"2026-10-22T18:02:00Z","user":'"$PERSON"',"body":"**Parked — ship refused.** critical file:1 Critical (lost data)"},
  {"created_at":"2026-10-22T18:03:00Z","user":'"$PERSON"',"body":"Follow-up: Critical (lost data) seen\n\n<!-- harness:machine -->"},
  {"created_at":"2026-10-22T18:04:00Z","user":'"$BOT"',"body":"Critical: the bot says so"}]' '[]' '[]' "$READY"
run "$T" "$N"
want "none of those stops it"                   "0" "$rc"
want "and nothing is said"                      "" "$out"


echo "--- a later PM answer that names no stop clears it ---"
world "[$HANDOFF"',{"created_at":"2026-10-22T18:00:00Z","user":'"$PERSON"',"body":"**Critical (lost data):** fold."},
  {"created_at":"2026-10-22T19:00:00Z","user":'"$PERSON"',"body":"## PM answer (2026-10-22)\nFixed at abc1234; the key now carries memberUserId. Ship it."}]' '[]' '[]' "$READY"
run "$T" "$N"
want "cleared by the person"                    "0" "$rc"
world "[$HANDOFF"',{"created_at":"2026-10-22T18:00:00Z","user":'"$PERSON"',"body":"**Critical (lost data):** fold."},
  {"created_at":"2026-10-22T19:00:00Z","user":'"$PERSON"',"body":"Thanks, looking."}]' '[]' '[]' "$READY"
run "$T" "$N"
want "but a comment that is not a clearing leaves it open" "1" "$rc"

echo "--- a Cleared or a PM answer never raises, and clears every finding before it ---"
# Live texts from a consuming project, 2026-10-23 (product name swapped): each refused ship by its own clearing.
CLEARED='Cleared: the Critical (a restored row losing the app'"'"'s checks and generation) is fixed in 31a7685c64. `appWords` now counts a row carrying a generationId or checks as the app'"'"'s words, so restoring it again keeps them. Ship.'
LIFT='**PM (merge-first until the release, Dom 22 Oct):** the sign-off hold is off and Dom reviews on UAT. Lifting `needs:human-approval`: merge develop in, push, arm auto-merge, ship. Only a Critical blocks.'
FIND='Critical: erasing one member deletes another'"'"'s facts'
c() { jq -nc --arg at "$1" --arg b "$2" --argjson u "$PERSON" '{created_at: $at, user: $u, body: $b}'; }
world "[$HANDOFF,$(c 2026-10-22T18:00:00Z "$CLEARED")]" '[]' '[]' "$READY"
run "$T" "$N"
want "the #12749 Cleared on its own raises nothing" "0" "$rc"
want "and says nothing"                          "" "$out"
world "[$HANDOFF,$(c 2026-10-22T18:00:00Z "$LIFT")]" '[]' '[]' "$READY"
run "$T" "$N"
want "the #11331 hold-lift note raises nothing"  "0" "$rc"
for m in 'only a Critical blocks' 'no Critical here' 'the Critical is fixed' 'a Critical still blocks' 'fix the Critical in this PR'; do
  world "[$HANDOFF,$(c 2026-10-22T18:00:00Z "Note: $m.")]" '[]' '[]' "$READY"
  run "$T" "$N"
  want "a mention is not a grade: $m"            "0" "$rc"
done
for g in "$FIND" '[Critical] erasing one member' 'Critical — erasing one member' 'grade: Critical, erasing one member' '1. **Critical (lost data):** fold'; do
  world "[$HANDOFF,$(c 2026-10-22T18:00:00Z "$g")]" '[]' '[]' "$READY"
  run "$T" "$N"
  want "an affirmative grade blocks: $g"         "1" "$rc"
done
world "[$HANDOFF,$(c 2026-10-22T18:00:00Z "$FIND"),$(c 2026-10-22T19:00:00Z "$CLEARED")]" '[]' '[]' "$READY"
run "$T" "$N"
want "a Cleared after a Critical clears it"      "0" "$rc"
world "[$HANDOFF,$(c 2026-10-22T18:00:00Z "$CLEARED"),$(c 2026-10-22T19:00:00Z "$FIND")]" '[]' '[]' "$READY"
run "$T" "$N"
want "a Critical after a Cleared blocks again"   "1" "$rc"
want_in "naming the later finding"               "pm named a blocking finding on #5 on 2026-10-22: $FIND" "$out"
world "[$HANDOFF,$(c 2026-10-22T19:00:00Z "  ## **PM answer** (2026-10-22)
The Critical: a restore drops the gate's findings — fixed. Ship.")]" \
  "[$(c 2026-10-22T18:00:00Z "$FIND")]" '[]' "$READY"
run "$T" "$N"
want "a PM answer on the ticket clears the PR's older Critical, and raises none itself" "0" "$rc"

echo "--- a review on the PR counts like a comment ---"
world "[$HANDOFF]" '[]' '[]' "$READY"
api "repos/$R/pulls/$N/reviews?per_page=100" '[{"submitted_at":"2026-10-22T18:00:00Z","user":'"$PERSON"',"body":"Critical: erasing one member deletes another'"'"'s facts."}]'
run "$T" "$N"
want "stopped"                                  "1" "$rc"
want_in "on the review"                         'a review on PR #50' "$out"

echo "--- do-not-merge stops it; the label name is labels.doNotMerge ---"
world "[$HANDOFF]" '[]' '[]' '{"number":50,"draft":false,"labels":[{"name":"do-not-merge"}]}'
run "$T" "$N"
want "stopped"                                  "1" "$rc"
want_in "naming the label"                      '`do-not-merge` label' "$out"
jq '.labels.doNotMerge = "hold:dnm"' "$HARNESS_CFG_PATH" > "$FIX/h.json" && mv "$FIX/h.json" "$HARNESS_CFG_PATH"
run "$T" "$N"
want "another project's name for it is read"   "0" "$rc"
world "[$HANDOFF]" '[]' '[]' '{"number":50,"draft":false,"labels":[{"name":"hold:dnm"}]}'
run "$T" "$N"
want "and stops on its own name"                "1" "$rc"
cp "$FIX/h.orig" "$HARNESS_CFG_PATH"

echo "--- unreadable is never clear ---"
world "[$HANDOFF]" '[]' '[]' "$READY"
rm -f "$FIX/gh/api-repos_acme_widgets_issues_50_timeline_per_page_100.json"
run "$T" "$N"
want "a timeline that cannot be read"           "2" "$rc"
rm -f "$FIX/gh/api-repos_acme_widgets_issues_5_comments_per_page_100.json"
run "$T"
want "ticket comments that cannot be read"      "2" "$rc"

echo "--- the ticket alone, with no pull request yet ---"
world "[$HANDOFF"',{"created_at":"2026-10-22T18:00:00Z","user":'"$PERSON"',"body":"Critical: lost data."}]' '[]' '[]' "$READY"
run "$T"
want "a Critical on the ticket stops it"        "1" "$rc"

echo "--- drafted: the draft stop alone, from one timeline read ---"
dr() { out=$(bash "$P" drafted "$@" 2>&1); rc=$?; }
api "repos/$R/issues/$N/timeline?per_page=100" '[{"event":"convert_to_draft","created_at":"2026-10-22T17:32:10Z","actor":'"$PERSON"'}]'
: > "$GH_LOG"; dr "$N"
want "a person's conversion is a person's draft" "0" "$rc"
want_in "naming who and when"                   'a person \(pm\) put PR #50 back to draft on 2026-10-22' "$out"
want "one read, the timeline"                   "1" "$(grep -c . "$GH_LOG")"
api "repos/$R/issues/$N/timeline?per_page=100" '[{"event":"convert_to_draft","created_at":"2026-10-22T17:32:10Z","actor":'"$BOT"'}]'
dr "$N"
want "the bot's conversion is not"              "1" "$rc"
api "repos/$R/issues/$N/timeline?per_page=100" '[{"event":"convert_to_draft","created_at":"2026-10-22T10:00:00Z","actor":'"$PERSON"'},{"event":"ready_for_review","created_at":"2026-10-22T11:00:00Z","actor":'"$PERSON"'},{"event":"convert_to_draft","created_at":"2026-10-22T12:00:00Z","actor":'"$BOT"'}]'
dr "$N"
want "the last conversion decides"              "1" "$rc"
api "repos/$R/issues/$N/timeline?per_page=100" '[]'
dr "$N"
want "a draft never converted (opened as one) is the machine's" "1" "$rc"
rm -f "$FIX/gh/api-repos_acme_widgets_issues_50_timeline_per_page_100.json"
dr "$N"
want "an unread timeline is unread, never clear" "2" "$rc"

echo "--- every comment the harness posts carries the machine marker ---"
: > "$GH_LOG"
( . "$HERE/toolkit-env.sh" && . "$HERE/gh-batch.sh" && gh_call issue comment 5 --repo "$R" --body "Critical: the driver's own words" ) >/dev/null 2>&1
want_in "a --body comment is marked"            '<!-- harness:machine -->' "$(cat "$GH_LOG")"
printf 'from a file\n' > "$FIX/body.md"; : > "$GH_LOG"
cat > "$BIN/gh-cat" <<'GC'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
prev=""; for a in "$@"; do [ "$prev" = --body-file ] && cat "$a" >> "$GH_LOG"; prev="$a"; done
GC
chmod +x "$BIN/gh-cat"
( . "$HERE/toolkit-env.sh" && . "$HERE/gh-batch.sh" && GH_BATCH_BIN="$BIN/gh-cat" SWARM_GH="$BIN/gh-cat" gh_call pr comment 50 --repo "$R" --body-file "$FIX/body.md" ) >/dev/null 2>&1
want_in "a --body-file comment is marked"       'harness:machine' "$(cat "$GH_LOG")"
want "and the caller's file is left as it was"  "from a file" "$(cat "$FIX/body.md")"
: > "$GH_LOG"
( . "$HERE/toolkit-env.sh" && . "$HERE/gh-batch.sh" && gh_call issue comment 5 --repo "$R" --body $'Approved.\n<!-- approval-head:0123456789012345678901234567890123456789 -->' ) >/dev/null 2>&1
want_in "a closing marker stays the last line"  'harness:machine -->.<!-- approval-head:[0-9a-f]{40} -->$' "$(tr '\n' '.' < "$GH_LOG" | sed 's/\.$//')"
: > "$GH_LOG"
( . "$HERE/toolkit-env.sh" && . "$HERE/gh-batch.sh" && gh_call issue edit 5 --repo "$R" --body "an issue body" ) >/dev/null 2>&1
want_not_in "an issue's own body is not marked" 'harness:machine' "$(cat "$GH_LOG")"

suite_end "$FAILED"
