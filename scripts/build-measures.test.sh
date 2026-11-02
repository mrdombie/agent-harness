#!/usr/bin/env bash
# build-measures.test.sh — the daily figures the build is judged by (the Claude Code
# team's set: merged per day, reverted share, reviews to pass, PR wait time, finding
# tickets, feature lead time) come out right from a planted forge and driver logs,
# one JSON line per day, each figure naming what it counts. A failed or hung read
# writes nothing: an unread figure is unknown, never zero.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); on_exit_keep_status 'rm -rf "$T"'
FAILED=0
ok()  { echo "OK       $1"; }
bad() { echo "MISMATCH $1"; FAILED=1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2', want '$3'"; fi; }

# 2026-11-02T18:00:00Z: the run measures 1 and 2 November.
NOW=1793642400
mkdir -p "$T/state/driver" "$T/fx"

# ---- the forge, answering by what each call asks ----------------------------
cat > "$T/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/calls"
[ -f "$T/mode" ] && case "$(cat "$T/mode")" in
  hang) sleep 20; exit 0 ;;
  fail) echo 'gh: HTTP 502: Bad Gateway' >&2; exit 1 ;;
esac
a="$*" q=""
for x in "$@"; do case "$x" in q=*) q="${x#q=}" ;; esac; done
none='{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}'
# Each search is matched WHOLE: a query with anything doubled or appended answers nothing planned.
case "$a" in
  *search/commits*) case "$q" in "repo:acme/widgets revert committer-date:>=2026-11-0"[12]) cat "$T/fx/commits.json" ;; *) echo "unplanned call: $a" >&2; exit 1 ;; esac ;;
  *"label:"*) cat "$T/fx/findings.json" ;;
  *) case "$q" in
       "repo:acme/widgets is:pr is:merged base:develop merged:2026-11-01T00:00:00Z..2026-11-01T23:59:59Z") cat "$T/fx/merged-1101.json" ;;
       "repo:acme/widgets is:pr is:merged base:develop merged:2026-11-02T00:00:00Z..2026-11-02T23:59:59Z") cat "$T/fx/merged-1102.json" ;;
       "repo:acme/widgets is:pr is:merged base:develop merged:"*T00:00:00Z..*T23:59:59Z) echo "$none" ;;
       "repo:acme/widgets is:pr is:merged Revert in:title merged:>=2026-11-0"[12]) cat "$T/fx/revert-prs.json" ;;
       'repo:acme/widgets is:issue "split from #" in:body created:2026-10-31') cat "$T/fx/parts-1031.json" ;;
       'repo:acme/widgets is:issue "split from #" in:body created:2026-11-01') cat "$T/fx/parts-1101.json" ;;
       'repo:acme/widgets is:issue "split from #" in:body created:2026-11-02') echo "$none" ;;
       *) echo "unplanned call: $a" >&2; exit 1 ;;
     esac ;;
esac
SH
chmod +x "$T/gh"

page() { jq -c '{data:{search:{pageInfo:{hasNextPage:false,endCursor:null},nodes:.}}}'; }
# 1 Nov: three merges. #501 waited 1h, #502 3h, #503 5h; #502 is reverted by a PR, #503 by a direct commit.
jq -n '[{number:501,createdAt:"2026-11-01T09:00:00Z",mergedAt:"2026-11-01T10:00:00Z",mergeCommit:{oid:"aaa111"},reviews:{totalCount:1}},
        {number:502,createdAt:"2026-11-01T09:00:00Z",mergedAt:"2026-11-01T12:00:00Z",mergeCommit:{oid:"bbb222"},reviews:{totalCount:0}},
        {number:503,createdAt:"2026-11-01T10:00:00Z",mergedAt:"2026-11-01T15:00:00Z",mergeCommit:{oid:"ccc333"},reviews:{totalCount:2}}]' | page > "$T/fx/merged-1101.json"
# 2 Nov so far: two merges, 2h and 10h, and the revert PR itself (#601, 1h).
jq -n '[{number:600,createdAt:"2026-11-02T00:00:00Z",mergedAt:"2026-11-02T02:00:00Z",mergeCommit:{oid:"ddd444"},reviews:{totalCount:0}},
        {number:602,createdAt:"2026-11-01T22:00:00Z",mergedAt:"2026-11-02T08:00:00Z",mergeCommit:{oid:"eee555"},reviews:{totalCount:0}},
        {number:601,createdAt:"2026-11-02T08:00:00Z",mergedAt:"2026-11-02T09:00:00Z",mergeCommit:{oid:"fff666"},reviews:{totalCount:0}}]' | page > "$T/fx/merged-1102.json"
# The revert PR names #502 and a ticket (#9000, never a PR); "Revert in:title" also matches a PR that only mentions it.
jq -n '[{number:601,title:"Revert \"feat: thing (#502)\"",body:"Reverts #502\n\nCloses #9000",mergedAt:"2026-11-02T09:00:00Z"},
        {number:600,title:"docs: how to Revert a change",body:"see #501",mergedAt:"2026-11-02T02:00:00Z"}]' | page > "$T/fx/revert-prs.json"
# A direct revert commit naming #503's merge commit by sha only; a commit that merely says "revert" is not one,
# nor is a squash whose body carries an in-branch revert, even one naming a merged PR's merge commit.
jq -n '{total_count:3,items:[{sha:"zzz999",commit:{message:"Revert \"fix: other\"\n\nThis reverts commit ccc333."}},
                           {sha:"yyy888",commit:{message:"fix: stop the revert button double-firing (#501)"}},
                           {sha:"xxx777",commit:{message:"feat: y (#504)\n\n* Revert \"chore: z\"\n\nThis reverts commit aaa111.\n\nsee #501"}}]}' > "$T/fx/commits.json"
# Finding tickets: 4 filed on 1 Nov, 7 on 2 Nov.
echo '{"data":{"d0":{"issueCount":4},"d1":{"issueCount":7}}}' > "$T/fx/findings.json"
# Feature #700: 3 parts filed 31 Oct 10:00–11:00, last closed 1 Nov 08:00 → 22h, done on 1 Nov.
# Feature #800: 2 parts, both closed 2 Nov → 14h and done on 2 Nov. Feature #900: one of 2 parts open — not done.
part() { jq -n --argjson n "$1" --arg c "$2" --arg x "$3" --arg b "$4" '{number:$n,createdAt:$c,closedAt:(if $x=="" then null else $x end),state:(if $x=="" then "OPEN" else "CLOSED" end),stateReason:(if $x=="" then null else "COMPLETED" end),body:$b}'; }
{ part 701 2026-10-31T10:00:00Z 2026-10-31T20:00:00Z 'Part 1 of 3, split from #700 before it was built'
  part 702 2026-10-31T10:30:00Z 2026-11-01T02:00:00Z 'Part 2 of 3, split from #700 before it was built'
  part 703 2026-10-31T11:00:00Z 2026-11-01T08:00:00Z 'Part 3 of 3, split from #700 before it was built'
} | jq -s . | page > "$T/fx/parts-1031.json"
{ part 801 2026-11-01T20:00:00Z 2026-11-02T06:00:00Z 'Part 1 of 2, split from #800 before it was built'
  part 802 2026-11-01T20:00:00Z 2026-11-02T10:00:00Z 'Part 2 of 2, split from #800 before it was built'
  part 901 2026-11-01T20:00:00Z 2026-11-02T10:00:00Z 'Part 1 of 2, split from #900 before it was built'
  part 902 2026-11-01T20:00:00Z ''                     'Part 2 of 2, split from #900 before it was built'
} | jq -s . | page > "$T/fx/parts-1101.json"

# ---- the driver's logs: four shipped runs ----------------------------------
mklog() { mkdir -p "$T/state/driver/$1"; cat > "$T/state/driver/$1/log"; }
mklog 41 <<'L'
2026-11-01T09:00:00Z    review: SHIP after 1 round(s)
2026-11-01T09:01:00Z ✓ #41 shipped: start · size · plan · build · review · record · ship
L
mklog 42 <<'L'
2026-11-01T10:00:00Z ✋ review round 1 of 2: 2 blocking (critical) finding(s) — a.ts:1 — x
2026-11-01T10:20:00Z ✋ review round 2 of 2: 1 blocking (critical) finding(s) — a.ts:2 — y
2026-11-01T10:30:00Z    review: SHIP after 2 pass(es), 1 reviewed by the model
2026-11-01T10:31:00Z ✓ #42 shipped: start · size · plan · build · review · record · ship
2026-11-02T07:00:00Z ✋ review round 1 of 2: 1 blocking (major) finding(s) — b.ts:3 — z
2026-11-02T07:30:00Z    review: SHIP after 5 round(s)
2026-11-02T07:31:00Z ✓ #42 shipped: reenter · repair · fix · review · record · ship
L
mklog 43 <<'L'
2026-11-02T11:00:00Z    review: SHIP after 1 round(s)
2026-11-02T11:01:00Z ✓ #43 shipped: start · size · quick · review · ship
2026-11-02T12:00:00Z ⏸ #43 parked (driver): start refused
L
# A shipped line with no review figure before it counts as shipped, never as a round count.
mklog 44 <<'L'
2026-10-20T11:01:00Z ✓ #44 shipped: start · size · quick · ship
L

run() { # [args…] — sets OUT, ERR, RC
  OUT=$(env T="$T" SWARM_GH="$T/gh" GH_BACKOFF_FILE="$T/backoff" REPO_SLUG=acme/widgets ISSUE_SLUG=acme/widgets \
        INTEGRATION_BRANCH=develop STATE_DIR="$T/state" MEASURES_NOW="$NOW" MEASURES_FEATURE_LOOKBACK_DAYS=1 \
        MEASURES_GH_TIMEOUT="${TO:-20}" bash "$HERE/build-measures.sh" "$@" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}
FILE="$T/state/swarm/measures.jsonl"

echo "--- two days measured from the planted forge and logs ---"
run --days 2
eq "exit" "$RC" 0
[ -z "$ERR" ] || echo "stderr: $ERR"
eq "one line per day" "$(wc -l < "$FILE" | tr -d ' ')" 2
eq "days in order" "$(jq -r .day "$FILE" | tr '\n' ' ')" "2026-11-01 2026-11-02 "
d1() { jq -r "select(.day==\"2026-11-01\") | $1" "$FILE"; }
d2() { jq -r "select(.day==\"2026-11-02\") | $1" "$FILE"; }
eq "1 Nov merged"                "$(d1 .merged.n)" 3
eq "2 Nov merged"                "$(d2 .merged.n)" 3
eq "1 Nov reverted: #502 by PR, #503 by sha" "$(d1 '.reverted.prs|join(",")')" "502,503"
eq "1 Nov reverted share"        "$(d1 .reverted.share)" 0.667
eq "an issue number named in a revert is no PR; a mention is no revert" "$(d2 '.reverted.n')" 0
eq "1 Nov wait median (1,3,5h)"  "$(d1 .waitHours.median)" 3
eq "1 Nov wait p75"              "$(d1 .waitHours.p75)" 4
eq "2 Nov wait median (2,10,1h)" "$(d2 .waitHours.median)" 2
eq "1 Nov approvals per PR"      "$(d1 .approvalsPerPr.mean)" 1
eq "1 Nov runs shipped with a review figure" "$(d1 .reviewsToPass.runs)" 2
eq "1 Nov reviews to pass mean (1,2)" "$(d1 .reviewsToPass.mean)" 1.5
eq "1 Nov share needing 5+"      "$(d1 .reviewsToPass.fivePlusShare)" 0
eq "1 Nov share passing first time" "$(d1 .reviewsToPass.oneRoundShare)" 0.5
eq "2 Nov reviews to pass mean (5,1)" "$(d2 .reviewsToPass.mean)" 3
eq "2 Nov share needing 5+"      "$(d2 .reviewsToPass.fivePlusShare)" 0.5
eq "1 Nov blocking findings per shipped run (0,3)" "$(d1 .findingsPerRun.mean)" 1.5
eq "2 Nov blocking findings per shipped run (1,0)" "$(d2 .findingsPerRun.mean)" 0.5
eq "1 Nov finding tickets"       "$(d1 .findingTickets.n)" 4
eq "2 Nov finding tickets"       "$(d2 .findingTickets.n)" 7
eq "1 Nov features finished"     "$(d1 .featureLeadHours.features)" 1
eq "1 Nov feature lead (31 Oct 10:00 → 1 Nov 08:00)" "$(d1 .featureLeadHours.median)" 22
eq "1 Nov parts per feature"     "$(d1 .featureLeadHours.partsMedian)" 3
eq "2 Nov: #800 done, #900 still has a part open" "$(d2 '[.featureLeadHours.features, .featureLeadHours.median] | join(",")')" "1,14"
eq "today is marked as so far"   "$(d2 .complete)" false
eq "a past day is whole"         "$(d1 .complete)" true

echo "--- every figure names what it counts ---"
missing=$(jq -r 'to_entries[] | select(.value | type == "object") | select((.value.proxy // "") | length < 20) | .key' "$FILE" | sort -u)
eq "figures without a proxy" "${missing:-none}" none
eq "incidents are named as not measured, never zero" "$(d1 '.incidents.n')" null
case "$(d1 .findingTickets.proxy)" in *"wearing fix-after-merge"*) ok "the finding-ticket proxy names its label" ;; *) bad "finding proxy: $(d1 .findingTickets.proxy)" ;; esac
for k in merged reverted reviewsToPass findingsPerRun waitHours approvalsPerPr findingTickets featureLeadHours incidents; do
  [ "$(d1 ".${k}.proxy | length > 0")" = true ] || bad "$k has no proxy"
done
case "$OUT" in *"counts:"*) ok "the printed table names each figure's proxy" ;; *) bad "printed output names no proxy: $OUT" ;; esac

echo "--- a rerun replaces each day's row, never doubles it ---"
cp "$FILE" "$T/before"
run --days 2
eq "rerun exit" "$RC" 0
eq "still one line per day" "$(wc -l < "$FILE" | tr -d ' ')" 2
echo '{"day":"2026-10-30","merged":{"n":9,"proxy":"kept"}}' > "$T/old"; cat "$FILE" >> "$T/old"; cp "$T/old" "$FILE"
run --days 1
eq "one-day run exit" "$RC" 0
eq "an older day is kept, today replaced" "$(jq -r .day "$FILE" | tr '\n' ' ')" "2026-10-30 2026-11-01 2026-11-02 "

echo "--- --baseline also freezes the rows in their own file ---"
run --days 1 --baseline
eq "baseline run exit" "$RC" 0
eq "baseline row" "$(jq -r .day "$T/state/swarm/measures-baseline.jsonl")" 2026-11-02

echo "--- --span prints only one row over the whole window, and writes nothing ---"
cp "$FILE" "$T/before"
run --days 2 --span
eq "span run exit" "$RC" 0
eq "span merged" "$(printf '%s\n' "$OUT" | grep -m1 '^{' | jq -r .merged.n)" 6
eq "span label" "$(printf '%s\n' "$OUT" | grep -m1 '^{' | jq -r .day)" "2026-11-01..2026-11-02"
cmp -s "$FILE" "$T/before" && ok "span wrote nothing" || bad "span changed the file"

echo "--- a failed read writes nothing ---"
cp "$FILE" "$T/before"
echo fail > "$T/mode"; run --days 1
[ "$RC" -ne 0 ] && ok "exit $RC on a failed read" || bad "a failed read exited 0"
cmp -s "$FILE" "$T/before" && ok "file untouched" || bad "a failed read changed the file"
case "$ERR" in *unknown*) ok "says what is unknown" ;; *) bad "stderr: $ERR" ;; esac

echo "--- a hung gh is cut at its time limit ---"
echo hang > "$T/mode"; s=$(date +%s); TO=2 run --days 1; e=$(( $(date +%s) - s ))
[ "$RC" -ne 0 ] && [ "$e" -lt 15 ] && ok "a hung call ended in ${e}s, exit $RC" || bad "hung call: rc=$RC after ${e}s"
cmp -s "$FILE" "$T/before" && ok "file untouched after the hang" || bad "a hung read changed the file"
rm -f "$T/mode"

echo "--- every gh call went through gh_call: none named outside the planted shapes ---"
grep -q 'unplanned call' "$T/err" && bad "an unplanned call" || ok "no unplanned call"

suite_end "$FAILED"
