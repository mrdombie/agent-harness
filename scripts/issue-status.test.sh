#!/usr/bin/env bash
# issue-status.test.sh — a status change leaves exactly one lifecycle status on the
# ticket, and nothing in the kit adds a status label any other way.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
IS="$HERE/issue-status.sh"
CHECK="$HERE/check-status-label-writes.sh"

# What the edit leaves: the issue's labels with the recorded edit applied, sorted.
after() { # <n>
  local line cur; line=$(grep "^issue edit $1 " "$GH_LOG" | tail -1)
  cur=$(jq -r '.labels[].name' "$FIX/gh/issue-$1.json")
  printf '%s\n' "$line" | grep -oE -- '--(add|remove)-label [^ ]+' | {
    while read -r op l; do
      case "$op" in --add-label) cur=$(printf '%s\n%s\n' "$cur" "$l") ;;
                    --remove-label) cur=$(printf '%s\n' "$cur" | grep -vxF -- "$l") ;; esac
    done
    printf '%s\n' "$cur" | sed '/^$/d' | sort -u | paste -sd, -
  }
}

echo "--- set: three statuses in, exactly the new one out, in one edit ---"
fix_issue 501 OPEN "status:ready,status:in-review,status:partial,P1,needs:human-approval"
bash "$IS" set 501 status:claimed; want "it succeeds" 0 "$?"
want "one edit" 1 "$(grep -c '^issue edit 501 ' "$GH_LOG")"
want "read fresh first" 1 "$(grep -c '^issue view 501 ' "$GH_LOG")"
want "only claimed is left, other families kept" "P1,needs:human-approval,status:claimed" "$(after 501)"

echo "--- set: the status it already wears, beside another — the other comes off ---"
: > "$GH_LOG"; fix_issue 502 OPEN "status:ready,status:blocked"
bash "$IS" set 502 status:ready
want "blocked removed, ready kept" "status:ready" "$(after 502)"
want_not_in "ready is not re-added" '--add-label status:ready' "$(cat "$GH_LOG")"

echo "--- set: already exactly right — no edit at all ---"
: > "$GH_LOG"; fix_issue 503 OPEN "status:ready,P2"
bash "$IS" set 503 status:ready
want "no edit" 0 "$(grep -c '^issue edit' "$GH_LOG")"

echo "--- set: a decision marker sits beside the status and stays ---"
: > "$GH_LOG"; fix_issue 504 OPEN "status:parked,status:claimed,status:pm-decision"
bash "$IS" set 504 status:ready
want "pm-decision kept, parked and claimed gone" "status:pm-decision,status:ready" "$(after 504)"

echo "--- set: --also puts a marker or the hold on in the same edit; --drop takes one off ---"
: > "$GH_LOG"; fix_issue 505 OPEN "status:claimed,status:in-review"
bash "$IS" set 505 status:parked --also status:pm-decision --also needs:human-approval
want "one edit" 1 "$(grep -c '^issue edit 505 ' "$GH_LOG")"
want "parked + marker + hold" "needs:human-approval,status:parked,status:pm-decision" "$(after 505)"
: > "$GH_LOG"; fix_issue 506 OPEN "status:parked,status:pm-decision"
bash "$IS" set 506 status:ready --drop status:pm-decision
want "the answered question comes off with the move" "status:ready" "$(after 506)"

echo "--- refusals: a marker to set, a second status to --also, an unread ticket ---"
: > "$GH_LOG"; fix_issue 507 OPEN "status:ready"
bash "$IS" set 507 status:pm-decision 2>/dev/null; want "a marker is not a status" 2 "$?"
bash "$IS" set 507 status:claimed --also status:in-review 2>/dev/null; want "two statuses refused" 2 "$?"
bash "$IS" set 999 status:ready 2>/dev/null; want "unreadable labels refuse" 1 "$?"
want "and nothing was edited" 0 "$(grep -c '^issue edit' "$GH_LOG")"

echo "--- mark: adds the marker only ---"
: > "$GH_LOG"; fix_issue 508 OPEN "status:in-review"
bash "$IS" mark 508 status:pm-decision
want "marker added, status untouched" "status:in-review,status:pm-decision" "$(after 508)"
bash "$IS" mark 508 status:ready 2>/dev/null; want "a status is not a marker" 2 "$?"

echo "--- sourced: the functions every step calls come with toolkit-env ---"
: > "$GH_LOG"; fix_issue 509 OPEN "status:ready,status:claimed"
( . "$HERE/toolkit-env.sh" && issue_status_set 509 "$LBL_IN_REVIEW" ) 2>/dev/null
want "sourced set works" "status:in-review" "$(after 509)"

echo "--- the driver's start and park leave one status (the #10638 shapes) ---"
# start: in-review stayed beside claimed. park (machine): in-review stayed beside ready.
want_in "start calls the helper" 'issue_status_set "\$t" "\$LBL_CLAIMED"' "$(cat "$HERE/../driver/steps/start.sh")"
want_in "park calls the helper" 'issue_status_set "\$t" "\$LBL_READY"' "$(cat "$HERE/../driver/steps/park.sh")"

echo "--- guard: the kit itself adds no status label outside the helper ---"
out=$(bash "$CHECK" "$HERE/.." 2>&1); rc=$?
want "the repo is clean" 0 "$rc"

echo "--- guard: a planted status add goes red, in a script and in a skill ---"
P="$FIX/plant"; mkdir -p "$P/scripts" "$P/skills/x" "$P/driver/tests"
cat > "$P/scripts/bad.sh" <<'SH'
swarm_gh issue edit "$t" --repo "$REPO_SLUG" \
  --remove-label "$LBL_CLAIMED" --add-label "$LBL_READY" >/dev/null 2>&1
SH
out=$(bash "$CHECK" "$P" 2>&1); rc=$?
want "a variable status add is caught" 1 "$rc"
want_in "and named across the continuation" 'scripts/bad.sh:1: --add-label "\$LBL_READY"' "$out"
rm "$P/scripts/bad.sh"
printf '```bash\ngh issue edit "$N" --repo "$REPO_SLUG" --add-label status:partial\n```\n' > "$P/skills/x/SKILL.md"
out=$(bash "$CHECK" "$P" 2>&1); want "a literal status in skill prose is caught" 1 "$?"
printf 'gh api "repos/$REPO_SLUG/issues/$n/labels" -f "labels[]=$LBL_PARTIAL"\n' > "$P/skills/x/SKILL.md"
out=$(bash "$CHECK" "$P" 2>&1); want "a gh api labels write is caught" 1 "$?"
printf 'x=$(issue_status_set "$t" "$_to")\n' > "$P/scripts/fine.sh"
printf 'gh issue edit "$N" --repo "$R" --add-label "$HOLD_LABEL"\n' > "$P/skills/x/SKILL.md"
printf 'gh issue edit 1 --add-label status:ready\n' > "$P/driver/tests/t.sh"
out=$(bash "$CHECK" "$P" 2>&1); want "the helper, the hold label and test files pass" 0 "$?"

suite_end "$FAILED"
