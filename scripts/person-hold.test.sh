#!/usr/bin/env bash
# person-hold.test.sh — the labels that mean a person acts next, and a fresh read of whether
# a ticket wears one: which label, who put it on and when.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
jq '.labels.decision = ["status:pm-decision", "status:pm-track"]' "$HARNESS_CFG_PATH" > "$FIX/cfg-decisions.json"
export HARNESS_CFG_PATH="$FIX/cfg-decisions.json"
P="$HERE/person-hold.sh"
wearing() { # <n> <label,label…>
  jq -n --argjson n "$1" --arg l "$2" '{number:$n, state:"OPEN", title:"t", labels:[$l | split(",")[] | select(. != "") | {name:.}]}' > "$FIX/gh/issue-$1.json"
}
put_on() { # <n> <label> <login> <at> — appended to its timeline, oldest first
  local f="$FIX/gh/api-repos_acme_widgets_issues_$1_timeline_per_page_100.json"
  [ -f "$f" ] || printf '[]\n' > "$f"
  jq --arg l "$2" --arg u "$3" --arg at "$4" '. + [{event:"labeled", label:{name:$l}, actor:{login:$u}, created_at:$at}]' "$f" > "$f.t" && mv "$f.t" "$f"
}
check() { : > "$GH_LOG"; bash "$P" check "$@" 2>&1; }

echo "--- a person's hold: exit 1, naming the label, who and when ---"
for l in needs:owner-decision status:blocked needs:human-approval status:pm-track; do
  wearing 501 "status:ready,$l"
  put_on 501 "$l" harness-bot 2026-11-01T08:00:00Z
  put_on 501 "$l" dom 2026-11-01T09:30:00Z
  out=$(check 501); rc=$?
  want "$l: held"                        1 "$rc"
  want_in "  names it from the newest labeled event" "^$l put on by dom at 2026-11-01T09:30:00Z$" "$out"
  rm -f "$FIX/gh/api-repos_acme_widgets_issues_501_timeline_per_page_100.json"
done

echo "--- the labels are read fresh, every time ---"
wearing 502 "status:ready"
check 502 >/dev/null; rc=$?
want "free before the hold"            0 "$rc"
want "  read from GitHub"              1 "$(grep -c '^issue view 502 .*labels' "$GH_LOG")"
wearing 502 "status:ready,status:blocked"; put_on 502 status:blocked dom 2026-11-01T11:00:00Z
out=$(check 502); rc=$?
want "the hold put on since is seen at once" 1 "$rc"
want_in "  and named"                  '^status:blocked put on by dom at 2026-11-01T11:00:00Z$' "$out"
want "  read from GitHub again"        1 "$(grep -c '^issue view 502 .*labels' "$GH_LOG")"

echo "--- the machine's own park states are no person's hold ---"
for l in status:parked status:gated status:batched; do
  wearing 503 "$l"
  out=$(check 503); rc=$?
  want "$l alone: free"                  0 "$rc"
  want "  says nothing"                  "" "$out"
done

echo "--- a failed read is never free ---"
rm -f "$FIX/gh/issue-504.json"
check 504 >/dev/null; rc=$?
want "unread labels: exit 2"           2 "$rc"

echo "--- tickets in another repo's queue (issueRepo): who and when are read there ---"
wearing 505 "status:ready,status:blocked"
put_on 505 status:blocked harness-bot 2026-11-01T08:00:00Z
mv "$FIX/gh/api-repos_acme_widgets_issues_505_timeline_per_page_100.json" "$FIX/gh/api-repos_acme_queue_issues_505_timeline_per_page_100.json"
jq '.issueRepo = "acme/queue"' "$HARNESS_CFG_PATH" > "$FIX/cfg-queue.json"
out=$(HARNESS_CFG_PATH="$FIX/cfg-queue.json" check 505); rc=$?
want "held"                            1 "$rc"
want_in "  named from the queue's timeline" '^status:blocked put on by harness-bot at 2026-11-01T08:00:00Z$' "$out"

echo "--- the lists ---"
lists=$(cd "$REPO" && bash -c '. "$1/coordinator-env.sh" && . "$1/pr-red.sh" && . "$1/issue-status.sh" && . "$1/rebuild.sh" && . "$1/person-hold.sh" \
  && echo "P:$(person_hold_labels | sort | tr "\n" " ")" && echo "R:$(rebuild_person_labels | sort | tr "\n" " ")" \
  && echo "dups:$(person_hold_labels | sort | uniq -d | wc -l | tr -d " ")"' _ "$HERE")
want_in "person_hold_labels: every person's label, once" \
  '^P:needs:human-approval needs:owner-decision status:blocked status:external-blocked status:needs-human status:pm-decision status:pm-track $' "$lists"
want_in "  no label twice"                 '^dups:0$' "$lists"
want_in "rebuild_person_labels: that list plus parked, gated and batched" \
  '^R:needs:human-approval needs:owner-decision status:batched status:blocked status:external-blocked status:gated status:needs-human status:parked status:pm-decision status:pm-track $' "$lists"

suite_end "$FAILED"
